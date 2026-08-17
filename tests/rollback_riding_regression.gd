extends Node2D

const PLAYER_SCENE := preload("res://nodes/game/player.tscn")
const PLATFORM_SCENE := preload("res://nodes/game/moving_platform.tscn")
const ORDER_MANAGER_SCRIPT := preload("res://scripts/game/RollbackOrderManager.gd")

const TEST_TICKS := 120
const REWIND_TICK := 60
const SUPPORT_GAP_TOLERANCE := 4.1
const PUSH_TOLERANCE := 0.1
const REPLAY_TOLERANCE := 0.05
const VELOCITY_TOLERANCE := 0.1

var failures: Array[String] = []
var physics_driver: RapierDriver2D
var order_manager
var players_root: Node2D
var moving_objects_root: Node2D
var platform: MovingPlatform
var players: Array[Player] = []
var saw_up_right := false
var saw_down_left := false
var saw_second_up_right := false


func _ready() -> void:
	if not NetworkTime.is_initial_sync_done():
		var start_error := await NetworkTime.start()
		if start_error != OK:
			failures.append("Failed to initialize NetworkTime")
			_finish_test()
			return
	NetworkTime.stop()

	# Add the driver first so its process-tick step/flush callback runs before
	# RollbackOrderManager's ordered movement, matching Game.tscn's signal order.
	physics_driver = RapierDriver2D.new()
	physics_driver.name = "RapierDriver2D"
	physics_driver.physics_factor = 1
	physics_driver.rollback_physics_space = true
	add_child(physics_driver)

	order_manager = ORDER_MANAGER_SCRIPT.new()
	order_manager.name = "RollbackOrderManager"
	players_root = Node2D.new()
	players_root.name = "Players"
	order_manager.add_child(players_root)
	moving_objects_root = Node2D.new()
	moving_objects_root.name = "MovingObjects"
	order_manager.add_child(moving_objects_root)
	add_child(order_manager)

	platform = PLATFORM_SCENE.instantiate() as MovingPlatform
	platform.name = "DiagonalPlatform"
	platform.position = Vector2(300.0, 400.0)
	platform.speed = 150
	platform.distance_x = 200
	platform.distance_y = -200
	moving_objects_root.add_child(platform)

	for index in 2:
		var player := PLAYER_SCENE.instantiate() as Player
		player.name = str(101 + index)
		players_root.add_child(player)
		players.append(player)

	await get_tree().process_frame
	await get_tree().process_frame
	_place_stack()
	_reset_player_motion()
	_sync_physics_queries()

	var rewind_state: Array[Dictionary] = []
	for tick in range(1, TEST_TICKS + 1):
		var previous_platform_position := platform.global_position
		var previous_player_positions := _capture_player_positions()
		_run_rollback_tick(tick)
		_verify_stack_tick(tick, previous_platform_position, previous_player_positions, true)
		if not failures.is_empty():
			_finish_test()
			return
		if tick == REWIND_TICK:
			rewind_state = _capture_player_state()

	_verify_full_diagonal_cycle()
	if not failures.is_empty():
		_finish_test()
		return

	var expected_final_state := _capture_player_state()
	_restore_tick(REWIND_TICK, rewind_state)
	for tick in range(REWIND_TICK + 1, TEST_TICKS + 1):
		var previous_platform_position := platform.global_position
		var previous_player_positions := _capture_player_positions()
		_run_rollback_tick(tick)
		_verify_stack_tick(tick, previous_platform_position, previous_player_positions, false)
		if not failures.is_empty():
			_finish_test()
			return

	_verify_replay(expected_final_state)
	_verify_bottom_player_carries_top(TEST_TICKS + 1)
	_verify_top_rider_jump(TEST_TICKS + 2)
	if failures.is_empty():
		_verify_platform_push(70)
	if failures.is_empty():
		_verify_platform_side_contact(70)
	if failures.is_empty():
		_verify_floor_recovery(70)
	_finish_test()


func _run_rollback_tick(tick: int) -> void:
	NetworkRollback._simulated_nodes.clear()
	NetworkRollback._mutated_nodes.clear()
	var expected_platform_start := platform._get_position_for_tick(tick - 1)
	NetworkRollback.after_prepare_tick.emit(tick)
	if platform not in order_manager.ordered_bodies:
		_fail("Tick %d platform was missing from the ordered body sweep" % tick)
		return
	if not platform.global_position.is_equal_approx(expected_platform_start):
		_fail(
			"Tick %d platform was not restored to the ordered sweep start" % tick
		)
		return
	NetworkRollback.on_process_tick.emit(tick)


