extends PhysicsDriver

class_name RapierDriver2D

var _state: StateManager2D

func _init_physics_space() -> void:
	physics_space = get_viewport().world_2d.space
	PhysicsServer2D.space_set_active(physics_space, false)

	_state = StateManager2D.new()
	_state.root_node = get_parent() if rollback_physics_space else self
	_state.set_max_cache_length(ProjectSettings.get_setting("netfox/rollback/history_limit", 64))
	_state.set_rolling_cache(true)
	add_child(_state)


func _physics_step(delta) -> void:
	RapierPhysicsServer2D.space_step(physics_space, delta)
	RapierPhysicsServer2D.space_flush_queries(physics_space)


func _snapshot_space(tick: int) -> void:
	# Re-simulation rewrites ticks already present in the rolling cache. Replace
	# the old entry so every tag remains unique and exact lookup stays valid.
	var cache_index := _state.ordered_cache_tags().rfind(tick)
	while cache_index >= 0:
		_state.remove_cached_by_index(cache_index)
		cache_index = _state.ordered_cache_tags().rfind(tick)
	_state.cache_state(physics_space, tick)


func _rollback_space(tick: int) -> void:
	var cached_ticks := _state.ordered_cache_tags()
	var cache_index := cached_ticks.rfind(tick)
	if cache_index < 0:
		return
	_state.load_cached_state(physics_space, cache_index)
