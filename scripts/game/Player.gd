extends RapierCharacterBody2D
class_name Player
@export_group("Player Control")
@export var SPEED := 300.0
@export var JUMP_VELOCITY := -400.0
#the velocity a player can push another
@export var PUSH_FORCE := 200
@export var GROUND_CHECK_DISTANCE := 4.0
@export var CARRIER_BLOCK_CHECK_DISTANCE := 2.0
@export var facing_right := true


@export_group("Imports")
@export var input: PlayerInput
@export var rollback_sync : RollbackSynchronizer
@export var collision_shape : CollisionShape2D
@export var ride_query_shape : Shape2D
@export var effects_query_shape : Shape2D
@export var animations : AnimatedSprite2D
@export var internal_effects_holder : Node

@export_group("Force System Variables")
# Rollback note: Synchronize these IDs so every client knows what this player is attached to!
@export var attached_rope_object_ids : Array[int] = []
@export var knockback_vel := Vector2.ZERO
@export var KNOCKBACK_DECAY_SPEED := 800.0
# not sure what to call it but, when we see if a collision is right, left, upwards etc
# this is the tolerance for how closely the vector has to align in that direction.
@export var COLLISION_NORMAL_TOLERANCE := 0.7

@export_group("Equip System")
enum EQUIP {NONE,}
@export var active_equip : EQUIP = EQUIP.NONE
@export var equips_holder : Node2D
var equip_item : Node = null

# --- internally used variables ---
var impulse_velocity := Vector2.ZERO
var continuous_velocity := Vector2.ZERO
var tick_velocity := Vector2.ZERO
var emitted_velocity := Vector2.ZERO
var carrier_velocity := Vector2.ZERO

var rope_vel : Dictionary = {}
var grounded := false

const RIDE_QUERY_OFFSET := Vector2(0.0, 16.0)
const RIDE_QUERY_MOTION := Vector2(0.0, 1.0)
const EFFECTS_QUERY_OFFSET := Vector2(0.0, 4.5)
const EFFECTS_QUERY_MASK := 7
const MAX_QUERY_RESULTS := 32

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	rollback_sync.process_settings()

func _rollback_tick(_delta: float, _tick: int, _is_fresh: bool) -> void:
	pass

func _process(_delta: float) -> void:
	apply_animations()

func prepare_tick(delta: float, support = null) -> void:
	continuous_velocity = Vector2.ZERO
	carrier_velocity = Vector2.ZERO
	grounded = check_is_grounded(support)
	apply_equip()
	apply_continuous_forces()
	apply_impulse_forces()
	calc_input_movement(delta)
	tick_velocity = velocity + impulse_velocity + continuous_velocity
	emitted_velocity = Vector2.ZERO

func apply_equip() -> void:
	if input.action:
		if active_equip:
			return # TODO

func apply_continuous_forces() -> void:
	for child in internal_effects_holder.get_children():
		if child.has_method("apply_velocity"):
			continuous_velocity += child.apply_velocity(self)
		else:
			print("Internal Effect does not have apply_velocity method")
#all bombs/explosions/springs. Any effect that would be an area2d
#also player just cause its easy, i probably should have named this external
#and internal forces...
func apply_impulse_forces() -> void:
	for collider in find_effect_colliders():
		if collider.has_method("apply_velocity"):
			impulse_velocity += collider.apply_velocity(self)

func calc_input_movement(delta: float) -> void:
	if not grounded:
		velocity += get_gravity() * delta
	elif input.jump:
		velocity.y = JUMP_VELOCITY
		grounded = false
	else:
		velocity.y = 0

	var direction_x: float = input.movement
	if direction_x:
		velocity.x = direction_x * SPEED
		if direction_x > 0:
			facing_right = true
		elif direction_x < 0:
			facing_right = false
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)

	impulse_velocity = impulse_velocity.move_toward(Vector2.ZERO, KNOCKBACK_DECAY_SPEED*delta)

func apply_ride_velocity(support) -> void:
	if input.jump:
		update_emitted_velocity(null)
		return
	if support != null:
		if tick_velocity.y >= 0.0 and check_is_grounded(support):
			tick_velocity.y -= velocity.y
			velocity.y = 0.0
			grounded = true
		carrier_velocity = support.get_carrier_velocity()
		tick_velocity += carrier_velocity
	update_emitted_velocity(support)

