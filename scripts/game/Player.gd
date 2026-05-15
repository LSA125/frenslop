extends RapierCharacterBody2D
class_name Player
@export_group("player control")
@export var SPEED := 300.0
@export var JUMP_VELOCITY := -400.0
#gap between the snapped position and the platform
@export var SNAP_DISTANCE := 1

@export_group("imports") 
@export var input: PlayerInput
@export var rollback_sync : RollbackSynchronizer
@export var collision_shape : CollisionShape2D
@export var floor_detector : ShapeCast2D

var floor_vel := Vector2.ZERO
var on_platform := false

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	rollback_sync.process_settings()

func get_net_velocity() -> Vector2:
	return velocity + floor_vel
	
func get_platform_height() -> float:
	return global_position.y - collision_shape.shape.size.y/2
	
func _rollback_tick(delta: float, _tick, _is_fresh) -> void:
	apply_movement(delta)

func apply_movement(delta: float) -> void:
	update_platform_info()
	var grounded := is_on_floor()
	
	if not grounded and not on_platform:
		velocity += get_gravity() * delta
	else:
		velocity.y = JUMP_VELOCITY * input.jump

	var direction: Vector2 = input.movement
	if direction:
		velocity.x = direction.x * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
	
	velocity += floor_vel
	velocity *= NetworkTime.physics_factor
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	velocity -= floor_vel

func update_platform_info() -> void:
	floor_detector.force_shapecast_update()
	floor_vel = Vector2.ZERO
	on_platform = false
	if floor_detector.is_colliding():
		for i in floor_detector.get_collision_count():
			var collider := floor_detector.get_collider(i)
			if collider is Player or collider is MovingPlatform:
				if floor_detector.get_collision_normal(i).dot(Vector2.UP) > 0.7:
					floor_vel = collider.get_net_velocity()
					on_platform = true
					#force snap
					if collider.has_method("get_platform_height"):
						var bottom : float = global_position.y + collision_shape.shape.size.y/2
						global_position.y -= bottom - collider.get_platform_height() + SNAP_DISTANCE
					
					break
