extends Node2D

const PLAYER_SCENE := preload("res://nodes/game/player.tscn")
const PLATFORM_SCENE := preload("res://nodes/game/moving_platform.tscn")

const TEST_TICKS := 100
const WARMUP_TICKS := 8
const JUMP_TICK_OFFSET := 20
const DEFAULT_PORT := 19471
const DEFAULT_LATENCY_MS := 50
const SCENARIO_STATIONARY := "stationary"
const SCENARIO_BOTTOM_JUMP := "bottom_jump"

@onready var world: Node2D = $World
@onready var players_root: Node2D = $World/Players
var physics_driver: RapierDriver2D

var role := ""
var bottom_role := "host"
var server_port := DEFAULT_PORT
var latency_ms := DEFAULT_LATENCY_MS
var result_file := ""
var scenario := SCENARIO_STATIONARY
var inspect_mode := false

var client_peer_id := 0
var platform: MovingPlatform
var host_player: Player
var client_player: Player
var bottom_player: Player
var top_player: Player

var world_ready := false
var remote_world_ready := false
var configure_sent := false
var build_tick := -1
var building_world := false
var begin_tick := -1
var end_tick := -1
var started := false
var result_sent := false
var started_at_ms := 0
var sample_count := 0
var max_sag := 0.0
var max_separation := 0.0
var max_horizontal_error := 0.0
var falling_frames := 0
var unsupported_frames := 0
var not_riding_frames := 0
var jump_injected := false
var worst_sag_tick := -1
var worst_sag_details := ""

func _ready() -> void:
	# Run this node's visual assertion after Player and TickInterpolator _process().
	process_priority = 1000
	role = _arg_value("--integration-role", "")
	bottom_role = _arg_value("--integration-bottom", "host")
	server_port = int(_arg_value("--integration-port", str(DEFAULT_PORT)))
	latency_ms = int(_arg_value("--integration-latency-ms", str(DEFAULT_LATENCY_MS)))
	result_file = _arg_value("--integration-result-file", "")
	scenario = _arg_value("--integration-scenario", SCENARIO_STATIONARY)
	inspect_mode = _arg_value("--integration-inspect", "false") == "true"
	started_at_ms = Time.get_ticks_msec()
	_trace("READY role=%s bottom=%s port=%d latency_ms=%d scenario=%s" % [
		role, bottom_role, server_port, latency_ms, scenario
	])

	# Create the driver after the first trace so native initialization failures are
	# distinguishable from script/scene parsing failures in the paired harness.
	physics_driver = RapierDriver2D.new()
	physics_driver.name = "RapierDriver2D"
	physics_driver.physics_factor = 1
	add_child(physics_driver)
	_trace("PHYSICS_DRIVER_READY")

	if role != "host" and role != "client":
		_fail_process("missing --integration-role=host|client")
		return
	if bottom_role != "host" and bottom_role != "client":
		_fail_process("invalid --integration-bottom=%s" % bottom_role)
		return
	if scenario != SCENARIO_STATIONARY and scenario != SCENARIO_BOTTOM_JUMP:
		_fail_process("invalid --integration-scenario=%s" % scenario)
		return
	if inspect_mode:
		_setup_inspection_overlay()

	# The regression specifically covers the bandwidth-saving mode used by the game.
	NetworkRollback.enable_diff_states = true
	NetworkRollback.enabled = false
	NetworkTime.before_tick.connect(_on_before_network_tick)

	_isolate_game_multiplayer_manager()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func(): _fail_process("client connection failed"))
	multiplayer.server_disconnected.connect(func(): _fail_process("server disconnected"))

	_configure_latency_peer()


