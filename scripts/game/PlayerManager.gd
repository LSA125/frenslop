extends Node2D

var players: Array[Player] = []

func _ready() -> void:
	NetworkRollback.after_prepare_tick.connect(prepare_tick)
	NetworkRollback.on_process_tick.connect(ordered_movement)

func prepare_tick(_tick: int) -> void:
	players.clear()
	for child in get_children():
		if child is Player:
			players.append(child)
	players.sort_custom(sort_id)
	for player in players:
		NetworkRollback.notify_simulated(player)
		player.force_update_transform()
	for player in players:
		player.prepare_tick(NetworkTime.ticktime)

func resolve_pushes() -> void:
	players.sort_custom(sort_id)
	for player in players:
		var direction := signf(player.input.movement)
		if direction:
			propagate_push(player, direction, player.PUSH_FORCE * player.input.movement, {player: true})

func propagate_push(player: Player, direction: float, force: float, visited: Dictionary) -> void:
	var next_players: Array[Player] = []
	for index in player.effects_detector.get_collision_count():
		var collider := player.effects_detector.get_collider(index) as Player
		if (
			collider
			and player.effects_detector.get_collision_normal(index).dot(Vector2(direction, 0.0))
			< -player.COLLISION_NORMAL_TOLERANCE
		):
			next_players.append(collider)
	next_players.sort_custom(sort_id)
	for next_player in next_players:
		if visited.has(next_player):
			continue
		visited[next_player] = true
		next_player.tick_velocity.x += force
		propagate_push(next_player, direction, force, visited)

func ordered_movement(_tick: int) -> void:
	var delta := NetworkTime.ticktime
	for player in players:
		player.ride_detector.force_shapecast_update()
		player.effects_detector.force_shapecast_update()
	resolve_pushes()
	players.sort_custom(sort_y_descending)
	for player in players:
		player.apply_ride_velocity()
	players.sort_custom(sort_x_ascending)
	for player in players:
		if player.tick_velocity.x <= 0.0:
			player.custom_move_x(delta)
	players.reverse()
	for player in players:
		if player.tick_velocity.x > 0.0:
			player.custom_move_x(delta)
	for player in players:
		player.force_update_transform()
	players.sort_custom(sort_y_ascending)
	for player in players:
		if player.tick_velocity.y <= 0.0:
			player.custom_move_y(delta)
			player.force_update_transform()
	players.reverse()
	for player in players:
		if player.tick_velocity.y > 0.0:
			player.custom_move_y(delta)
			player.force_update_transform()
	for player in players:
		player.apply_ground_snap()


func sort_id(a: Player, b: Player) -> bool:
	return String(a.get_path()) < String(b.get_path())

func sort_x_ascending(a: Player, b: Player) -> bool:
	if a.position.x != b.position.x:
		return a.position.x < b.position.x
	return sort_id(a, b)

func sort_y_ascending(a: Player, b: Player) -> bool:
	if a.position.y != b.position.y:
		return a.position.y < b.position.y
	return sort_id(a, b)

func sort_y_descending(a: Player, b: Player) -> bool:
	if a.position.y != b.position.y:
		return a.position.y > b.position.y
	return sort_id(a, b)
