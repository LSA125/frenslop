extends NetworkRigidBody2D
class_name BouncingBall

@export var bounce_speed: float = 500.0
@export var max_contacts: int = 4

func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1, true)
	continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	contact_monitor = true
	max_contacts_reported = max_contacts
	$RollbackSynchronizer.process_settings()
	
func _physics_rollback_tick(_delta: float, _tick: int) -> void:
	var contact_count : int = direct_state.get_contact_count()
	if contact_count == 0:
		return
	var normal : Vector2 = Vector2.ZERO
	var contact_limit : int = min(contact_count, max_contacts)
	for i in contact_limit:
		normal += direct_state.get_contact_local_normal(i)

	normal = normal.normalized()
	if normal == Vector2.ZERO:
		return

	var normal_speed : float = direct_state.linear_velocity.dot(normal)
	if normal_speed > 0.0:
		return

	var tangent_velocity: Vector2 = direct_state.linear_velocity - normal * normal_speed
	direct_state.linear_velocity = tangent_velocity + normal * bounce_speed
