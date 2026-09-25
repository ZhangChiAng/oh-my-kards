extends SceneTree
## Fixtures only arrange state; all game commands and buttons use real Input events.

const Catalog = preload("res://scripts/card_catalog.gd")
var include_art: bool = OS.get_cmdline_user_args().has("--art")
var include_sizes: bool = OS.get_cmdline_user_args().has("--sizes")
const SCENE_PATH: String = "res://scenes/battle.tscn"
const TEST_SEED: int = 20260917
const AWAY := Vector2(8, 8)
const MAIN_WINDOW := Vector2i(1920, 1080)
const WINDOW_MATRIX: Array[Vector2i] = [Vector2i(1024, 640), Vector2i(3440, 1440)]
const CARDS: Array[String] = ["pathfinder", "dust_rover", "field_mortar", "interceptor", "strike_wing", "colony_guard", "bastion", "sky_guard", "eclipse"]
var run_id: String = ""
var output_dir: String = ""
var assertions: int = 0
var failures: Array[String] = []
var trace: Array = []
var screenshots: Array[String] = []
var resolutions: Array = []
var timings: Dictionary = {}
var battle
var _mouse := Vector2.ZERO
var _focus_loss_serial: int = 0
var _pointer_focus_serial: int = 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size() - 1):
		if args[index] == "--run-id": run_id = args[index + 1]
		elif args[index] == "--output-dir": output_dir = args[index + 1]
	call_deferred("_run")

func _run() -> void:
	if run_id.is_empty() or output_dir.is_empty():
		push_error("UI test requires --run-id and --output-dir.")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output_dir)
	if not _check(DisplayServer.get_name() != "headless", "UI requires a graphical display"):
		_finish()
		return
	root.focus_exited.connect(func():
		_focus_loss_serial += 1
		trace.append({"step": "window-focus-lost", "time_ms": Time.get_ticks_msec()})
	)
	root.mode = Window.MODE_WINDOWED
	root.size = MAIN_WINDOW
	Input.use_accumulated_input = false
	var scene: PackedScene = load(SCENE_PATH)
	if not _check(scene != null, "Battle scene loads"):
		_finish()
		return
	battle = scene.instantiate()
	battle.seed_override = TEST_SEED
	battle.ai_step_delay = 1.0
	root.add_child(battle)
	current_scene = battle
	await _frames(3)
	if not _check(battle.scene_file_path == SCENE_PATH, "Actually loaded battle matches the requested scene"):
		_finish()
		return
	_check(_no_development_entries() and not _state().has("workshop"), "Battle excludes development entries and workshop state")
	_resource_checks()
	if include_art: _export_art_template()
	for group in ["opening", "mulligan_cards", "fan", "positions", "cancellation_and_scale", "busy_and_restart", "settings_modal", "hover_delay_and_insertion", "history"]:
		await _timed_group(group)
	if include_art:
		for group in ["theme_independence", "font_geometry", "configuration", "component_bounds", "unit_icons"]:
			await _timed_group(group)
	if include_sizes: await _timed_group("resolution_matrix")
	_finish()

func _timed_group(group: String) -> void:
	var started: int = Time.get_ticks_msec()
	await call("_" + group)
	timings[group] = {"duration_seconds": (Time.get_ticks_msec() - started) / 1000.0}

func _opening() -> void:
	var before: Dictionary = _domain()
	if not _check(before.phase == "mulligan" and before.units.size() == 38 and _state().run_id == run_id, "Natural nineteen-card opening and current run"):
		return
	var id: String = str(before.sides.player.hand_ids[0])
	if not await _click("hand:" + id): return
	if not _check(_state().interaction.mulligan_selected_ids == [id] and _domain() == before, "Mouse selects replacement without domain mutation"): return
	await _capture("board.png")
	if not await _click("hand:" + id): return
	_check(_state().interaction.mulligan_selected_ids.is_empty(), "Mouse toggles replacement off")
	if not await _click("hand:" + id): return
	if not await _click("mulligan_confirm"): return
	var after: Dictionary = _domain()
	_check(after.phase == "active" and not after.sides.player.hand_ids.has(id), "Confirm button replaces selected card and starts battle")
	_check(_anonymous_history(), "Opening draws and mulligans reveal no card identity")
	_record("opening-confirmed")

func _mulligan_cards() -> void:
	for count in [4, 5]:
		if not await _load_fixture(_mulligan_fixture(count)): return
		if not _mulligan_geometry(count): return
		_record("mulligan-count-%d" % count)

func _fan() -> void:
	var fixture: Dictionary = _fixture()
	for index in range(9): _put(fixture, "fan-%d" % index, "player", "hand", CARDS[index])
	if not await _load_fixture(fixture): return
	var before: Dictionary = _domain()
	var base_poses: Dictionary = battle._view._hand_poses.duplicate(true)
	for index in range(9):
		var id: String = "fan-%d" % index
		_motion(AWAY)
		await _frames()
		if not await _hover_source(id): return
		var point: Vector2 = _point("hand:" + id)
		_button(point, true)
		await _frames(1)
		if not _check(_state().interaction.source_id == id, "Nine-card safe point presses exact card: " + id): return
		_button(point, false)
		if not await _idle(): return
		if not _check(_domain() == before and battle._view._hand_poses == base_poses, "Nine-card clicks preserve domain and base slots"): return
	# Preserve the raised rightmost card's original visible slot regression.
	_motion(AWAY)
	await _frames()
	var safe: Vector2 = _point("hand:fan-8")
	if not await _hover_source("fan-8"): return
	var probe: Vector2 = safe + Vector2(2, 0)
	if not _check(root.get_visible_rect().has_point(probe), "Rightmost original-slot probe remains on-screen"): return
	_motion(probe)
	await _frames()
	_button(probe, true)
	await _frames(1)
	if not _check(_state().interaction.source_id == "fan-8", "Raised rightmost card accepts original base-slot click"): return
	_button(probe, false)
	if not await _idle(): return
	# Consecutive motions must switch neighbours without leaving the fan.
	for index in [4, 5, 6, 7, 8]:
		if not await _hover_source("fan-%d" % index): return
		if not _hovered_fan_safe_points(): return
		if not _check(battle._view._hand_poses == base_poses and _domain() == before, "Neighbour hovers preserve slots and domain"): return
	if not await _rotated_fan_hit(): return
	_motion(AWAY)
	await _frames()
	if not await _hover_source("fan-4"): return
	if not await _hand_hover("fan-4", before.units["fan-4"]): return
	await _capture("hand-nine.png")
	_record("nine-card-input")

func _hover_source(id: String) -> bool:
	var point: Vector2 = _point("hand:" + id)
	if point.x < 0: return false
	_motion(point)
	var deadline: int = Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if _pointer_focus_serial != _focus_loss_serial:
			root.grab_focus()
			_motion(point)
		elif not battle._view._cursor.is_equal_approx(point):
			_motion(point)
		var settled: bool = true
		for tween in battle._view._hover_tweens.values():
			if tween.is_valid() and tween.is_running(): settled = false
		if settled and battle._view._hover_id == id: return true
	return _check(false, "Hand hover settles on exact card: " + id)

func _rotated_fan_hit() -> bool:
	for id in ["fan-0", "fan-8"]:
		_motion(AWAY)
		await _frames()
		var card: Control = battle._view._cards[id]
		var bounds: Rect2 = card.screen_rect()
		if not _check(absf(card.rotation) > 0.01, "Outer playable hand slot has actual rotation: " + id): return false
		var checked: bool = false
		for point in [bounds.position + Vector2(2, 2), Vector2(bounds.end.x - 2, bounds.position.y + 2), Vector2(bounds.position.x + 2, bounds.end.y - 2), bounds.end - Vector2(2, 2)]:
			if not root.get_visible_rect().has_point(point): continue
			if Rect2(Vector2.ZERO, card.size).has_point(card.get_global_transform().affine_inverse() * point): continue
			_motion(point)
			await _frames()
			if not _check(battle._view._hover_id != id, "Actual pointer outside a rotated card does not select its bounding box: " + id): return false
			checked = true
			break
		if not _check(checked, "Rotated card exposes a visible outside-polygon probe: " + id): return false
	return true

