extends AnimatableBody2D
class_name MovingPlatform
@export var speed := 100
@export var distance_y := 200
@export var distance_x := 200
@export var server_position := Vector2.ZERO

var start_position := Vector2.ZERO
var end_position := Vector2.ZERO
var distance := 0.0
var _velocity : Vector2 = Vector2.ZERO

#for collisions to detect moving speed.
func get_net_velocity() -> Vector2:
	return _velocity

func _ready() -> void:
	start_position = global_position
	end_position = Vector2(start_position.x + distance_x, start_position.y + distance_y)
	distance = start_position.distance_to(end_position)
	server_position = start_position
	NetworkRollback.on_prepare_tick.connect(_apply_tick)
	
func _apply_tick(tick) -> void:
	var previous_position = _get_position_for_tick(tick - 1)
	global_position = _get_position_for_tick(tick)

	_velocity = (global_position - previous_position) / NetworkTime.ticktime
		
func _get_position_for_tick(tick: int):
	var distance_moved = NetworkTime.ticks_to_seconds(tick) * speed
	var progress = distance_moved / distance
	progress = pingpong(progress, 1)

	return start_position.lerp(end_position, progress)
