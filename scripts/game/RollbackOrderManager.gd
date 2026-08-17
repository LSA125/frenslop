extends Node2D
class_name RollbackOrderManager

var players: Array[Player] = []
var moving_objects: Array[Node2D] = []
var equips: Array[Equip] = []
var ordered_bodies: Array[Node2D] = []
var ride_supports := {}
var players_by_peer_id := {}
var held_equips := {}

@onready var players_root: Node2D = $Players
@onready var moving_objects_root: Node2D = $MovingObjects
@onready var equips_root: Node2D = _find_equips_root()

func _ready() -> void:
	NetworkRollback.after_prepare_tick.connect(prepare_tick)
	NetworkRollback.on_process_tick.connect(ordered_movement)

func _find_equips_root() -> Node2D:
	var local_root := get_node_or_null("Equips") as Node2D
	if local_root != null:
		return local_root
	var sibling_root := get_node_or_null("../Equips") as Node2D
	if sibling_root != null:
		return sibling_root
	return get_parent() as Node2D

func prepare_tick(tick: int) -> void:
	players.clear()
	moving_objects.clear()
	equips.clear()
	ordered_bodies.clear()
	ride_supports.clear()
	players_by_peer_id.clear()
	held_equips.clear()
	for child in players_root.get_children():
		if child is Player:
			players.append(child)
			players_by_peer_id[child.get_peer_id()] = child
	for child in moving_objects_root.get_children():
		if child is Node2D and child.has_method("prepare"):
			moving_objects.append(child)
	if equips_root != null:
		for child in equips_root.get_children():
			if child is Equip:
				equips.append(child)
	players.sort_custom(sort_node_path)
	moving_objects.sort_custom(sort_node_path)
	equips.sort_custom(sort_node_path)
	ordered_bodies.assign(moving_objects)
	ordered_bodies.append_array(players)
	ordered_bodies.sort_custom(sort_node_path)
	for player in players:
		NetworkRollback.notify_simulated(player)
	for equip in equips:
		NetworkRollback.notify_simulated(equip)
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
	_refresh_equipped_items()
	for equip in equips:
		equip.prepare_tick(players_by_peer_id)

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

func ordered_movement(tick: int) -> void:
	var delta := NetworkTime.ticktime
	resolve_equipment()
	for equip in equips:
		var previous_position := equip.global_position
		equip.simulate_world_tick(delta)
		if NetworkRollback.is_rollback() and equip.global_position != previous_position:
			NetworkRollback.mutate(equip)
	resolve_attacks(tick)
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
	_update_held_equip_transforms()

func resolve_equipment() -> void:
	players.sort_custom(sort_node_path)
	var dropped_this_tick := {}
	var dropping_players := {}
	for player in players:
		if not player.equip_pressed_this_tick:
			continue
		var held := held_equips.get(player.get_peer_id()) as Equip
		if held == null:
			continue
		_mark_mutated(held)
		_mark_mutated(player)
		held.drop_from(player)
		player.cancel_action_charge()
		dropped_this_tick[held] = true
		dropping_players[player] = true
	_refresh_equipped_items()

	var claims: Array[Dictionary] = []
	for player in players:
		if (
			not player.equip_pressed_this_tick
			or player.equipped_item != null
			or dropping_players.has(player)
		):
			continue
		var candidate := player.find_nearest_equip(equips, dropped_this_tick)
		if candidate == null:
			continue
		var player_transform := PhysicsServer2D.body_get_state(
			player.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM
		) as Transform2D
		claims.append({
			"player": player,
			"equip": candidate,
			"distance": player_transform.origin.distance_squared_to(candidate.global_position),
		})
	claims.sort_custom(sort_equip_claim)
	for claim in claims:
		var player := claim["player"] as Player
		var equip := claim["equip"] as Equip
		if player.equipped_item != null or equip.holder_peer_id != 0:
			continue
		_mark_mutated(equip)
		_mark_mutated(player)
		equip.equip_to(player)
		player.cancel_action_charge()
		player.set_equipped_item(equip)
		held_equips[player.get_peer_id()] = equip
	_refresh_equipped_items()
	_update_held_equip_transforms()

func resolve_attacks(tick: int) -> void:
	players.sort_custom(sort_node_path)
	for player in players:
		var equip := player.equipped_item
		if equip != null:
			equip.process_action(player, tick)
		elif player.can_use_default_attack():
			_mark_mutated(player)
			player.use_default_attack(tick)

func _refresh_equipped_items() -> void:
	held_equips.clear()
	for player in players:
		player.set_equipped_item(null)
	for equip in equips:
		if equip.holder_peer_id == 0:
			continue
		var holder := equip.get_holder(players_by_peer_id)
		if holder == null or held_equips.has(equip.holder_peer_id):
			_mark_mutated(equip)
			equip.holder_peer_id = 0
			equip.sleep = false
			continue
		held_equips[equip.holder_peer_id] = equip
		holder.set_equipped_item(equip)

func _update_held_equip_transforms() -> void:
	for equip in equips:
		var holder := equip.get_holder(players_by_peer_id)
		if holder == null:
			continue
		var previous_position := equip.global_position
		equip.update_held_transform(holder)
		if NetworkRollback.is_rollback() and equip.global_position != previous_position:
			NetworkRollback.mutate(equip)

func _mark_mutated(node: Node) -> void:
	if NetworkRollback.is_rollback():
		NetworkRollback.mutate(node)

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

func sort_equip_claim(a: Dictionary, b: Dictionary) -> bool:
	if not is_equal_approx(a["distance"], b["distance"]):
		return a["distance"] < b["distance"]
	var a_player := a["player"] as Player
	var b_player := b["player"] as Player
	if a_player.get_peer_id() != b_player.get_peer_id():
		return a_player.get_peer_id() < b_player.get_peer_id()
	return String((a["equip"] as Equip).get_path()) < String((b["equip"] as Equip).get_path())

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
