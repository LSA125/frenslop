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
@export var floor_detector : ShapeCast2D
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

var visited := false

func on_tick_end(_tick):
	visited = false

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	NetworkRollback.on_prepare_tick.connect(prepare)
	NetworkRollback.on_record_tick.connect(on_tick_end)
	rollback_sync.process_settings()

func get_net_velocity(delta:float,tick:int,is_fresh:bool) -> Vector2:
	if not visited:
		update(delta,tick,is_fresh)
	return velocity + floor_vel
	
func update(delta:float, tick:int, is_fresh:bool):
	if not visited:
		if tmp != position:
			print("tmp != position (rollback updated)")
		apply_equip(delta, tick)
		apply_continuous_forces(delta)
		apply_impulse_forces(delta)
		apply_movement(delta, tick, is_fresh)
		visited = true

func get_platform_height() -> float:
	return global_position.y - collision_shape.shape.size.y/2

func _rollback_tick(delta: float, tick:int, _is_fresh:bool) -> void:
	update(delta,tick,_is_fresh)

var tmp
func _process(delta: float) -> void:
	apply_animations()

func prepare(_tick):
	tmp = position
	effects_detector.force_shapecast_update()
	floor_detector.force_shapecast_update()
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

func apply_movement(delta, tick, is_fresh) -> void:
	update_platform_info(delta, tick, is_fresh)
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
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	velocity -= floor_vel
	velocity -= continuous_velocity
	if on_platform:
		snap_to_platform()

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
	# If the platform manager explicitly snapped us down this frame, we are grounded
	var collision := KinematicCollision2D.new()
	#Test for a collision 
	if test_move(global_transform, Vector2.DOWN * (SNAP_DISTANCE + 1), collision):
		if collision.get_normal().dot(Vector2.UP) > 0.7:
			return true
	return false

func update_platform_info(delta, tick, is_fresh) -> void:
	floor_vel = Vector2.ZERO
	on_platform = false
	if floor_detector.is_colliding():
			for i in floor_detector.get_collision_count():
				var collider := floor_detector.get_collider(i)
				if collider.has_method("get_net_velocity") and collider.global_position.y > global_position.y:
					if floor_detector.get_collision_normal(i).dot(Vector2.UP) > 0.7:
						floor_vel = collider.get_net_velocity(delta, tick, is_fresh)
						on_platform = true
						break

func snap_to_platform() -> void:
	if not floor_detector.is_colliding(): return
	
	var collider = floor_detector.get_collider(0)
	if collider.has_method("get_platform_height"):
		var bottom : float = global_position.y + collision_shape.shape.size.y / 2
		global_position.y -= bottom - collider.get_platform_height() + SNAP_DISTANCE
