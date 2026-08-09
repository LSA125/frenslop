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
@export var ride_detector : ShapeCast2D
@export var effects_detector : ShapeCast2D
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

var rope_vel : Dictionary = {}
var grounded := false

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	rollback_sync.process_settings()

func _rollback_tick(_delta: float, _tick: int, _is_fresh: bool) -> void:
	pass

func _process(_delta: float) -> void:
	apply_animations()

func prepare_tick(delta: float) -> void:
	continuous_velocity = Vector2.ZERO
	effects_detector.force_shapecast_update()
	grounded = check_is_grounded()
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
	if effects_detector.is_colliding():
		for i in effects_detector.get_collision_count():
			var collider := effects_detector.get_collider(i)
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

func apply_ride_velocity() -> void:
	var support: Node2D
	for index in ride_detector.get_collision_count():
		var collider := ride_detector.get_collider(index) as Node2D
		if not (collider is Player or collider is MovingPlatform):
			continue
		if ride_detector.get_collision_normal(index).dot(Vector2.UP) <= COLLISION_NORMAL_TOLERANCE:
			continue
		if collider.global_position.y <= global_position.y:
			continue
		if support == null or collider.global_position.y < support.global_position.y or (
			is_equal_approx(collider.global_position.y, support.global_position.y)
			and String(collider.get_path()) < String(support.get_path())
		):
			support = collider
	if input.jump:
		update_emitted_velocity(null)
		return
	if support != null and tick_velocity.y >= 0.0 and check_is_grounded():
		tick_velocity.y -= velocity.y
		velocity.y = 0.0
		grounded = true
	if support is Player:
		tick_velocity += (support as Player).emitted_velocity
	elif support is MovingPlatform:
		tick_velocity += (support as MovingPlatform).get_tick_offset() / NetworkTime.ticktime
	update_emitted_velocity(support)

func update_emitted_velocity(support: Node2D) -> void:
	emitted_velocity = tick_velocity
	var direction := signf(tick_velocity.x)
	if is_zero_approx(direction):
		return

	effects_detector.target_position = Vector2(direction * CARRIER_BLOCK_CHECK_DISTANCE, 0.0)
	effects_detector.force_shapecast_update()
	var pushed_player := false
	var blocked_by_other := false
	for index in effects_detector.get_collision_count():
		var collider := effects_detector.get_collider(index)
		if collider == support or not (collider is PhysicsBody2D):
			continue
		if (
			effects_detector.get_collision_normal(index).dot(Vector2(direction, 0.0))
			>= -COLLISION_NORMAL_TOLERANCE
		):
			continue
		if collider is Player:
			pushed_player = true
		else:
			blocked_by_other = true
	effects_detector.target_position = Vector2.ZERO

	if not pushed_player and not blocked_by_other:
		return
	emitted_velocity.x = 0.0
	if pushed_player and not blocked_by_other and signf(input.movement) == direction:
		var push_velocity := PUSH_FORCE * input.movement
		emitted_velocity.x = direction * minf(absf(tick_velocity.x), absf(push_velocity))

func custom_move_x(delta: float) -> void:
	var motion := Vector2(tick_velocity.x * delta, 0.0)
	var collision := move_and_collide(motion, false, safe_margin, true)
	if (
		collision
		and motion.dot(collision.get_normal()) < 0.0
		and absf(collision.get_normal().x) > COLLISION_NORMAL_TOLERANCE
	):
		velocity.x = 0.0
		tick_velocity.x = 0.0

func custom_move_y(delta: float) -> void:
	var motion := Vector2(0.0, tick_velocity.y * delta)
	var collision := move_and_collide(motion, false, safe_margin, true)
	if not collision:
		return
	var normal := collision.get_normal()
	if normal.dot(Vector2.UP) > COLLISION_NORMAL_TOLERANCE:
		grounded = true
		if tick_velocity.y > 0.0:
			velocity.y = 0.0
			tick_velocity.y = 0.0
	elif normal.dot(Vector2.DOWN) > COLLISION_NORMAL_TOLERANCE and tick_velocity.y < 0.0:
		var collider := collision.get_collider() as Player
		var collider_is_moving_up := collider != null and collider.tick_velocity.y < 0.0
		if not collider_is_moving_up:
			velocity.y = 0.0
			tick_velocity.y = 0.0

func apply_ground_snap() -> void:
	if input.jump or velocity.y < 0.0:
		return
	var snap_motion := Vector2.DOWN * GROUND_CHECK_DISTANCE
	var collision := move_and_collide(snap_motion, true, safe_margin, false)
	if (
		collision == null
		or collision.get_normal().dot(Vector2.UP) <= COLLISION_NORMAL_TOLERANCE
	):
		return
	collision = move_and_collide(snap_motion, false, safe_margin, false)
	if (
		collision == null
		or collision.get_normal().dot(Vector2.UP) <= COLLISION_NORMAL_TOLERANCE
	):
		return
	grounded = true
	velocity.y = 0.0
	tick_velocity.y = 0.0

func check_is_grounded() -> bool:
	var collision := KinematicCollision2D.new()
	return (
		test_move(global_transform, Vector2.DOWN * GROUND_CHECK_DISTANCE, collision)
		and collision.get_normal().dot(Vector2.UP) > COLLISION_NORMAL_TOLERANCE
	)

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
