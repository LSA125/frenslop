extends RapierCharacterBody2D
class_name Player
@export_group("Player Control")
@export var SPEED := 300.0
@export var JUMP_VELOCITY := -400.0
#gap between the snapped position and the platform
@export var SNAP_DISTANCE := 1

@export_group("Imports") 
@export var input: PlayerInput
@export var rollback_sync : RollbackSynchronizer
@export var collision_shape : CollisionShape2D
@export var floor_detector : ShapeCast2D
@export var effects_detector : ShapeCast2D
@export var internal_effects_holder : Node

@export_group("Force System Variables")
# Rollback note: Synchronize these IDs so every client knows what this player is attached to!
@export var attached_rope_object_ids : Array[int] = []
@export var knockback_vel := Vector2.ZERO
@export var KNOCKBACK_DECAY_SPEED := 800.0

@export_group("Equip System")
enum EQUIP {NONE,}
@export var active_equip : EQUIP = EQUIP.NONE
var equip_item : Node = null

# --- internally used variables ---
var applied_effects_velocity := Vector2.ZERO

var floor_vel := Vector2.ZERO

var rope_vel : Dictionary = {}
var on_platform := false
var is_grounded := false



func _ready() -> void:
	await get_tree().process_frame
	set_multiplayer_authority(1)
	input.set_multiplayer_authority(name.to_int())
	rollback_sync.process_settings()

func get_net_velocity() -> Vector2:
	return velocity + floor_vel
	
func get_platform_height() -> float:
	return global_position.y - collision_shape.shape.size.y/2
	
func _rollback_tick(delta: float, _tick, _is_fresh) -> void:
	apply_external_forces(delta)
	apply_movement(delta)

func apply_equip() -> void:
	if input.action:
		if active_equip:
			return

func apply_internal_forces(delta: float) -> void:
	for child in internal_effects_holder.get_children():
		if child.has_method("apply_velocity"):
			applied_effects_velocity += child.apply_velocity(self)
		else:
			print("Child does not have apply_velocity method")
#all bombs/explosions/springs. Any effect that would be an area2d
func apply_external_forces(delta: float) -> void:
	effects_detector.force_shapecast_update()
	if effects_detector.is_colliding():
		for i in effects_detector.get_collision_count():
			var collider := effects_detector.get_collider(i)
			if collider.has_method("apply_velocity"):
				applied_effects_velocity += collider.apply_velocity(self)
	return

func apply_movement(delta: float) -> void:
	update_platform_info()
	var grounded := check_is_grounded()
	
	if not grounded:
		velocity += get_gravity() * delta
	elif input.jump:
		velocity.y = JUMP_VELOCITY
		on_platform = false

	var direction_x: float = input.movement
	if direction_x:
		velocity.x = direction_x * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
	
	velocity += floor_vel
	velocity *= NetworkTime.physics_factor
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	velocity -= floor_vel
	
	if on_platform:
		snap_to_platform()
# Deterministic replacement for is_on_floor()
func check_is_grounded() -> bool:
	# If the platform manager explicitly snapped us down this frame, we are grounded
	var collision := KinematicCollision2D.new()
	#Test for a collision 
	if test_move(global_transform, Vector2.DOWN * (SNAP_DISTANCE + 1), collision):
		if collision.get_normal().dot(Vector2.UP) > 0.7:
			return true
	return false

func update_platform_info() -> void:
	floor_detector.force_shapecast_update()
	floor_vel = Vector2.ZERO
	on_platform = false
	if floor_detector.is_colliding():
			for i in floor_detector.get_collision_count():
				var collider := floor_detector.get_collider(i)
				if collider.has_method("get_net_velocity"):
					if floor_detector.get_collision_normal(i).dot(Vector2.UP) > 0.7:
						floor_vel = collider.get_net_velocity()
						on_platform = true
						break

func snap_to_platform() -> void:
	if not floor_detector.is_colliding(): return
	
	var collider = floor_detector.get_collider(0)
	if collider.has_method("get_platform_height"):
		var bottom : float = global_position.y + collision_shape.shape.size.y / 2
		global_position.y -= bottom - collider.get_platform_height() + SNAP_DISTANCE