func get_carrier_velocity() -> Vector2:
	return emitted_velocity

func get_carrier_motion_velocity() -> Vector2:
	return carrier_velocity

func get_ordered_velocity() -> Vector2:
	return tick_velocity

func update_emitted_velocity(support) -> void:
	emitted_velocity = tick_velocity
	var relative_velocity_x := tick_velocity.x - carrier_velocity.x
	var direction := signf(relative_velocity_x)
	if is_zero_approx(direction):
		return

	var blocker := find_horizontal_blocker(direction, support)
	if blocker == null:
		return
	emitted_velocity.x = carrier_velocity.x
	if blocker is Player and signf(input.movement) == direction:
		var push_velocity := PUSH_FORCE * input.movement
		emitted_velocity.x += direction * minf(absf(relative_velocity_x), absf(push_velocity))

func find_effect_colliders() -> Array[Node]:
	var colliders: Array[Node] = []
	var seen := {}
	var query := _make_shape_query(
		effects_query_shape,
		EFFECTS_QUERY_OFFSET,
		EFFECTS_QUERY_MASK,
		true
	)
	for result in get_world_2d().direct_space_state.intersect_shape(query, MAX_QUERY_RESULTS):
		var collider := result.get("collider") as Node
		if collider == null or seen.has(collider):
			continue
		seen[collider] = true
		colliders.append(collider)
	colliders.sort_custom(_sort_node_path)
	return colliders

func find_push_contacts(direction: float, candidates: Array) -> Array[Player]:
	var players: Array[Player] = []
	var player_rectangle := collision_shape.shape as RectangleShape2D
	var player_center := (_body_physics_transform(self) * collision_shape.transform).origin
	player_center.x += direction * CARRIER_BLOCK_CHECK_DISTANCE
	for other_player: Player in candidates:
		if other_player == self:
			continue
		var other_rectangle := other_player.collision_shape.shape as RectangleShape2D
		var other_transform := _body_physics_transform(other_player)
		var other_center := (other_transform * other_player.collision_shape.transform).origin
		var center_delta := other_center - player_center
		var overlap := (player_rectangle.size + other_rectangle.size) * 0.5 - center_delta.abs()
		if overlap.x <= 0.0 or overlap.y <= 0.0:
			continue
		if overlap.x <= overlap.y and signf(center_delta.x) == direction:
			players.append(other_player)
	return players

func find_support_below(candidates: Array) -> Node2D:
	var support: Node2D
	var player_transform := _body_physics_transform(self)
	var player_shape_transform := player_transform * collision_shape.transform
	var player_rectangle := collision_shape.shape as RectangleShape2D
	var query_transform := player_transform * Transform2D(
		0.0, RIDE_QUERY_OFFSET + RIDE_QUERY_MOTION
	)
	var support_position := Vector2.ZERO
	for candidate in candidates:
		var candidate_shape := candidate.get(&"collision_shape") as CollisionShape2D
		if candidate == self or candidate_shape == null or candidate_shape.shape == null:
			continue
		var candidate_transform := _body_physics_transform(candidate)
		if candidate_transform.origin.y <= player_transform.origin.y:
			continue
		var candidate_rectangle := candidate_shape.shape as RectangleShape2D
		if player_rectangle != null and candidate_rectangle != null:
			var candidate_shape_transform := candidate_transform * candidate_shape.transform
			var center_delta := candidate_shape_transform.origin - player_shape_transform.origin
			var overlap := (
				(player_rectangle.size + candidate_rectangle.size) * 0.5
				- center_delta.abs()
			)
			if overlap.x <= 0.0 or overlap.y > overlap.x:
				continue
		if not ride_query_shape.collide(
			query_transform,
			candidate_shape.shape,
			candidate_transform * candidate_shape.transform
		):
			continue
		if support == null or candidate_transform.origin.y < support_position.y or (
			is_equal_approx(candidate_transform.origin.y, support_position.y)
			and String(candidate.get_path()) < String(support.get_path())
		):
			support = candidate
			support_position = candidate_transform.origin
	return support

