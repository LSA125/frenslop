extends Node
class_name PlayerInput

@export var movement : Vector2 = Vector2.ZERO
@export var jump : float = false

func _ready() -> void:
	NetworkTime.before_tick_loop.connect(_gather)
	
func _gather() -> void:
	if not is_multiplayer_authority():
		return
	
	movement = Input.get_vector("MoveLeft", "MoveRight", "MoveUp", "MoveDown")
	jump = Input.get_action_strength("Jump")
