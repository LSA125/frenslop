extends Node

const CRUSH_PLATFORM_SCENE := preload("res://tests/integration_crush_platform.tscn")
const RIDE_PLATFORM_SCENE := preload("res://tests/integration_ride_platform.tscn")
const GAME_SCENE_PATH := "res://scenes/Game.tscn"
const MAIN_MENU_SCENE_PATH := "res://scenes/MainMenu.tscn"
const DEFAULT_PORT := 19471
const DEFAULT_LATENCY_MS := 50
const TEST_TICKS := 45
const WARMUP_TICKS := 10
const JUMP_TICK_OFFSET := 15
const SETUP_LEAD_TICKS := 32
const SETTLE_TICKS := 34
const STACK_HORIZONTAL_TICKS := 15
const BOTTOM_WALK_TICKS := 18
const CRUSH_TRAVEL_TICKS := 30
const CRUSH_PLATFORM_START_Y := 420.0
const CRUSH_PLATFORM_END_Y := 522.0
const RIDE_PLATFORM_START_Y := 582.0
const RIDE_PLATFORM_END_Y := 482.0
const RIDE_PLATFORM_TRAVEL_X := 100.0
const SCENARIO_STATIONARY := "stationary"
const SCENARIO_BOTTOM_WALK := "bottom_walk"
const SCENARIO_BOTTOM_JUMP := "bottom_jump"
const SCENARIO_PLATFORM_CRUSH := "platform_crush"
const SCENARIO_PLATFORM_RIDE_UP := "platform_ride_up"

var role := ""
var bottom_role := "client"
var scenario := SCENARIO_STATIONARY
var server_port := DEFAULT_PORT
var latency_ms := DEFAULT_LATENCY_MS
var result_file := ""
var inspect_mode := false

var connection_started := false
var game_start_sent := false
var local_game_ready := false
var remote_game_ready := false
var scenario_scheduled := false
var result_sent := false
var result_received := false
var started_at_ms := 0
var client_peer_id := 0

var setup_tick := -1
var begin_tick := -1
var end_tick := -1
var jump_input_tick := -1
var jump_injected := false
var bottom_walk_start_position_x := INF
var max_bottom_walk_distance := 0.0
var jump_start_position_y := INF
var jump_peak_position_y := INF
var last_sample_tick := -1

var host_player: Player
var client_player: Player
var bottom_player: Player
var top_player: Player
var order_manager: RollbackOrderManager
var crush_platform
var ride_platform: MovingPlatform

var sample_count := 0
var max_sag := 0.0
var max_separation := 0.0
var max_horizontal_error := 0.0
var falling_frames := 0
var jump_animation_frames := 0
var unsupported_frames := 0
var not_riding_frames := 0
var ride_detector_connected_frames := 0
var ride_detector_disconnected_frames := 0
var ride_detector_sample_count := 0
var ride_platform_start_position_y := INF
var ride_platform_peak_position_y := INF
var stack_geometry_frames := 0
var rollback_carrier_jump_frames := 0
var rollback_rider_motion_mismatch_frames := 0
var max_rollback_rider_motion_error := 0.0
var rollback_carrier_walk_frames := 0
var rollback_rider_walk_mismatch_frames := 0
var max_rollback_rider_walk_error := 0.0
var rollback_start_tick := -1
var rollback_bottom_start_position := Vector2.ZERO
var rollback_top_start_position := Vector2.ZERO
var worst_sag_tick := -1
var worst_sag_details := ""
var render_sample_count := 0
var max_bottom_render_step := 0.0
var max_top_render_step := 0.0
var max_platform_render_step := 0.0
var max_render_stack_gap_change := 0.0
var max_render_backtrack := 0.0
var render_backtrack_frames := 0
var previous_bottom_render_position := Vector2.ZERO
var previous_top_render_position := Vector2.ZERO
var previous_platform_render_position := Vector2.ZERO
var previous_render_stack_gap := 0.0
var previous_bottom_render_delta := Vector2.ZERO
var previous_top_render_delta := Vector2.ZERO
var previous_platform_render_delta := Vector2.ZERO
var has_previous_render_sample := false
var has_previous_render_delta := false
var max_player_penetration := 0.0
var final_player_penetration := 0.0
var max_platform_penetration := 0.0
var final_platform_penetration := 0.0
var collision_exception_frames := 0
var platform_end_error := INF