func find_horizontal_blocker(direction: float, support = null) -> Node:
	var parameters := PhysicsTestMotionParameters2D.new()
	parameters.from = _body_physics_transform(self)
	parameters.motion = Vector2(direction * CARRIER_BLOCK_CHECK_DISTANCE, 0.0)
	parameters.margin = 0.0
	parameters.recovery_as_collision = false
	if support != null:
		parameters.exclude_bodies = [support.get_rid()]
	var result := PhysicsTestMotionResult2D.new()
	if not PhysicsServer2D.body_test_motion(get_rid(), parameters, result):
		return null
	if result.get_collision_normal().dot(Vector2(direction, 0.0)) >= -COLLISION_NORMAL_TOLERANCE:
		return null
	return result.get_collider() as Node

func _make_shape_query(
	shape: Shape2D,
	local_offset: Vector2,
	collision_mask: int,
	collide_with_areas: bool
) -> PhysicsShapeQueryParameters2D:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	var body_transform := PhysicsServer2D.body_get_state(
		get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM
	) as Transform2D
	query.transform = body_transform * Transform2D(0.0, local_offset)
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = collide_with_areas
	query.exclude = [get_rid()]
	return query

func _body_physics_transform(body) -> Transform2D:
	return PhysicsServer2D.body_get_state(
		body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM
	) as Transform2D

func _sort_node_path(a: Node, b: Node) -> bool:
	return String(a.get_path()) < String(b.get_path())

func custom_move_x(
	delta: float,
	excluded_bodies: Array[RID] = [],
	player_candidates: Array[Player] = []
) -> void:
	if is_zero_approx(tick_velocity.x):
		return
	var motion := Vector2(tick_velocity.x * delta, 0.0)
	if _move_horizontal(motion, excluded_bodies, player_candidates):
		velocity.x = 0.0
		tick_velocity.x = 0.0

func custom_move_carrier_x(
	delta: float,
	excluded_bodies: Array[RID] = [],
	player_candidates: Array[Player] = []
) -> void:
	if not is_zero_approx(carrier_velocity.x):
		_move_horizontal(
			Vector2(carrier_velocity.x * delta, 0.0),
			excluded_bodies,
			player_candidates
		)

func _move_horizontal(
	motion: Vector2,
	excluded_bodies: Array[RID],
	player_candidates: Array[Player]
) -> bool:
	var world_exclusions := excluded_bodies.duplicate()
	for candidate in player_candidates:
		if candidate != self:
			world_exclusions.append(candidate.get_rid())
	var parameters := PhysicsTestMotionParameters2D.new()
	parameters.from = _body_physics_transform(self)
	parameters.motion = motion
	parameters.margin = 0.0
	parameters.recovery_as_collision = false
	parameters.exclude_bodies = world_exclusions
	var result := PhysicsTestMotionResult2D.new()
	var collided := PhysicsServer2D.body_test_motion(get_rid(), parameters, result)
	var safe_fraction := 1.0
	var direction := signf(motion.x)
	if (
		collided
		and result.get_collision_normal().dot(Vector2(direction, 0.0))
		< -COLLISION_NORMAL_TOLERANCE
	):
		safe_fraction = clampf(
			(absf(result.get_travel().x) - safe_margin) / absf(motion.x),
			0.0,
			1.0
		)
	var player_rectangle := collision_shape.shape as RectangleShape2D
	var player_center := (_body_physics_transform(self) * collision_shape.transform).origin
	for candidate in player_candidates:
		if candidate == self or excluded_bodies.has(candidate.get_rid()):
			continue
		var candidate_rectangle := candidate.collision_shape.shape as RectangleShape2D
		var candidate_center := (
			_body_physics_transform(candidate) * candidate.collision_shape.transform
		).origin
		var center_delta := candidate_center - player_center
		var combined_half_size := (player_rectangle.size + candidate_rectangle.size) * 0.5
		if absf(center_delta.y) >= combined_half_size.y:
			continue
		var forward_distance := center_delta.x * direction
		if forward_distance <= 0.0:
			continue
		var horizontal_gap := forward_distance - combined_half_size.x
		if horizontal_gap <= absf(motion.x):
			safe_fraction = minf(
				safe_fraction,
				maxf(0.0, horizontal_gap - safe_margin) / absf(motion.x)
			)
	global_position += motion * safe_fraction
	return safe_fraction < 1.0

