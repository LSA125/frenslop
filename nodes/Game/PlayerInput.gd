extends Node
class_name PlayerInput

@export var movement : float = 0.0
@export var jump : bool = false
@export var action : bool = false
func _ready() -> void:
	NetworkTime.before_tick_loop.connect(_gather)
	
func _gather() -> void:
	if not is_multiplayer_authority():
		return
	
	movement = Input.get_axis("MoveLeft", "MoveRight")
	jump = Input.get_action_strength("Jump")
	action = Input.is_action_just_pressed("Action")
