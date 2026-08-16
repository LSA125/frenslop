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
	_assert_true(carrier.check_is_grounded(), "side collision hid the floor contact")
	carrier.update_emitted_velocity(null)
	_assert_close(carrier.emitted_velocity.x, 0.0, "wall-blocked carrier emitted movement speed")

	rider.tick_velocity = Vector2.ZERO
	rider.apply_ride_velocity(rider.find_support_below([carrier, rider]))
	_assert_close(rider.tick_velocity.x, 0.0, "rider inherited wall-blocked carrier speed")

	# RideDetector deliberately reaches farther than the floor check. Detection
	# alone must not cancel a rider's downward velocity while there is still a gap.
	rider.position.y -= 5.0
	rider.force_update_transform()
	rider.velocity = Vector2(0.0, 90.0)
	rider.tick_velocity = rider.velocity
	rider.apply_ride_velocity(rider.find_support_below([carrier, rider]))
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
	# Direct-space queries see the broadphase produced by the physics lifecycle,
	# so reproduce the driver's step-and-flush before querying the moved platform.
	var physics_space := get_viewport().world_2d.space
	RapierPhysicsServer2D.space_step(physics_space, 0.0)
	RapierPhysicsServer2D.space_flush_queries(physics_space)
	_assert_close(
		_vertical_gap(first_contact_rider, upward_platform),
		4.0 - 100.0 * NetworkTime.ticktime,
		"upward platform did not enter floor-check range before prepare"
	)
	var first_contact_support := first_contact_rider.find_support_below([
		first_contact_rider, upward_platform
	])
	first_contact_rider.prepare_tick(NetworkTime.ticktime, first_contact_support)
	_assert_true(first_contact_rider.grounded, "rider was not grounded before ride inheritance")
	_assert_close(first_contact_rider.velocity.y, 0.0, "gravity was applied despite floor detection")
	first_contact_rider.apply_ride_velocity(first_contact_support)
	first_contact_rider.custom_move_y(NetworkTime.ticktime)
	first_contact_rider.force_update_transform()
	_assert_close(
		_vertical_gap(first_contact_rider, upward_platform),
		4.0,
		"ride inheritance did not recreate the four-pixel gap"
	)
	first_contact_rider.apply_ground_snap(first_contact_support)
	_assert_at_most(
		_vertical_gap(first_contact_rider, upward_platform),
		0.1,
		"first upward platform contact preserved the detector-sized gap"
	)

	# Resolve the whole support chain before a platform moves diagonally down.
	# Both riders must inherit the same exact tick offset without re-querying the
	# platform's destination or the already-moved lower rider.
	var descending_platform := PLATFORM_SCENE.instantiate() as MovingPlatform
	descending_platform.name = "DescendingPlatform"
	descending_platform.position = Vector2(500.0, 300.0)
	descending_platform.speed = 0
	descending_platform.distance_x = 0
	descending_platform.distance_y = 0
	add_child(descending_platform)
	var lower_rider := _add_player(players_root, "6", Vector2(500.0, 276.0))
	var upper_rider := _add_player(players_root, "7", Vector2(500.0, 252.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	lower_rider.force_update_transform()
	upper_rider.force_update_transform()
	descending_platform.force_update_transform()
	RapierPhysicsServer2D.space_step(physics_space, 0.0)
	RapierPhysicsServer2D.space_flush_queries(physics_space)
	var support_candidates: Array[PhysicsBody2D] = [
		lower_rider,
		upper_rider,
		descending_platform,
	]
	var lower_support := lower_rider.find_support_below(support_candidates)
	var upper_support := upper_rider.find_support_below(support_candidates)
	_assert_true(lower_support == descending_platform, "lower rider missed descending platform")
	_assert_true(upper_support == lower_rider, "upper rider missed lower rider")
	lower_rider.prepare_tick(NetworkTime.ticktime, lower_support)
	upper_rider.prepare_tick(NetworkTime.ticktime, upper_support)
	_assert_true(
		upper_rider not in lower_rider.find_push_contacts(1.0, [lower_rider, upper_rider]),
		"vertical player contact was treated as a push contact"
	)
	var lower_start := lower_rider.position
	var upper_start := upper_rider.position
	var descending_offset := Vector2(3.0, 3.0)
	descending_platform.position += descending_offset
	descending_platform.platform_velocity = descending_offset / NetworkTime.ticktime
	descending_platform.force_update_transform()
	RapierPhysicsServer2D.space_step(physics_space, NetworkTime.ticktime)
	RapierPhysicsServer2D.space_flush_queries(physics_space)
	lower_rider.apply_ride_velocity(lower_support)
	upper_rider.apply_ride_velocity(upper_support)
	var expected_descending_velocity := descending_offset / NetworkTime.ticktime
	_assert_vector_close(
		lower_rider.tick_velocity,
		expected_descending_velocity,
		"lower rider lost descending diagonal platform velocity"
	)
	_assert_vector_close(
		upper_rider.tick_velocity,
		expected_descending_velocity,
		"upper rider lost inherited descending diagonal velocity"
	)
	for stacked_rider in [lower_rider, upper_rider]:
		stacked_rider.custom_move_x(NetworkTime.ticktime)
		stacked_rider.force_update_transform()
	for stacked_rider in [lower_rider, upper_rider]:
		stacked_rider.custom_move_y(NetworkTime.ticktime)
		stacked_rider.force_update_transform()
	lower_rider.apply_ground_snap(lower_support)
	upper_rider.apply_ground_snap(upper_support)
	_assert_close(
		lower_rider.position.x,
		lower_start.x + descending_offset.x,
		"lower rider lost descending platform X offset"
	)
	_assert_close(
		upper_rider.position.x,
		upper_start.x + descending_offset.x,
		"upper rider lost inherited descending X offset"
	)
	_assert_at_most(
		absf(_vertical_gap(upper_rider, lower_rider)),
		0.1,
		"descending platform split the stacked riders"
	)
	_assert_at_most(
		_vertical_gap(lower_rider, descending_platform),
		lower_rider.GROUND_CHECK_DISTANCE + 0.1,
		"lower rider slipped beyond ground-snap range"
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
	_assert_true(pushed in carrier.find_push_contacts(1.0, [carrier, pushed]), "horizontal push contact was missed")
	carrier.update_emitted_velocity(null)
	_assert_close(
		carrier.emitted_velocity.x,
		EXPECTED_PUSH_VELOCITY,
		"carrier did not emit push speed against a player"
	)

	rider.tick_velocity = Vector2.ZERO
	rider.apply_ride_velocity(rider.find_support_below([carrier, rider, pushed]))
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
