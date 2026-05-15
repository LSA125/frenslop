extends NetworkRigidBody2D
class_name BouncingBall

@export var bounce_force: float = 32000.0
@export var max_contacts: int = 4

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1, true)
	contact_monitor = true
	max_contacts_reported = max_contacts
	$RollbackSynchronizer.process_settings()
	
func _physics_rollback_tick(_delta: float, _tick: int) -> void:
	var contact_count : int = direct_state.get_contact_count()
	if contact_count == 0:
		return
	var normal : Vector2 = Vector2.ZERO
	var range : int = min(contact_count, max_contacts)
	for i in range:
		if contact_count > max_contacts:
			break
		normal += direct_state.get_contact_local_normal(i)

	normal = normal.normalized()
	if normal == Vector2.ZERO:
		return
	apply_central_force(normal * bounce_force)
