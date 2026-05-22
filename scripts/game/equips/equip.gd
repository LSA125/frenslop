extends Node2D
class_name Equip

var player: Player
var attached_to_player := false
var DEFAULT_POS : Vector2 = Vector2.ZERO

func _ready() -> void:
	DEFAULT_POS = Vector2.ZERO
	
func pick_up(player) -> void:
	pass
		
func equip_tick(delta : float, input : PlayerInput) -> void:
	pass

#returns the force the other colliding object should receive
func on_collision(collider : Node2D) -> Vector2:
	return Vector2.ZERO
	
func on_equip() -> void:
	show()
	
func on_unequip() -> void:
	hide()

func flip_horizontal(right : bool) -> void:
	pass
