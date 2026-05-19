extends Node2D
class_name Equip

var player: Player

func _ready() -> void:
	player = get_parent().get_parent() as Player
	
func equip_tick(delta : float, input : PlayerInput) -> void:
	pass

#returns the force the other colliding object should receive
func on_collision(collider : Node2D) -> Vector2:
	return Vector2.ZERO
	
func on_equip() -> void:
	show()
	
func on_unequip() -> void:
	hide()
