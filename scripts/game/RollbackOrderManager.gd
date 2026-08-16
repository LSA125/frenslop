extends Node2D
class_name RollbackOrderManager

var players: Array[Player] = []
var moving_objects: Array[Node2D] = []
var ordered_bodies: Array[Node2D] = []
var ride_supports := {}

@onready var players_root: Node2D = $Players
@onready var moving_objects_root: Node2D = $MovingObjects

func _ready() -> void:
	NetworkRollback.after_prepare_tick.connect(prepare_tick)
	NetworkRollback.on_process_tick.connect(ordered_movement)

func prepare_tick(tick: int) -> void:
	players.clear()
	moving_objects.clear()
	ordered_bodies.clear()
	ride_supports.clear()
	for child in players_root.get_children():
		if child is Player:
			players.append(child)
	for child in moving_objects_root.get_children():
		if child is Node2D and child.has_method("prepare"):
			moving_objects.append(child)
	players.sort_custom(sort_node_path)
	moving_objects.sort_custom(sort_node_path)
	ordered_bodies.assign(moving_objects)
	ordered_bodies.append_array(players)
	ordered_bodies.sort_custom(sort_node_path)
	for player in players:
		NetworkRollback.notify_simulated(player)
	for moving_object in moving_objects:
		moving_object.prepare(tick)
	for body in ordered_bodies:
		body.force_update_transform()
	var support_candidates: Array[Node2D] = []
	support_candidates.assign(players)
	support_candidates.append_array(moving_objects)
	for player in players:
		ride_supports[player] = player.find_support_below(support_candidates)
	for player in players:
		player.prepare_tick(NetworkTime.ticktime, ride_supports.get(player))

func resolve_pushes() -> void:
	players.sort_custom(sort_node_path)
	for player in players:
		var direction := signf(player.input.movement)
		if direction:
			propagate_push(
				player,
				direction,
				player.PUSH_FORCE * player.input.movement,
				{player: true}
			)

func propagate_push(
	player: Player,
	direction: float,
	force: float,
	visited: Dictionary
) -> void:
	for next_player in player.find_push_contacts(direction, players):
		if (
			ride_supports.get(next_player) == player
			or ride_supports.get(player) == next_player
		):
			continue
		if visited.has(next_player):
			continue
		visited[next_player] = true
		if NetworkRollback.is_rollback():
			NetworkRollback.mutate(next_player)
		next_player.tick_velocity.x += force
		propagate_push(next_player, direction, force, visited)

func ordered_movement(_tick: int) -> void:
	var delta := NetworkTime.ticktime
	resolve_pushes()
	players.sort_custom(sort_y_descending)
	for player in players:
		player.apply_ride_velocity(ride_supports.get(player))
		if NetworkRollback.is_rollback() and not player.carrier_velocity.is_zero_approx():
			NetworkRollback.mutate(player)
	var horizontal_exclusions := {}
	for body in ordered_bodies:
		var excluded_bodies: Array[RID] = []
		var support = ride_supports.get(body)
		if support != null:
			excluded_bodies.append(support.get_rid())
		for candidate in players:
			if ride_supports.get(candidate) == body:
				excluded_bodies.append(candidate.get_rid())
		horizontal_exclusions[body] = excluded_bodies
	# Shared carrier translation must resolve before relative walk/push motion.
	move_carriers_x(delta, horizontal_exclusions)
	players.sort_custom(sort_x_ascending)
	for player in players:
		if player.tick_velocity.x <= 0.0:
			player.custom_move_x(delta, horizontal_exclusions[player], players)
			player.force_update_transform()
	players.reverse()
	for player in players:
		if player.tick_velocity.x > 0.0:
			player.custom_move_x(delta, horizontal_exclusions[player], players)
			player.force_update_transform()
	ordered_bodies.sort_custom(sort_y_ascending)
	for body in ordered_bodies:
		if body.get_ordered_velocity().y <= 0.0:
			body.custom_move_y(delta)
			body.force_update_transform()
	ordered_bodies.reverse()
	for body in ordered_bodies:
		if body.get_ordered_velocity().y > 0.0:
			body.custom_move_y(delta)
			body.force_update_transform()
	players.sort_custom(sort_y_descending)
	for player in players:
		player.apply_ground_snap(ride_supports.get(player))
		player.force_update_transform()

func move_carriers_x(delta: float, horizontal_exclusions: Dictionary) -> void:
	ordered_bodies.sort_custom(sort_x_ascending)
	for body in ordered_bodies:
		if body.get_carrier_motion_velocity().x < 0.0:
			body.custom_move_carrier_x(
				delta, horizontal_exclusions[body], players
			)
			body.force_update_transform()
	ordered_bodies.reverse()
	for body in ordered_bodies:
		if body.get_carrier_motion_velocity().x > 0.0:
			body.custom_move_carrier_x(
				delta, horizontal_exclusions[body], players
			)
			body.force_update_transform()
	for player in players:
		player.tick_velocity.x -= player.carrier_velocity.x

func sort_node_path(a: Node, b: Node) -> bool:
	return String(a.get_path()) < String(b.get_path())

func sort_x_ascending(a: Node2D, b: Node2D) -> bool:
	if a.position.x != b.position.x:
		return a.position.x < b.position.x
	return sort_node_path(a, b)

func sort_y_ascending(a: Node2D, b: Node2D) -> bool:
	if a.position.y != b.position.y:
		return a.position.y < b.position.y
	return sort_node_path(a, b)

func sort_y_descending(a: Player, b: Player) -> bool:
	if a.position.y != b.position.y:
		return a.position.y > b.position.y
	return sort_node_path(a, b)
