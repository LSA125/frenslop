extends RapierCharacterBody2D
class_name Player
@export_group("Player Control")
@export var SPEED := 300.0
@export var JUMP_VELOCITY := -400.0
#gap between the snapped position and the platform
@export var SNAP_DISTANCE := 1
#the velocity a player can push another
@export var PUSH_FORCE := 200
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

var floor_vel := Vector2.ZERO

var rope_vel : Dictionary = {}
var on_platform := false
var grounded := false



func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	NetworkRollback.after_prepare_tick.connect(prepare)
	rollback_sync.process_settings()

func get_net_velocity() -> Vector2:
	return velocity + floor_vel
	
func get_platform_height() -> float:
	return collision_shape.global_position.y - collision_shape.shape.size.y / 2.0

func _rollback_tick(delta: float, tick, _is_fresh) -> void:
	apply_equip(delta, tick)
	apply_continuous_forces(delta)
	apply_impulse_forces(delta)
	apply_movement(delta)

func _process(delta: float) -> void:
	apply_animations()

func prepare(_tick):
	effects_detector.force_shapecast_update()
	ride_detector.force_shapecast_update()
	continuous_velocity = Vector2.ZERO

func apply_equip(delta, tick) -> void:
	if input.action:
		if active_equip:
			return

func apply_continuous_forces(delta: float) -> void:
	for child in internal_effects_holder.get_children():
		if child.has_method("apply_velocity"):
			continuous_velocity += child.apply_velocity(self)
		else:
			print("Child does not have apply_velocity method")
#all bombs/explosions/springs. Any effect that would be an area2d
func apply_impulse_forces(delta: float) -> void:
	if effects_detector.is_colliding():
		for i in effects_detector.get_collision_count():
			var collider := effects_detector.get_collider(i)
			if collider.has_method("apply_velocity"):
				impulse_velocity += collider.apply_velocity(self)
			if collider is Player:
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
	return

func apply_movement(delta: float) -> void:
	grounded = check_is_grounded()
	
	if not grounded:
		velocity += get_gravity() * delta
	elif input.jump:
		velocity.y = JUMP_VELOCITY
		on_platform = false

	var direction_x: float = input.movement
	if direction_x:
		velocity.x = direction_x * SPEED
		if direction_x > 0:
			facing_right = true
		elif direction_x < 0:
			facing_right = false
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
	
	velocity += impulse_velocity
	impulse_velocity = impulse_velocity.move_toward(Vector2.ZERO, KNOCKBACK_DECAY_SPEED*delta)
	velocity += continuous_velocity
	velocity += floor_vel
	velocity *= NetworkTime.physics_factor
	var before_pos := global_position
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	velocity -= floor_vel
	velocity -= continuous_velocity
	var riding_bodies := collect_riding_bodies()
	update_riding_bodies(global_position - before_pos, riding_bodies)

func collect_riding_bodies() -> Array[Player]:
	var bodies: Array[Player] = []
	for i in ride_detector.get_collision_count():
		var collider := ride_detector.get_collider(i) as Player
		if ride_detector.get_collision_normal(i).dot(Vector2.DOWN) > 0.7:
			bodies.append(collider)
	return bodies

func update_riding_bodies(position_offset: Vector2, riding_bodies: Array[Player]) -> void:
	for collider in riding_bodies:
		var player := collider as Player
		player.velocity = Vector2.ZERO
		player.apply_position_offset(position_offset)
		if player.velocity.y > 0:
			player.velocity.y = 0

func apply_position_offset(offset : Vector2) -> void:
	position += offset
	var riding_bodies := collect_riding_bodies()
	update_riding_bodies(offset, riding_bodies)

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
# Deterministic replacement for is_on_floor()
func check_is_grounded() -> bool:
	var collision := KinematicCollision2D.new()
	if test_move(global_transform, Vector2.DOWN * (SNAP_DISTANCE + 1), collision):
		if collision.get_normal().dot(Vector2.UP) > 0.7:
			return true
	return false
