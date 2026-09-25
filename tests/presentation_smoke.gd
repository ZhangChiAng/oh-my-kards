extends "res://tests/ui_smoke.gd"
## Independent presentation acceptance, reusing the established real-input harness.

const PresentationRun = preload("res://scripts/art_battle/presentation_run.gd")
const ProbeCard = preload("res://scripts/art/art_card.gd")


func _run() -> void:
	if run_id.is_empty() or output_dir.is_empty():
		push_error("Presentation test requires --run-id and --output-dir.")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output_dir)
	if not _check(DisplayServer.get_name() != "headless", "Presentation tests require a graphical display"):
		_finish()
		return
	root.mode = Window.MODE_WINDOWED
	root.size = MAIN_WINDOW
	Input.use_accumulated_input = false
	var scene: PackedScene = load(SCENE_PATH)
	battle = scene.instantiate()
	battle.seed_override = TEST_SEED
	# Observe the player's end-turn presentation before autonomous AI commands.
	battle.ai_step_delay = 10.0
	root.add_child(battle)
	current_scene = battle
	await _frames(3)
	_run_contract()
	await _turn_hints()
	await _frontline_geometry_and_transition()
	await _skin_timing_and_simultaneous_damage()
	await _terminal_delay()
	await _resize_cancels_animation()
	await _restart_during_animation()
	await _effect_sequence_and_interruption()
	await _draw_terminal()
	_finish()


func _run_contract() -> void:
	var run := PresentationRun.new()
	var receipt: Dictionary = {"count": 0, "cancelled": false}
	run.finished.connect(func(cancelled: bool): receipt.count += 1; receipt.cancelled = cancelled)
	run.complete()
	run.complete()
	run.cancel()
	_check(run.done and not run.cancelled and receipt.count == 1, "Successful presentation resolves exactly once")
	var cancelled_run := PresentationRun.new()
	var cancelled_receipt: Dictionary = {"count": 0, "cancelled": false}
	cancelled_run.finished.connect(func(cancelled: bool): cancelled_receipt.count += 1; cancelled_receipt.cancelled = cancelled)
	cancelled_run.cancel()
	cancelled_run.cancel()
	cancelled_run.complete()
	_check(cancelled_run.done and cancelled_run.cancelled and cancelled_receipt.count == 1 and cancelled_receipt.cancelled, "Cancel without a live animation owner resolves once")
	var snapshot: Dictionary = cancelled_run.snapshot()
	snapshot.stage = "modified-copy"
	_check(cancelled_run.snapshot().stage == "cancelled", "Presentation snapshot cannot change the run")


func _turn_hints() -> void:
	if not await _load_fixture(_mulligan_fixture(4)): return
	if not await _click("mulligan_confirm", false): return
	var opening: Dictionary = await _observe()
	_check(opening.stages.has("turn_start") and not opening.stages.has("turn_end"), "First battle turn has a start hint without a fictional ending")
	_check(opening.stages.has("travel"), "Opening cards travel from the mulligan row into their hand slots")
	var fixture: Dictionary = _fixture()
	_put(fixture, "secret-enemy-draw", "ai", "draw")
	if not await _load_fixture(fixture): return
	if not await _click("end_turn", false): return
	var ending: Dictionary = await _observe()
	_check(ending.stages.find("turn_end") >= 0 and ending.stages.find("turn_start") > ending.stages.find("turn_end"), "End-turn hint precedes the next start-turn hint")
	_check(ending.stages.has("travel"), "Enemy draw uses a visible card-back travel")
	_check(not JSON.stringify(ending).contains("secret-enemy-draw"), "Presentation trace retains no hidden opponent card identity")
	for card in _visible_cards():
		if str(card.mode) == "back":
			_check(not card.display_data.has("instance_id") and not card.display_data.has("card_id"), "Opponent draw is represented only by an anonymous card back")