func custom_move_y(delta: float) -> void:
	var motion := Vector2(0.0, tick_velocity.y * delta)
	var collision := move_and_collide(motion, false, safe_margin, true)
	if collision == null:
		return
	var normal := collision.get_normal()
	if normal.dot(Vector2.UP) > COLLISION_NORMAL_TOLERANCE:
		grounded = true
		if tick_velocity.y > 0.0:
			velocity.y = 0.0
			tick_velocity.y = 0.0
	elif normal.dot(Vector2.DOWN) > COLLISION_NORMAL_TOLERANCE and tick_velocity.y < 0.0:
		var player_collider := collision.get_collider() as Player
		var collider_is_moving_up := player_collider != null and player_collider.tick_velocity.y < 0.0
		if not collider_is_moving_up:
			velocity.y = 0.0
			tick_velocity.y = 0.0


func apply_ground_snap(support = null) -> void:
	if input.jump or velocity.y < 0.0:
		return
	var snap_motion := Vector2.DOWN * GROUND_CHECK_DISTANCE
	var floor_travel = _find_floor(snap_motion, support)
	if floor_travel == null:
		return
	global_position += floor_travel
	grounded = true
	velocity.y = 0.0
	tick_velocity.y = 0.0

func check_is_grounded(support = null) -> bool:
	return _find_floor(Vector2.DOWN * GROUND_CHECK_DISTANCE, support) != null

func _find_floor(motion: Vector2, support = null):
	if motion.is_zero_approx():
		return null
	var destination_transform := _body_physics_transform(self) * collision_shape.transform
	destination_transform.origin += motion
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	query.transform = destination_transform
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	if support != null:
		query.exclude.append(support.get_rid())
	var closest_travel := _support_floor_travel(motion, support)
	var contacts := get_world_2d().direct_space_state.collide_shape(
		query, MAX_QUERY_RESULTS
	)
	for contact_index in range(0, contacts.size(), 2):
		var separation := contacts[contact_index + 1] - contacts[contact_index]
		if (
			not separation.is_zero_approx()
			and separation.normalized().dot(Vector2.UP) > COLLISION_NORMAL_TOLERANCE
		):
			closest_travel = minf(
				closest_travel,
				maxf(0.0, motion.length() - separation.length())
			)
	if is_inf(closest_travel):
		return null
	return motion.normalized() * closest_travel

func _support_floor_travel(motion: Vector2, support) -> float:
	if support == null or motion.y <= 0.0:
		return INF
	var support_collision_shape := support.get(&"collision_shape") as CollisionShape2D
	var player_rectangle := collision_shape.shape as RectangleShape2D
	if support_collision_shape == null:
		return INF
	var support_rectangle := support_collision_shape.shape as RectangleShape2D
	if player_rectangle == null or support_rectangle == null:
		return INF
	var player_transform := _body_physics_transform(self) * collision_shape.transform
	var support_transform := _body_physics_transform(support) * support_collision_shape.transform
	var combined_half_width := (player_rectangle.size.x + support_rectangle.size.x) * 0.5
	if absf(player_transform.origin.x - support_transform.origin.x) >= combined_half_width:
		return INF
	var floor_gap := (
		support_transform.origin.y
		- support_rectangle.size.y * 0.5
		- player_transform.origin.y
		- player_rectangle.size.y * 0.5
	)
	if floor_gap > motion.y + safe_margin:
		return INF
	return floor_gap - safe_margin

func apply_animations() -> void:
	face_direction(facing_right)

	if input.action:
		animations.play(&"wall_jump")
	if grounded:
		if absf(input.movement) < 0.01:
			animations.play(&"idle")
		elif impulse_velocity.length() > 1000:
			animations.play(&"spin")
		else:
			animations.play(&"run")
	else:
		if velocity.y < 0:
			animations.play(&"jump")
		elif velocity.y > 0:
			animations.play(&"fall")
		elif impulse_velocity.length() > 1000:
			animations.play(&"spin")
		else:
			animations.play(&"idle")

func face_direction(right : bool) -> void:
	if right:
		animations.flip_h = false
	else:
		animations.flip_h = true