func _ready() -> void:
	process_priority = 1000
	role = _arg_value("--integration-role", "")
	bottom_role = _arg_value("--integration-bottom", "client")
	scenario = _arg_value("--integration-scenario", SCENARIO_STATIONARY)
	server_port = int(_arg_value("--integration-port", str(DEFAULT_PORT)))
	latency_ms = int(_arg_value("--integration-latency-ms", str(DEFAULT_LATENCY_MS)))
	result_file = _arg_value("--integration-result-file", "")
	inspect_mode = _arg_value("--integration-inspect", "false") == "true"
	started_at_ms = Time.get_ticks_msec()

	if role != "host" and role != "client":
		_fail_process("missing --integration-role=host|client")
		return
	if bottom_role != "host" and bottom_role != "client":
		_fail_process("invalid --integration-bottom=%s" % bottom_role)
		return
	if scenario not in [
		SCENARIO_STATIONARY,
		SCENARIO_BOTTOM_WALK,
		SCENARIO_BOTTOM_JUMP,
		SCENARIO_PLATFORM_CRUSH,
		SCENARIO_PLATFORM_RIDE_UP,
	]:
		_fail_process("invalid --integration-scenario=%s" % scenario)
		return

	NetworkRollback.enable_diff_states = true
	NetworkTime.before_tick_loop.connect(_on_before_tick_loop)
	NetworkRollback.after_process_tick.connect(_sample_ride_detector_tick)
	NetworkRollback.after_process_tick.connect(_sample_rollback_ride_velocity_tick)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	if inspect_mode:
		_setup_inspection_overlay()
	_trace_event("ready", {
		"bottom_role": bottom_role,
		"latency_ms": latency_ms,
		"role": role,
		"scenario": scenario,
	})


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() - started_at_ms > 9000 and not result_sent:
		_fail_process("production E2E test timed out")
		return
	_update_simulated_latency()

	var current_scene := get_tree().current_scene
	if current_scene == null:
		return

	if not connection_started and current_scene.scene_file_path == MAIN_MENU_SCENE_PATH:
		connection_started = true
		_configure_latency_transport_and_call_production()
		return

	if role == "host" and connection_started and not game_start_sent:
		_try_start_production_game()

	if current_scene.scene_file_path != GAME_SCENE_PATH:
		return

	if not local_game_ready:
		_try_mark_game_ready(current_scene)

	if role == "host" and local_game_ready and remote_game_ready and not scenario_scheduled:
		scenario_scheduled = true
		schedule_scenario.rpc(
			NetworkTime.tick + SETUP_LEAD_TICKS,
			bottom_player.global_position.x
		)

	if begin_tick >= 0 and NetworkTime.tick >= begin_tick + _sample_warmup_ticks():
		_sample_display_state()
		_sample_render_state()

	if role == "client" and end_tick >= 0 and NetworkTime.tick >= end_tick and not result_sent:
		result_sent = true
		submit_client_result.rpc_id(1, JSON.stringify(_get_metrics()))


func _update_simulated_latency() -> void:
	if scenario != SCENARIO_PLATFORM_RIDE_UP or latency_ms == 0 or not connection_started:
		return
	var phase := (Time.get_ticks_msec() - started_at_ms) / 125
	NetworkSimulator.latency_ms = latency_ms if int(phase) % 2 == 0 else latency_ms / 5


