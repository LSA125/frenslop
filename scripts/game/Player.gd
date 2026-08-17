extends RapierCharacterBody2D
class_name Player

const GAMEPLAY_EFFECT := preload("res://scripts/game/effects/GameplayEffect.gd")

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
@export var punch_query_shape: Shape2D
@export var pickup_query_shape: Shape2D
@export var effect_receiver: Area2D
@export var animations : AnimatedSprite2D
@export var internal_effects_holder : Node

@export_group("Force System Variables")
# Reserved for rope gameplay. Synchronize these IDs before reading them in rollback.
@export var attached_rope_object_ids: Array[int] = []
@export var knockback_vel := Vector2.ZERO
@export var KNOCKBACK_DECAY_SPEED := 800.0
# Minimum alignment for treating a collision normal as horizontal or vertical.
@export var COLLISION_NORMAL_TOLERANCE := 0.7

@export_group("Equip System")
@export var PUNCH_VELOCITY := 200.0
@export var PUNCH_COOLDOWN_TICKS := 150
@export var PUNCH_QUERY_OFFSET := Vector2(18.0, 2.0)
var equipped_item: Equip

var action_hold_ticks := 0
var equip_was_held := false
var remaining_cooldown_ticks := 0

# --- internally used variables ---
var impulse_velocity := Vector2.ZERO
var continuous_velocity := Vector2.ZERO
var tick_velocity := Vector2.ZERO
var emitted_velocity := Vector2.ZERO
var carrier_velocity := Vector2.ZERO

var rope_vel: Dictionary = {}
var grounded := false
var action_started_this_tick := false
var action_released_ticks := 0
var equip_pressed_this_tick := false

const RIDE_QUERY_OFFSET := Vector2(0.0, 16.0)
const RIDE_QUERY_MOTION := Vector2(0.0, 1.0)
const EFFECTS_QUERY_OFFSET := Vector2(0.0, 4.5)
const EFFECTS_QUERY_MASK := 7
const EFFECT_RECEIVER_QUERY_MASK := 1 << 2
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

func prepare_tick(delta: float, support: Node2D = null) -> void:
	continuous_velocity = Vector2.ZERO
	carrier_velocity = Vector2.ZERO
	_update_action_state()
	remaining_cooldown_ticks = maxi(0, remaining_cooldown_ticks - 1)
	grounded = check_is_grounded(support)
	apply_continuous_forces()
	apply_impulse_forces()
	calc_input_movement(delta)
	tick_velocity = velocity + impulse_velocity + continuous_velocity
	emitted_velocity = Vector2.ZERO

func _update_action_state() -> void:
	action_started_this_tick = input.action_held and action_hold_ticks == 0
	action_released_ticks = action_hold_ticks if not input.action_held else 0
	if input.action_held:
		action_hold_ticks += 1
	else:
		action_hold_ticks = 0
	equip_pressed_this_tick = input.equip_held and not equip_was_held
	equip_was_held = input.equip_held

func cancel_action_charge() -> void:
	action_hold_ticks = 0
	action_started_this_tick = false
	action_released_ticks = 0

func set_equipped_item(item: Equip) -> void:
	equipped_item = item

func get_peer_id() -> int:
	return name.to_int()

func can_use_default_attack() -> bool:
	return equipped_item == null and action_started_this_tick and remaining_cooldown_ticks == 0

func should_play_action_animation() -> bool:
	if not input.action_held:
		return false
	if equipped_item != null:
		return false
	return (
		remaining_cooldown_ticks > 0
		and remaining_cooldown_ticks + action_hold_ticks == PUNCH_COOLDOWN_TICKS + 1
	)

func use_default_attack(tick: int) -> Array[Node]:
	remaining_cooldown_ticks = PUNCH_COOLDOWN_TICKS
	return apply_velocity_effect(
		punch_query_shape,
		PUNCH_QUERY_OFFSET,
		PUNCH_VELOCITY,
		tick
	)

func apply_velocity_effect(
	shape: Shape2D,
	local_offset: Vector2,
	velocity_amount: float,
	tick: int
) -> Array[Node]:
	var targets: Array[Node] = []
	if shape == null or is_zero_approx(velocity_amount):
		return targets
	var direction := 1.0 if facing_right else -1.0
	var effect := GAMEPLAY_EFFECT.new(
		get_peer_id(),
		Vector2(direction * velocity_amount, 0.0),
		tick
	)
	for receiver in find_effect_receivers(shape, local_offset):
		var target := receiver.call(&"get_effect_target") as Node
		if target == null or target == self:
			continue
		if NetworkRollback.is_rollback():
			NetworkRollback.mutate(target)
		if receiver.call(&"apply_effect", effect):
			targets.append(target)
	return targets

