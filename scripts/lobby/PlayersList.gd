extends HBoxContainer

@export var player_card_scene: PackedScene
@export var ready_button: Button
@export var start_button: Button

func _ready() -> void:
	ready_button.pressed.connect(_on_ready_button_pressed)
	child_exiting_tree.connect(_on_child_exiting_tree)

func add_player_card(player: Dictionary) -> void:
	for child in get_children():
		if child.name == str(player["id"]):
			child.setup(player["name"], player["id"], false)
			return

	var card = player_card_scene.instantiate()
	card.name = str(player["id"])
	card.setup(player["name"], player["id"], false)
	add_child(card)
	card.ready_status_changed.connect(_on_ready_changed)

func _on_ready_button_pressed() -> void:
	if multiplayer.is_server():
		var card = get_node(str(MultiplayerManager.local_player["id"]))
		card.update_ready_state(not card.is_ready)
		_on_ready_changed()
	else:
		rpc_id(1, "server_toggle_ready", MultiplayerManager.local_player["id"])

@rpc("any_peer", "reliable")
func server_toggle_ready(player_id: int) -> void:
	if not multiplayer.is_server():
		return

	var card = get_node(str(player_id))
	card.update_ready_state(not card.is_ready)

func on_player_list_changed() -> void:
	var current_ids := {}
	for child in get_children():
		current_ids[child.name] = true

	var manager_ids := {}
	for player_id in MultiplayerManager.players.keys():
		manager_ids[str(player_id)] = true

	for player in MultiplayerManager.players.values():
		if not current_ids.has(str(player["id"])):
			add_player_card(player)

	for card in get_children():
		if not manager_ids.has(card.name):
			card.queue_free()

func _on_ready_changed() -> void:
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		start_button.disabled = not _all_ready()

func _all_ready() -> bool:
	for child in get_children():
		if not child.is_ready:
			return false
	return true

func _on_child_exiting_tree(node: Node) -> void:
	if node.has_signal("ready_status_changed") and node.ready_status_changed.is_connected(_on_ready_changed):
		node.ready_status_changed.disconnect(_on_ready_changed)
	_on_ready_changed()

func _exit_tree() -> void:
	if MultiplayerManager.player_list_changed.is_connected(on_player_list_changed):
		MultiplayerManager.player_list_changed.disconnect(on_player_list_changed)