func _configure_latency_transport_and_call_production() -> void:
	NetworkSimulator.hostname = "127.0.0.1"
	NetworkSimulator.server_port = server_port
	NetworkSimulator.latency_ms = latency_ms
	NetworkSimulator.packet_loss_percent = 0.0
	NetworkSimulator.use_compression = true
	NetworkSimulator._udp_proxy_port = server_port + 1

	var status: Error
	if role == "host":
		NetworkSimulator._enet_peer.set_bind_ip(NetworkSimulator.hostname)
		status = NetworkSimulator._try_and_host()
	else:
		status = NetworkSimulator._try_and_join()
	if status != OK:
		_fail_process("failed to create %s transport: %s" % [role, error_string(status)])
		return

	if role == "host":
		MultiplayerManager.host_game("E2E Host", NetworkSimulator._enet_peer)
		_trace_event("production_call", {"method": "host_game"})
	else:
		MultiplayerManager.join_game("127.0.0.1", "E2E Client", NetworkSimulator._enet_peer)
		_trace_event("production_call", {"method": "join_game"})
	_trace("PEER_READY")


func _try_start_production_game() -> void:
	if MultiplayerManager.players.size() < 2:
		return
	client_peer_id = _find_client_peer_id()
	if client_peer_id <= 1:
		return
	if not NetworkTime.is_initial_sync_done() or not NetworkTime.is_client_synced(client_peer_id):
		return
	game_start_sent = true
	_trace_event("production_call", {
		"client_peer_id": client_peer_id,
		"method": "start_game",
	})
	MultiplayerManager.start_game()


func _try_mark_game_ready(game: Node) -> void:
	var players_root := game.get_node_or_null("RollbackOrderManager/Players")
	if players_root == null or players_root.get_child_count() < 2:
		return
	order_manager = game.get_node("RollbackOrderManager") as RollbackOrderManager

	client_peer_id = _find_client_peer_id()
	if client_peer_id <= 1:
		return
	host_player = players_root.get_node_or_null("1") as Player
	client_player = players_root.get_node_or_null(str(client_peer_id)) as Player
	if host_player == null or client_player == null:
		return
	if host_player.rollback_sync._history_transmitter == null:
		return
	if client_player.rollback_sync._history_transmitter == null:
		return

	bottom_player = host_player if bottom_role == "host" else client_player
	top_player = client_player if bottom_role == "host" else host_player
	if scenario == SCENARIO_PLATFORM_CRUSH and not is_instance_valid(crush_platform):
		crush_platform = CRUSH_PLATFORM_SCENE.instantiate()
		game.get_node("RollbackOrderManager/MovingObjects").add_child(crush_platform)
	elif scenario == SCENARIO_PLATFORM_RIDE_UP and not is_instance_valid(ride_platform):
		ride_platform = RIDE_PLATFORM_SCENE.instantiate() as MovingPlatform
		game.get_node("RollbackOrderManager/MovingObjects").add_child(ride_platform)
	if not NetworkRollback.after_prepare_tick.is_connected(_capture_rollback_tick_start):
		# RollbackOrderManager is connected, so this records restored positions
		# after production preparation and immediately before the movement phase.
		NetworkRollback.after_prepare_tick.connect(_capture_rollback_tick_start)
	local_game_ready = true
	if role == "host":
		remote_game_ready = false
	else:
		client_game_ready.rpc_id(1, client_peer_id)
	_trace_event("game_ready", {
		"client_peer_id": client_peer_id,
		"players": [host_player.name, client_player.name],
	})


@rpc("any_peer", "reliable")
func client_game_ready(peer_id: int) -> void:
	if role != "host":
		return
	if multiplayer.get_remote_sender_id() != peer_id:
		return
	client_peer_id = peer_id
	remote_game_ready = true
	_trace_event("remote_game_ready", {"client_peer_id": peer_id})