func _hovered_fan_safe_points() -> bool:
	var hovered: String = battle._view._hover_id
	if not _check(not hovered.is_empty(), "Nine-card safe-point regression starts with an active hover"): return false
	for index in range(9):
		var key: String = "hand:fan-%d" % index
		var point: Vector2 = _point(key)
		if point.x < 0: return false
		if not _check(battle._view.pick_source(point) == key, "While %s is raised, on-screen safe point resolves %s" % [hovered, key]): return false
	return _check(battle._view._hover_id == hovered, "Reading other safe points preserves the existing hover")

func _positions() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "left", "player", "hand")
	_put(fixture, "right", "player", "hand")
	_put(fixture, "mover", "player", "support", "dust_rover")
	_put(fixture, "front-left", "player", "frontline", "colony_guard")
	_put(fixture, "front-right", "player", "frontline", "interceptor")
	_put(fixture, "enemy-left", "ai", "support", "bastion")
	_put(fixture, "enemy-right", "ai", "support", "strike_wing")
	fixture.sides.ai.hq_index = 1
	if not await _load_fixture(fixture): return
	if not await _drag("hand:left", "support:player:0"): return
	if not await _drag("hand:right", "support:player:3"): return
	var state: Dictionary = _domain()
	if not _check(state.sides.player.support_ids == ["left", "mover", "right"] and state.sides.player.hq_index == 1, "Mouse inserts units on both sides of HQ"): return
	if not await _drag("unit:mover", "frontline:1"): return
	state = _domain()
	_check(state.frontline_ids == ["front-left", "mover", "front-right"] and state.sides.player.support_ids == ["left", "right"] and state.sides.player.hq_index == 1, "Mouse advances into middle gap, preserving ordered rows")
	_check(state.sides.player.command_points == 9, "Three inputs spend exactly three command points")
	_check(_point("unit:left").x < _point("hq:player").x and _point("hq:player").x < _point("unit:right").x, "HQ renders between its ordered neighbors")
	_record("ordered-insertion")


func _cancellation_and_scale() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "hand", "player", "hand")
	if not await _load_fixture(fixture): return
	var before: Dictionary = _domain()
	if not await _click("hand:hand"): return
	_check(_domain() == before, "Battle click never deploys")
	var start: Vector2 = _point("hand:hand")
	var small_move: Vector2 = Vector2(6.0 * float(battle._view._layout.art_scale), 0)
	_button(start, true)
	_motion(start + small_move, MOUSE_BUTTON_MASK_LEFT)
	_check(_state().interaction.state == "pressed", "Six design pixels stays below drag threshold")
	_button(start + small_move, false)
	await _idle()
	_check(_domain() == before, "Sub-threshold release leaves domain unchanged")
	for cancel in ["invalid", "right", "escape", "focus", "resize"]:
		if not await _begin_drag("hand:hand", "support:player:0"): return
		match cancel:
			"invalid": _motion(AWAY, MOUSE_BUTTON_MASK_LEFT)
			"right":
				_button(_mouse, true, MOUSE_BUTTON_RIGHT)
				_button(_mouse, false, MOUSE_BUTTON_RIGHT)
			"escape": _key(KEY_ESCAPE)
			"focus": root.propagate_notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
			"resize": root.size = Vector2i(1024, 640)
		await _frames(3)
		if cancel == "invalid":
			if not _feedback_visible("invalid cancellation"): return
		_button(AWAY if cancel == "invalid" else _point("support:player:0"), false)
		if cancel == "focus": root.propagate_notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
		if not await _idle(): return
		_check(_domain() == before, cancel + " cancels drag and stale release")
	if not await _drag("hand:hand", "support:player:1"): return
	_check(_domain().sides.player.support_ids == ["hand"], "Safe logical points still deploy in scaled window")
	root.size = MAIN_WINDOW
	await _frames(3)
	_record("cancellation-and-scale")

func _busy_and_restart() -> void:
	root.size = MAIN_WINDOW
	var fixture: Dictionary = _fixture()
	_put(fixture, "first", "player", "hand")
	_put(fixture, "second", "player", "hand")
	if not await _load_fixture(fixture): return
	if not await _begin_drag("hand:first", "support:player:0"): return
	_button(_point("support:player:0"), false)
	var committed: Dictionary = _domain()
	if not _check(_state().interaction.presentation_busy and committed.sides.player.support_ids == ["first"], "Release commits and enters busy presentation"): return
	_key(KEY_SPACE)
	_motion(_point("hand:second"))
	_button(_point("hand:second"), true)
	_motion(_point("support:player:2"), MOUSE_BUTTON_MASK_LEFT)
	_button(_point("support:player:2"), false)
	if not await _idle(): return
	_check(_domain() == committed, "Busy keyboard and second drag cannot submit")
	fixture = _fixture()
	_put(fixture, "hand", "player", "hand")
	_put(fixture, "enemy-draw", "ai", "draw")
	if not await _load_fixture(fixture): return
	battle.ai_step_delay = 0.8
	if not await _click("end_turn"): return
	var pending: Dictionary = _domain()
	if not _check(pending.active_side == "ai" and not _state().ui_controls["hand:hand"].draggable, "Player input locks during pending AI turn"): return
	_key(KEY_SPACE)
	_check(_domain() == pending, "Player cannot skip AI turn")
	if not await _click("restart"): return
	var fresh: Dictionary = _domain()
	await create_timer(1.0).timeout
	_check(_domain() == fresh, "Old AI timer cannot mutate new battle")
	battle.ai_step_delay = 1.0
	_record("busy-and-restart")

func _history() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "gun", "player", "support", "rail_battery")
	_put(fixture, "victim", "ai", "frontline")
	for side in ["player", "ai"]:
		for index in range(1):
			var id: String = side + "-secret-%d" % index
			_put(fixture, id, side, "draw", "eclipse")
			fixture.units[id].name = "隐秘牌名" + id
			fixture.units[id].deploy_cost = 20
	if not await _load_fixture(fixture): return
	var count: int = _state().history.entries.size()
	if not await _drag("unit:gun", "unit:victim"): return
	var entries: Array = _state().history.entries
	if not _check(entries.size() == count + 1 and entries.back().type == "attack" and str(entries.back().text).contains("阵亡") and str(entries.back().text).contains("边境侦察队"), "Public attack and death share one history item"): return
	battle.ai_step_delay = 0.01
	if not await _click("end_turn"): return
	if not await _player_idle(): return
	_check(_anonymous_history(), "Turn draws reveal counts without secret names or IDs")
	_check(not _state().history.open and not _state().ui_controls.has("history_toggle") and not _state().ui_controls.has("history_scroll"), "Public history remains observable without a separate history panel")
	_record("history-data-only")
	battle.ai_step_delay = 1.0

