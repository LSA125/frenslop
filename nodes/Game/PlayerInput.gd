extends Node
class_name PlayerInput

@export var movement : float = 0.0
@export var jump : bool = false
@export var action_held := false
@export var equip_held := false

func _ready() -> void:
	NetworkTime.before_tick_loop.connect(_gather)
	
func _gather() -> void:
	if not is_multiplayer_authority():
		return
	
	movement = Input.get_axis("MoveLeft", "MoveRight")
	jump = Input.is_action_pressed("Jump")
	action_held = Input.is_action_pressed("Action")
	equip_held = Input.is_action_pressed("Drop")
