extends CharacterBody2D

const SPEED := 300.0
const JUMP_VELOCITY := -400.0

@export var input: PlayerInput
@export var rollback_sync : RollbackSynchronizer

var _last_handled_jump_input_sequence := 0
func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	rollback_sync.process_settings()
	
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

	var v_temp : Vector2 = velocity
	velocity *= NetworkTime.physics_factor
	move_and_slide()
	velocity = v_temp

func _force_update_is_on_floor():
	var v_tmp : Vector2 = velocity
	velocity = Vector2.ZERO
	move_and_slide()
	velocity = v_tmp
	
