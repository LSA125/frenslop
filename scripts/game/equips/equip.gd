extends Node2D
class_name Equip

@export var pick_up_collider : CollisionShape2D
@export var pick_up_offset := Vector2.ZERO
@export var floor_detector : ShapeCast2D
@export var rollback_synchronizer : RollbackSynchronizer
@export var FALL_SPEED := 20
var player: Player = null
var DEFAULT_POS : Vector2 = Vector2.ZERO
var velocity := Vector2.ZERO
var sleep := false

func _ready() -> void:
	DEFAULT_POS = global_position
	set_multiplayer_authority(1)
	rollback_synchronizer.process_settings()
	NetworkRollback.on_prepare_tick.connect(prepare)

#prepare for the frame
func prepare(_tick) -> void:
	pass

func _rollback_tick(delta : float, _tick, _is_fresh) -> void:
	if player:
		sleep = false
		global_position = player.global_position + pick_up_offset
	else:
		if not sleep:
			floor_detector.force_shapecast_update()
			if not floor_detector.is_colliding():
				velocity.y = FALL_SPEED
			else:
				velocity = Vector2.ZERO
				var collider_count = floor_detector.get_collision_count()
				# If the weapon enters a kill zone, send it back
				for i in collider_count:
					if floor_detector.get_collider(i).has_method("is_in_group") and \
					   floor_detector.get_collider(i).is_in_group("kill"):
						position = DEFAULT_POS
						velocity = Vector2.ZERO
						return
				
				#Otherwise make it stop falling
				var collision_point := floor_detector.get_collision_point(0)
				position.y =  collision_point.y - pick_up_collider.shape.size.y/2
				sleep = true
			position += velocity * delta

#What to do when the user clicks the attack button
func on_action() -> void:
	pass

#returns the force the other colliding object should receive
###not a signal
func on_collision(collider : Node2D) -> Vector2:
	return Vector2.ZERO
	
func equip(player : Player) -> void:
	self.player = player
	pick_up_collider.disabled = true

#when a player is hoving in the hitbox
func hover() -> void:
	pass

func unequip() -> void:
	self.player = null
	pick_up_collider.disabled = false
	sleep = false


#flips the weapons on the horizontal axis.
###DO NOT scale by -1
func flip_horizontal(right : bool) -> void:
	pass