func apply_effect(effect: Variant) -> void:
	impulse_velocity += effect.velocity_delta
	# Combat resolves after prepare_tick(), so include the impulse in both the
	# persistent state and this tick's already-built movement velocity.
	tick_velocity += effect.velocity_delta

func apply_continuous_forces() -> void:
	for child in internal_effects_holder.get_children():
		if child.has_method("apply_velocity"):
			continuous_velocity += child.apply_velocity(self)
		else:
			push_warning("Internal effect does not implement apply_velocity")

# External impulses include bombs, explosions, springs, and other players.
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

	if input.movement:
		velocity.x = input.movement * SPEED
		facing_right = input.movement > 0.0
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)

	impulse_velocity = impulse_velocity.move_toward(Vector2.ZERO, KNOCKBACK_DECAY_SPEED * delta)

func apply_ride_velocity(support: Node2D) -> void:
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

func update_emitted_velocity(support: Node2D) -> void:
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
	var query_transform := _body_physics_transform(self) * Transform2D(
		0.0, EFFECTS_QUERY_OFFSET
	)
	var query := _make_shape_query(
		effects_query_shape, query_transform, EFFECTS_QUERY_MASK, true, true
	)
	for result in get_world_2d().direct_space_state.intersect_shape(query, MAX_QUERY_RESULTS):
		var collider := result.get("collider") as Node
		if collider == null or seen.has(collider):
			continue
		seen[collider] = true
		colliders.append(collider)
	colliders.sort_custom(_sort_node_path)
	return colliders

func find_effect_receivers(shape: Shape2D, local_offset: Vector2) -> Array[Area2D]:
	var receivers: Array[Area2D] = []
	var seen_targets := {}
	var direction := 1.0 if facing_right else -1.0
	var query_transform := _body_physics_transform(self) * Transform2D(
		0.0,
		Vector2(local_offset.x * direction, local_offset.y)
	)
	var additional_exclusions: Array[RID] = [effect_receiver.get_rid()]
	var query := _make_shape_query(
		shape,
		query_transform,
		EFFECT_RECEIVER_QUERY_MASK,
		false,
		true,
		additional_exclusions
	)
	for result in get_world_2d().direct_space_state.intersect_shape(query, MAX_QUERY_RESULTS):
		var receiver := result.get("collider") as Area2D
		if receiver == null or not receiver.has_method(&"get_effect_target"):
			continue
		var target := receiver.call(&"get_effect_target") as Node
		if target == null or target == self or seen_targets.has(target):
			continue
		seen_targets[target] = true
		receivers.append(receiver)
	return receivers

func find_nearest_equip(candidates: Array[Equip], excluded: Dictionary = {}) -> Equip:
	if pickup_query_shape == null:
		return null
	var player_transform := _body_physics_transform(self)
	var closest: Equip
	var closest_distance := INF
	for candidate in candidates:
		if candidate.holder_peer_id != 0 or excluded.has(candidate):
			continue
		if not pickup_query_shape.collide(
			player_transform,
			candidate.pick_up_collider.shape,
			candidate.get_pickup_shape_transform()
		):
			continue
		var distance := player_transform.origin.distance_squared_to(candidate.global_position)
		if distance < closest_distance or (
			is_equal_approx(distance, closest_distance)
			and (closest == null or String(candidate.get_path()) < String(closest.get_path()))
		):
			closest = candidate
			closest_distance = distance
	return closest

func find_push_contacts(direction: float, candidates: Array) -> Array[Player]:
	var players: Array[Player] = []
	var player_rectangle := collision_shape.shape as RectangleShape2D
	var player_center := _shape_physics_transform(self, collision_shape).origin
	player_center.x += direction * CARRIER_BLOCK_CHECK_DISTANCE
	for other_player: Player in candidates:
		if other_player == self:
			continue
		var other_rectangle := other_player.collision_shape.shape as RectangleShape2D
		var center_delta := _shape_physics_transform(other_player, other_player.collision_shape).origin - player_center
		var overlap := (player_rectangle.size + other_rectangle.size) * 0.5 - center_delta.abs()
		if overlap.x <= 0.0 or overlap.y <= 0.0:
			continue
		if overlap.x <= overlap.y and signf(center_delta.x) == direction:
			players.append(other_player)
	return players