func _place_stack() -> void:
	var bottom := players[0]
	var top := players[1]
	bottom.global_position = Vector2(
		platform.global_position.x,
		_shape_top(platform) - _shape_bottom_offset(bottom)
	)
	top.global_position = Vector2(
		bottom.global_position.x,
		_shape_top(bottom) - _shape_bottom_offset(top)
	)
	for player in players:
		player.force_update_transform()


func _reset_player_motion() -> void:
	for player in players:
		player.velocity = Vector2.ZERO
		player.impulse_velocity = Vector2.ZERO
		player.continuous_velocity = Vector2.ZERO
		player.tick_velocity = Vector2.ZERO
		player.emitted_velocity = Vector2.ZERO
		player.carrier_velocity = Vector2.ZERO
		player.input.movement = 0.0
		player.input.jump = false
		player.input.action_held = false
		player.input.equip_held = false


func _restore_tick(tick: int, state: Array[Dictionary]) -> void:
	platform.restore_to_tick(tick)
	platform.force_update_transform()
	for index in players.size():
		var player := players[index]
		player.global_position = state[index]["position"]
		player.velocity = state[index]["velocity"]
		player.impulse_velocity = state[index]["impulse_velocity"]
		player.facing_right = state[index]["facing_right"]
		player.continuous_velocity = Vector2.ZERO
		player.tick_velocity = Vector2.ZERO
		player.emitted_velocity = Vector2.ZERO
		player.carrier_velocity = Vector2.ZERO
		player.grounded = false
		player.input.movement = 0.0
		player.input.jump = false
		player.input.action_held = false
		player.input.equip_held = false
		player.force_update_transform()
	_sync_physics_queries()


func _capture_player_state() -> Array[Dictionary]:
	var state: Array[Dictionary] = []
	for player in players:
		state.append({
			"position": player.global_position,
			"velocity": player.velocity,
			"impulse_velocity": player.impulse_velocity,
			"facing_right": player.facing_right,
		})
	return state


func _capture_player_positions() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	for player in players:
		positions.append(player.global_position)
	return positions


func _verify_stack_tick(
	tick: int,
	previous_platform_position: Vector2,
	previous_player_positions: Array[Vector2],
	record_directions: bool
) -> void:
	var platform_motion := platform.global_position - previous_platform_position
	if record_directions:
		if platform_motion.x > 0.0 and platform_motion.y < 0.0:
			if saw_down_left:
				saw_second_up_right = true
			else:
				saw_up_right = true
		elif platform_motion.x < 0.0 and platform_motion.y > 0.0:
			saw_down_left = true

	var expected_support: Node2D = platform
	for index in players.size():
		var player := players[index]
		if order_manager.ride_supports.get(player) != expected_support:
			_fail(
				"Tick %d player %s selected %s instead of support %s" % [
					tick,
					player.name,
					order_manager.ride_supports.get(player),
					expected_support,
				]
			)
			return
		var support_gap := _shape_bottom(player) - _shape_top(expected_support)
		if absf(support_gap) > SUPPORT_GAP_TOLERANCE:
			_fail(
				"Tick %d player %s left its support by %.4f px while platform moved %s" %
				[tick, player.name, support_gap, platform_motion]
			)
			return

		var player_motion := player.global_position - previous_player_positions[index]
		var horizontal_motion_error := absf(player_motion.x - platform_motion.x)
		var vertical_motion_error := absf(player_motion.y - platform_motion.y)
		if (
			horizontal_motion_error > PUSH_TOLERANCE
			or vertical_motion_error > SUPPORT_GAP_TOLERANCE
		):
			_fail(
				(
					"Tick %d player %s did not inherit diagonal motion: expected %s, "
					+ "got %s (tick velocity %s, carrier %s, emitted %s)"
				) % [
					tick,
					player.name,
					platform_motion,
					player_motion,
					player.tick_velocity,
					player.carrier_velocity,
					player.emitted_velocity,
				]
			)
			return

		var expected_carrier_velocity := platform_motion / NetworkTime.ticktime
		if player.emitted_velocity.distance_to(expected_carrier_velocity) > VELOCITY_TOLERANCE:
			_fail(
				"Tick %d player %s emitted %s instead of carrier velocity %s" %
				[tick, player.name, player.emitted_velocity, expected_carrier_velocity]
			)
			return

		if player.velocity.length() > VELOCITY_TOLERANCE:
			_fail(
				"Tick %d player %s leaked carrier motion into persistent velocity: %s" %
				[tick, player.name, player.velocity]
			)
			return
		expected_support = player


func _verify_full_diagonal_cycle() -> void:
	if not saw_up_right:
		_fail("Diagonal regression never exercised upward-right platform motion")
	elif not saw_down_left:
		_fail("Diagonal regression never exercised downward-left platform motion")
	elif not saw_second_up_right:
		_fail("Diagonal regression did not cross both platform reversals")


