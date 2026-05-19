extends Equip

@export var collision_shape : CollisionShape2D
@export var force : float = 500
func equip_tick(delta : float, input : PlayerInput) -> void:
	if input.action:
		collision_shape.disabled = false
	else:
		collision_shape.disabled = true
		
func on_collision(collider : Node2D) -> Vector2:
	return Vector2(force * player.d)
