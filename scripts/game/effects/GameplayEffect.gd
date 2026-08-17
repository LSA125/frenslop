extends RefCounted
class_name GameplayEffect

var source_peer_id: int
var velocity_delta: Vector2
var tick: int


func _init(p_source_peer_id: int, p_velocity_delta: Vector2, p_tick: int) -> void:
	source_peer_id = p_source_peer_id
	velocity_delta = p_velocity_delta
	tick = p_tick
