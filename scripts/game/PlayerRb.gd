extends NetworkRigidBody2D
class_name PlayerRb

@export_group("player control")
@export var SPEED := 300.0
@export var JUMP_VELOCITY := -400.0
# Gap between the snapped position and the platform
@export var SNAP_DISTANCE := 1

@export_group("imports") 
@export var input: PlayerInput
@export var rollback_sync : RollbackSynchronizer
@export var collision_shape : CollisionShape2D
@export var floor_detector : ShapeCast2D

var floor_vel := Vector2.ZERO
var on_platform := false
var is_grounded := false

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	rollback_sync.process_settings()
	lock_rotation = true

func get_net_velocity() -> Vector2:
	return linear_velocity
	
func get_platform_height() -> float:
	return global_position.y - collision_shape.shape.size.y / 2
	
func _rollback_tick(delta: float, _tick, _is_fresh) -> void:
	apply_movement(delta)

func apply_movement(delta: float) -> void:
	update_platform_info()
	
	# Vertical Movement & Gravity
	if not is_grounded and not on_platform:
		gravity_scale = 1
	else:
		if input.jump:
			linear_velocity.y = JUMP_VELOCITY
			gravity_scale = 1
		else:
			# Match the platform's vertical velocity to prevent drifting or bouncing
			linear_velocity.y = floor_vel.y
			gravity_scale = 0

	# Horizontal Movement
	var direction: Vector2 = input.movement
	if direction.x != 0:
		# Move at SPEED relative to the moving platform
		linear_velocity.x = (direction.x * SPEED) + floor_vel.x
	else:
		# Halt completely relative to the platform's current speed
		linear_velocity.x = move_toward(linear_velocity.x, floor_vel.x, SPEED)

func update_platform_info() -> void:
	floor_detector.force_shapecast_update()
	floor_vel = Vector2.ZERO
	on_platform = false
	is_grounded = false
	
	if floor_detector.is_colliding():
		for i in floor_detector.get_collision_count():
			# Verify the surface normal is facing upward
			if floor_detector.get_collision_normal(i).dot(Vector2.UP) > 0.7:
				is_grounded = true
				var collider := floor_detector.get_collider(i)
				
				# Duck-typing check to ensure the collider can provide network velocity
				if collider.has_method("get_net_velocity"):
					floor_vel = collider.get_net_velocity()
					on_platform = true
					
					# Force Snap execution
					if collider.has_method("get_platform_height"):
						var bottom : float = global_position.y + collision_shape.shape.size.y / 2
						global_position.y -= bottom - collider.get_platform_height() + SNAP_DISTANCE
				break