func _verify_replay(expected: Array[Dictionary]) -> void:
	for index in players.size():
		var player := players[index]
		var position_error := player.global_position.distance_to(expected[index]["position"])
		var velocity_error := player.velocity.distance_to(expected[index]["velocity"])
		if position_error > REPLAY_TOLERANCE or velocity_error > VELOCITY_TOLERANCE:
			_fail(
				"Replay diverged for player %s: position %.4f, velocity %.4f" %
				[player.name, position_error, velocity_error]
			)
			return


func _verify_top_rider_jump(tick: int) -> void:
	var support := players[0]
	var rider := players[1]
	rider.input.jump = true
	_run_rollback_tick(tick)
	rider.input.jump = false
	var separation := _shape_top(support) - _shape_bottom(rider)
	if rider.velocity.y >= 0.0 or separation <= REPLAY_TOLERANCE:
		_fail(
			"Top rider failed to jump away: velocity %.4f, separation %.4f" %
			[rider.velocity.y, separation]
		)


func _verify_bottom_player_carries_top(tick: int) -> void:
	var cases := [
		{"direction": 1.0, "rider_offset": Vector2.ZERO},
		{"direction": -1.0, "rider_offset": Vector2.ZERO},
		{"direction": 1.0, "rider_offset": Vector2(15.0, 1.0)},
		{"direction": -1.0, "rider_offset": Vector2(-15.0, 1.0)},
	]
	for case_index in cases.size():
		_place_stack()
		_reset_player_motion()
		var bottom := players[0]
		var top := players[1]
		var direction: float = cases[case_index]["direction"]
		top.global_position += cases[case_index]["rider_offset"] as Vector2
		bottom.input.movement = direction
		for player in players:
			player.force_update_transform()
		_sync_physics_queries()
		for step in 6:
			var bottom_start := bottom.global_position
			var top_start := top.global_position
			_run_rollback_tick(tick + case_index * 6 + step)
			var bottom_motion := bottom.global_position - bottom_start
			var top_motion := top.global_position - top_start
			if order_manager.ride_supports.get(top) != bottom:
				_fail("Moving top player stopped riding the bottom player")
				return
			if absf(top_motion.x - bottom_motion.x) > PUSH_TOLERANCE:
				_fail(
					(
						"Bottom movement case %d step %d diverged: bottom %s, top %s, "
						+ "bottom carrier/emitted/residual %s/%s/%s, "
						+ "top carrier/emitted/residual %s/%s/%s"
					) % [
						case_index,
						step,
						bottom_motion,
						top_motion,
						bottom.carrier_velocity,
						bottom.emitted_velocity,
						bottom.tick_velocity,
						top.carrier_velocity,
						top.emitted_velocity,
						top.tick_velocity,
					]
				)
				return
		bottom.input.movement = 0.0


func _verify_platform_push(tick: int) -> void:
	platform.restore_to_tick(tick - 1)
	platform.force_update_transform()
	var pusher := players[0]
	var pushed := players[1]
	var half_player_width := (
		(pusher.collision_shape.shape as RectangleShape2D).size.x * 0.5
	)
	var player_y := _shape_top(platform) - _shape_bottom_offset(pusher)
	pusher.global_position = Vector2(
		platform.global_position.x - half_player_width,
		player_y - 1.0
	)
	pushed.global_position = Vector2(platform.global_position.x + half_player_width, player_y)
	_reset_player_motion()
	pusher.input.movement = 1.0
	for player in players:
		player.force_update_transform()
	_sync_physics_queries()

	var previous_platform_position := platform.global_position
	var previous_pusher_position := pusher.global_position
	var previous_pushed_position := pushed.global_position
	NetworkRollback._simulated_nodes.clear()
	NetworkRollback._mutated_nodes.clear()
	NetworkRollback.after_prepare_tick.emit(tick)
	for player in players:
		if not player.grounded:
			_fail("Side contact hid the floor from player %s" % player.name)
			return
		if order_manager.ride_supports.get(player) != platform:
			_fail("Side contact was misclassified as support for player %s" % player.name)
			return
	NetworkRollback.on_process_tick.emit(tick)
	var platform_motion := platform.global_position - previous_platform_position
	var pusher_motion := pusher.global_position - previous_pusher_position
	var pushed_motion := pushed.global_position - previous_pushed_position
	if (
		absf(pusher_motion.y - platform_motion.y) > PUSH_TOLERANCE
		or absf(pushed_motion.y - platform_motion.y) > PUSH_TOLERANCE
	):
		_fail(
			"Player push added vertical motion: platform %s, pusher %s, pushed %s" %
			[platform_motion, pusher_motion, pushed_motion]
		)
		return
	var expected_pushed_motion_x := (
		platform_motion.x + pusher.PUSH_FORCE * NetworkTime.ticktime
	)
	if absf(pushed_motion.x - expected_pushed_motion_x) > PUSH_TOLERANCE:
		_fail(
			"Moving-platform push failed: platform %s, expected pushed X %.4f, got %.4f" %
			[platform_motion, expected_pushed_motion_x, pushed_motion.x]
		)
		return
	var player_width := (pusher.collision_shape.shape as RectangleShape2D).size.x
	var horizontal_gap := pushed.global_position.x - pusher.global_position.x - player_width
	if absf(horizontal_gap) > PUSH_TOLERANCE:
		_fail("Moving-platform push left a %.4f px player gap" % horizontal_gap)


