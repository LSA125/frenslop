extends Node2D
class_name Equip

@export var pick_up_collider : CollisionShape2D
@export var pick_up_offset := Vector2.ZERO
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
			var floor_collision := _find_floor_collision()
			if floor_collision.is_empty():
				velocity.y = FALL_SPEED
			else:
				velocity = Vector2.ZERO
				# If the weapon enters a kill zone, send it back
				if floor_collision["in_kill_zone"]:
					position = DEFAULT_POS
					velocity = Vector2.ZERO
					return
				
				#Otherwise make it stop falling
				var collision_point: Vector2 = floor_collision["point"]
				position.y =  collision_point.y - pick_up_collider.shape.size.y/2
				sleep = true
			position += velocity * delta

func _find_floor_collision() -> Dictionary:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = pick_up_collider.shape
	query.transform = pick_up_collider.global_transform
	query.collision_mask = 1
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var space_state := get_world_2d().direct_space_state
	var intersections := space_state.intersect_shape(query, 32)
	if intersections.is_empty():
		return {}
	var in_kill_zone := false
	for intersection in intersections:
		var collider := intersection.get("collider") as Node
		if collider != null and collider.is_in_group("kill"):
			in_kill_zone = true
			break
	var contact_points := space_state.collide_shape(query, 1)
	if contact_points.size() < 2:
		return {}
	return {
		"in_kill_zone": in_kill_zone,
		"point": contact_points[1],
	}

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
