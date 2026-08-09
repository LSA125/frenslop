extends MovingPlatform

var start_tick := -1
var travel_ticks := 1


func _ready() -> void:
	NetworkRollback.on_prepare_tick.connect(_prepare_tick)


func _exit_tree() -> void:
	if NetworkRollback.on_prepare_tick.is_connected(_prepare_tick):
		NetworkRollback.on_prepare_tick.disconnect(_prepare_tick)


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
	global_position = start_position
	force_update_transform()
	var interpolator := get_node_or_null("TickInterpolator") as TickInterpolator
	if interpolator:
		interpolator.teleport()


func _prepare_tick(tick: int) -> void:
	if start_tick < 0:
		return
	var previous_position := _position_for_tick(tick - 1)
	global_position = _position_for_tick(tick)
	force_update_transform()
	platform_velocity = (global_position - previous_position) / NetworkTime.ticktime


func _position_for_tick(tick: int) -> Vector2:
	var progress := clampf(float(tick - start_tick) / float(travel_ticks), 0.0, 1.0)
	return start_position.lerp(end_position, progress)
