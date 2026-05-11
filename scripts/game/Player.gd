extends RapierCharacterBody2D

@export var SPEED := 300.0
@export var JUMP_VELOCITY := -400.0

@export var input: PlayerInput
@export var rollback_sync : RollbackSynchronizer

@export var external_velocity : Vector2 = Vector2.ZERO

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	rollback_sync.process_settings()
	
func _rollback_tick(delta: float, tick, is_fresh) -> void:
	apply_movement(delta)

func apply_movement(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	else:
		velocity.y = JUMP_VELOCITY * input.jump

	var direction: Vector2 = input.movement
	if direction:
		velocity.x = direction.x * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)

	velocity *= NetworkTime.physics_factor
	move_and_slide()
	velocity /= NetworkTime.physics_factor

func _force_update_is_on_floor():
	var v_tmp : Vector2 = velocity
	velocity = Vector2.ZERO
	move_and_slide()
	velocity = v_tmp
	