func find_support_below(candidates: Array) -> Node2D:
	# Cache a carrier before any body moves. Grounding is verified separately.
	var support: Node2D
	var player_transform := _body_physics_transform(self)
	var player_shape_transform := _shape_physics_transform(self, collision_shape)
	var player_rectangle := collision_shape.shape as RectangleShape2D
	var query_transform := player_transform * Transform2D(0.0, RIDE_QUERY_OFFSET + RIDE_QUERY_MOTION)
	var support_position := Vector2.ZERO
	for candidate in candidates:
		var candidate_shape := candidate.get(&"collision_shape") as CollisionShape2D
		if candidate == self or candidate_shape == null or candidate_shape.shape == null:
			continue
		var candidate_body_transform := _body_physics_transform(candidate)
		if candidate_body_transform.origin.y <= player_transform.origin.y:
			continue
		var candidate_shape_transform := candidate_body_transform * candidate_shape.transform
		var candidate_rectangle := candidate_shape.shape as RectangleShape2D
		if player_rectangle != null and candidate_rectangle != null:
			var center_delta := candidate_shape_transform.origin - player_shape_transform.origin
			var overlap := (player_rectangle.size + candidate_rectangle.size) * 0.5 - center_delta.abs()
			if overlap.x <= 0.0 or overlap.y > overlap.x:
				continue
		if not ride_query_shape.collide(query_transform, candidate_shape.shape, candidate_shape_transform):
			continue
		if support == null or candidate_body_transform.origin.y < support_position.y or (
			is_equal_approx(candidate_body_transform.origin.y, support_position.y)
			and String(candidate.get_path()) < String(support.get_path())
		):
			support = candidate
			support_position = candidate_body_transform.origin
	return support

func find_horizontal_blocker(direction: float, support: Node2D = null) -> Node:
	var excluded_bodies: Array[RID] = []
	if support != null:
		excluded_bodies.append(support.get_rid())
	var result := _test_motion(Vector2(direction * CARRIER_BLOCK_CHECK_DISTANCE, 0.0), excluded_bodies)
	if result == null:
		return null
	if result.get_collision_normal().dot(Vector2(direction, 0.0)) >= -COLLISION_NORMAL_TOLERANCE:
		return null
	return result.get_collider() as Node

func _make_shape_query(
	shape: Shape2D,
	query_transform: Transform2D,
	collision_mask_value: int,
	collide_with_bodies: bool = true,
	collide_with_areas: bool = false,
	additional_exclusions: Array[RID] = []
) -> PhysicsShapeQueryParameters2D:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = query_transform
	query.collision_mask = collision_mask_value
	query.collide_with_bodies = collide_with_bodies
	query.collide_with_areas = collide_with_areas
	query.exclude = [get_rid()]
	query.exclude.append_array(additional_exclusions)
	return query

func _body_physics_transform(body) -> Transform2D:
	return PhysicsServer2D.body_get_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM) as Transform2D

func _shape_physics_transform(body, shape: CollisionShape2D) -> Transform2D:
	return _body_physics_transform(body) * shape.transform

func _test_motion(motion: Vector2, excluded_bodies: Array[RID]) -> PhysicsTestMotionResult2D:
	var parameters := PhysicsTestMotionParameters2D.new()
	parameters.from = _body_physics_transform(self)
	parameters.motion = motion
	parameters.margin = 0.0
	parameters.recovery_as_collision = false
	parameters.exclude_bodies = excluded_bodies
	var result := PhysicsTestMotionResult2D.new()
	if PhysicsServer2D.body_test_motion(get_rid(), parameters, result):
		return result
	return null

func _sort_node_path(a: Node, b: Node) -> bool:
	return String(a.get_path()) < String(b.get_path())

func custom_move_x(
	delta: float, excluded_bodies: Array[RID] = [], player_candidates: Array[Player] = []
) -> void:
	if is_zero_approx(tick_velocity.x):
		return
	if _move_x_until_blocked(tick_velocity.x * delta, excluded_bodies, player_candidates):
		velocity.x = 0.0
		tick_velocity.x = 0.0

func custom_move_carrier_x(
	delta: float, excluded_bodies: Array[RID] = [], player_candidates: Array[Player] = []
) -> void:
	if is_zero_approx(carrier_velocity.x):
		return
	# Carrier travel is a separate phase and must not clear relative X velocity.
	_move_x_until_blocked(carrier_velocity.x * delta, excluded_bodies, player_candidates)

