extends AnimatableBody2D

@export var speed := 100
@export var distance_y := 200
@export var distance_x := 200
@export var server_position := Vector2.ZERO

var start_position := Vector2.ZERO
var end_position := Vector2.ZERO
var moving_to_end := true

func _ready() -> void:
	start_position = global_position
	end_position = Vector2(start_position.x + distance_x, start_position.y + distance_y)
	server_position = start_position
	NetworkTime.on_tick.connect(_tick)

func _tick(delta: float, tick) -> void:
	var target_position := end_position if moving_to_end else start_position
	global_position = global_position.move_toward(target_position, speed * delta)

	if global_position.distance_to(target_position) < 5.0:
		moving_to_end = not moving_to_end