func _skin_timing_and_simultaneous_damage() -> void:
	var expected_duration: float = -1.0
	for debug_enabled in ([false, true] if OS.get_cmdline_user_args().has("--art") else [false]):
		battle._view.geometry_debug = debug_enabled
		var profile_path: String = "geometry_debug" if debug_enabled else "material"
		var fixture: Dictionary = _fixture()
		_put(fixture, "attacker", "player", "frontline", "raid_tank")
		_put(fixture, "defender", "ai", "support", "raid_tank")
		fixture.units.attacker.attack = 2
		fixture.units.defender.attack = 2
		if not await _load_fixture(fixture): return
		if not await _begin_drag("unit:attacker", "unit:defender"): return
		_button(_point("unit:defender"), false)
		var observed: Dictionary = await _observe({"unit:attacker": 2, "unit:defender": 2}, {"unit:attacker": 0, "unit:defender": 0})
		_check(observed.before_checked and observed.before_valid, "Pre-impact attacker and defender retain their old HP: " + profile_path)
		_check(observed.before_counters_valid, "Pre-impact discard counters retain their old values: " + profile_path)
		_check(observed.hit_checked and observed.hit_valid, "Attack and retaliation HP change together at impact: " + profile_path)
		_check(observed.stages.has("attack_windup") and observed.stages.has("attack_line") and observed.stages.has("attack_hit") and observed.stages.has("attack_recover"), "Every attack phase is observable: " + profile_path)
		_check(_domain().sides.player.discard_ids.has("attacker") and _domain().sides.ai.discard_ids.has("defender"), "Simultaneous deaths resolve from one real mouse attack")
		_check(not _state().ui_controls.has("unit:attacker") and not _state().ui_controls.has("unit:defender"), "Dead cards leave the interactive layout after recovery")
		_check(_domain().frontline_ids.is_empty() and is_equal_approx(float(_state().presentation.frontline_y), _frontline_anchor("neutral")), "Final frontline casualty returns the divider to neutral: " + profile_path)
		if expected_duration < 0.0: expected_duration = float(observed.duration)
		_check(is_equal_approx(float(observed.duration), expected_duration) and is_equal_approx(expected_duration, 0.64), "All visual themes share the configured 0.64 second attack")
		trace.append({"step": "skin-timing", "profile": str(_state().presentation.render_mode), "duration": observed.duration, "stages": observed.stages})
	battle._view.geometry_debug = false


func _frontline_geometry_and_transition() -> void:
	for owner in ["neutral", "player", "ai", "neutral"]:
		var ownership_fixture: Dictionary = _fixture()
		if owner != "neutral": _put(ownership_fixture, "frontline-owner", owner, "frontline")
		if not await _load_fixture(ownership_fixture): return
		_check(is_equal_approx(float(_state().presentation.frontline_y), _frontline_anchor(owner)), "Public frontline ownership selects the divider anchor: " + owner)
	var fixture: Dictionary = _fixture()
	_put(fixture, "frontline-mover", "player", "support", "raid_tank")
	if not await _load_fixture(fixture): return
	if not await _begin_drag("unit:frontline-mover", "frontline:0"): return
	_button(_point("frontline:0"), false)
	var observed: Dictionary = await _observe()
	var intermediate: bool = false
	var lower: float = minf(_frontline_anchor("neutral"), _frontline_anchor("player"))
	var upper: float = maxf(_frontline_anchor("neutral"), _frontline_anchor("player"))
	for value in observed.frontline_values:
		if float(value) > lower + 0.01 and float(value) < upper - 0.01: intermediate = true
	_check(intermediate, "Real mouse advance moves the frontline divider through intermediate positions")
	_check(_domain().frontline_ids == ["frontline-mover"] and is_equal_approx(float(_state().presentation.frontline_y), _frontline_anchor("player")), "Accepted advance settles on the player's frontline anchor")
	trace.append({"step": "frontline-transition", "stages": observed.stages, "frontline_values": observed.frontline_values})


func _frontline_anchor(owner: String) -> float:
	return float(battle._view.geometry.layout["frontline_%s_y" % ("enemy" if owner == "ai" else owner)])