@rpc("authority", "reliable", "call_local")
func schedule_scenario(p_setup_tick: int, platform_x: float) -> void:
	setup_tick = p_setup_tick
	begin_tick = setup_tick + SETTLE_TICKS
	end_tick = begin_tick + (30 if scenario == SCENARIO_PLATFORM_RIDE_UP else TEST_TICKS)
	jump_input_tick = begin_tick + JUMP_TICK_OFFSET
	if scenario == SCENARIO_PLATFORM_CRUSH:
		crush_platform.configure(
			begin_tick,
			CRUSH_TRAVEL_TICKS,
			Vector2(platform_x, CRUSH_PLATFORM_START_Y),
			Vector2(platform_x, CRUSH_PLATFORM_END_Y)
		)
	elif scenario == SCENARIO_PLATFORM_RIDE_UP:
		ride_platform.configure(
			begin_tick,
			CRUSH_TRAVEL_TICKS,
			Vector2(platform_x, RIDE_PLATFORM_START_Y),
			Vector2(
				platform_x + RIDE_PLATFORM_TRAVEL_X,
				RIDE_PLATFORM_END_Y
			)
		)
	_trace_event("scenario_scheduled", {
		"begin_tick": begin_tick,
		"end_tick": end_tick,
		"jump_input_tick": jump_input_tick,
		"setup_tick": setup_tick,
	})


func _on_before_tick_loop() -> void:
	if setup_tick < 0 or not is_instance_valid(top_player) or not is_instance_valid(bottom_player):
		return

	if scenario != SCENARIO_PLATFORM_RIDE_UP and top_player.input.is_multiplayer_authority():
		var move_action := "MoveRight" if top_player.global_position.x < bottom_player.global_position.x else "MoveLeft"
		if NetworkTime.tick == setup_tick:
			Input.action_press(move_action)
			Input.action_press("Jump")
			_trace_event("stack_input_started", {
				"move_action": move_action,
				"player": top_player.name,
				"tick": NetworkTime.tick,
			})
		elif NetworkTime.tick == setup_tick + 1:
			Input.action_release("Jump")
		elif NetworkTime.tick == setup_tick + STACK_HORIZONTAL_TICKS:
			Input.action_release("MoveLeft")
			Input.action_release("MoveRight")
			_trace_event("stack_input_finished", {
				"player": top_player.name,
				"tick": NetworkTime.tick,
			})

	if scenario == SCENARIO_BOTTOM_WALK:
		if not bottom_player.input.is_multiplayer_authority():
			return
		if NetworkTime.tick == begin_tick:
			bottom_walk_start_position_x = bottom_player.global_position.x
			Input.action_press("MoveRight")
		elif NetworkTime.tick == begin_tick + BOTTOM_WALK_TICKS:
			Input.action_release("MoveRight")
		return
	if scenario != SCENARIO_BOTTOM_JUMP or not bottom_player.input.is_multiplayer_authority():
		return
	if NetworkTime.tick == jump_input_tick:
		Input.action_press("Jump")
		jump_injected = true
		_trace_event("jump_input_pressed", {
			"player": bottom_player.name,
			"tick": NetworkTime.tick,
		})
	elif NetworkTime.tick == jump_input_tick + 1:
		Input.action_release("Jump")
		_trace_event("jump_input_released", {
			"player": bottom_player.name,
			"tick": NetworkTime.tick,
		})


