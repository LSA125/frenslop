extends RapierCharacterBody2D
class_name Player
@export_group("player control")
@export var SPEED := 300.0
@export var JUMP_VELOCITY := -400.0
#distance downwards to check for moving platforms
@export var DOWN_SCAN := 1

@export_group("imports")
@export var input: PlayerInput
@export var rollback_sync : RollbackSynchronizer

var floor_vel := Vector2.ZERO

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	rollback_sync.process_settings()

func get_net_velocity():
	return velocity + floor_vel
	
func _rollback_tick(delta: float, tick, is_fresh) -> void:
	apply_movement(delta)

func apply_movement(delta: float) -> void:
	_force_update_is_on_floor()
	if not is_on_floor():
		velocity += get_gravity() * delta
	else:
		velocity.y = JUMP_VELOCITY * input.jump

	var direction: Vector2 = input.movement
	if direction:
		velocity.x = direction.x * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		
	#check platforms/players and add velocity
	floor_vel = Vector2.ZERO
	var floor_collision := KinematicCollision2D.new()
	if test_move(global_transform, Vector2.DOWN*DOWN_SCAN, floor_collision):
		var collider : Node2D = floor_collision.get_collider()
		if collider is MovingPlatform or collider is Player and collider.global_position.y > global_position.y:
			floor_vel = collider.get_net_velocity()
	velocity += floor_vel
	velocity *= NetworkTime.physics_factor
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	velocity -= floor_vel

func _force_update_is_on_floor():
	var v_tmp : Vector2 = velocity
	velocity = Vector2.ZERO
	move_and_slide()
	velocity = v_tmp