func _terminal_delay() -> void:
	var fixture: Dictionary = _fixture()
	fixture.sides.ai.hq_hp = 1
	_put(fixture, "finisher", "player", "frontline")
	fixture.units.finisher.attack = 1
	if not await _load_fixture(fixture): return
	var old_end_turn: Vector2 = _point("end_turn")
	if not await _begin_drag("unit:finisher", "hq:ai"): return
	_button(_point("hq:ai"), false)
	var observed: Dictionary = await _observe({"hq:ai": 1}, {"hq:ai": 0}, true)
	_check(observed.before_checked and observed.before_valid, "Lethal attack preserves HQ HP until impact")
	_check(observed.hit_checked and observed.hit_valid, "HQ HP reaches zero at impact")
	_check(observed.terminal_hidden, "Terminal panel stays hidden throughout attack recovery")
	_check(_domain().phase == "finished" and battle._view._modal_panel.visible, "Terminal panel appears only after the presentation completes")
	var final: Dictionary = _domain()
	_motion(old_end_turn)
	_button(old_end_turn, true)
	await _frames(1)
	_button(old_end_turn, false)
	_key(KEY_SPACE)
	await _frames()
	_check(_domain() == final and not _state().ui_controls["unit:finisher"].draggable, "Terminal rejects battle input")
	_check(not _state().history.open and _state().history.entries.back().type == "battle_finished", "Terminal public log remains observable")
	_check(battle._view.is_modal_open() and _state().ui_controls.has("restart"), "Terminal exposes restart control")
	await _capture("presentation-terminal.png")
	if not await _click("restart"): return
	_check(_domain().phase == "mulligan" and not battle._view.is_modal_open(), "Terminal restart returns to interactive mulligan")


func _restart_during_animation() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "restart-attacker", "player", "frontline", "armor_tank")
	_put(fixture, "restart-defender", "ai", "support", "armor_tank")
	if not await _load_fixture(fixture): return
	if not await _begin_drag("unit:restart-attacker", "unit:restart-defender"): return
	_button(_point("unit:restart-defender"), false)
	await _frames(1)
	var active_run: RefCounted = battle._view._presentation_run
	if not _check(active_run != null and not active_run.done, "Restart test begins with an unfinished attack"): return
	var receipt: Dictionary = {"count": 0, "cancelled": false}
	active_run.finished.connect(func(cancelled: bool): receipt.count += 1; receipt.cancelled = cancelled)
	var old_battle: int = int(_state().battle_number)
	if not await _click("restart"): return
	var fresh: Dictionary = _domain()
	var fresh_battle: int = int(_state().battle_number)
	_check(fresh_battle > old_battle, "Restart advances session generation")
	_check(active_run.done and active_run.cancelled and receipt.count == 1 and receipt.cancelled, "Real restart cancels the running presentation and resolves its waiter once")
	active_run.cancel()
	_check(receipt.count == 1, "Repeated cancellation after restart emits no extra completion")
	await create_timer(0.8).timeout
	_check(_domain() == fresh and int(_state().battle_number) == fresh_battle, "Old animation completion cannot modify the restarted battle")
	_check(not _state().interaction.presentation_busy and _domain().phase == "mulligan", "Restart leaves an interactive, settled mulligan")


func _resize_cancels_animation() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "resize-attacker", "player", "frontline", "armor_tank")
	_put(fixture, "resize-defender", "ai", "support", "armor_tank")
	if not await _load_fixture(fixture): return
	if not await _begin_drag("unit:resize-attacker", "unit:resize-defender"): return
	_button(_point("unit:resize-defender"), false)
	await _frames(1)
	var active_run: RefCounted = battle._view._presentation_run
	if not _check(active_run != null and not active_run.done, "Resize test begins during an accepted attack"): return
	var accepted: Dictionary = _domain()
	var old_battle: int = int(_state().battle_number)
	var receipt: Dictionary = {"count": 0, "cancelled": false}
	active_run.finished.connect(func(cancelled: bool): receipt.count += 1; receipt.cancelled = cancelled)
	# Native window resizing delivers size_changed; do not invoke controller handlers.
	root.size = Vector2i(1280, 720)
	if not await _idle(): return
	_check(active_run.done and active_run.cancelled and receipt.count == 1 and receipt.cancelled, "Native resize resolves the active presentation through cancellation exactly once")
	_check(not _state().interaction.presentation_busy and _state().interaction.state == "idle", "Resize cancellation releases controller input immediately")
	_check(_domain() == accepted and int(_state().battle_number) == old_battle, "Resize preserves the already accepted domain result and battle identity")
	await create_timer(0.8).timeout
	_check(_domain() == accepted and not _state().interaction.presentation_busy, "Late animation callbacks do not disturb the resized battle")
	trace.append({"step": "resize-cancellation", "run": active_run.snapshot(), "battle_number": old_battle, "window": {"width": root.size.x, "height": root.size.y}})
	root.size = MAIN_WINDOW
	await _frames(3)