func _verify_platform_side_contact(tick: int) -> void:
	platform.restore_to_tick(tick)
	platform.force_update_transform()
	var player := players[0]
	var other_player := players[1]
	var player_rectangle := player.collision_shape.shape as RectangleShape2D
	var platform_rectangle := platform.collision_shape.shape as RectangleShape2D
	var combined_half_width := (player_rectangle.size.x + platform_rectangle.size.x) * 0.5
	player.global_position = Vector2(
		platform.global_position.x + combined_half_width + 2.0,
		platform.global_position.y - player.collision_shape.position.y
	)
	other_player.global_position = Vector2.ZERO
	_reset_player_motion()
	player.tick_velocity.x = -120.0
	player.force_update_transform()
	other_player.force_update_transform()
	_sync_physics_queries()
	player.custom_move_x(NetworkTime.ticktime)
	player.force_update_transform()
	var horizontal_gap := (
		player.collision_shape.global_position.x
		- platform.collision_shape.global_position.x
		- combined_half_width
	)
	if horizontal_gap < 0.0 or horizontal_gap > player.safe_margin + PUSH_TOLERANCE:
		_fail("Horizontal sweep left an invalid platform gap: %.4f" % horizontal_gap)
		return
	var vertical_velocity := 30.0
	player.tick_velocity.y = vertical_velocity
	var start_position := player.global_position
	player.custom_move_y(NetworkTime.ticktime)
	var motion := player.global_position - start_position
	var expected_motion := Vector2.DOWN * vertical_velocity * NetworkTime.ticktime
	if motion.distance_to(expected_motion) > PUSH_TOLERANCE:
		_fail("Platform side contact changed vertical motion: expected %s, got %s" % [
			expected_motion, motion
		])


func _verify_floor_recovery(tick: int) -> void:
	platform.restore_to_tick(tick)
	platform.force_update_transform()
	var player := players[0]
	var other_player := players[1]
	player.global_position = Vector2(
		platform.global_position.x,
		_shape_top(platform) - _shape_bottom_offset(player) + 1.0
	)
	other_player.global_position = Vector2.ZERO
	_reset_player_motion()
	player.force_update_transform()
	other_player.force_update_transform()
	_sync_physics_queries()
	var start_y := player.global_position.y
	player.custom_move_y(NetworkTime.ticktime)
	var remaining_penetration := _shape_bottom(player) - _shape_top(platform)
	if player.global_position.y >= start_y or remaining_penetration > PUSH_TOLERANCE:
		_fail(
			"Floor recovery failed: moved %.4f px with %.4f px penetration remaining" %
			[player.global_position.y - start_y, remaining_penetration]
		)


func _shape_top(body: PhysicsBody2D) -> float:
	var collision_shape := _collision_shape(body)
	var rectangle := collision_shape.shape as RectangleShape2D
	return collision_shape.global_position.y - rectangle.size.y * 0.5


func _shape_bottom(body: PhysicsBody2D) -> float:
	var collision_shape := _collision_shape(body)
	var rectangle := collision_shape.shape as RectangleShape2D
	return collision_shape.global_position.y + rectangle.size.y * 0.5


func _shape_bottom_offset(body: PhysicsBody2D) -> float:
	return _shape_bottom(body) - body.global_position.y


func _collision_shape(body: PhysicsBody2D) -> CollisionShape2D:
	return body.get(&"collision_shape") as CollisionShape2D


func _sync_physics_queries() -> void:
	RapierPhysicsServer2D.space_step(physics_driver.physics_space, 0.0)
	RapierPhysicsServer2D.space_flush_queries(physics_driver.physics_space)


func _fail(message: String) -> void:
	failures.append("ROLLBACK_RIDING_REGRESSION: %s" % message)


func _finish_test() -> void:
	if failures.is_empty():
		print(
			"ROLLBACK_RIDING_REGRESSION: PASS " +
			"(diagonal stack, replay, pushing, side contact, floor recovery)"
		)
		get_tree().quit()
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)
