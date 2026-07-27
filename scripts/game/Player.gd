extends RapierCharacterBody2D
class_name Player
@export_group("Player Control")
@export var SPEED := 300.0
@export var JUMP_VELOCITY := -400.0
#the velocity a player can push another
@export var PUSH_FORCE := 200
@export var GROUND_CHECK_DISTANCE := 6.0
@export var facing_right := true


@export_group("Imports") 
@export var input: PlayerInput
@export var rollback_sync : RollbackSynchronizer
@export var collision_shape : CollisionShape2D
@export var ride_detector : ShapeCast2D
@export var effects_detector : ShapeCast2D
@export var animations : AnimatedSprite2D
@export var internal_effects_holder : Node

@export_group("Force System Variables")
# Rollback note: Synchronize these IDs so every client knows what this player is attached to!
@export var attached_rope_object_ids : Array[int] = []
@export var knockback_vel := Vector2.ZERO
@export var KNOCKBACK_DECAY_SPEED := 800.0

@export_group("Equip System")
enum EQUIP {NONE,}
@export var active_equip : EQUIP = EQUIP.NONE
@export var equips_holder : Node2D
var equip_item : Node = null

# --- internally used variables ---
var impulse_velocity := Vector2.ZERO
var continuous_velocity := Vector2.ZERO

var rope_vel : Dictionary = {}
var on_platform := false
var grounded := false

var riding_bodies : Array[Player] = []
var is_riding := false
var tick_position_offset := Vector2.ZERO

static var _last_coordinated_tick := -1

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	if get_tree().get_nodes_in_group("rollback_players").is_empty():
		_last_coordinated_tick = -1
	add_to_group("rollback_players")
	NetworkRollback.on_prepare_tick.connect(prepare)
	NetworkRollback.after_prepare_tick.connect(after_prepare)
	rollback_sync.process_settings()

func _rollback_tick(delta: float, tick, _is_fresh) -> void:
	if _last_coordinated_tick == tick:
		return
	_last_coordinated_tick = tick

	var players := get_rollback_players()
	for player in players:
		player.force_update_transform()
	for player in players:
		player.ride_detector.force_shapecast_update()
		player.effects_detector.force_shapecast_update()

	var support_by_player := {}
	for player in players:
		var support := player.find_support_below()
		if not support:
			continue
		support_by_player[player] = support
		player.is_riding = support is Player
		player.on_platform = support is MovingPlatform
		if support is Player:
			(support as Player).riding_bodies.append(player)

	for player in players:
		if NetworkRollback.is_simulated(player):
			player.prepare_tick_effects(delta, tick)

	var visited := {}
	for player in players:
		simulate_recursive(player, delta, support_by_player, visited)

func simulate_recursive(
	player: Player,
	delta: float,
	support_by_player: Dictionary,
	visited: Dictionary
) -> void:
	if visited.has(player):
		return
	visited[player] = true

	var support: Node2D = support_by_player.get(player)
	if support is Player:
		simulate_recursive(support, delta, support_by_player, visited)

	if not NetworkRollback.is_simulated(player):
		return

	var start_position := player.global_position
	if support is Player:
		player.global_position += (support as Player).tick_position_offset
	elif support is MovingPlatform:
		player.global_position += (support as MovingPlatform).get_tick_offset()
	if support:
		player.force_update_transform()

	player.simulate_tick_movement(delta)
	player.tick_position_offset = player.global_position - start_position

func prepare_tick_effects(delta: float, tick: int) -> void:
	apply_equip(delta, tick)
	apply_continuous_forces()
	apply_impulse_forces()

func simulate_tick_movement(delta: float) -> void:
	for rider in riding_bodies:
		add_collision_exception_with(rider)
	apply_movement(delta)
	for rider in riding_bodies:
		remove_collision_exception_with(rider)
	force_update_transform()

func _process(_delta: float) -> void:
	apply_animations()

func prepare(_tick):
	continuous_velocity = Vector2.ZERO
	is_riding = false
	on_platform = false
	tick_position_offset = Vector2.ZERO
	riding_bodies.clear()

func after_prepare(_tick):
	_last_coordinated_tick = -1


