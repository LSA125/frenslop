extends Node2D

const PLAYER_SCENE := preload("res://nodes/game/player.tscn")
const BAT_SCENE := preload("res://nodes/game/equips/bat.tscn")
const ORDER_MANAGER_SCRIPT := preload("res://scripts/game/RollbackOrderManager.gd")

const TOLERANCE := 0.1
const PLAYER_Y := 300.0

var failures: Array[String] = []
var order_manager: RollbackOrderManager
var players_root: Node2D
var equips_root: Node2D
var attacker: Player
var target: Player
var bat: Equip


func _ready() -> void:
	if not NetworkTime.is_initial_sync_done():
		var start_error := await NetworkTime.start()
		if start_error != OK:
			_fail("Failed to initialize NetworkTime")
			_finish()
			return
	NetworkTime.stop()

	var physics_driver := RapierDriver2D.new()
	physics_driver.name = "RapierDriver2D"
	physics_driver.physics_factor = 1
	physics_driver.rollback_physics_space = true
	add_child(physics_driver)

	order_manager = ORDER_MANAGER_SCRIPT.new()
	order_manager.name = "RollbackOrderManager"
	players_root = Node2D.new()
	players_root.name = "Players"
	order_manager.add_child(players_root)
	var moving_objects_root := Node2D.new()
	moving_objects_root.name = "MovingObjects"
	order_manager.add_child(moving_objects_root)
	equips_root = Node2D.new()
	equips_root.name = "Equips"
	order_manager.add_child(equips_root)
	add_child(order_manager)

	_add_floor()
	attacker = _add_player("101", Vector2(200.0, PLAYER_Y))
	target = _add_player("102", Vector2(232.0, PLAYER_Y))
	bat = BAT_SCENE.instantiate() as Equip
	bat.name = "Bat"
	bat.position = Vector2(216.0, PLAYER_Y)
	equips_root.add_child(bat)

	await get_tree().process_frame
	await get_tree().process_frame
	_sync_physics_queries()
	_reset_inputs()

	_test_default_attack()
	if failures.is_empty():
		_test_pickup_and_drop()
	if failures.is_empty():
		_test_bat_charge()
	_finish()


func _test_default_attack() -> void:
	_reset_player_motion()
	attacker.input.action_held = true
	_run_tick(1)
	_assert_close(target.impulse_velocity.x, 200.0, "default attack velocity")
	_assert_equal(
		attacker.remaining_cooldown_ticks,
		attacker.PUNCH_COOLDOWN_TICKS,
		"default attack cooldown"
	)
	_assert_true(attacker.should_play_action_animation(), "successful punch animation was suppressed")

	_run_tick(2)
	_assert_close(
		target.impulse_velocity.x,
		200.0 - target.KNOCKBACK_DECAY_SPEED * NetworkTime.ticktime,
		"held action repeated the default attack"
	)

	attacker.input.action_held = false
	_run_tick(3)
	_reset_target()
	attacker.input.action_held = true
	_run_tick(4)
	_assert_close(target.impulse_velocity.x, 0.0, "cooldown allowed an early attack")
	_assert_true(
		not attacker.should_play_action_animation(),
		"cooldown allowed the unarmed action animation"
	)

	attacker.input.action_held = false
	_run_tick(5)
	_reset_target()
	attacker.remaining_cooldown_ticks = 1
	attacker.input.action_held = true
	_run_tick(6)
	_assert_close(target.impulse_velocity.x, 200.0, "expired cooldown blocked attack")
	_assert_true(attacker.should_play_action_animation(), "expired cooldown blocked the animation")


func _test_pickup_and_drop() -> void:
	attacker.input.action_held = false
	_reset_player_motion()
	_reset_bat_world_position()
	attacker.input.equip_held = true
	target.input.equip_held = true
	_run_tick(10)
	_assert_equal(bat.holder_peer_id, attacker.get_peer_id(), "pickup tie-break owner")
	_assert_true(attacker.equipped_item == bat, "attacker did not derive held bat")
	_assert_true(target.equipped_item == null, "one item was assigned to two players")

	attacker.input.equip_held = false
	target.input.equip_held = false
	_run_tick(11)
	attacker.input.equip_held = true
	_run_tick(12)
	_assert_equal(bat.holder_peer_id, 0, "drop did not clear holder peer ID")
	_assert_true(attacker.equipped_item == null, "drop left a derived equipped item")

	attacker.input.equip_held = false
	_run_tick(13)
	attacker.input.equip_held = true
	_run_tick(14)
	_assert_equal(bat.holder_peer_id, attacker.get_peer_id(), "bat could not be picked up again")
	attacker.input.equip_held = false


