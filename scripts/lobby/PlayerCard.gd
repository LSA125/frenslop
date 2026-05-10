extends PanelContainer

signal ready_status_changed

@export var name_label: Label
@export var id_label: Label
@export var ready_label: Label
@export var is_ready := false:
	set(value):
		is_ready = value
		if ready_label != null:
			ready_label.text = "Ready" if value else "Not Ready"
		ready_status_changed.emit()

func _enter_tree() -> void:
	set_multiplayer_authority(1)

func setup(player_name: String, id: int, in_ready: bool) -> void:
	name_label.text = player_name
	id_label.text = "ID: %s" % id
	is_ready = in_ready

func update_ready_state(in_ready: bool) -> void:
	is_ready = in_ready