func _settings_modal() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "modal-hand", "player", "hand")
	if not await _load_fixture(fixture): return
	var before: Dictionary = _domain()
	var source: Vector2 = _point("hand:modal-hand")
	var target: Vector2 = _point("support:player:0")
	if not await _click("settings"): return
	if not _check(battle._view.is_modal_open() and _state().ui_controls.has("restart"), "Settings exposes a real restart modal"): return
	_check(_no_development_entries(), "Battle and settings contain no workshop or theme-switch entry")
	_check(not _state().ui_controls["hand:modal-hand"].draggable, "Modal reports underlying cards as non-draggable")
	_key(KEY_SPACE)
	await _frames(3)
	if not _check(_domain() == before and battle._view.is_modal_open(), "Open modal blocks the end-turn keyboard without domain changes"): return
	_motion(source)
	_button(source, true)
	_motion(target, MOUSE_BUTTON_MASK_LEFT)
	_button(target, false)
	await _frames(3)
	if not _check(_domain() == before and _state().interaction.state == "idle", "Modal backdrop consumes underlying drag without domain changes"): return
	if not battle._view.is_modal_open() and not await _click("settings"): return
	if not await _click("modal_close"): return
	if not _check(not battle._view.is_modal_open() and _domain() == before, "Real close control restores board input without changing rules"): return
	if not await _click("settings"): return
	_key(KEY_ESCAPE)
	await _frames()
	_check(not battle._view.is_modal_open() and _domain() == before, "Escape dismisses settings without a battle command")
	_record("settings-modal")

func _no_development_entries() -> bool:
	for key in _state().ui_controls:
		if str(key).begins_with("workshop") or str(key).begins_with("theme"): return false
	return not _has_workshop_node(battle)

func _has_workshop_node(node: Node) -> bool:
	var script: Script = node.get_script()
	if script != null and script.resource_path == "res://scripts/workshop/card_workshop.gd": return true
	for child in node.get_children():
		if _has_workshop_node(child): return true
	return false

func _theme_independence() -> void:
	var fixture: Dictionary = _fixture()
	for index in range(9): _put(fixture, "theme-hand-%d" % index, "player", "hand", CARDS[index])
	for side in ["player", "ai"]:
		for index in range(4): _put(fixture, "%s-theme-rear-%d" % [side, index], side, "support", CARDS[index])
		fixture.sides[side].hq_index = 2
	for index in range(5): _put(fixture, "theme-front-%d" % index, "player", "frontline", CARDS[index])
	if not await _load_fixture(fixture): return
	var original: Resource = battle._view.profile
	var domain_before: Dictionary = _domain()
	var expected_controls: Dictionary = _state().ui_controls.duplicate(true)
	var expected_legal: Array = _state().legal_actions.duplicate(true)
	var expected_config: Dictionary = _state().presentation.duplicate(true)
	var profiles: Array = [original, original.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)]
	if include_art:
		var plain: Resource = original.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
		plain.profile_id = "plain-surface-probe"
		plain.visual_theme.background_texture = null
		plain.visual_theme.card_texture = null
		profiles.append(plain)
	for profile: Resource in profiles:
		battle._view.set_profile(profile)
		_motion(AWAY)
		await _frames(3)
		if not await _draw_frame("shared geometry " + profile.profile_id): return
		var observed: Dictionary = _state()
		_check(observed.ui_controls == expected_controls and observed.legal_actions == expected_legal and _domain() == domain_before, "Appearance replacement preserves controls, hit points and legal actions: " + profile.profile_id)
		_check(observed.presentation.geometry_id == expected_config.geometry_id and observed.presentation.geometry_fingerprint == expected_config.geometry_fingerprint and observed.presentation.motion_id == expected_config.motion_id and observed.presentation.motion_fingerprint == expected_config.motion_fingerprint, "Appearance replacement preserves geometry and motion identity: " + profile.profile_id)
		_check(observed.presentation.profile_id == profile.profile_id and observed.presentation.render_mode == "material" and not str(observed.presentation.appearance_fingerprint).is_empty(), "Runtime identifies the actual appearance configuration: " + profile.profile_id)
		for card in battle._view._cards.values():
			_check(card.geometry_snapshot().diagnostics.is_empty(), "Configured card has no missing-resource diagnostic: " + profile.profile_id)
		var visible_cards: Array = battle._view._cards.values() + battle._view._back_cards + [battle._view._controls["hq:player"], battle._view._controls["hq:ai"]]
		for card in visible_cards:
			if card.is_visible_in_tree():
				_check(card.profile.visual_theme.card_texture == profile.visual_theme.card_texture, "Visible %s card uses selected paper" % card.mode)
		for side in ["player", "enemy"]:
			_check(battle._view._widgets[side + "_deck"].profile.visual_theme.card_texture == profile.visual_theme.card_texture, "Deck uses selected card paper")
		_record("theme-" + profile.profile_id)
	battle._view.set_profile(original)
	await _frames(3)
	_check(original.artworks == null and original.visual_theme.background_texture != null, "Default tabletop has a background texture but no card artwork")
	if include_art:
		for debug_enabled in [true, false]:
			battle._view.geometry_debug = debug_enabled
			await _frames(3)
			var inspected: Dictionary = _state()
			_check((battle._view.display_profile.visual_theme.card_texture == null) == debug_enabled, "Only material display references card paper")
			_check(battle._view.profile == original and inspected.presentation.material_fingerprint == expected_config.material_fingerprint, "Geometry inspection preserves selected material")
			_check(inspected.ui_controls == expected_controls and inspected.legal_actions == expected_legal and _domain() == domain_before, "Geometry inspection preserves interaction and rules")
			_check(inspected.presentation.geometry_fingerprint == expected_config.geometry_fingerprint and inspected.presentation.motion_fingerprint == expected_config.motion_fingerprint, "Geometry inspection preserves geometry and timing")
			_check(inspected.presentation.render_mode == ("geometry_debug" if debug_enabled else "material"), "Snapshot identifies actual display mode")
			_check(inspected.presentation.background_texture == ("" if debug_enabled else original.visual_theme.background_texture.resource_path), "Snapshot identifies actual visible background")
			_check((inspected.presentation.appearance_fingerprint != expected_config.appearance_fingerprint) == debug_enabled, "Display fingerprint tracks diagnostic override independently")
			if debug_enabled:
				await _capture("geometry-debug.png")
				var changed: Resource = original.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
				changed.visual_theme.surface.palette["text"] = Color.RED
				changed.visual_theme.card_texture = null
				battle._view.set_profile(changed)
				_check(_state().presentation.appearance_fingerprint == inspected.presentation.appearance_fingerprint and _state().presentation.material_fingerprint != expected_config.material_fingerprint, "Diagnostic style stays fixed while underlying material changes")
				battle._view.set_profile(original)
	_check(_no_development_entries(), "Normal battle has no development-only nodes or controls")
	_record("shared-geometry-and-motion")

func _unit_icons() -> void:
	# Render actual shared cards: distinct visible marks, no former text, no layout changes.
	var viewport := SubViewport.new()
	viewport.size = Vector2i(600, 300)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var geometry: Resource = battle._view.geometry
	var before: Dictionary = geometry.spec()
	var material: Resource = battle._view.profile
	var debug: Resource = preload("res://scripts/art/display_profile.gd").geometry_only()
	var cards: Array = []
	for mode in ["full", "field"]:
		for index in range(5):
			var card = preload("res://scripts/art/art_card.gd").new()
			viewport.add_child(card)
			card.position = Vector2(index * 120, 0 if mode == "full" else 174)
			var data: Dictionary = Catalog.card(CARDS[index])
			data.hp = data.max_hp
			# Deliberately supply old display copy to catch accidental rendering.
			data.type_name = "不应出现在卡面"
			data.rule_text = "底部应留白"
			card.configure(data, mode, material, geometry.template(mode))
			cards.append(card)
	for profile: Resource in [material, debug]:
		for card in cards: card.configure(card.display_data, card.mode, profile, geometry.template(card.mode))
		if not await _draw_frame("five shared unit icons " + profile.profile_id):
			viewport.queue_free()
			return
		var image: Image = viewport.get_texture().get_image()
		var hashes: Dictionary = {"full": [], "field": []}
		for card in cards:
			var text: Dictionary = card.geometry_snapshot().text
			_check(not text.has("type_name") and not text.has("rule_text"), "Card omits old type/rule text: " + card.mode)
			var slot: Rect2 = geometry.template(card.mode).slots.type_icon
			var region := Rect2i(Vector2i(card.position + slot.position), Vector2i(slot.size))
			var pixels: Image = image.get_region(region)
			var color_role: String = "card_text" if profile.visual_theme.has_color("card_text") else "text"
			var ink: Color = profile.visual_theme.color(color_role)
			var ink_pixels: int = 0
			for y in range(pixels.get_height()):
				for x in range(pixels.get_width()):
					var color: Color = pixels.get_pixel(x, y)
					if absf(color.r - ink.r) + absf(color.g - ink.g) + absf(color.b - ink.b) < 0.3: ink_pixels += 1
			_check(ink_pixels > 10, "Actual pixels show unit icon: %s/%s/%s" % [profile.profile_id, card.mode, card.display_data.unit_type])
			var digest: int = hash(pixels.get_data())
			_check(not hashes[card.mode].has(digest), "Five unit marks differ: " + card.mode)
			hashes[card.mode].append(digest)
	_check(geometry.spec() == before, "Unit icon rendering preserves every template and reserved slot")
	viewport.queue_free()


