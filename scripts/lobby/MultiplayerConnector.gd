extends Node

@export var name_input: LineEdit
@export var host_button: Button
@export var join_button: Button
@export var start_button: Button
@export var players_list: HBoxContainer

func _ready() -> void:
	start_button.disabled = true
	start_button.visible = false
	host_button.pressed.connect(_on_host_button_pressed)
	join_button.pressed.connect(_on_join_button_pressed)
	start_button.pressed.connect(_on_start_button_pressed)
	MultiplayerManager.game_started.connect(_on_game_started)
	MultiplayerManager.player_list_changed.connect(players_list.on_player_list_changed)

func _on_host_button_pressed() -> void:
	print("Hosting game...")
	MultiplayerManager.host_game(name_input.text)
	start_button.visible = true
	players_list.on_player_list_changed()

func _on_join_button_pressed() -> void:
	print("Joining game...")
	MultiplayerManager.join_game("", name_input.text)

func _on_start_button_pressed() -> void:
	print("Starting game...")
	MultiplayerManager.start_game()

func _on_game_started() -> void:
	get_tree().change_scene_to_file("res://scenes/Game.tscn")
	print("Successfully switched to main scene.")