func _isolate_game_multiplayer_manager() -> void:
	# This scene owns its peer lifecycle. The game lobby autoload assumes its
	# Steam/player dictionaries were initialized and must not handle test peers.
	var bindings := [
		[multiplayer.connected_to_server, MultiplayerManager._on_connected_to_server],
		[multiplayer.connection_failed, MultiplayerManager._on_connection_failed],
		[multiplayer.server_disconnected, MultiplayerManager._on_server_disconnected],
		[multiplayer.peer_connected, MultiplayerManager._on_peer_connected],
		[multiplayer.peer_disconnected, MultiplayerManager._on_peer_disconnected],
	]
	for binding in bindings:
		var source: Signal = binding[0]
		var callback: Callable = binding[1]
		if source.is_connected(callback):
			source.disconnect(callback)

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() - started_at_ms > 9000 and not result_sent:
		_fail_process("integration test timed out")
		return

	if role == "host" and client_peer_id > 0 and not configure_sent:
		if NetworkTime.is_initial_sync_done() and NetworkTime.is_client_synced(client_peer_id):
			configure_sent = true
			configure_world.rpc(client_peer_id, bottom_role, NetworkTime.tick + 12)

	if role == "host" and world_ready and remote_world_ready and begin_tick < 0:
		begin_at.rpc(NetworkTime.tick + 12)

	if role == "client" and started and NetworkTime.tick >= begin_tick + WARMUP_TICKS:
		_sample_display_state(NetworkRollback.display_tick)
	if role == "client" and started and not result_sent and NetworkTime.tick >= end_tick:
		result_sent = true
		submit_client_result.rpc_id(1, JSON.stringify(_get_metrics()))

func _setup_inspection_overlay() -> void:
	get_window().title = "Riding integration: %s / %s / %dms" % [role, scenario, latency_ms]
	var label := Label.new()
	label.position = Vector2(12.0, 12.0)
	label.text = "%s | bottom: %s | %s | %d ms one-way" % [
		role.to_upper(), bottom_role, scenario, latency_ms
	]
	label.add_theme_font_size_override("font_size", 20)
	add_child(label)

func _configure_latency_peer() -> void:
	NetworkSimulator.hostname = "127.0.0.1"
	NetworkSimulator.server_port = server_port
	NetworkSimulator.latency_ms = latency_ms
	NetworkSimulator.packet_loss_percent = 0.0
	NetworkSimulator.use_compression = false
	NetworkSimulator._udp_proxy_port = server_port + 1

	var status: Error
	if role == "host":
		# Binding ENet to every interface can trigger a Windows Firewall/UAC prompt.
		# This test is local-only, so constrain both ENet and the latency proxy to
		# loopback before creating either socket.
		NetworkSimulator._enet_peer.set_bind_ip(NetworkSimulator.hostname)
		status = NetworkSimulator._try_and_host()
	else:
		status = NetworkSimulator._try_and_join()
	if status != OK:
		_fail_process("failed to create %s peer: %s" % [role, error_string(status)])
		return

	multiplayer.multiplayer_peer = NetworkSimulator._enet_peer
	print("RIDING_INTEGRATION %s peer ready port=%d latency_ms=%d bottom=%s" % [
		role, server_port, latency_ms, bottom_role
	])
	_trace("PEER_READY")

func _on_peer_connected(peer_id: int) -> void:
	if role == "host":
		client_peer_id = peer_id

func _on_connected_to_server() -> void:
	if role == "client":
		client_peer_id = multiplayer.get_unique_id()

@rpc("authority", "reliable", "call_local")
func configure_world(
	p_client_peer_id: int,
	p_bottom_role: String,
	p_build_tick: int
) -> void:
	client_peer_id = p_client_peer_id
	bottom_role = p_bottom_role
	build_tick = p_build_tick