func _test_bat_charge() -> void:
	var bat_sprite := bat.get("sprite") as AnimatedSprite2D
	_reset_player_motion()
	attacker.cancel_action_charge()
	attacker.input.action_held = true
	_run_tick(20)
	attacker.apply_animations()
	_assert_close(target.impulse_velocity.x, 0.0, "bat attacked before release")
	_assert_equal(bat_sprite.animation, &"charge", "bat did not show its charge animation")
	_assert_true(
		bat_sprite.sprite_frames.get_animation_loop(&"charge"),
		"bat charge animation was not configured to loop"
	)
	attacker.input.action_held = false
	_run_tick(21)
	attacker.apply_animations()
	_assert_close(target.impulse_velocity.x, 300.0, "minimum bat charge")
	_assert_equal(bat_sprite.animation, &"hit", "bat release did not show the hit animation")
	bat_sprite.animation_finished.emit()

	_reset_target()
	attacker.cancel_action_charge()
	attacker.input.action_held = true
	var maximum_charge_ticks: int = bat.get("maximum_charge_ticks")
	for charge_index in maximum_charge_ticks:
		_run_tick(30 + charge_index)
	attacker.apply_animations()
	_assert_equal(bat_sprite.animation, &"charge", "maximum charge stopped the charge animation")
	attacker.input.action_held = false
	_run_tick(30 + maximum_charge_ticks)
	_assert_close(target.impulse_velocity.x, 1000.0, "maximum bat charge")


func _run_tick(tick: int) -> void:
	NetworkRollback._simulated_nodes.clear()
	NetworkRollback._mutated_nodes.clear()
	NetworkRollback.after_prepare_tick.emit(tick)
	NetworkRollback.on_process_tick.emit(tick)


func _reset_inputs() -> void:
	for player in [attacker, target]:
		player.input.movement = 0.0
		player.input.jump = false
		player.input.action_held = false
		player.input.equip_held = false


func _reset_player_motion() -> void:
	attacker.global_position = Vector2(200.0, PLAYER_Y)
	target.global_position = Vector2(232.0, PLAYER_Y)
	for player in [attacker, target]:
		player.velocity = Vector2.ZERO
		player.impulse_velocity = Vector2.ZERO
		player.continuous_velocity = Vector2.ZERO
		player.tick_velocity = Vector2.ZERO
		player.emitted_velocity = Vector2.ZERO
		player.carrier_velocity = Vector2.ZERO
		player.force_update_transform()
	_sync_physics_queries()


func _reset_target() -> void:
	target.global_position = Vector2(232.0, PLAYER_Y)
	target.velocity = Vector2.ZERO
	target.impulse_velocity = Vector2.ZERO
	target.tick_velocity = Vector2.ZERO
	target.force_update_transform()
	_sync_physics_queries()


func _reset_bat_world_position() -> void:
	bat.holder_peer_id = 0
	bat.global_position = Vector2(216.0, PLAYER_Y)
	bat.velocity = Vector2.ZERO
	bat.sleep = true


func _add_player(player_name: String, player_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.name = player_name
	player.position = player_position
	players_root.add_child(player)
	return player


func _add_floor() -> void:
	var floor_body := StaticBody2D.new()
	floor_body.position = Vector2(216.0, 326.0)
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(400.0, 20.0)
	shape.shape = rectangle
	floor_body.add_child(shape)
	add_child(floor_body)


func _sync_physics_queries() -> void:
	var physics_space := get_viewport().world_2d.space
	RapierPhysicsServer2D.space_step(physics_space, 0.0)
	RapierPhysicsServer2D.space_flush_queries(physics_space)


func _assert_close(actual: float, expected: float, message: String) -> void:
	if absf(actual - expected) > TOLERANCE:
		_fail("%s: expected %.3f, got %.3f" % [message, expected, actual])


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		_fail("%s: expected %s, got %s" % [message, expected, actual])


func _assert_true(value: bool, message: String) -> void:
	if not value:
		_fail(message)


func _fail(message: String) -> void:
	failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("EQUIP_COMBAT_REGRESSION: PASS")
		get_tree().quit()
		return
	for failure in failures:
		push_error("EQUIP_COMBAT_REGRESSION: %s" % failure)
	get_tree().quit(1)
