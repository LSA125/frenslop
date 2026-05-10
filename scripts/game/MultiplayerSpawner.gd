extends MultiplayerSpawner

@export var player_scene: PackedScene

func _ready() -> void:
	if multiplayer.is_server():
		var counter := 0
		for player_id in MultiplayerManager.players.keys():
			print("Spawning player for ID %s" % player_id)
			var player_instance = player_scene.instantiate()
			player_instance.name = str(player_id)
			player_instance.position = Vector2(100 * counter, 100)
			get_node(spawn_path).add_child(player_instance, true)
			counter += 1
			print("Spawned player %s at position %s" % [player_id, player_instance.position])
