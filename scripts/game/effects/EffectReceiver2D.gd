extends Area2D
class_name EffectReceiver2D

@export var effect_target_path: NodePath = ^".."


func get_effect_target() -> Node:
	return get_node_or_null(effect_target_path)


func apply_effect(effect: Variant) -> bool:
	var target := get_effect_target()
	if target == null or not target.has_method(&"apply_effect"):
		push_warning("Effect receiver target does not implement apply_effect: %s" % target)
		return false
	target.apply_effect(effect)
	return true