func apply_equip(_delta, _tick) -> void:
	if input.action:
		if active_equip:
			return # TODO

func apply_continuous_forces() -> void:
	for child in internal_effects_holder.get_children():
		if child.has_method("apply_velocity"):
			continuous_velocity += child.apply_velocity(self)
		else:
			print("Child does not have apply_velocity method")
#all bombs/explosions/springs. Any effect that would be an area2d
#also player just cause its easy, i probably should have named this external
#and internal forces...
func apply_impulse_forces() -> void:
	if effects_detector.is_colliding():
		for i in effects_detector.get_collision_count():
			var collider := effects_detector.get_collider(i)
			if collider.has_method("apply_velocity"):
				impulse_velocity += collider.apply_velocity(self)
			if collider is Player:
				var other_player := collider as Player
				if is_riding or riding_bodies.has(other_player):
					continue

				#we are pushing the other player(lets not do bouncing off eachother yet...):
				var my_push_force := PUSH_FORCE * input.movement
				var other_push_force:float = collider.PUSH_FORCE * collider.input.movement

				var total := other_push_force
				#if we are pushing against eachother, take that force
				if abs(my_push_force + other_push_force) < abs(other_push_force):
					total = my_push_force + other_push_force
				var force = Vector2(total,0)
				#check the collision normal matches
				if effects_detector.get_collision_normal(i).dot(force) > 0.7 * total:
					continuous_velocity += force

func apply_movement(delta: float) -> void:
	grounded = check_is_grounded()
	if not grounded:
		velocity += get_gravity() * delta
	elif input.jump:
		velocity.y = JUMP_VELOCITY
		grounded = false
		is_riding = false
		on_platform = false
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

	var applied_impulse_velocity := impulse_velocity
	impulse_velocity = impulse_velocity.move_toward(Vector2.ZERO, KNOCKBACK_DECAY_SPEED*delta)
	var additive_velocity := applied_impulse_velocity + continuous_velocity
	velocity += additive_velocity
	velocity *= NetworkTime.physics_factor
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	velocity -= additive_velocity

func get_rollback_players() -> Array[Player]:
	var players: Array[Player] = []
	for node in get_tree().get_nodes_in_group("rollback_players"):
		var player := node as Player
		if player:
			players.append(player)

	players.sort_custom(sort_nodes_by_path)
	return players

static func sort_nodes_by_path(a: Node, b: Node) -> bool:
	return String(a.get_path()) < String(b.get_path())

func find_support_below() -> Node2D:
	var support: Node2D = null
	var closest_gap := INF
	for index in ride_detector.get_collision_count():
		var collider := ride_detector.get_collider(index) as Node2D
		if not (collider is Player or collider is MovingPlatform):
			continue
		if collider is Player and collider.global_position.y <= global_position.y:
			continue

		var support_top := (
			(collider as Player).get_shape_top()
			if collider is Player
			else (collider as MovingPlatform).get_shape_top()
		)
		var gap := absf(support_top - get_shape_bottom())
		if gap < closest_gap or (
			is_equal_approx(gap, closest_gap)
			and support != null
			and String(collider.get_path()) < String(support.get_path())
		):
			support = collider
			closest_gap = gap
	return support


func apply_animations() -> void:
		
	face_direction(facing_right)
	
	if input.action:
		animations.play(&"wall_jump")
	if grounded or on_platform:
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
# Deterministic replacement for is_on_floor()
func check_is_grounded() -> bool:
	var collision := KinematicCollision2D.new()
	if test_move(global_transform, Vector2.DOWN * GROUND_CHECK_DISTANCE, collision):
		if collision.get_normal().dot(Vector2.UP) > 0.7:
			return true
	return false

func get_shape_top() -> float:
	return collision_shape.global_position.y - get_shape_half_extents().y

func get_shape_bottom() -> float:
	return collision_shape.global_position.y + get_shape_half_extents().y

func get_shape_half_extents() -> Vector2:
	var rectangle := collision_shape.shape as RectangleShape2D
	if rectangle:
		return rectangle.size * 0.5
	return Vector2.ZERO