func _effect_sequence_and_interruption() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "effect-deployer", "player", "hand", "deploy_damage_artillery")
	_put(fixture, "aftermath-victim", "ai", "support", "aftermath_draw_infantry")
	_put(fixture, "private-after-draw", "ai", "draw")
	if not await _load_fixture(fixture): return
	if not await _begin_drag("hand:effect-deployer", "support:player:0"): return
	_button(_point("support:player:0"), false)
	await _frames(1)
	if not await _click("unit:aftermath-victim", false): return
	var observed: Dictionary = await _observe()
	var sequence: Array = observed.sequence
	_check(sequence.find("effect_damage") >= 0 and sequence.find("unit_destroyed") > sequence.find("effect_damage") and sequence.rfind("ability_triggered") > sequence.find("unit_destroyed") and sequence.find("card_drawn") > sequence.rfind("ability_triggered"), "Deployment damage, destruction, aftermath and draw animate in rule event order")
	_check(not JSON.stringify(observed).contains("private-after-draw") and _anonymous_history(), "Aftermath presentation and history preserve hidden draw identities")
	_check(_domain().sides.ai.discard_ids.has("aftermath-victim") and _domain().sides.ai.hand_ids.size() == 1, "Effect animation settles on the complete chain result")
	fixture = _fixture()
	_put(fixture, "cancel-order", "player", "hand", "order_row_damage")
	_put(fixture, "area-one", "ai", "support", "std_bomber")
	_put(fixture, "area-two", "ai", "support", "std_bomber")
	if not await _load_fixture(fixture): return
	if not await _begin_drag("hand:cancel-order", "row:ai:support"): return
	_button(_point("row:ai:support"), false)
	await _frames(1)
	var accepted: Dictionary = _domain()
	var active_run: RefCounted = battle._view._presentation_run
	root.size = Vector2i(1280, 720)
	if not await _idle(): return
	_check(active_run.done and active_run.cancelled and _domain() == accepted and _domain().units["area-one"].hp == 5 and _domain().units["area-two"].hp == 5, "Interrupting the area-effect animation preserves both accepted damage results")
	root.size = MAIN_WINDOW
	await _frames(3)


func _draw_terminal() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "mutual-destruction", "player", "hand", "order_draw")
	fixture.units["mutual-destruction"].abilities = [{"trigger": "play", "effects": [{"op": "damage", "target": "all_hqs", "amount": 20}]}]
	if not await _load_fixture(fixture): return
	if not await _begin_drag("hand:mutual-destruction", "cast:player"): return
	_button(_point("cast:player"), false)
	var observed: Dictionary = await _observe({}, {}, true)
	_check(observed.terminal_hidden and _domain().winner == "draw", "Simultaneous headquarters destruction resolves as a draw after presentation")
	_check(str(battle._view._labels.modal_title.text).contains("平局") and str(battle._view._labels.phase.text).contains("平局") and str(_state().history.entries.back().text).contains("平局"), "Draw result appears consistently in phase, modal and public history")


