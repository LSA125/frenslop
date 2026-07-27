extends RapierAnimatableBody2D
class_name MovingPlatform
@export var speed := 100
@export var distance_y := 200
@export var distance_x := 200
@export var collision_shape : CollisionShape2D

var start_position := Vector2.ZERO
var end_position := Vector2.ZERO
var distance := 0.0
var platform_velocity := Vector2.ZERO

func _ready() -> void:
	await get_tree().process_frame
	start_position = global_position
	end_position = Vector2(start_position.x + distance_x, start_position.y + distance_y)
	distance = start_position.distance_to(end_position)
	NetworkRollback.on_prepare_tick.connect(prepare)
	set_multiplayer_authority(1,true)

func get_tick_offset() -> Vector2:
	return platform_velocity * NetworkTime.ticktime

func prepare(tick) -> void:
	var previous_position = _get_position_for_tick(tick - 1)
	global_position = _get_position_for_tick(tick)
	force_update_transform()
	platform_velocity = (global_position - previous_position) / NetworkTime.ticktime

func _get_position_for_tick(tick):
	if is_zero_approx(distance):
		return start_position
	var distance_moved = NetworkTime.ticks_to_seconds(tick) * speed
	var progress = distance_moved / distance
	progress = pingpong(progress, 1)
	return start_position.lerp(end_position, progress)

func get_shape_top() -> float:
	return collision_shape.global_position.y - get_shape_half_extents().y

func get_shape_half_extents() -> Vector2:
	var rectangle := collision_shape.shape as RectangleShape2D
	if rectangle:
		return rectangle.size * 0.5
	return Vector2.ZERO
