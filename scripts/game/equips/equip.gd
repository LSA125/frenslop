extends Node2D
class_name Equip

@export var pick_up_collider: CollisionShape2D
@export var pick_up_offset := Vector2.ZERO
@export var rollback_synchronizer: RollbackSynchronizer
@export var FALL_SPEED := 20.0

var holder_peer_id := 0
var velocity := Vector2.ZERO
var sleep := false
var default_position := Vector2.ZERO


func _ready() -> void:
	default_position = global_position
	set_multiplayer_authority(1)
	rollback_synchronizer.process_settings()


# RollbackOrderManager owns the coordinated equipment pass.
func _rollback_tick(_delta: float, _tick: int, _is_fresh: bool) -> void:
	pass


func prepare_tick(players_by_peer_id: Dictionary) -> void:
	var holder := get_holder(players_by_peer_id)
	if holder == null:
		return
	sleep = false
	velocity = Vector2.ZERO
	update_held_transform(holder)


func simulate_world_tick(delta: float) -> void:
	if holder_peer_id != 0 or sleep:
		return
	var floor_collision := _find_floor_collision()
	if floor_collision.is_empty():
		velocity.y = FALL_SPEED
		position += velocity * delta
		return
	velocity = Vector2.ZERO
	if floor_collision["in_kill_zone"]:
		global_position = default_position
		return
	var collision_point: Vector2 = floor_collision["point"]
	var rectangle := pick_up_collider.shape as RectangleShape2D
	var half_height := rectangle.size.y * 0.5 if rectangle != null else 0.0
	global_position.y = collision_point.y - half_height - pick_up_collider.position.y
	sleep = true


func _find_floor_collision() -> Dictionary:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = pick_up_collider.shape
	query.transform = get_pickup_shape_transform()
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


func get_pickup_shape_transform() -> Transform2D:
	return pick_up_collider.global_transform


func get_holder(players_by_peer_id: Dictionary) -> Player:
	return players_by_peer_id.get(holder_peer_id) as Player


func equip_to(player: Player) -> void:
	holder_peer_id = player.get_peer_id()
	velocity = Vector2.ZERO
	sleep = false
	update_held_transform(player)


func drop_from(player: Player) -> void:
	if holder_peer_id != player.get_peer_id():
		return
	update_held_transform(player)
	holder_peer_id = 0
	velocity = Vector2.ZERO
	sleep = false


func update_held_transform(player: Player) -> void:
	var player_transform := PhysicsServer2D.body_get_state(
		player.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM
	) as Transform2D
	var direction := 1.0 if player.facing_right else -1.0
	global_position = player_transform.origin + Vector2(
		pick_up_offset.x * direction,
		pick_up_offset.y
	)
	flip_horizontal(player.facing_right)

func animate(_action_hold_ticks: int, _action_released_ticks: int) -> void:
	pass

func process_action(_player: Player, _tick: int) -> Array[Node]:
	return []


func flip_horizontal(_right: bool) -> void:
	pass