func _observe(before_hp: Dictionary = {}, hit_hp: Dictionary = {}, terminal: bool = false) -> Dictionary:
	var result: Dictionary = {"stages": [], "sequence": [], "duration": 0.0, "before_checked": false, "before_valid": true, "before_counters_valid": true, "hit_checked": false, "hit_valid": true, "terminal_hidden": true, "frontline_values": []}
	var deadline: int = Time.get_ticks_msec() + 5000
	var seen_running: bool = false
	while Time.get_ticks_msec() < deadline:
		var presentation: Dictionary = _state().presentation
		var playback: Dictionary = presentation.playback
		var stage_name: String = str(playback.get("stage", ""))
		if not playback.get("done", true):
			seen_running = true
			if stage_name in ["travel", "attack_windup", "attack_line", "attack_hit", "attack_recover"]:
				for side in ["player", "ai"]:
					var widget = battle._view._widgets["cp_player" if side == "player" else "cp_enemy"]
					_check(widget.display_data.available == _domain().sides[side].command_points, "Displayed energy matches accepted state during " + stage_name)
			result.duration = playback.duration
			if result.frontline_values.is_empty() or not is_equal_approx(float(result.frontline_values.back()), float(presentation.frontline_y)):
				result.frontline_values.append(float(presentation.frontline_y))
			if not result.stages.has(stage_name): result.stages.append(stage_name)
			if result.sequence.is_empty() or result.sequence.back() != stage_name: result.sequence.append(stage_name)
			if stage_name in ["attack_windup", "attack_line"] and not before_hp.is_empty():
				result.before_checked = true
				result.before_valid = result.before_valid and _visible_hp_matches(before_hp)
				result.before_counters_valid = result.before_counters_valid and str(battle._view._labels.player_counts.text).contains("弃牌 0") and str(battle._view._labels.enemy_counts.text).contains("弃牌 0")
			if stage_name == "attack_hit" and not hit_hp.is_empty():
				result.hit_checked = true
				result.hit_valid = result.hit_valid and _visible_hp_matches(hit_hp)
			if terminal: result.terminal_hidden = result.terminal_hidden and not battle._view._modal_panel.visible
		elif seen_running:
			await _frames(1)
			return result
		await process_frame
	_check(false, "Presentation completes within five seconds")
	return result


func _visible_hp_matches(expected: Dictionary) -> bool:
	var visible: Dictionary = {}
	for card in _visible_cards():
		var data: Dictionary = card.display_data
		var key: String = ""
		if str(card.mode) == "hq": key = "hq:" + str(data.get("owner", ""))
		elif data.has("instance_id"): key = "unit:" + str(data.instance_id)
		if expected.has(key):
			if int(data.get("hp", -1)) != int(expected[key]): return false
			visible[key] = true
	return visible.size() == expected.size()


func _visible_cards() -> Array[Control]:
	var result: Array[Control] = []
	_collect_visible_cards(battle._view, result)
	return result


func _collect_visible_cards(node: Node, result: Array[Control]) -> void:
	if node.get_script() == ProbeCard and node.is_visible_in_tree() and float(node.modulate.a) > 0.05:
		result.append(node)
	for child in node.get_children(): _collect_visible_cards(child, result)


func _begin_drag(source: String, target: String) -> bool:
	var start: Vector2 = _point(source)
	var destination: Vector2 = _point(target)
	if start.x < 0 or destination.x < 0: return false
	var request: Dictionary = {"source": source, "target": target, "start": start, "destination": destination, "final_transform": root.get_final_transform(), "window_size": root.size}
	_motion(start)
	await _frames(1)
	_button(start, true)
	if not await _wait_drag_input("pressed", request): return false
	for part in range(1, 5):
		_motion(start.lerp(destination, float(part) / 4.0), MOUSE_BUTTON_MASK_LEFT)
		await _frames(1)
	return await _wait_drag_input("dragging", request)


func _finish() -> void:
	var result: Dictionary = {"run_id": run_id, "scene_path": SCENE_PATH, "loaded_scene_path": battle.scene_file_path if is_instance_valid(battle) else "", "seed": TEST_SEED, "status": "passed" if failures.is_empty() else "failed", "assertions": assertions, "failures": failures, "trace": trace, "screenshots": screenshots, "renderer": DisplayServer.get_name(), "scope": {"art": OS.get_cmdline_user_args().has("--art")}}
	var output := FileAccess.open(output_dir.path_join("presentation-result.json"), FileAccess.WRITE)
	if output == null:
		push_error("Cannot write presentation result")
		quit(2)
		return
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print(JSON.stringify({"event": "presentation_smoke_complete", "run_id": run_id, "status": result.status, "assertions": assertions}))
	quit(0 if failures.is_empty() else 1)
