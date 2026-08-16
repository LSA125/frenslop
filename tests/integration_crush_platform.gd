extends MovingPlatform

var start_tick := -1
var travel_ticks := 1


func configure(
	p_start_tick: int,
	p_travel_ticks: int,
	p_start_position: Vector2,
	p_end_position: Vector2
) -> void:
	start_tick = p_start_tick
	travel_ticks = maxi(p_travel_ticks, 1)
	start_position = p_start_position
	end_position = p_end_position
	initialized = true
	global_position = start_position
	force_update_transform()
	var interpolator := get_node_or_null("TickInterpolator") as TickInterpolator
	if interpolator:
		interpolator.teleport()


func _get_position_for_tick(tick: int) -> Vector2:
	if start_tick < 0:
		return global_position
	var progress := clampf(float(tick - start_tick) / float(travel_ticks), 0.0, 1.0)
	return start_position.lerp(end_position, progress)


func get_shape_bottom() -> float:
	return collision_shape.global_position.y + get_shape_half_extents().y
