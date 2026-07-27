extends MultiplayerSpawner

@export var player_scene: PackedScene

func _ready() -> void:
	if multiplayer.is_server():
		_spawn_players.call_deferred()

func _spawn_players() -> void:
	var spawn_parent := get_node(spawn_path)
	var counter := 1
	var peers_and_self := Array(multiplayer.get_peers())
	peers_and_self.append(1)
	peers_and_self.sort()

	for player_id in peers_and_self:
		var player_name := str(player_id)
		if spawn_parent.has_node(player_name):
			continue

		print("Spawning player for ID %s" % player_id)
		var player_instance = player_scene.instantiate()
		player_instance.name = player_name
		player_instance.position = Vector2(100 * counter, 100)
		spawn_parent.add_child(player_instance)
		counter += 1
		print("Spawned player %s at position %s" % [player_id, player_instance.position])