func _move_x_until_blocked(
	distance: float, excluded_bodies: Array[RID], player_candidates: Array[Player]
) -> bool:
	var motion := Vector2(distance, 0.0)
	var world_exclusions: Array[RID] = excluded_bodies.duplicate()
	for candidate in player_candidates:
		if candidate != self:
			world_exclusions.append(candidate.get_rid())
	var result := _test_motion(motion, world_exclusions)
	var safe_fraction := 1.0
	var direction := signf(motion.x)
	if result != null and result.get_collision_normal().dot(Vector2(direction, 0.0)) < -COLLISION_NORMAL_TOLERANCE:
		safe_fraction = clampf((absf(result.get_travel().x) - safe_margin) / absf(motion.x), 0.0, 1.0)
	var player_rectangle := collision_shape.shape as RectangleShape2D
	var player_center := _shape_physics_transform(self, collision_shape).origin
	for candidate in player_candidates:
		if candidate == self or excluded_bodies.has(candidate.get_rid()):
			continue
		var candidate_rectangle := candidate.collision_shape.shape as RectangleShape2D
		var center_delta := _shape_physics_transform(candidate, candidate.collision_shape).origin - player_center
		var combined_half_size := (player_rectangle.size + candidate_rectangle.size) * 0.5
		if absf(center_delta.y) >= combined_half_size.y:
			continue
		var forward_distance := center_delta.x * direction
		if forward_distance <= 0.0:
			continue
		var horizontal_gap := forward_distance - combined_half_size.x
		if horizontal_gap <= absf(motion.x):
			safe_fraction = minf(safe_fraction, maxf(0.0, horizontal_gap - safe_margin) / absf(motion.x))
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


func apply_ground_snap(support: Node2D = null) -> void:
	if input.jump or velocity.y < 0.0:
		return
	var floor_motion = _find_floor_motion(Vector2.DOWN * GROUND_CHECK_DISTANCE, support)
	if floor_motion == null:
		return
	global_position += floor_motion
	grounded = true
	velocity.y = 0.0
	tick_velocity.y = 0.0

func check_is_grounded(support: Node2D = null) -> bool:
	return _find_floor_motion(Vector2.DOWN * GROUND_CHECK_DISTANCE, support) != null

func _find_floor_motion(motion: Vector2, support: Node2D = null):
	if motion.is_zero_approx():
		return null
	var destination_transform := _shape_physics_transform(self, collision_shape)
	destination_transform.origin += motion
	var additional_exclusions: Array[RID] = []
	if support != null:
		additional_exclusions.append(support.get_rid())
	var query := _make_shape_query(
		collision_shape.shape,
		destination_transform,
		collision_mask,
		true,
		false,
		additional_exclusions
	)
	# The cached support is checked explicitly because restored transforms can be
	# newer than Rapier's direct-space query broadphase during rollback prepare.
	var closest_distance := _cached_support_floor_distance(motion, support)
	var contacts := get_world_2d().direct_space_state.collide_shape(query, MAX_QUERY_RESULTS)
	for contact_index in range(0, contacts.size(), 2):
		closest_distance = minf(
			closest_distance,
			_floor_distance_from_contact(contacts[contact_index], contacts[contact_index + 1], motion.length())
		)
	if is_inf(closest_distance):
		return null
	return motion.normalized() * closest_distance

func _floor_distance_from_contact(
	point_on_player: Vector2, point_on_collider: Vector2, maximum_distance: float
) -> float:
	var separation := point_on_collider - point_on_player
	if separation.is_zero_approx() or separation.normalized().dot(Vector2.UP) <= COLLISION_NORMAL_TOLERANCE:
		return INF
	return maxf(0.0, maximum_distance - separation.length())

func _cached_support_floor_distance(motion: Vector2, support: Node2D) -> float:
	if support == null or motion.y <= 0.0:
		return INF
	var support_collision_shape := support.get(&"collision_shape") as CollisionShape2D
	var player_rectangle := collision_shape.shape as RectangleShape2D
	if support_collision_shape == null:
		return INF
	var support_rectangle := support_collision_shape.shape as RectangleShape2D
	if player_rectangle == null or support_rectangle == null:
		return INF
	var player_transform := _shape_physics_transform(self, collision_shape)
	var support_transform := _shape_physics_transform(support, support_collision_shape)
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
	animations.flip_h = not facing_right

	if should_play_action_animation():
		animations.play(&"wall_jump")
	elif grounded:
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
	if equipped_item != null:
		equipped_item.animate(action_hold_ticks, action_released_ticks)
