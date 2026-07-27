extends Node2D

const PLAYER_SCENE := preload("res://nodes/game/player.tscn")
const PLATFORM_SCENE := preload("res://nodes/game/moving_platform.tscn")
const TEST_TICKS := 120
const POSITION_TOLERANCE := 0.05

var failures: Array[String] = []
var physics_space: RID

func _ready() -> void:
	if not NetworkTime.is_initial_sync_done():
		var start_error := await NetworkTime.start()
		if start_error != OK:
			push_error("ROLLBACK_RIDING_REGRESSION: failed to initialize NetworkTime")
			get_tree().quit(1)
			return
	NetworkTime.stop()

	var driver := RapierDriver2D.new()
	driver.rollback_physics_space = false
	add_child(driver)
	physics_space = driver.physics_space

	var platform := PLATFORM_SCENE.instantiate() as MovingPlatform
	platform.name = "TestPlatform"
	platform.position = Vector2(300.0, 400.0)
	platform.speed = 150
	platform.distance_x = 200
	platform.distance_y = -200
	add_child(platform)

	var players: Array[Player] = []
	for index in 2:
		var player := PLAYER_SCENE.instantiate() as Player
		player.name = str(101 + index)
		add_child(player)
		players.append(player)

	await get_tree().process_frame
	await get_tree().process_frame

	var platform_top := platform.get_shape_top()
	players[0].global_position = Vector2(platform.global_position.x, 0.0)
	players[0].global_position.y += platform_top - players[0].get_shape_bottom()
	for index in range(1, players.size()):
		players[index].global_position = Vector2(players[index - 1].global_position.x, 0.0)
		players[index].global_position.y += (
			players[index - 1].get_shape_top() - players[index].get_shape_bottom()
		)
	await get_tree().physics_frame
	sync_physics_queries()

	var rewind_state: Array[Dictionary] = []
	var expected_final_state: Array[Dictionary] = []
	for tick in range(1, TEST_TICKS + 1):
		var previous_platform_position := platform.global_position
		var previous_player_positions := capture_player_positions(players)
		run_tick(platform, players, tick)
		verify_stack(
			platform,
			players,
			tick,
			platform.global_position - previous_platform_position,
			previous_player_positions
		)
		if not failures.is_empty():
			break
		if tick == TEST_TICKS / 2:
			rewind_state = capture_player_state(players)

	if not failures.is_empty():
		finish_test(platform, players)
		return

	expected_final_state = capture_player_state(players)
	platform.prepare(TEST_TICKS / 2)
	restore_player_state(players, rewind_state)

	for tick in range(TEST_TICKS / 2 + 1, TEST_TICKS + 1):
		var previous_platform_position := platform.global_position
		var previous_player_positions := capture_player_positions(players)
		run_tick(platform, players, tick)
		verify_stack(
			platform,
			players,
			tick,
			platform.global_position - previous_platform_position,
			previous_player_positions
		)
		if not failures.is_empty():
			break

	if failures.is_empty():
		verify_replay(players, expected_final_state)
		verify_rider_jump(platform, players, TEST_TICKS + 1)

	finish_test(platform, players)

func finish_test(platform: MovingPlatform, players: Array[Player]) -> void:
	if failures.is_empty():
		print("ROLLBACK_RIDING_REGRESSION: PASS (%d ticks + rewind replay)" % TEST_TICKS)
		cleanup_test_nodes(platform, players)
		get_tree().quit()
	else:
		for failure in failures:
			push_error(failure)
		cleanup_test_nodes(platform, players)
		get_tree().quit(1)

func run_tick(platform: MovingPlatform, players: Array[Player], tick: int) -> void:
	platform.prepare(tick)
	for player in players:
		player.prepare(tick)
		player.after_prepare(tick)
	sync_physics_queries()

	NetworkRollback._simulated_nodes.clear()
	NetworkRollback._mutated_nodes.clear()
	for player in players:
		NetworkRollback.notify_simulated(player)

	players[0]._rollback_tick(NetworkTime.ticktime, tick, true)

func sync_physics_queries() -> void:
	RapierPhysicsServer2D.space_step(physics_space, 0.0)
	RapierPhysicsServer2D.space_flush_queries(physics_space)

func capture_player_state(players: Array[Player]) -> Array[Dictionary]:
	var state: Array[Dictionary] = []
	for player in players:
		state.append({
			"position": player.global_position,
			"velocity": player.velocity,
			"impulse_velocity": player.impulse_velocity,
		})
	return state

func capture_player_positions(players: Array[Player]) -> Array[Vector2]:
	var positions: Array[Vector2] = []
	for player in players:
		positions.append(player.global_position)
	return positions

func restore_player_state(players: Array[Player], state: Array[Dictionary]) -> void:
	for index in players.size():
		players[index].global_position = state[index].position
		players[index].velocity = state[index].velocity
		players[index].impulse_velocity = state[index].impulse_velocity
		players[index].force_update_transform()

func cleanup_test_nodes(platform: MovingPlatform, players: Array[Player]) -> void:
	for player in players:
		player.free()
	platform.free()

func verify_replay(players: Array[Player], expected: Array[Dictionary]) -> void:
	for index in players.size():
		var position_error := players[index].global_position.distance_to(expected[index].position)
		var velocity_error := players[index].velocity.distance_to(expected[index].velocity)
		if position_error > POSITION_TOLERANCE or velocity_error > POSITION_TOLERANCE:
			failures.append(
				"Replay diverged for player %s: position %.4f, velocity %.4f" %
				[players[index].name, position_error, velocity_error]
			)

func verify_rider_jump(
	platform: MovingPlatform,
	players: Array[Player],
	tick: int
) -> void:
	var support := players[players.size() - 2]
	var rider := players[players.size() - 1]
	rider.input.jump = true
	run_tick(platform, players, tick)
	rider.input.jump = false

	var separation := support.get_shape_top() - rider.get_shape_bottom()
	if rider.velocity.y >= 0.0 or separation <= POSITION_TOLERANCE:
		failures.append(
			"Rider jump failed: velocity %.4f, separation %.4f" %
			[rider.velocity.y, separation]
		)

func verify_stack(
	platform: MovingPlatform,
	players: Array[Player],
	tick: int,
	platform_motion: Vector2,
	previous_player_positions: Array[Vector2]
) -> void:
	var expected_bottom := platform.get_shape_top()
	for index in players.size():
		var player := players[index]
		var vertical_error := absf(player.get_shape_bottom() - expected_bottom)
		if vertical_error > POSITION_TOLERANCE:
			failures.append(
				"Tick %d player %s vertical drift: %.4f" %
				[tick, player.name, vertical_error]
			)
			return

		var horizontal_error := absf(player.global_position.x - platform.global_position.x)
		if horizontal_error > POSITION_TOLERANCE:
			failures.append(
				"Tick %d player %s horizontal drift: %.4f" %
				[tick, player.name, horizontal_error]
			)
			return

		var player_motion := player.global_position - previous_player_positions[index]
		var motion_error := player_motion.distance_to(platform_motion)
		if motion_error > POSITION_TOLERANCE:
			failures.append(
				"Tick %d player %s amplified carrier motion: %.4f" %
				[tick, player.name, motion_error]
			)
			return

		if player.velocity.length() > POSITION_TOLERANCE:
			failures.append(
				"Tick %d player %s leaked carrier motion into velocity: %.4f" %
				[tick, player.name, player.velocity.length()]
			)
			return

		expected_bottom = player.get_shape_top()