func _build_world() -> void:
	platform = PLATFORM_SCENE.instantiate() as MovingPlatform
	platform.name = "TestPlatform"
	platform.position = Vector2(400.0, 420.0)
	platform.speed = 0
	platform.distance_x = 0
	platform.distance_y = 0
	world.add_child(platform)

	host_player = PLAYER_SCENE.instantiate() as Player
	host_player.name = "1"
	host_player.position = Vector2(400.0, 300.0)
	players_root.add_child(host_player)

	client_player = PLAYER_SCENE.instantiate() as Player
	client_player.name = str(client_peer_id)
	client_player.position = Vector2(400.0, 260.0)
	players_root.add_child(client_player)

	bottom_player = host_player if bottom_role == "host" else client_player
	top_player = client_player if bottom_role == "host" else host_player

	# Player and MovingPlatform finish their rollback setup one frame after ready.
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	world_ready = true
	if role == "client":
		client_world_ready.rpc_id(1)
	print("RIDING_INTEGRATION %s world ready tick=%d" % [role, NetworkTime.tick])
	_trace("WORLD_READY tick=%d" % NetworkTime.tick)

@rpc("any_peer", "reliable")
func client_world_ready() -> void:
	if role == "host" and multiplayer.get_remote_sender_id() == client_peer_id:
		remote_world_ready = true

@rpc("authority", "reliable", "call_local")
func begin_at(p_begin_tick: int) -> void:
	begin_tick = p_begin_tick
	end_tick = begin_tick + TEST_TICKS
	print("RIDING_INTEGRATION %s scheduled begin=%d end=%d" % [role, begin_tick, end_tick])
	_trace("SCHEDULED begin=%d end=%d" % [begin_tick, end_tick])

func _on_before_network_tick(_delta: float, tick: int) -> void:
	if not world_ready and not building_world and build_tick >= 0 and tick >= build_tick:
		building_world = true
		_build_world()
	if started or begin_tick < 0 or tick < begin_tick:
		if started:
			_drive_scenario_input(tick)
		return
	_prime_world(tick)

func _drive_scenario_input(tick: int) -> void:
	if scenario != SCENARIO_BOTTOM_JUMP or not bottom_player.input.is_multiplayer_authority():
		return
	var should_jump := tick == begin_tick + JUMP_TICK_OFFSET
	bottom_player.input.jump = should_jump
	if should_jump:
		jump_injected = true
		_trace("JUMP_INJECTED tick=%d player=%s" % [tick, bottom_player.name])

func _prime_world(tick: int) -> void:
	platform.restore_to_tick(tick)
	platform.force_update_transform()
	_place_stack()

	for player in [bottom_player, top_player]:
		player.velocity = Vector2.ZERO
		player.impulse_velocity = Vector2.ZERO
		player.input.movement = 0.0
		player.input.jump = false
		player.input.action = false
		player.prepare(tick)
		player.force_update_transform()

	RapierPhysicsServer2D.space_step(physics_driver.physics_space, 0.0)
	RapierPhysicsServer2D.space_flush_queries(physics_driver.physics_space)

	for player in [host_player, client_player]:
		_seed_player_history(player, tick)
		var interpolator := player.get_node("TickInterpolator") as TickInterpolator
		interpolator.teleport()
	platform.get_node("TickInterpolator").teleport()

	# PhysicsDriver already cached this fresh tick before this callback. Replace it
	# with the deliberately aligned starting state; rfind() loads this last tag.
	physics_driver._snapshot_space(tick)
	Player._last_coordinated_tick = -1
	NetworkRollback.enabled = true
	started = true
	print("RIDING_INTEGRATION %s started tick=%d bottom=%s top=%s" % [
		role, tick, bottom_player.name, top_player.name
	])
	_trace("STARTED tick=%d bottom=%s top=%s" % [tick, bottom_player.name, top_player.name])

func _place_stack() -> void:
	bottom_player.global_position = Vector2(platform.global_position.x, 0.0)
	bottom_player.global_position.y = platform.get_shape_top() - (
		bottom_player.get_shape_bottom() - bottom_player.global_position.y
	)
	top_player.global_position = Vector2(bottom_player.global_position.x, 0.0)
	top_player.global_position.y = bottom_player.get_shape_top() - (
		top_player.get_shape_bottom() - top_player.global_position.y
	)
	bottom_player.force_update_transform()
	top_player.force_update_transform()

