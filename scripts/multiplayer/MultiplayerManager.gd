extends Node

signal player_list_changed
signal connection_failed
signal game_started

const PlayerInfo = preload("res://scripts/multiplayer/PlayerInfo.gd")

@export var port := 8910
@export var default_address := "127.0.0.1"

var players: Dictionary = {}
var local_player: Dictionary = {}
var peer: ENetMultiplayerPeer

func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func host_game(player_name: String) -> void:
	if player_name.is_empty():
		player_name = "Host_%s" % (randi() % 1000)

	peer = ENetMultiplayerPeer.new()
	var error := peer.create_server(port)
	if error != OK:
		push_error("Failed to host: %s" % error)
		return

	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.multiplayer_peer = peer

	local_player = PlayerInfo.create(1, player_name, default_address)
	players[1] = local_player
	print("Server started.")

func join_game(address: String, player_name: String) -> void:
	if address.is_empty():
		address = default_address
	if player_name.is_empty():
		player_name = "Player_%s" % (randi() % 1000)

	peer = ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port)
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	if error != OK:
		push_error("Failed to start client: %s" % error)
		return

	local_player = PlayerInfo.create(0, player_name, address)
	multiplayer.multiplayer_peer = peer
	print("Client started, connecting...")

func start_game() -> void:
	if multiplayer.is_server():
		rpc("rpc_start_game")

func _on_connected_to_server() -> void:
	local_player["id"] = multiplayer.get_unique_id()
	rpc_id(1, "server_register_player", local_player["name"])
	print("Connected to server with ID %s" % local_player["id"])

func _on_connection_failed() -> void:
	connection_failed.emit()
	multiplayer.multiplayer_peer = null

func _on_server_disconnected() -> void:
	players.clear()
	local_player = {}
	multiplayer.multiplayer_peer = null
	player_list_changed.emit()

func _on_peer_connected(id: int) -> void:
	print("Peer %s connecting..." % id)

func _on_peer_disconnected(id: int) -> void:
	if players.has(id):
		players.erase(id)
		player_list_changed.emit()

@rpc("any_peer", "reliable")
func server_register_player(player_name: String) -> void:
	if not multiplayer.is_server():
		return

	var id := multiplayer.get_remote_sender_id()
	players[id] = PlayerInfo.create(id, player_name)
	sync_player_list()

@rpc("authority", "reliable", "call_local")
func update_player_list(data: Dictionary) -> void:
	players = data.duplicate(true)
	player_list_changed.emit()

@rpc("authority", "call_local")
func rpc_start_game() -> void:
	game_started.emit()

func sync_player_list() -> void:
	rpc("update_player_list", players)
