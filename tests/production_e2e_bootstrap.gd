extends Node

const ProductionE2EController := preload("res://tests/production_e2e_controller.gd")


func _ready() -> void:
	var controller := ProductionE2EController.new()
	controller.name = "ProductionE2EController"
	get_tree().root.add_child.call_deferred(controller)
	get_tree().change_scene_to_file.call_deferred("res://scenes/MainMenu.tscn")