func _font_geometry() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "font-hand", "player", "hand")
	_put(fixture, "font-field", "player", "support")
	if not await _load_fixture(fixture): return
	var original: Resource = battle._view.profile
	var before: Dictionary = _domain()
	var controls_before: Dictionary = _state().ui_controls.duplicate(true)
	var labels_before: Dictionary = _label_rects()
	var config_before: Dictionary = _state().presentation.duplicate(true)
	var enlarged: Resource = original.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	enlarged.profile_id = "font-metrics-geometry-probe"
	var text_font := FontVariation.new()
	text_font.base_font = original.visual_theme.surface.font
	text_font.spacing_glyph = 20
	text_font.spacing_top = 18
	text_font.spacing_bottom = 18
	enlarged.visual_theme.surface.font = text_font
	var number_font := FontVariation.new()
	number_font.base_font = original.visual_theme.surface.number_font
	number_font.spacing_glyph = 16
	number_font.spacing_top = 12
	number_font.spacing_bottom = 12
	enlarged.visual_theme.surface.number_font = number_font
	_check(text_font.get_height(16) > original.visual_theme.surface.font.get_height(16) and text_font.get_string_size("字体间距", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x > original.visual_theme.surface.font.get_string_size("字体间距", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x, "Font probe actually expands glyph spacing and metrics")
	battle._view.set_profile(enlarged)
	await _frames(3)
	if not await _draw_frame("font metric geometry isolation"): return
	var changed: Dictionary = _state()
	_check(changed.ui_controls == controls_before and _label_rects() == labels_before, "Large font metrics cannot resize controls, label slots or hit points")
	_check(_domain() == before and changed.presentation.geometry_fingerprint == config_before.geometry_fingerprint and changed.presentation.motion_fingerprint == config_before.motion_fingerprint, "Font metrics cannot change rules, geometry or animation configuration")
	_check(changed.presentation.appearance_fingerprint != config_before.appearance_fingerprint, "Font changes are reflected in the actual appearance fingerprint")
	_record("font-metrics-independent-of-geometry")
	battle._view.set_profile(original)
	await _frames(3)
	_check(_state().ui_controls == controls_before and _label_rects() == labels_before, "Original font restores without layout drift")

func _label_rects() -> Dictionary:
	var result: Dictionary = {}
	for key in battle._view._labels:
		result[key] = battle._view._labels[key].get_global_rect()
	return result

func _configuration() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "config-hand", "player", "hand")
	if not await _load_fixture(fixture): return
	var before: Dictionary = _domain()
	var history_before: Dictionary = _state().history.duplicate(true)
	var original: Resource = battle._view.profile
	var identity: Dictionary = _state().presentation.duplicate(true)
	var changed: Resource = original.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	var original_width: float = original.visual_theme.surface.strokes.line_width
	changed.visual_theme.surface.strokes.line_width = original_width + 1.0
	battle._view.set_profile(changed)
	await _frames(3)
	var observed: Dictionary = _state().presentation
	_check(observed.appearance_fingerprint != identity.appearance_fingerprint and changed.profile_id == original.profile_id, "Line appearance changes fingerprint without changing profile identity")
	_check(observed.geometry_fingerprint == identity.geometry_fingerprint and observed.motion_fingerprint == identity.motion_fingerprint, "Appearance edits preserve geometry and motion")
	_check(original.visual_theme.surface.strokes.line_width == original_width and _domain() == before and _state().history == history_before, "Appearance copy leaves source resources and battle state untouched")
	battle._view.set_profile(original)
	await _frames(3)
	if not await _begin_drag("hand:config-hand", "support:player:0"): return
	var stale_target: Vector2 = _point("support:player:0")
	battle._view.set_profile(changed)
	await _frames(2)
	_check(_state().interaction.state == "idle" and not battle._view._drag_preview.visible, "Profile replacement cancels armed drag")
	_button(stale_target, false)
	if not await _idle(): return
	_check(_domain() == before and _state().history == history_before, "Stale release after profile replacement cannot deploy")
	battle._view.set_profile(original)
	await _frames(2)
	_record("configuration-domain-isolation")

func _component_bounds() -> void:
	# One representative full/field/HQ fixture retains double-digit text bounds.
	for card_id in ["strike_wing"]:
		var fixture: Dictionary = _fixture()
		_put(fixture, "bounds-hand", "player", "hand", card_id)
		_put(fixture, "bounds-field", "player", "support", card_id)
		for id in ["bounds-hand", "bounds-field"]:
			fixture.units[id].merge({"deploy_cost": 12, "action_cost": 12, "attack": 10, "hp": 20, "max_hp": 20}, true)
		fixture.sides.player.hq_hp = 1
		if not await _load_fixture(fixture): return
		_motion(_point("hand:bounds-hand"))
		if not await _draw_frame("playable component bounds " + card_id): return
		if not _text_bounds(battle._view._cards["bounds-hand"], "full", {"name": fixture.units["bounds-hand"].name, "deploy_cost": "12", "deploy_unit": "K", "action_cost": "12", "attack": "10", "health": "20"}): return
		if not _text_bounds(battle._view._cards["bounds-field"], "field", {"name": fixture.units["bounds-field"].name, "action_cost": "12", "attack": "10", "health": "20"}): return
		if not _text_bounds(battle._view._controls["hq:player"], "hq", {"health": "1"}): return
		if not _text_bounds(battle._view._controls["hq:ai"], "hq", {"health": "20"}): return
		if not _button_text_bounds("end_turn"): return
	for available in [0, 12]:
		var fixture: Dictionary = _fixture()
		fixture.sides.player.command_points = available
		if not await _load_fixture(fixture): return
		if not await _draw_frame("command point text " + str(available)): return
		if not _text_bounds(battle._view._widgets.cp_player, "cp", {"available": str(available), "capacity": "12", "unit": "K"}): return
	if not await _load_fixture(_mulligan_fixture(5)): return
	if not _button_text_bounds("mulligan_confirm"): return
	if not await _click("hand:opening-0"): return
	if not _button_text_bounds("mulligan_confirm"): return
	_record("playable-component-text-bounds")

func _text_bounds(component: Control, role: String, expected: Dictionary = {}) -> bool:
	var geometry: Dictionary = component.geometry_snapshot()
	var definition: Resource = battle._view.geometry.template(role)
	if not _check(geometry.diagnostics.is_empty() and not geometry.text.is_empty(), "Rendered " + role + " has text geometry and no visual diagnostics"): return false
	for key in expected:
		if not _check(geometry.text.has(key) and geometry.text[key].get("text", "") == str(expected[key]), "Rendered " + role + " shows expected " + key): return false
	for key in geometry.text:
		var text: Dictionary = geometry.text[key]
		if str(text.get("text", "")).is_empty(): continue
		if not _check(text.get("drawn", false) and text.get("fits", false), "Rendered " + role + " draws fitting text: " + key): return false
		var glyph: Rect2 = text.glyph_rect
		var slot: Rect2 = text.slot
		var visible: Rect2 = _visible_text_region(role, key, definition)
		if not _check(slot.grow(0.01).encloses(glyph) and visible.grow(0.01).encloses(glyph), "Rendered " + role + " keeps glyphs inside their slot and visible face: " + key): return false
	return true

func _visible_text_region(role: String, key: String, definition: Resource) -> Rect2:
	var slot_name: String = ""
	match role:
		"cp", "end_turn":
			slot_name = "well"
		"field":
			slot_name = {"action_cost": "action_box", "attack": "attack_box", "health": "health_box"}.get(key, "")
		"full":
			slot_name = {"deploy_cost": "deploy_box", "deploy_unit": "deploy_box", "action_cost": "deploy_box", "name": "header", "attack": "stats_bar", "health": "stats_bar"}.get(key, "")
		"hq":
			if key == "health":
				slot_name = "health_box"
	# Destination text bounds belong solely to geometry, including material themes.
	return definition.slots.get(slot_name, definition.inner_rect) if not slot_name.is_empty() else definition.inner_rect

func _button_text_bounds(key: String) -> bool:
	var button: BaseButton = battle._view._controls[key]
	var surface: Control = button._surface
	var role: String = button.role
	if not _text_bounds(surface, role, {"text": button.text}): return false
	var drawn: Dictionary = surface.geometry_snapshot()
	var definition: Resource = battle._view.geometry.template(role)
	var ratio: Vector2 = surface.size / definition.size
	var actual_text: Dictionary = drawn.text.text
	var glyph: Rect2 = actual_text.glyph_rect
	var well: Rect2 = _visible_text_region(role, "text", definition)
	var transform: Transform2D = surface.get_global_transform()
	var screen_glyph: Rect2 = transform * Rect2(glyph.position * ratio, glyph.size * ratio)
	var screen_well: Rect2 = transform * Rect2(well.position * ratio, well.size * ratio)
	var screen_surface: Rect2 = drawn.rect
	if not _check(surface.size.is_equal_approx(button.size) and screen_surface.is_equal_approx(button.get_global_rect()), "Rendered button surface equals its interactive control: " + key): return false
	return _check(button.is_visible_in_tree() and surface.is_visible_in_tree() and screen_well.grow(0.01).encloses(screen_glyph) and screen_surface.grow(0.01).encloses(screen_well) and root.get_visible_rect().encloses(screen_surface), "Measured button glyphs and visible recess fit the actual rendered surface: " + key)







func _mulligan_fixture(count: int) -> Dictionary:
	var fixture: Dictionary = _fixture()
	fixture.phase = "mulligan"
	fixture.turn = 0
	fixture.first_side = "player" if count == 4 else "ai"
	fixture.sides.player.mulligan_done = false
	for index in range(count): _put(fixture, "opening-%d" % index, "player", "hand", CARDS[index])
	return fixture

func _mulligan_geometry(count: int) -> bool:
	var viewport: Rect2 = root.get_visible_rect()
	var previous_end: float = -1.0
	for index in range(count):
		var key: String = "hand:opening-%d" % index
		var point: Vector2 = _point(key)
		if point.x < 0: return false
		var card = battle._view._cards["opening-%d" % index]
		var rect: Rect2 = card.screen_rect()
		if not _check(viewport.encloses(rect) and is_zero_approx(card.rotation) and _full_card(card), "Mulligan %d: entire upright full card %d fits viewport" % [count, index]): return false
		if not _check(rect.position.x >= previous_end and rect.position.y < viewport.size.y * 0.65, "Mulligan %d: separated central card %d" % [count, index]): return false
		previous_end = rect.end.x
	return true

func _hand_hover(id: String, expected: Dictionary) -> bool:
	if not await _wait_hover_detail("hand:" + id): return false
	var card = battle._view._detail
	var data: Dictionary = card.display_data
	var description: String = str(data.get("rule_description", ""))
	trace.append({"step": "hand-hover-observed", "expected": id, "actual": battle._view._hover_id, "data": data, "full": _full_card(card), "visible": card.visible, "rect": _json_geometry(card.screen_rect()), "viewport": _json_geometry(root.get_visible_rect()), "cursor": _json_geometry(battle._view._cursor)})
	if not _check(battle._view._hover_id == id and card.visible and _full_card(card) and str(data.get("instance_id", "")) == id and str(data.get("name", "")) == str(expected.name) and not description.is_empty() and root.get_visible_rect().encloses(card.screen_rect()), "Hand safe point opens separate complete detail card: " + id): return false
	return _hover_rules_clear(card, "hand:" + id)

func _field_hover(id: String, expected: Dictionary) -> bool:
	if not await _wait_hover_detail("unit:" + id): return false
	var detail = battle._view._detail
	var data: Dictionary = detail.display_data
	var description: String = str(data.get("rule_description", ""))
	if not _check(detail.visible and _full_card(detail) and str(data.get("instance_id", "")) == id and str(data.get("name", "")) == str(expected.name) and not description.is_empty() and root.get_visible_rect().encloses(detail.screen_rect()), "Field safe point exposes complete visible card: " + id): return false
	return _hover_rules_clear(detail, "unit:" + id)

func _hover_rules_clear(card: Control, label: String) -> bool:
	var panel: Control = battle._view._rules_detail
	var rules_rect: Rect2 = panel.get_global_rect()
	var card_rect: Rect2 = card.screen_rect()
	var viewport: Rect2 = root.get_visible_rect()
	trace.append({"step": "hover-rules", "label": label, "window": _json_geometry(root.size), "rules_rect": _json_geometry(rules_rect), "card_rect": _json_geometry(card_rect), "viewport": _json_geometry(viewport)})
	if not _check(panel.is_visible_in_tree() and rules_rect.has_area() and viewport.encloses(rules_rect) and viewport.encloses(card_rect), "Actual hover rules and complete card remain inside the viewport: " + label): return false
	return _check(not rules_rect.intersects(card_rect), "Actual hover rules do not cover the complete card or its costs: " + label)

func _full_card(card: Control) -> bool:
	return card.mode == "full"

func _geometry(label: String) -> bool:
	var viewport: Rect2 = root.get_visible_rect()
	var controls: Dictionary = _state().ui_controls
	for key in controls:
		var control: Dictionary = controls[key]
		var point: Vector2 = _point(str(key))
		if point.x < 0: return false
		var rect := Rect2(float(control.x), float(control.y), float(control.w), float(control.h))
		if not _check(rect.has_area() and viewport.intersects(rect), label + ": visible geometry " + str(key)): return false
		if str(key).begins_with("unit:") or str(key).begins_with("hq:") or key in ["end_turn", "restart", "mulligan_confirm", "settings"]:
			if not _check(viewport.encloses(rect), label + ": complete control fits " + str(key)): return false
		if key in ["end_turn", "mulligan_confirm"] and not _button_text_bounds(key): return false
		if str(key).begins_with("hand:") or str(key).begins_with("unit:"):
			if not _check(battle._view.pick_source(point) == str(key), label + ": safe point resolves exact card " + str(key)): return false
	return true

func _resolution_matrix() -> void:
	for window_size in WINDOW_MATRIX:
		root.mode = Window.MODE_WINDOWED
		root.size = window_size
		await _frames(4)
		var label: String = "%dx%d" % [window_size.x, window_size.y]
		if not _check(root.size == window_size, "Requested native window size applied: " + label): return
		if not await _load_fixture(_mulligan_fixture(5)): return
		if not _mulligan_geometry(5) or not _geometry(label + " mulligan"): return
		if not await _click("hand:opening-0"): return
		if not _check(_state().interaction.mulligan_selected_ids == ["opening-0"], label + ": real mulligan click"): return
		var fixture: Dictionary = _fixture()
		for index in range(9): _put(fixture, "matrix-hand-%d" % index, "player", "hand", CARDS[index])
		for side in ["player", "ai"]:
			for index in range(4): _put(fixture, "%s-matrix-rear-%d" % [side, index], side, "support", CARDS[index + 1])
			fixture.sides[side].hq_index = 2
		for index in range(5): _put(fixture, "matrix-front-%d" % index, "player", "frontline", CARDS[index])
		if not await _load_fixture(fixture): return
		if not _geometry(label + " full battlefield"): return
		_motion(_point("hand:matrix-hand-4"))
		if not await _hand_hover("matrix-hand-4", fixture.units["matrix-hand-4"]): return
		await _capture("resolution-%s-board.png" % label)
		fixture = _fixture()
		_put(fixture, "matrix-deploy", "player", "hand")
		if not await _load_fixture(fixture): return
		if not await _drag("hand:matrix-deploy", "support:player:0"): return
		if not _check(_domain().sides.player.support_ids == ["matrix-deploy"], label + ": real drag deploys after resize"): return
		resolutions.append({"window": {"x": root.size.x, "y": root.size.y}, "logical_viewport": {"x": root.get_visible_rect().size.x, "y": root.get_visible_rect().size.y}, "status": "passed"})
		_record("resolution-" + label)
	root.size = MAIN_WINDOW
	await _frames(3)

func _resource_checks() -> void:
	_check(Catalog.CARDS.size() == 11, "Catalogue retains ten deck definitions and reserve militia")
	var profile: Resource = battle._view.profile
	if not _check(profile != null and profile.visual_theme != null and profile.artworks == null and profile.visual_theme.background_texture != null, "Default tabletop loads its background without a card artwork library"): return
	_check(profile.visual_theme.card_texture != null and profile.visual_theme.card_texture.resource_path == "res://assets/art/materials/graphite-paper.png", "Default cards load the selected graphite paper")
	_check(battle._view._board.geometry_snapshot().diagnostics.is_empty(), "Tabletop board has no missing-resource errors")
	if not include_art: return
	var texture := load("res://assets/art/illustrations/infantry-street-assault-v2.png") as Texture2D
	_check(texture != null and texture.get_width() == 1346 and texture.get_height() == 1169, "Retained street assault illustration keeps its original dimensions")
	_check(profile.artworks == null, "Retained illustrations are not mapped into battle")
	_record("retained-art-resources")

func _export_art_template() -> void:
	var profile: Resource = battle._view.profile
	var specification: Dictionary = {"run_id": run_id, "scene_path": SCENE_PATH, "profile_id": profile.profile_id, "presentation": _state().presentation, "geometry_id": battle._view.geometry.geometry_id, "templates": {}, "cards": {}}
	for mode in ["full", "field", "hq", "back", "cp", "end_turn", "deck", "settings"]:
		specification.templates[mode] = battle._view.geometry.template(mode).spec()
	var output := FileAccess.open(output_dir.path_join("art-template-spec.json"), FileAccess.WRITE)
	if not _check(output != null, "Playable art template specification can be written"): return
	output.store_string(JSON.stringify(_json_geometry(specification), "\t"))
	output.close()

func _json_geometry(value: Variant) -> Variant:
	if value is Vector2 or value is Vector2i: return {"x": value.x, "y": value.y}
	if value is Vector4: return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
	if value is Transform2D: return {"x": _json_geometry(value.x), "y": _json_geometry(value.y), "origin": _json_geometry(value.origin)}
	if value is Rect2: return {"x": value.position.x, "y": value.position.y, "w": value.size.x, "h": value.size.y}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json_geometry(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value: result.append(_json_geometry(item))
		return result
	return value

func _fixture() -> Dictionary:
	var state: Dictionary = {"seed": TEST_SEED, "turn": 1, "first_side": "player", "active_side": "player", "phase": "active", "winner": "", "frontline_ids": [], "units": {}, "sides": {}}
	for side in ["player", "ai"]:
		state.sides[side] = {"hq_hp": 20, "hq_index": 0, "fatigue": 0, "command_points": 12, "max_command_points": 12, "turns_started": 1, "mulligan_done": true, "hand_ids": [], "draw_ids": [], "discard_ids": [], "support_ids": []}
	return state

func _put(state: Dictionary, id: String, owner: String, zone: String, card: String = "pathfinder") -> void:
	var unit: Dictionary = Catalog.card(card)
	unit.merge({"instance_id": id, "owner": owner, "hp": unit.max_hp, "deployed_this_turn": false, "moved_this_turn": false, "attacked_this_turn": false})
	state.units[id] = unit
	if zone == "frontline": state.frontline_ids.append(id)
	else: state.sides[owner][zone + "_ids"].append(id)

func _load_fixture(state: Dictionary) -> bool:
	if not await _click("restart"): return false
	var limits: Dictionary = battle.rules.snapshot().limits.duplicate(true)
	battle.rules._state = state.duplicate(true)
	battle.rules._state.limits = limits
	battle._refresh_ui()
	_motion(AWAY)
	await _frames(3)
	return true

func _state() -> Dictionary:
	return battle._mcp_state()

func _domain() -> Dictionary:
	return battle.rules.snapshot()

func _anonymous_history() -> bool:
	for entry in _state().history.entries:
		if entry.type not in ["card_drawn", "mulligan_completed", "hand_overflow"]: continue
		var text: String = JSON.stringify(entry)
		for unit in _domain().units.values():
			if text.contains(str(unit.instance_id)) or text.contains(str(unit.name)): return false
	return true

func _point(key: String) -> Vector2:
	var control: Dictionary = _state().ui_controls.get(key, {})
	if not _check(control.has("hit_point"), "Safe input point exists: " + key): return Vector2(-1, -1)
	var point := Vector2(float(control.hit_point.x), float(control.hit_point.y))
	if not _check(root.get_visible_rect().has_point(point), "Safe point in viewport: " + key): return Vector2(-1, -1)
	return point

func _motion(point: Vector2, mask: int = 0) -> void:
	var transform: Transform2D = root.get_final_transform()
	var event := InputEventMouseMotion.new()
	event.position = transform * point
	event.global_position = event.position
	event.relative = transform * point - transform * _mouse
	event.button_mask = mask
	_mouse = point
	_pointer_focus_serial = _focus_loss_serial
	Input.parse_input_event(event)

func _button(point: Vector2, down: bool, button: int = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = root.get_final_transform() * point
	event.global_position = event.position
	event.button_index = button
	event.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if down and button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT] else 0
	event.pressed = down
	Input.parse_input_event(event)

func _key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		Input.parse_input_event(event)

func _click(key: String, wait_idle: bool = true) -> bool:
	if key == "restart" and not _state().ui_controls.has("restart"):
		if not await _click("settings", false): return false
		if not _check(battle._view.is_modal_open(), "Real settings click exposes the restart menu"): return false
	var point: Vector2 = _point(key)
	if point.x < 0: return false
	_motion(point)
	await _frames(1)
	_button(point, true)
	await _frames(1)
	_button(point, false)
	if not wait_idle:
		await _frames(1)
		return true
	return await _idle()

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
	if not await _wait_drag_input("dragging", request): return false
	if not await _draw_frame("drag feedback " + source + " -> " + target): return false
	if not _feedback_visible(source + " -> " + target): return false
	var evidence: String = "drag-deploy.png" if source.begins_with("hand:") else ("drag-advance.png" if target.begins_with("frontline:") else "drag-attack.png")
	return true

func _feedback_visible(label: String) -> bool:
	return _check(battle._view._overlay.get_child_count() == 0 and battle._view.find_child("*Feedback*", true, false) == null, "Drag has no instruction label or insertion markers: " + label)


func _wait_drag_input(expected: String, request: Dictionary) -> bool:
	var started: int = Time.get_ticks_msec()
	var deadline: int = started + 5000
	var label: String = "Real press resolves exact source: " + str(request.source)
	if expected == "dragging": label = "Real drag resolves exact source and target: " + str(request.source) + " -> " + str(request.target)
	var observations: Array = []
	var previous: String = ""
	while Time.get_ticks_msec() < deadline:
		var interaction: Dictionary = _state().interaction
		var matches: bool = interaction.state == expected and interaction.source_id == str(request.source).get_slice(":", 1)
		if expected == "dragging": matches = matches and interaction.hover_target_key == request.target
		if matches: return _check(true, label)
		var observation: Dictionary = _json_geometry({"interaction": interaction, "controller_cursor": battle._cursor, "window_focus": root.has_focus(), "relayout_queued": battle._relayout_queued, "window_size": root.size})
		var fingerprint: String = JSON.stringify(observation)
		if fingerprint != previous and observations.size() < 32:
			previous = fingerprint
			observation["wait_ms"] = Time.get_ticks_msec() - started
			observations.append(observation)
		await process_frame
	var state: Dictionary = _state()
	var diagnostic: Dictionary = _json_geometry({
		"run_id": run_id, "expected_state": expected, "wait_ms": Time.get_ticks_msec() - started,
		"request": request, "observations": observations, "state": state,
		"controller_cursor": battle._cursor, "controller_press_position": battle._press_position,
		"test_mouse": _mouse, "viewport_mouse": root.get_mouse_position(), "desktop_mouse": DisplayServer.mouse_get_position(),
		"mouse_button_mask": Input.get_mouse_button_mask(), "window_size": root.size, "window_position": root.position,
		"visible_rect": root.get_visible_rect(), "final_transform": root.get_final_transform(),
		"window_focus": root.has_focus(), "relayout_queued": battle._relayout_queued,
		"source_control": state.ui_controls.get(request.source, {}), "target_control": state.ui_controls.get(request.target, {})
	})
	trace.append({"step": "drag-input-timeout", "elapsed_ms": Time.get_ticks_msec(), "diagnostic": diagnostic})
	var output := FileAccess.open(output_dir.path_join("drag-failure.json"), FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify(diagnostic, "\t"))
		output.close()
	return _check(false, label)

func _drag(source: String, target: String) -> bool:
	if not await _begin_drag(source, target): return false
	_button(_point(target), false)
	if not await _idle(): return false
	return true

func _frames(count: int = 2) -> void:
	for index in range(count): await process_frame

func _idle() -> bool:
	var deadline: int = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if _state().interaction.state == "idle" and not _state().interaction.presentation_busy:
			await _frames(1)
			return true
		await process_frame
	return _check(false, "Presentation settles within five seconds")

func _player_idle() -> bool:
	var deadline: int = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if _domain().active_side == "player" and _state().interaction.state == "idle" and not _state().interaction.presentation_busy: return true
		await process_frame
	return _check(false, "AI returns to idle player turn")

func _draw_frame(label: String) -> bool:
	await _frames()
	var receipt: Dictionary = {"drawn": false}
	var on_draw: Callable = func(): receipt.drawn = true
	RenderingServer.frame_post_draw.connect(on_draw, CONNECT_ONE_SHOT)
	battle.queue_redraw()
	var deadline: int = Time.get_ticks_msec() + 5000
	var next_draw: int = Time.get_ticks_msec() + 100
	var forced_draws: int = 0
	while not receipt.drawn and Time.get_ticks_msec() < deadline:
		if Time.get_ticks_msec() >= next_draw and forced_draws < 20:
			forced_draws += 1
			next_draw = Time.get_ticks_msec() + 250
			RenderingServer.force_draw(false)
		if not receipt.drawn: await process_frame
	if RenderingServer.frame_post_draw.is_connected(on_draw): RenderingServer.frame_post_draw.disconnect(on_draw)
	if forced_draws > 0: trace.append({"step": "actual-draw-request", "label": label, "forced_draws": forced_draws, "frame_post_draw": receipt.drawn})
	return _check(receipt.drawn, "Visual evidence receives frame_post_draw: " + label)

func _capture(filename: String) -> void:
	var interaction: Dictionary = _state().interaction
	if interaction.state == "idle" and not interaction.presentation_busy:
		await create_timer(battle._view.motion.detail_delay_seconds + battle._view.motion.hover_seconds).timeout
		await _frames(2)
	if not await _draw_frame(filename): return
	var frame: Image = root.get_texture().get_image()
	if not _check(frame != null and not frame.is_empty(), "Screenshot contains pixels: " + filename): return
	if not _check(frame.get_size() == root.size, "Screenshot retains native window dimensions: " + filename): return
	if _check(frame.save_png(output_dir.path_join(filename)) == OK, "Screenshot saved: " + filename):
		screenshots.append(filename)
		var snapshot: Dictionary = _state()
		var evidence: Dictionary = {"run_id": run_id, "game_run_id": snapshot.run_id, "scene_path": SCENE_PATH, "seed": TEST_SEED, "battle_number": snapshot.battle_number, "presentation": snapshot.presentation, "viewport": {"window": _json_geometry(root.size), "logical": _json_geometry(root.get_visible_rect()), "transform": _json_geometry(root.get_final_transform())}, "state": snapshot}
		var sidecar := FileAccess.open(output_dir.path_join(filename + ".json"), FileAccess.WRITE)
		if _check(sidecar != null, "Screenshot configuration sidecar opens: " + filename):
			sidecar.store_string(JSON.stringify(evidence, "\t"))
			sidecar.close()

func _record(label: String) -> void:
	trace.append({"step": label, "elapsed_ms": Time.get_ticks_msec(), "state": _state()})
	print(JSON.stringify({"event": "ui_test_step", "run_id": run_id, "step": label}))

func _check(condition: bool, label: String) -> bool:
	assertions += 1
	if not condition:
		failures.append(label)
		printerr("UI ASSERTION FAILED: " + label)
	return condition

func _finish() -> void:
	var result: Dictionary = {"run_id": run_id, "scene_path": SCENE_PATH, "loaded_scene_path": battle.scene_file_path if is_instance_valid(battle) else "", "seed": TEST_SEED, "status": "passed" if failures.is_empty() else "failed", "assertions": assertions, "failures": failures, "trace": trace, "screenshots": screenshots, "resolutions": resolutions, "timings": timings, "scope": {"art": include_art, "sizes": include_sizes}, "art_template": {"spec": "art-template-spec.json", "full_view": "hand-nine.png", "field_view": "geometry-debug.png"} if include_art else {}, "renderer": DisplayServer.get_name()}
	var output := FileAccess.open(output_dir.path_join("ui-result.json"), FileAccess.WRITE)
	if output == null:
		push_error("Cannot write UI result")
		quit(2)
		return
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print(JSON.stringify({"event": "ui_smoke_complete", "run_id": run_id, "status": result.status, "assertions": assertions}))
	quit(0 if failures.is_empty() else 1)


func _hover_delay_and_insertion() -> void:
	var fixture: Dictionary = _fixture()
	_put(fixture, "preview-hand", "player", "hand", "pathfinder")
	_put(fixture, "preview-hand-2", "player", "hand", "pathfinder")
	_put(fixture, "preview-mover", "player", "support", "pathfinder")
	_put(fixture, "preview-neighbor", "player", "frontline", "pathfinder")
	_put(fixture, "preview-neighbor-2", "player", "frontline", "pathfinder")
	if not await _load_fixture(fixture): return
	var hand_card: Control = battle._view._cards["preview-hand"]
	var base_pose: Dictionary = hand_card.pose().duplicate(true)
	var base_layer: int = hand_card.z_index
	var hand_point: Vector2 = _point("hand:preview-hand")
	_motion(hand_point)
	await create_timer(0.20).timeout
	_check(absf(base_pose.position.y - hand_card.position.y - 4.0) < 0.05 and is_equal_approx(hand_card.rotation, base_pose.rotation) and hand_card.size.is_equal_approx(base_pose.size) and hand_card.z_index == base_layer and not battle._view._rules_detail.visible, "Hand immediately micro-lifts four pixels, preserves angle, size, layer and hides detail during dwell")
	trace.append({"step": "micro-lift", "pixels": base_pose.position.y - hand_card.position.y, "rotation_before": base_pose.rotation, "rotation_after": hand_card.rotation, "layer_before": base_layer, "layer_after": hand_card.z_index})
	var started: int = battle._view._detail_started_msec
	_motion(hand_point + Vector2(1, 0))
	await _frames(1)
	_check(battle._view._detail_started_msec == started, "Motion within the same card does not reset hover dwell")
	if not await _wait_hover_detail("hand:preview-hand"): return
	_check(battle._view._hover_id == "preview-hand" and not hand_card.position.is_equal_approx(base_pose.position), "Hand raises after dwell and shows detail")
	_check(is_equal_approx(battle._view.motion.detail_delay_seconds, 0.4) and is_equal_approx(battle._view.motion.hover_seconds, 0.1), "Detail delay and immediate hover travel timings are configured")
	_motion(_point("hand:preview-hand-2"))
	await _frames(1)
	_check(battle._view._hover_id == "preview-hand-2" and not battle._view._rules_detail.visible and hand_card.get_meta("hover_pose") == "base", "Changing cards immediately starts old card return and new card micro-lift")
	await create_timer(0.16).timeout
	_check(hand_card.position.is_equal_approx(base_pose.position) and battle._view._hover_id == "preview-hand-2", "Return completes in 0.1 seconds without a second dwell")
	_motion(AWAY)
	await create_timer(0.45).timeout
	_check(battle._view._hover_id.is_empty() and not battle._view._rules_detail.visible, "Leaving before dwell restores base and cancels detail")
	_motion(hand_point)
	await create_timer(0.1).timeout
	_button(hand_point, true)
	await create_timer(0.45).timeout
	_check(battle._view._hover_id.is_empty() and not battle._view._rules_detail.visible, "Press cancels pending delayed hover")
	_button(hand_point, false)
	_motion(AWAY)
	await _idle()
	_motion(_point("unit:preview-mover"))
	await create_timer(0.20).timeout
	_check(not battle._view._rules_detail.visible, "Brief hover does not open enlarged detail")
	_motion(_point("unit:preview-neighbor"))
	await create_timer(0.25).timeout
	_check(not battle._view._rules_detail.visible, "Changing cards resets the 0.4 second dwell")
	await create_timer(0.25).timeout
	if not await _field_hover("preview-neighbor", fixture.units["preview-neighbor"]): return
	_motion(_point("unit:preview-mover"))
	_button(_point("unit:preview-mover"), true)
	await _frames(2)
	_check(not battle._view._rules_detail.visible, "Press closes detail and cancels dwell")
	_button(_point("unit:preview-mover"), false)
	await _idle()
	var source: Dictionary = battle._view._cards["preview-mover"].pose()
	var neighbor: Dictionary = battle._view._cards["preview-neighbor"].pose()
	var before: Dictionary = _domain()
	var stable_gap: Vector2 = _point("frontline:1")
	if not await _begin_drag("unit:preview-mover", "frontline:1"): return
	await create_timer(0.16).timeout
	_check(battle._view._cards["preview-mover"].pose() == source and battle._view._cards["preview-mover"].modulate.a == 1.0, "Move preview keeps the original unit fixed and opaque")
	_check(battle._view._overlay.arrow and not battle._view._drag_preview.visible, "Move preview uses an arrow without a following card")
	_check(battle._view._cards["preview-neighbor"].position != neighbor.position and _point("frontline:1") == stable_gap and _domain() == before, "Arrow opens a gap without changing hit selection or domain")
	_key(KEY_ESCAPE)
	await _frames(1)
	_check(_state().interaction.presentation_busy, "Cancel waits for neighboring cards to return")
	if not await _idle(): return
	_check(battle._view._cards["preview-neighbor"].position.is_equal_approx(neighbor.position) and _domain() == before, "Escape restores insertion without submitting")
	if not await _begin_drag("unit:preview-mover", "frontline:1"): return
	for index in [0, 2, 1]:
		_motion(_point("frontline:%d" % index), MOUSE_BUTTON_MASK_LEFT)
		await create_timer(0.16).timeout
		_check(_state().interaction.hover_target_key == "frontline:%d" % index and _domain() == before, "Stable insertion target while crossing gaps %d" % index)
	_motion(AWAY, MOUSE_BUTTON_MASK_LEFT)
	await create_timer(0.16).timeout
	_check(battle._view._cards["preview-neighbor"].position.is_equal_approx(neighbor.position), "Leaving a legal row restores the neighbor")
	_button(AWAY, false)
	if not await _idle(): return
	_check(_domain() == before and not battle._view._overlay.active, "Invalid move release leaves no arrow or rule change")
	if not await _begin_drag("hand:preview-hand", "support:player:1"): return
	await create_timer(0.16).timeout
	_check(battle._view._drag_preview.visible and not battle._view._overlay.arrow and battle._view._drag_preview.size.x > battle._view._layout.field_size.x, "Deployment retains the larger following card")
	_button(_point("support:player:1"), false)
	if not await _idle(): return
	_check(_domain().units["preview-hand"].zone == "support", "Insertion deployment commits on release")


func _wait_hover_detail(key: String) -> bool:
	var deadline: int = Time.get_ticks_msec() + 2500
	var held_point: Vector2 = _mouse
	while Time.get_ticks_msec() < deadline:
		await process_frame
		# Focus loss intentionally cancels detail even when the pointer did not move.
		# Restore focus and inject a fresh real motion, within the original deadline.
		if _pointer_focus_serial != _focus_loss_serial:
			trace.append({"step": "hover-focus-recovery", "expected": key, "focus_loss_serial": _focus_loss_serial})
			root.grab_focus()
			_motion(held_point)
			continue
		# Native desktop motion can arrive after injected input. Hold the test's
		# pointer through Input, without extending the deadline or setting view state.
		if not battle._view._cursor.is_equal_approx(held_point):
			trace.append({"step": "hover-pointer-drift", "expected": _json_geometry(held_point), "actual": _json_geometry(battle._view._cursor)})
			_motion(held_point)
			continue
		var settled: bool = true
		for tween in battle._view._hover_tweens.values():
			if tween.is_valid() and tween.is_running(): settled = false
		if settled and battle._view._detail_key == key and battle._view._rules_detail.visible:
			return await _draw_frame("hover detail " + key)
	trace.append({"step": "hover-timeout", "expected": key, "actual": battle._view._detail_key, "hover_id": battle._view._hover_id, "cursor": _json_geometry(battle._view._cursor), "visible": battle._view._rules_detail.visible})
	return _check(false, "Hover detail did not settle before deadline: " + key)
