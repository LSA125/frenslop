extends RapierAnimatableBody2D
class_name MovingPlatform
@export var speed := 100
@export var distance_y := 200
@export var distance_x := 200
@export var server_position := Vector2.ZERO

@export var collision_shape : CollisionShape2D
@export var ride_detector : ShapeCast2D

var start_position := Vector2.ZERO
var end_position := Vector2.ZERO
var distance := 0.0
var _velocity : Vector2 = Vector2.ZERO

func _ready() -> void:
	await get_tree().process_frame
	start_position = global_position
	end_position = Vector2(start_position.x + distance_x, start_position.y + distance_y)
	distance = start_position.distance_to(end_position)
	server_position = start_position
	NetworkRollback.after_prepare_tick.connect(update)
	set_multiplayer_authority(1,true)
	
	
func update(tick) -> void:
	ride_detector.force_shapecast_update()
	var previous_position = _get_position_for_tick(tick-1)
	global_position = _get_position_for_tick(tick)
	_velocity = (global_position-previous_position) / NetworkTime.ticktime
	for i in ride_detector.get_collision_count():
		var player := ride_detector.get_collider(i) as Player
		if ride_detector.get_collision_normal(i).dot(Vector2.DOWN) > 0.7:
			if player.velocity.y > 0:
				player.velocity.y = 0
			player.apply_position_offset(global_position - previous_position)
	
func _get_position_for_tick(tick):
	var distance_moved = NetworkTime.ticks_to_seconds(tick) * speed
	var progress = distance_moved / distance
	progress = pingpong(progress, 1)
	return start_position.lerp(end_position, progress)