func _sample_display_state() -> void:
	if not is_instance_valid(top_player) or not is_instance_valid(bottom_player):
		return
	var display_tick := NetworkRollback.display_tick
	if display_tick == last_sample_tick or display_tick >= end_tick:
		return
	last_sample_tick = display_tick

	var rider := bottom_player if scenario == SCENARIO_PLATFORM_RIDE_UP else top_player
	var expected_support: Node2D = (
		ride_platform if scenario == SCENARIO_PLATFORM_RIDE_UP else bottom_player
	)
	var vertical_gap := _shape_bottom(rider) - _shape_top(expected_support)
	var horizontal_gap := rider.global_position.x - expected_support.global_position.x
	var support := _ride_detector_support(rider)
	sample_count += 1
	max_sag = maxf(max_sag, vertical_gap)
	max_separation = maxf(max_separation, -vertical_gap)
	max_horizontal_error = maxf(max_horizontal_error, absf(horizontal_gap))
	if scenario == SCENARIO_BOTTOM_WALK and not is_inf(bottom_walk_start_position_x):
		max_bottom_walk_distance = maxf(
			max_bottom_walk_distance,
			absf(bottom_player.global_position.x - bottom_walk_start_position_x)
		)
	if rider.animations.animation == &"fall":
		falling_frames += 1
	if rider.animations.animation == &"jump":
		jump_animation_frames += 1
	if support != expected_support:
		unsupported_frames += 1
		not_riding_frames += 1
	if scenario == SCENARIO_BOTTOM_JUMP:
		if display_tick < jump_input_tick and is_inf(jump_start_position_y):
			jump_start_position_y = bottom_player.global_position.y
		if display_tick >= jump_input_tick:
			jump_peak_position_y = minf(jump_peak_position_y, bottom_player.global_position.y)
	if absf(horizontal_gap) <= 2.0 and absf(vertical_gap) <= 8.0:
		stack_geometry_frames += 1
	if vertical_gap >= max_sag:
		worst_sag_tick = display_tick
		worst_sag_details = (
			"gap=%.3f horizontal=%.3f grounded=%s riding=%s support=%s animation=%s"
		) % [
			vertical_gap,
			horizontal_gap,
			rider.grounded,
			support == expected_support,
			support.get_path() if support else "none",
			rider.animations.animation,
		]

	if scenario == SCENARIO_PLATFORM_CRUSH:
		_sample_crush_collisions()

	_trace_event("sample", {
		"bottom_input_tick": _last_known_input(bottom_player.rollback_sync),
		"bottom_node_position": _vector_json(bottom_player.global_position),
		"bottom_physics_position": _vector_json(_physics_position(bottom_player)),
		"bottom_state_tick": bottom_player.rollback_sync.get_last_known_state(),
		"bottom_velocity": _vector_json(bottom_player.velocity),
		"display_tick": display_tick,
		"horizontal_gap": horizontal_gap,
		"network_tick": NetworkTime.tick,
		"role": role,
		"support": str(support.get_path()) if support else "none",
		"top_animation": str(rider.animations.animation),
		"top_grounded": rider.grounded,
		"top_input_tick": _last_known_input(top_player.rollback_sync),
		"top_is_riding": support == expected_support,
		"top_node_position": _vector_json(top_player.global_position),
		"top_physics_position": _vector_json(_physics_position(top_player)),
		"top_state_tick": top_player.rollback_sync.get_last_known_state(),
		"top_velocity": _vector_json(top_player.velocity),
		"vertical_gap": vertical_gap,
	})


func _sample_render_state() -> void:
	if not is_instance_valid(top_player) or not is_instance_valid(bottom_player):
		return
	if NetworkRollback.display_tick >= end_tick:
		return

	var bottom_position := bottom_player.global_position
	var top_position := top_player.global_position
	var stack_gap := _shape_bottom(top_player) - _shape_top(bottom_player)
	var platform_position := Vector2.ZERO
	if is_instance_valid(crush_platform):
		platform_position = crush_platform.global_position
	elif is_instance_valid(ride_platform):
		platform_position = ride_platform.global_position
		stack_gap = _shape_bottom(bottom_player) - _shape_top(ride_platform)

	if has_previous_render_sample:
		var bottom_delta := bottom_position - previous_bottom_render_position
		var top_delta := top_position - previous_top_render_position
		var platform_delta := platform_position - previous_platform_render_position
		max_bottom_render_step = maxf(max_bottom_render_step, bottom_delta.length())
		max_top_render_step = maxf(max_top_render_step, top_delta.length())
		max_render_stack_gap_change = maxf(
			max_render_stack_gap_change,
			absf(stack_gap - previous_render_stack_gap)
		)
		if is_instance_valid(crush_platform) or is_instance_valid(ride_platform):
			max_platform_render_step = maxf(
				max_platform_render_step, platform_delta.length()
			)

		if has_previous_render_delta:
			_record_backtrack(previous_bottom_render_delta, bottom_delta)
			_record_backtrack(previous_top_render_delta, top_delta)
			if is_instance_valid(crush_platform) or is_instance_valid(ride_platform):
				_record_backtrack(previous_platform_render_delta, platform_delta)
		previous_bottom_render_delta = bottom_delta
		previous_top_render_delta = top_delta
		previous_platform_render_delta = platform_delta
		has_previous_render_delta = true
	else:
		has_previous_render_sample = true

	previous_bottom_render_position = bottom_position
	previous_top_render_position = top_position
	previous_platform_render_position = platform_position
	previous_render_stack_gap = stack_gap
	render_sample_count += 1


