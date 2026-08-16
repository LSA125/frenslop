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
var initialized := false

func _ready() -> void:
	await get_tree().process_frame
	if not initialized:
		start_position = global_position
		end_position = Vector2(start_position.x + distance_x, start_position.y + distance_y)
		distance = start_position.distance_to(end_position)
		initialized = true
	set_multiplayer_authority(1,true)

func get_carrier_velocity() -> Vector2:
	return platform_velocity

func get_carrier_motion_velocity() -> Vector2:
	return platform_velocity

func get_ordered_velocity() -> Vector2:
	return platform_velocity

func prepare(tick: int) -> void:
	if not initialized:
		platform_velocity = Vector2.ZERO
		return
	var previous_position: Vector2 = _get_position_for_tick(tick - 1)
	var next_position: Vector2 = _get_position_for_tick(tick)
	global_position = previous_position
	platform_velocity = (next_position - previous_position) / NetworkTime.ticktime

func restore_to_tick(tick: int) -> void:
	global_position = _get_position_for_tick(tick)
	platform_velocity = Vector2.ZERO

func custom_move_carrier_x(
	delta: float,
	_excluded_bodies: Array[RID] = [],
	_player_candidates: Array[Player] = []
) -> void:
	global_position.x += platform_velocity.x * delta

func custom_move_y(delta: float) -> void:
	global_position.y += platform_velocity.y * delta

func _get_position_for_tick(tick: int) -> Vector2:
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
