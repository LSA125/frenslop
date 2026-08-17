extends Equip
class_name BatEquip

const CHARGE_ANIMATION := &"charge"
const HIT_ANIMATION := &"hit"
const IDLE_ANIMATION := &"idle"

@export var attack_shape: Shape2D
@export var attack_offset := Vector2(24.0, 2.0)
@export var minimum_velocity := 300.0
@export var maximum_velocity := 1000.0
@export var maximum_charge_ticks := 45
@export var sprite: AnimatedSprite2D


func _ready() -> void:
	super()
	sprite.play(&"idle")
	if sprite != null and not sprite.animation_finished.is_connected(_on_animation_finished):
		sprite.animation_finished.connect(_on_animation_finished)


func process_action(player: Player, tick: int) -> Array[Node]:
	if player.action_released_ticks <= 0:
		return []
	var charge := _get_charge_ratio(player.action_released_ticks)
	var attack_velocity := roundf(lerpf(minimum_velocity, maximum_velocity, charge))
	return player.apply_velocity_effect(attack_shape, attack_offset, attack_velocity, tick)

func flip_horizontal(right: bool) -> void:
	if sprite != null:
		sprite.flip_h = not right


func animate(action_hold_ticks: int, action_released_ticks: int) -> void:
	if sprite == null:
		return
	if action_released_ticks > 0:
		if sprite.animation != HIT_ANIMATION:
			sprite.play(HIT_ANIMATION)
		return
	if action_hold_ticks > 0:
		if sprite.animation != CHARGE_ANIMATION or not sprite.is_playing():
			sprite.play(CHARGE_ANIMATION)
	elif sprite.animation == HIT_ANIMATION:
		return
	elif sprite.animation != IDLE_ANIMATION or not sprite.is_playing():
		sprite.play(IDLE_ANIMATION)


func _get_charge_ratio(charge_ticks: int) -> float:
	var charge_range := maxi(1, maximum_charge_ticks - 1)
	var charged_ticks := clampi(charge_ticks - 1, 0, charge_range)
	return float(charged_ticks) / float(charge_range)


func _on_animation_finished() -> void:
	if sprite.animation == HIT_ANIMATION:
		sprite.play(IDLE_ANIMATION)