func _record_backtrack(previous_delta: Vector2, current_delta: Vector2) -> void:
	if previous_delta.length() < 0.25 or current_delta.length() < 0.25:
		return
	if previous_delta.dot(current_delta) >= 0.0:
		return
	var backtrack := minf(previous_delta.length(), current_delta.length())
	max_render_backtrack = maxf(max_render_backtrack, backtrack)
	render_backtrack_frames += 1


func _sample_crush_collisions() -> void:
	if not is_instance_valid(crush_platform):
		return
	var player_penetration := _penetration_depth(
		bottom_player.collision_shape.global_position,
		_shape_half_extents(bottom_player),
		top_player.collision_shape.global_position,
		_shape_half_extents(top_player)
	)
	var platform_center: Vector2 = crush_platform.collision_shape.global_position
	var platform_half_extents: Vector2 = crush_platform.get_shape_half_extents()
	var platform_penetration := maxf(
		_penetration_depth(
			platform_center,
			platform_half_extents,
			bottom_player.collision_shape.global_position,
			_shape_half_extents(bottom_player)
		),
		_penetration_depth(
			platform_center,
			platform_half_extents,
			top_player.collision_shape.global_position,
			_shape_half_extents(top_player)
		)
	)
	final_player_penetration = player_penetration
	final_platform_penetration = platform_penetration
	max_player_penetration = maxf(max_player_penetration, player_penetration)
	max_platform_penetration = maxf(max_platform_penetration, platform_penetration)
	platform_end_error = absf(crush_platform.global_position.y - CRUSH_PLATFORM_END_Y)
	if (
		not bottom_player.get_collision_exceptions().is_empty()
		or not top_player.get_collision_exceptions().is_empty()
	):
		collision_exception_frames += 1


func _penetration_depth(
	center_a: Vector2,
	half_extents_a: Vector2,
	center_b: Vector2,
	half_extents_b: Vector2
) -> float:
	var overlap_x := (
		half_extents_a.x + half_extents_b.x - absf(center_a.x - center_b.x)
	)
	var overlap_y := (
		half_extents_a.y + half_extents_b.y - absf(center_a.y - center_b.y)
	)
	if overlap_x <= 0.0 or overlap_y <= 0.0:
		return 0.0
	return minf(overlap_x, overlap_y)


