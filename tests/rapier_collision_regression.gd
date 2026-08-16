extends Node2D

const BALL_SCENE := preload("res://nodes/game/bouncing_ball.tscn")
const TEST_TICKS := 240

var finished := false

func _ready() -> void:
	get_tree().create_timer(5.0).timeout.connect(on_watchdog_timeout)
	if not NetworkTime.is_initial_sync_done():
		var start_error := await NetworkTime.start()
		if start_error != OK:
			push_error("RAPIER_COLLISION_REGRESSION: failed to initialize NetworkTime")
			finished = true
			get_tree().quit(1)
			return
	NetworkTime.stop()

	var floor_body := StaticBody2D.new()
	floor_body.position = Vector2(300.0, 400.0)
	var floor_shape := CollisionShape2D.new()
	var floor_rectangle := RectangleShape2D.new()
	floor_rectangle.size = Vector2(500.0, 20.0)
	floor_shape.shape = floor_rectangle
	floor_body.add_child(floor_shape)
	add_child(floor_body)

	var ball_instance := BALL_SCENE.instantiate()
	var ball := ball_instance as BouncingBall
	if not ball:
		push_error("RAPIER_COLLISION_REGRESSION: failed to instantiate BouncingBall")
		ball_instance.queue_free()
		finished = true
		get_tree().quit(1)
		return
	ball.position = Vector2(300.0, 100.0)
	if "--no-bounce" in OS.get_cmdline_user_args():
		ball.bounce_speed = 0.0
	add_child(ball)

	var use_manual_driver := "--manual-driver" in OS.get_cmdline_user_args()
	var driver: RapierDriver2D

	await get_tree().process_frame
	await get_tree().process_frame
	if use_manual_driver:
		await get_tree().physics_frame
		driver = RapierDriver2D.new()
		driver.rollback_physics_space = true
		driver.physics_factor = 1
		add_child(driver)
		floor_body.force_update_transform()
		ball.force_update_transform()
		RapierPhysicsServer2D.space_flush_queries(driver.physics_space)
		if not verify_cache_restore(driver, ball):
			finished = true
			get_tree().quit(1)
			return
		if not verify_step_then_flush(driver, ball):
			finished = true
			get_tree().quit(1)
			return

	var greatest_y := ball.global_position.y
	var logged_contact := false
	for tick in range(TEST_TICKS):
		if use_manual_driver:
			driver.before_tick(NetworkTime.ticktime, tick)
			if not logged_contact and ball.direct_state.get_contact_count() > 0:
				logged_contact = true
				print(
					"RAPIER_COLLISION_CONTACT: normal=%s velocity=%s" %
						[
							ball.direct_state.get_contact_local_normal(0),
							ball.direct_state.linear_velocity,
						]
				)
		else:
			await get_tree().physics_frame
		greatest_y = maxf(greatest_y, ball.global_position.y)

	var floor_bottom_limit := floor_body.global_position.y + 30.0
	if greatest_y > floor_bottom_limit:
		push_error(
			"RAPIER_COLLISION_REGRESSION: ball passed through floor (max y %.3f)" %
				greatest_y
		)
		finished = true
		get_tree().quit(1)
		return

	var mode := "manual driver" if use_manual_driver else "engine stepping"
	print("RAPIER_COLLISION_REGRESSION: PASS (%s, max y %.3f)" % [mode, greatest_y])
	finished = true
	get_tree().quit()

func on_watchdog_timeout() -> void:
	if finished:
		return
	push_error("RAPIER_COLLISION_REGRESSION: watchdog timeout")
	get_tree().quit(1)

func verify_cache_restore(driver: RapierDriver2D, ball: BouncingBall) -> bool:
	const FIRST_CACHE_TEST_TICK := -1000
	const SECOND_CACHE_TEST_TICK := 37
	var expected_state := ball.physics_state.duplicate(true)
	driver._snapshot_space(FIRST_CACHE_TEST_TICK)

	var disturbed_state := expected_state.duplicate(true)
	disturbed_state[NetworkRigidBody2D.ORIGIN] += Vector2(37.0, 53.0)
	ball.physics_state = disturbed_state
	driver._snapshot_space(SECOND_CACHE_TEST_TICK)
	driver._rollback_space(FIRST_CACHE_TEST_TICK)

	var restored_state := ball.physics_state
	var position_error := (
		(restored_state[NetworkRigidBody2D.ORIGIN] as Vector2)
		.distance_to(expected_state[NetworkRigidBody2D.ORIGIN])
	)
	if position_error > 0.001:
		push_error(
			"RAPIER_COLLISION_REGRESSION: cached space did not restore (error %.4f)" %
				position_error
		)
		return false

	# Rewriting a tick must replace its old cache entry instead of creating a
	# duplicate whose offset depends on cache insertion history.
	var replacement_state := expected_state.duplicate(true)
	replacement_state[NetworkRigidBody2D.ORIGIN] += Vector2(-19.0, 11.0)
	ball.physics_state = replacement_state
	driver._snapshot_space(SECOND_CACHE_TEST_TICK)
	var cached_ticks := driver._state.ordered_cache_tags()
	if cached_ticks.count(SECOND_CACHE_TEST_TICK) != 1:
		push_error("RAPIER_COLLISION_REGRESSION: duplicate physics cache tick")
		return false

	ball.physics_state = disturbed_state
	driver._rollback_space(SECOND_CACHE_TEST_TICK)
	var replacement_error := (
		(ball.physics_state[NetworkRigidBody2D.ORIGIN] as Vector2)
		.distance_to(replacement_state[NetworkRigidBody2D.ORIGIN])
	)
	if replacement_error > 0.001:
		push_error(
			"RAPIER_COLLISION_REGRESSION: rewritten cache tick restored wrong state"
		)
		return false

	ball.physics_state = expected_state
	driver._physics_step(0.0)
	return true

func verify_step_then_flush(
	driver: RapierDriver2D,
	ball: BouncingBall,
) -> bool:
	# A flush before the step does not publish a direct-state transform to its
	# Godot node. Keep the driver contract locked to step, then flush.
	var original_state := ball.physics_state.duplicate(true)
	var displaced_state := original_state.duplicate(true)
	displaced_state[NetworkRigidBody2D.ORIGIN] += Vector2(23.0, -17.0)
	ball.physics_state = displaced_state
	driver._physics_step(0.0)

	var expected_position := displaced_state[NetworkRigidBody2D.ORIGIN] as Vector2
	if ball.global_position.distance_to(expected_position) > 0.001:
		push_error(
			"RAPIER_COLLISION_REGRESSION: step-then-flush did not publish node state"
		)
		return false

	ball.physics_state = original_state
	driver._physics_step(0.0)
	return true