func _seed_player_history(player: Player, tick: int) -> void:
	var sync := player.rollback_sync
	sync.process_settings()
	var state := _PropertySnapshot.extract(sync._get_recorded_state_props())
	var input_state := _PropertySnapshot.extract(sync._get_recorded_input_props())
	sync._states.set_snapshot(tick, state)
	sync._inputs.set_snapshot(tick, input_state)
	sync._history_transmitter._latest_state_tick = tick
	sync._history_transmitter._earliest_input_tick = tick
	sync._history_recorder.set_latest_state_tick(tick)

func _sample_display_state(tick: int) -> void:
	if not is_instance_valid(top_player):
		return

	var vertical_gap := top_player.get_shape_bottom() - bottom_player.get_shape_top()
	var horizontal_gap := top_player.global_position.x - bottom_player.global_position.x
	top_player.force_update_transform()
	bottom_player.force_update_transform()
	var support := top_player.find_support_below([
		host_player, client_player, platform
	])
	sample_count += 1
	max_sag = maxf(max_sag, vertical_gap)
	max_separation = maxf(max_separation, -vertical_gap)
	max_horizontal_error = maxf(max_horizontal_error, absf(horizontal_gap))
	if top_player.animations.animation == &"fall":
		falling_frames += 1
	if support != bottom_player:
		unsupported_frames += 1
	if not top_player.is_riding:
		not_riding_frames += 1
	if vertical_gap >= max_sag:
		worst_sag_tick = tick
		worst_sag_details = (
			"gap=%.3f horizontal=%.3f grounded=%s riding=%s support=%s animation=%s"
		) % [
			vertical_gap,
			horizontal_gap,
			top_player.grounded,
			top_player.is_riding,
			support.get_path() if support else "none",
			top_player.animations.animation,
		]

func _get_metrics() -> Dictionary:
	return {
		"scenario": scenario,
		"bottom_role": bottom_role,
		"latency_ms": latency_ms,
		"sample_count": sample_count,
		"max_sag": max_sag,
		"max_separation": max_separation,
		"max_horizontal_error": max_horizontal_error,
		"falling_frames": falling_frames,
		"unsupported_frames": unsupported_frames,
		"not_riding_frames": not_riding_frames,
		"jump_injected": jump_injected,
		"worst_sag_tick": worst_sag_tick,
		"worst_sag_details": worst_sag_details,
	}

@rpc("any_peer", "reliable")
func submit_client_result(metrics_json: String) -> void:
	if role != "host" or multiplayer.get_remote_sender_id() != client_peer_id:
		return
	print("RIDING_INTEGRATION RESULT_JSON %s" % metrics_json)
	_trace("RESULT_JSON %s" % metrics_json)
	result_ack.rpc_id(client_peer_id)
	# Give the latency proxy time to forward the reliable result before the host
	# tears down its ENet peer.
	await get_tree().create_timer((latency_ms * 2 + 100) / 1000.0).timeout
	get_tree().quit()

@rpc("authority", "reliable")
func result_ack() -> void:
	if role != "client":
		return
	print("RIDING_INTEGRATION CLIENT RESULT_ACK bottom=%s" % bottom_role)
	_trace("RESULT_ACK bottom=%s" % bottom_role)
	await get_tree().process_frame
	get_tree().quit()

func _fail_process(message: String) -> void:
	_trace("HARNESS_ERROR %s" % message)
	push_error("RIDING_INTEGRATION HARNESS_ERROR %s: %s" % [role, message])
	get_tree().quit(2)

func _trace(message: String) -> void:
	if result_file.is_empty():
		return
	var file := FileAccess.open(result_file, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(result_file, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(message)
	file.flush()

func _arg_value(key: String, fallback: String) -> String:
	var prefix := key + "="
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix)
	return fallback