func _get_metrics() -> Dictionary:
	return {
		"bottom_role": bottom_role,
		"falling_frames": falling_frames,
		"jump_animation_frames": jump_animation_frames,
		"jump_injected": jump_injected,
		"jump_peak_position_y": jump_peak_position_y,
		"jump_start_position_y": jump_start_position_y,
		"latency_ms": latency_ms,
		"collision_exception_frames": collision_exception_frames,
		"final_platform_penetration": final_platform_penetration,
		"final_player_penetration": final_player_penetration,
		"max_horizontal_error": max_horizontal_error,
		"max_bottom_render_step": max_bottom_render_step,
		"max_bottom_walk_distance": max_bottom_walk_distance,
		"max_platform_penetration": max_platform_penetration,
		"max_platform_render_step": max_platform_render_step,
		"max_player_penetration": max_player_penetration,
		"max_render_backtrack": max_render_backtrack,
		"max_render_stack_gap_change": max_render_stack_gap_change,
		"max_sag": max_sag,
		"max_separation": max_separation,
		"max_top_render_step": max_top_render_step,
		"not_riding_frames": not_riding_frames,
		"platform_end_error": platform_end_error,
		"render_backtrack_frames": render_backtrack_frames,
		"render_sample_count": render_sample_count,
		"rollback_carrier_jump_frames": rollback_carrier_jump_frames,
		"rollback_carrier_walk_frames": rollback_carrier_walk_frames,
		"rollback_rider_motion_mismatch_frames": rollback_rider_motion_mismatch_frames,
		"rollback_rider_walk_mismatch_frames": rollback_rider_walk_mismatch_frames,
		"max_rollback_rider_motion_error": max_rollback_rider_motion_error,
		"max_rollback_rider_walk_error": max_rollback_rider_walk_error,
		"ride_detector_connected_frames": ride_detector_connected_frames,
		"ride_detector_disconnected_frames": ride_detector_disconnected_frames,
		"ride_detector_sample_count": ride_detector_sample_count,
		"ride_platform_peak_position_y": ride_platform_peak_position_y,
		"ride_platform_start_position_y": ride_platform_start_position_y,
		"sample_count": sample_count,
		"scenario": scenario,
		"stack_geometry_frames": stack_geometry_frames,
		"unsupported_frames": unsupported_frames,
		"worst_sag_details": worst_sag_details,
		"worst_sag_tick": worst_sag_tick,
	}


func _sample_warmup_ticks() -> int:
	return 0 if scenario == SCENARIO_PLATFORM_RIDE_UP else WARMUP_TICKS


func _sample_ride_detector_tick(tick: int) -> void:
	if (
		scenario != SCENARIO_PLATFORM_RIDE_UP
		or tick < begin_tick
		or tick >= end_tick
		or not is_instance_valid(bottom_player)
		or not is_instance_valid(ride_platform)
	):
		return
	bottom_player.force_update_transform()
	ride_detector_sample_count += 1
	if is_inf(ride_platform_start_position_y):
		ride_platform_start_position_y = ride_platform.global_position.y
	ride_platform_peak_position_y = minf(
		ride_platform_peak_position_y, ride_platform.global_position.y
	)
	if order_manager.ride_supports.get(bottom_player) == ride_platform:
		ride_detector_connected_frames += 1
		return
	ride_detector_disconnected_frames += 1


func _capture_rollback_tick_start(tick: int) -> void:
	if not is_instance_valid(bottom_player) or not is_instance_valid(top_player):
		return
	rollback_start_tick = tick
	rollback_bottom_start_position = bottom_player.global_position
	rollback_top_start_position = top_player.global_position


func _sample_rollback_ride_velocity_tick(tick: int) -> void:
	if (
		scenario == SCENARIO_BOTTOM_WALK
		and rollback_start_tick == tick
		and is_instance_valid(bottom_player)
		and is_instance_valid(top_player)
	):
		var carrier_motion_x := (
			bottom_player.global_position.x - rollback_bottom_start_position.x
		)
		if absf(carrier_motion_x) > 0.05:
			var rider_motion_x := (
				top_player.global_position.x - rollback_top_start_position.x
			)
			var walk_error := absf(rider_motion_x - carrier_motion_x)
			rollback_carrier_walk_frames += 1
			max_rollback_rider_walk_error = maxf(
				max_rollback_rider_walk_error, walk_error
			)
			if walk_error > 0.1:
				rollback_rider_walk_mismatch_frames += 1
		return
	if (
		scenario != SCENARIO_BOTTOM_JUMP
		or not NetworkRollback.is_rollback()
		or rollback_start_tick != tick
		or not is_instance_valid(bottom_player)
		or not is_instance_valid(top_player)
	):
		return
	var carrier_motion := bottom_player.global_position - rollback_bottom_start_position
	if carrier_motion.y >= -0.05:
		return
	var rider_motion := top_player.global_position - rollback_top_start_position
	rollback_carrier_jump_frames += 1
	var motion_error := absf(rider_motion.y - carrier_motion.y)
	max_rollback_rider_motion_error = maxf(
		max_rollback_rider_motion_error, motion_error
	)
	if motion_error > 0.1:
		rollback_rider_motion_mismatch_frames += 1


