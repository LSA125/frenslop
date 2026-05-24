extends Node2D
class_name Equip

@export var pick_up_collider : CollisionShape2D
@export var pick_up_offset := Vector2.ZERO
@export var floor_detector : ShapeCast2D
@export var rollback_synchronizer : RollbackSynchronizer
var player: Player = null
var DEFAULT_POS : Vector2 = Vector2.ZERO
var highlighted := false
var velocity := Vector2.ZERO
var sleep := false
@onready var gravity : float = ProjectSettings.get_setting("physics/2d/default_gravity")
func _ready() -> void:
	DEFAULT_POS = Vector2.ZERO
	set_multiplayer_authority(1)
	rollback_synchronizer.process_settings()

func _rollback_tick(delta : float, input : PlayerInput) -> void:
	if player:
		sleep = false
		global_position = player.global_position + pick_up_offset
	else:
		if not sleep:
			floor_detector.force_shapecast_update()
			if not floor_detector.is_colliding():
				velocity.y += gravity
			else:
				velocity = Vector2.ZERO
				var collision_point := floor_detector.get_collision_point(0)
				position.y = pick_up_collider.shape.y/2 + collision_point
				sleep = true
			position += velocity * delta

#returns the force the other colliding object should receive
func on_collision(collider : Node2D) -> Vector2:
	return Vector2.ZERO
	
func equip(player : Player) -> void:
	self.player = player
	pick_up_collider.disabled = true
	
func unequip() -> void:
	self.player = null
	pick_up_collider.disabled = false
	
func flip_horizontal(right : bool) -> void:
	pass
