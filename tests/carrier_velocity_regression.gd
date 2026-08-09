extends Node

const PLAYER_SCENE := preload("res://nodes/game/player.tscn")
const PLATFORM_SCENE := preload("res://nodes/game/moving_platform.tscn")
const EXPECTED_PUSH_VELOCITY := 20.0
const TOLERANCE := 0.001

var failures: Array[String] = []

func _ready() -> void:
	var players_root := Node2D.new()
	players_root.name = "Players"
	add_child(players_root)

	var carrier := _add_player(players_root, "1", Vector2(200.0, 300.0))
	var rider := _add_player(players_root, "2", Vector2(200.0, 276.0))
	_add_floor()
	var wall := _add_wall(Vector2(219.5, 304.0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	carrier.input.movement = 1.0
	carrier.tick_velocity = Vector2(200.0, 0.0)
	carrier.force_update_transform()
	wall.force_update_transform()
	carrier.update_emitted_velocity(null)
	_assert_close(carrier.emitted_velocity.x, 0.0, "wall-blocked carrier emitted movement speed")

	rider.tick_velocity = Vector2.ZERO
	rider.ride_detector.force_shapecast_update()
	rider.apply_ride_velocity()
	_assert_close(rider.tick_velocity.x, 0.0, "rider inherited wall-blocked carrier speed")

	# RideDetector deliberately reaches farther than the floor check. Detection
	# alone must not cancel a rider's downward velocity while there is still a gap.
	rider.position.y -= 5.0
	rider.force_update_transform()
	rider.ride_detector.force_shapecast_update()
	rider.velocity = Vector2(0.0, 90.0)
	rider.tick_velocity = rider.velocity
	rider.apply_ride_velocity()
	_assert_close(rider.velocity.y, 90.0, "ride detector stopped persistent downward velocity")
	_assert_close(rider.tick_velocity.y, 90.0, "ride detector stopped tick downward velocity")

	# Once the gap is within the four-pixel floor-snap range, snapping must close
	# it even though the same body is also selected as the ride support.
	rider.position.y += 2.0
	rider.force_update_transform()
	rider.velocity = Vector2.ZERO
	rider.tick_velocity = Vector2.ZERO
	rider.input.jump = false
	rider.apply_ground_snap()
	_assert_at_most(_vertical_gap(rider, carrier), 0.1, "ground snap left a rider gap")

	# Reproduce the first upward platform tick from the edge of floor-snap range.
	# Inheriting the platform offset temporarily restores the original four-pixel
	# separation; the same tick's floor snap must still close it.
	var upward_platform := PLATFORM_SCENE.instantiate() as MovingPlatform
	upward_platform.name = "UpwardPlatform"
	upward_platform.position = Vector2(350.0, 300.0)
	upward_platform.speed = 0
	upward_platform.distance_x = 0
	upward_platform.distance_y = 0
	add_child(upward_platform)
	var first_contact_rider := _add_player(players_root, "4", Vector2(350.0, 270.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var platform_offset := Vector2.UP * (100.0 * NetworkTime.ticktime)
	upward_platform.position += platform_offset
	upward_platform.platform_velocity = platform_offset / NetworkTime.ticktime
	upward_platform.force_update_transform()
	_assert_close(
		_vertical_gap(first_contact_rider, upward_platform),
		4.0 - 100.0 * NetworkTime.ticktime,
		"upward platform did not enter floor-check range before prepare"
	)
	first_contact_rider.prepare_tick(NetworkTime.ticktime)
	_assert_true(first_contact_rider.grounded, "rider was not grounded before ride inheritance")
	_assert_close(first_contact_rider.velocity.y, 0.0, "gravity was applied despite floor detection")
	first_contact_rider.ride_detector.force_shapecast_update()
	first_contact_rider.apply_ride_velocity()
	first_contact_rider.custom_move_y(NetworkTime.ticktime)
	first_contact_rider.force_update_transform()
	_assert_close(
		_vertical_gap(first_contact_rider, upward_platform),
		4.0,
		"ride inheritance did not recreate the four-pixel gap"
	)
	first_contact_rider.apply_ground_snap()
	_assert_at_most(
		_vertical_gap(first_contact_rider, upward_platform),
		0.1,
		"first upward platform contact preserved the detector-sized gap"
	)

	# Characterize publication after both direct assignment and CharacterBody
	# movement so later cleanup does not remove calls that update otherwise-stale
	# Rapier state.
	var transform_probe := _add_player(players_root, "5", Vector2(550.0, 200.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var original_physics_position := _physics_position(transform_probe)
	transform_probe.position += Vector2(11.0, -7.0)
	var position_without_force := _physics_position(transform_probe)
	_assert_vector_close(
		position_without_force,
		original_physics_position,
		"direct assignment unexpectedly published before force_update_transform"
	)
	transform_probe.force_update_transform()
	var position_with_force := _physics_position(transform_probe)
	_assert_vector_close(
		position_with_force,
		transform_probe.global_position,
		"force_update_transform did not publish a direct position assignment"
	)
	var physics_position_before_move := _physics_position(transform_probe)
	transform_probe.tick_velocity = Vector2(30.0, 0.0)
	transform_probe.custom_move_x(NetworkTime.ticktime)
	_assert_vector_close(
		_physics_position(transform_probe),
		physics_position_before_move,
		"move_and_collide unexpectedly published before force_update_transform"
	)
	transform_probe.force_update_transform()
	_assert_vector_close(
		_physics_position(transform_probe),
		transform_probe.global_position,
		"force_update_transform did not publish move_and_collide motion"
	)

	wall.position.x += 100.0
	wall.force_update_transform()
	var pushed := _add_player(players_root, "3", Vector2(217.0, 300.0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	carrier.input.movement = 1.0
	carrier.tick_velocity = Vector2(200.0, 0.0)
	carrier.force_update_transform()
	pushed.force_update_transform()
	carrier.update_emitted_velocity(null)
	_assert_close(
		carrier.emitted_velocity.x,
		EXPECTED_PUSH_VELOCITY,
		"carrier did not emit push speed against a player"
	)

	rider.tick_velocity = Vector2.ZERO
	rider.ride_detector.force_shapecast_update()
	rider.apply_ride_velocity()
	_assert_close(
		rider.tick_velocity.x,
		EXPECTED_PUSH_VELOCITY,
		"rider did not inherit the carrier's push speed"
	)

	if failures.is_empty():
		print("CARRIER_VELOCITY_REGRESSION: PASS")
		get_tree().quit()
		return
	for failure in failures:
		push_error("CARRIER_VELOCITY_REGRESSION: %s" % failure)
	get_tree().quit(1)

func _add_player(parent: Node, player_name: String, player_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.name = player_name
	player.position = player_position
	parent.add_child(player)
	return player

func _add_wall(wall_position: Vector2) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.position = wall_position
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(20.0, 24.0)
	shape.shape = rectangle
	wall.add_child(shape)
	add_child(wall)
	return wall

func _add_floor() -> void:
	var floor_body := StaticBody2D.new()
	floor_body.position = Vector2(200.0, 326.0)
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(400.0, 20.0)
	shape.shape = rectangle
	floor_body.add_child(shape)
	add_child(floor_body)

func _assert_close(actual: float, expected: float, message: String) -> void:
	if absf(actual - expected) > TOLERANCE:
		failures.append("%s: expected %.3f, got %.3f" % [message, expected, actual])

func _assert_at_most(actual: float, maximum: float, message: String) -> void:
	if actual > maximum:
		failures.append("%s: expected <= %.3f, got %.3f" % [message, maximum, actual])


func _assert_true(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func _assert_vector_close(actual: Vector2, expected: Vector2, message: String) -> void:
	if actual.distance_to(expected) > TOLERANCE:
		failures.append("%s: expected %s, got %s" % [message, expected, actual])

func _physics_position(body: PhysicsBody2D) -> Vector2:
	var transform := PhysicsServer2D.body_get_state(
		body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM
	) as Transform2D
	return transform.origin

func _vertical_gap(rider: Player, support: Node2D) -> float:
	var support_collision_shape := support.get_node("CollisionShape2D") as CollisionShape2D
	var rider_bottom := (
		rider.collision_shape.global_position.y
		+ (rider.collision_shape.shape as RectangleShape2D).size.y * 0.5
	)
	var support_top := (
		support_collision_shape.global_position.y
		- (support_collision_shape.shape as RectangleShape2D).size.y * 0.5
	)
	return support_top - rider_bottom