func _ride_detector_support(player: Player) -> Node2D:
	return order_manager.ride_supports.get(player) as Node2D


func _shape_top(body: Node2D) -> float:
	var collision_shape := body.get_node("CollisionShape2D") as CollisionShape2D
	return collision_shape.global_position.y - _shape_half_extents(body).y


func _shape_bottom(body: Node2D) -> float:
	var collision_shape := body.get_node("CollisionShape2D") as CollisionShape2D
	return collision_shape.global_position.y + _shape_half_extents(body).y


func _shape_half_extents(body: Node2D) -> Vector2:
	var collision_shape := body.get_node("CollisionShape2D") as CollisionShape2D
	var rectangle := collision_shape.shape as RectangleShape2D
	return rectangle.size * 0.5 if rectangle else Vector2.ZERO


@rpc("any_peer", "reliable")
func submit_client_result(metrics_json: String) -> void:
	if role != "host" or multiplayer.get_remote_sender_id() != client_peer_id:
		return
	result_received = true
	var metrics: Dictionary = JSON.parse_string(metrics_json)
	if scenario == SCENARIO_PLATFORM_RIDE_UP:
		# The test-only platform is local to each peer rather than multiplayer-spawned.
		# Assert its detector identity on the host that owns the reported node path.
		metrics = _get_metrics()
	var reported_metrics := JSON.stringify(metrics)
	_trace("RESULT_JSON %s" % reported_metrics)
	_trace_event("result", metrics)
	result_ack.rpc_id(client_peer_id)
	await get_tree().create_timer((latency_ms * 2 + 100) / 1000.0).timeout
	get_tree().quit()


@rpc("authority", "reliable")
func result_ack() -> void:
	if role != "client":
		return
	_trace("RESULT_ACK")
	await get_tree().process_frame
	get_tree().quit()


func _find_client_peer_id() -> int:
	for player_id in MultiplayerManager.players.keys():
		var id := int(player_id)
		if id != 1:
			return id
	for peer_id in multiplayer.get_peers():
		if peer_id != 1:
			return peer_id
	return 0


func _physics_position(player: Player) -> Vector2:
	var transform := PhysicsServer2D.body_get_state(
		player.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM
	) as Transform2D
	return transform.origin


func _last_known_input(sync: RollbackSynchronizer) -> int:
	if sync._inputs.is_empty():
		return -1
	return sync._inputs.get_latest_tick()


func _vector_json(value: Vector2) -> Dictionary:
	return {"x": value.x, "y": value.y}


func _setup_inspection_overlay() -> void:
	get_window().title = "Production E2E: %s / %s / %dms" % [role, scenario, latency_ms]
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	var label := Label.new()
	label.position = Vector2(12.0, 12.0)
	label.text = "%s | bottom: %s | %s | %d ms one-way" % [
		role.to_upper(), bottom_role, scenario, latency_ms
	]
	label.add_theme_font_size_override("font_size", 20)
	layer.add_child(label)


func _on_connection_failed() -> void:
	_fail_process("production MultiplayerManager connection failed")


func _on_server_disconnected() -> void:
	if not result_sent and not result_received:
		_fail_process("server disconnected")


func _fail_process(message: String) -> void:
	_trace_event("harness_error", {"message": message})
	push_error("PRODUCTION_E2E HARNESS_ERROR %s: %s" % [role, message])
	get_tree().quit(2)


func _trace_event(event: String, fields: Dictionary = {}) -> void:
	var record := fields.duplicate(true)
	record["event"] = event
	record["process_role"] = role
	record["time_ms"] = Time.get_ticks_msec() - started_at_ms
	_trace(JSON.stringify(record))


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
