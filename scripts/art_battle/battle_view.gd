extends Control
## Presentation of the live battle through the interchangeable art profile.
## Rules, turn scheduling and input commitment remain in the controller.

signal end_turn_requested
signal restart_requested
signal main_menu_requested
signal mulligan_confirm_requested
signal modal_changed(open: bool)
signal presentation_invalidated

const FixedLabel = preload("res://scripts/art_battle/fixed_label.gd")
const FixedPanel = preload("res://scripts/art_battle/fixed_panel.gd")
const CardView = preload("res://scripts/art/art_card.gd")
const Widgets = preload("res://scripts/art/art_widgets.gd")
const Board = preload("res://scripts/art/art_board.gd")
const Layout = preload("res://scripts/art_battle/battle_layout.gd")
const Presenter = preload("res://scripts/art_battle/presenter.gd")
const WidgetButton = preload("res://scripts/art_battle/widget_button.gd")
const Overlay = preload("res://scripts/art_battle/battle_overlay.gd")
const DisplayProfile = preload("res://scripts/art/display_profile.gd")

const DefaultGeometry = preload("res://resources/art/battle_geometry.tres")
const DefaultText = preload("res://resources/text/approved_zh.tres")
const DefaultMotion = preload("res://resources/presentation/basic_motion.tres")
const PresentationPlayer = preload("res://scripts/art_battle/presentation_player.gd")
const PresentationRun = preload("res://scripts/art_battle/presentation_run.gd")
const Fingerprint = preload("res://scripts/art_battle/config_fingerprint.gd")

@export var geometry: Resource = DefaultGeometry
@export var text: Resource = DefaultText
@export var motion: Resource = DefaultMotion
@export var profile: Resource
@export var geometry_debug: bool = false:
	set(value):
		if geometry_debug == value: return
		geometry_debug = value
		_refresh_display()

var display_profile: Resource

var _state: Dictionary = {}
var _actions: Array = []
var _interaction: Dictionary = {}
var _selected: Array = []
var _layout: Dictionary = {}
var _controls: Dictionary = {}
var _labels: Dictionary = {}
var _widgets: Dictionary = {}
var _cards: Dictionary = {}
var _hand_poses: Dictionary = {}
var _gap_nodes: Dictionary = {}
var _gap_points: Dictionary = {}
var _back_cards: Array[Control] = []
var _card_layer: Control
var _board: Control
var _overlay: Control
var _drag_preview: Control
var _detail: Control
var _rules_detail: Control
var _rules_text: Control
var _detail_geometry: Dictionary = {}
var _modal_blocker: ColorRect
var _modal_panel: Control
var _menu_panel: Control
var _menu_open: bool = false
var _hover_id: String = ""
var _cursor := Vector2(-100, -100)
var _tween: Tween
var _player = PresentationPlayer.new()
var _presentation_run: RefCounted
var _presentation_hidden: Dictionary = {}
var _presentation_status: Dictionary = {}
var _hover_tweens: Dictionary = {}
var _detail_key: String = ""
var _detail_started_msec: int = 0
var _row_preview_key: String = ""
var _row_base: Dictionary = {}
var _row_tweens: Dictionary = {}
var _row_return_from: Dictionary = {}
var _effect_regions: Dictionary = {}


func _process(_delta: float) -> void:
	if _detail_key.is_empty(): return
	if _interaction.get("state", "idle") != "idle" or is_modal_open():
		_hide_detail()
		return
	var now: int = Time.get_ticks_msec()
	if not _detail_key.is_empty() and now - _detail_started_msec >= motion.detail_delay_seconds * 1000.0:
		var moving_hand: bool = _detail_key.begins_with("hand:") and _hover_tweens.has(_hover_id) and _hover_tweens[_hover_id].is_running()
		if not _rules_detail.visible or moving_hand:
			_update_detail(_detail_key)


func _stop_row_tweens() -> void:
	for tween in _row_tweens.values():
		if tween.is_valid(): tween.kill()
	_row_tweens.clear()


func _row_slide(key: String, target: Dictionary) -> void:
	var card: Control = _controls[key]
	if _row_tweens.has(key) and _row_tweens[key].is_valid(): _row_tweens[key].kill()
	var tween := create_tween()
	_row_tweens[key] = tween
	tween.tween_property(card, "position", target.position, motion.insertion_seconds).set_trans(motion.tween_transition()).set_ease(Tween.EASE_OUT)


func _preview_insertion(key: String) -> void:
	if key == _row_preview_key: return
	for old_key in _row_base:
		if _controls.has(old_key): _row_slide(old_key, _row_base[old_key])
	_row_preview_key = key
	if key.is_empty(): return
	var row: String = "frontline" if key.begins_with("frontline:") else "player"
	var index: int = int(key.get_slice(":", 1 if row == "frontline" else 2))
	var ids: Array = _state.frontline_ids.duplicate() if row == "frontline" else _state.sides.player.support_ids.duplicate()
	if row == "player": ids.insert(int(_state.sides.player.hq_index), "hq:player")
	for i in range(ids.size()):
		var card_key: String = str(ids[i]) if str(ids[i]).begins_with("hq:") else "unit:" + str(ids[i])
		if not _row_base.has(card_key): _row_base[card_key] = _controls[card_key].pose()
		_row_slide(card_key, Layout.row_pose(_layout, row, "hq" if card_key.begins_with("hq:") else "field", i if i < index else i + 1, ids.size() + 1))



func _ready() -> void:
	assert(profile != null and profile.visual_theme != null, "Battle scene must provide a material profile")
	display_profile = DisplayProfile.resolve(profile, geometry_debug)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_measure_layout()
	_build_view()
	_apply_layout()
	reset_presentation()


func set_profile(value: Resource) -> void:
	assert(value != null and value.visual_theme != null, "Invalid material profile")
	profile = value
	_refresh_display()


func _refresh_display() -> void:
	if not is_node_ready(): return
	presentation_invalidated.emit()
	stop_presentation()
	clear_drag()
	display_profile = DisplayProfile.resolve(profile, geometry_debug)
	_apply_layout()
	if not _state.is_empty(): render(_state, _actions, _interaction, _selected)
	queue_redraw()


func _measure_layout() -> void:
	size = get_viewport().get_visible_rect().size
	_layout = Layout.calculate(size, get_viewport().get_final_transform().x.length(), geometry)


func relayout() -> void:
	_cursor = Vector2(-100, -100)
	_hover_id = ""
	_measure_layout()
	_apply_layout()
	if not _state.is_empty(): render(_state, _actions, _interaction, _selected)
	queue_redraw()


func drag_distance(from: Vector2, to: Vector2) -> float:
	return from.distance_to(to) / maxf(float(_layout.get("art_scale", 1.0)), 0.01)


func _draw() -> void:
	if display_profile == null or display_profile.visual_theme == null: return
	var visual_theme: Resource = display_profile.visual_theme
	if visual_theme.renderer != null:
		visual_theme.renderer.draw_tabletop(self, visual_theme, Rect2(Vector2.ZERO, size))
	else:
		draw_rect(Rect2(Vector2.ZERO, size), visual_theme.color("background"))


func _build_view() -> void:
	_board = Board.new()
	add_child(_board)
	_card_layer = Control.new()
	_card_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_card_layer)
	for key in ["cp_player", "cp_enemy", "player_deck", "enemy_deck"]:
		var widget := Widgets.new()
		widget.z_index = int(geometry.layout.layers.command_points) if str(key).begins_with("cp_") else 0
		add_child(widget)
		_widgets[key] = widget
	for key in ["phase", "turn", "front_control", "player_counts", "enemy_counts"]:
		_make_label(key)
	var end_button: BaseButton = _make_button("end_turn", text.caption("end_turn"))
	end_button.pressed.connect(func(): end_turn_requested.emit())
	var confirm: BaseButton = _make_button("mulligan_confirm", text.caption("mulligan_keep"))
	confirm.pressed.connect(func(): mulligan_confirm_requested.emit())
	var settings: BaseButton = _make_button("settings", text.caption("settings"), "settings")
	settings.tooltip_text = text.caption("settings")
	settings.pressed.connect(_open_menu)
	for side in ["player", "ai"]:
		var headquarters := CardView.new()
		_card_layer.add_child(headquarters)
		_controls["hq:" + side] = headquarters
	_detail = CardView.new()
	_detail.z_index = int(geometry.layout.layers.detail_card)
	add_child(_detail)
	_rules_detail = FixedPanel.new()
	_rules_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rules_detail.z_index = int(geometry.layout.layers.detail_rules)
	add_child(_rules_detail)
	_rules_text = FixedLabel.new()
	_rules_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rules_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rules_detail.add_child(_rules_text)
	_overlay = Overlay.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.z_index = int(geometry.layout.layers.drag_overlay)
	add_child(_overlay)
	_drag_preview = CardView.new()
	_drag_preview.z_index = int(geometry.layout.layers.drag_card)
	add_child(_drag_preview)
	_drag_preview.hide()
	_modal_blocker = ColorRect.new()
	_modal_blocker.color = Color(display_profile.visual_theme.color("shadow"), float(display_profile.visual_theme.surface.strokes.modal_alpha))
	_modal_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_blocker.z_index = int(geometry.layout.layers.modal_mask)
	_modal_blocker.gui_input.connect(_modal_input)
	add_child(_modal_blocker)
	_menu_panel = FixedPanel.new()
	_menu_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_panel.z_index = int(geometry.layout.layers.modal_panel)
	add_child(_menu_panel)
	_modal_panel = FixedPanel.new()
	_modal_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_panel.z_index = int(geometry.layout.layers.modal_panel)
	add_child(_modal_panel)
	for key in ["modal_title", "modal_text"]:
		_make_label(key)
		_labels[key].z_index = int(geometry.layout.layers.modal_text)
	_labels.modal_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var restart: BaseButton = _make_button("restart", text.caption("restart"))
	restart.z_index = int(geometry.layout.layers.modal_button)
	restart.pressed.connect(func(): restart_requested.emit())
	var home: BaseButton = _make_button("main_menu", text.caption("main_menu"))
	home.z_index = int(geometry.layout.layers.modal_button)
	home.pressed.connect(func(): main_menu_requested.emit())
	var close_button: BaseButton = _make_button("modal_close", text.caption("close"), "settings")
	close_button.z_index = int(geometry.layout.layers.modal_button)
	close_button.tooltip_text = text.caption("close_settings")
	close_button.pressed.connect(close_modal)
	_hide_detail()
	_sync_modal()


func _make_label(key: String) -> Control:
	var label := FixedLabel.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(label)
	_labels[key] = label
	return label


func _make_button(key: String, caption: String, role: String = "end_turn") -> BaseButton:
	var button := WidgetButton.new()
	button.profile = display_profile
	button.geometry = geometry
	button.role = role
	button.icon_role = "settings_icon" if key == "settings" else ("close_icon" if key == "modal_close" else "")
	button.text = caption
	add_child(button)
	_controls[key] = button
	return button


func _set_rect(control: Control, value: Rect2) -> void:
	control.position = value.position
	control.size = value.size


func _apply_layout() -> void:
	_card_layer.size = size
	_board.configure(display_profile, geometry)
	_board.position = _layout.stage_rect.position
	_board.scale = Vector2.ONE * float(_layout.art_scale)
	_overlay.size = size
	_overlay.profile = display_profile
	_overlay.presentation_scale = _layout.art_scale
	_overlay.hint_rect = Layout.rect(_layout, Rect2(260, 44, 380, 26))
	_modal_blocker.size = size
	_modal_blocker.color = Color(display_profile.visual_theme.color("shadow"), float(display_profile.visual_theme.surface.strokes.modal_alpha))
	for key in _labels:
		var label: Control = _labels[key]
		if _layout.rects.has(key): _set_rect(label, _layout.rects[key])
		label.add_theme_font_override("font", display_profile.visual_theme.surface.font)
		label.add_theme_font_size_override("font_size", _layout.body_font)
		label.add_theme_color_override("font_color", display_profile.visual_theme.color("text"))
	_labels.front_control.add_theme_color_override("font_color", display_profile.visual_theme.color("muted"))
	for key in ["phase", "turn"]:
		var backing: StyleBox = display_profile.visual_theme.style("status_backing")
		if backing != null: _labels[key].add_theme_stylebox_override("background", backing)
		else: _labels[key].remove_theme_stylebox_override("background")
	_labels.modal_title.add_theme_font_size_override("font_size", _font_size("modal_title"))
	for key in ["end_turn", "settings", "restart", "main_menu", "mulligan_confirm", "modal_close"]:
		var button: BaseButton = _controls[key]
		button.profile = display_profile
		button.geometry = geometry
		_set_rect(button, _layout.rects[key])
		button.refresh()
	for panel in [_rules_detail, _menu_panel, _modal_panel]:
		panel.add_theme_stylebox_override("panel", display_profile.visual_theme.style("well"))
	_set_rect(_menu_panel, _layout.rects.menu)
	_set_rect(_modal_panel, _layout.rects.modal)
	_rules_text.add_theme_font_override("font", display_profile.visual_theme.surface.font)
	_rules_text.add_theme_color_override("font_color", display_profile.visual_theme.color("text"))
	_hide_detail()
	_sync_modal()


func _font_size(role: String) -> int:
	return maxi(int(_layout.body_font), roundi(float(geometry.layout.battle_font_sizes[role]) * float(_layout.art_scale)))


func render(state: Dictionary, actions: Array, interaction: Dictionary, selected: Array) -> void:
	if state.is_empty():
		reset_presentation()
		return
	if state.get("turn") != _state.get("turn") or state.get("phase") != _state.get("phase"): _hide_detail()
	_state = state
	_actions = actions
	_interaction = interaction
	_selected = selected
	var idle: bool = interaction.get("state", "idle") == "idle"
	presentation_set_status(_presentation_status if _presentation_run != null and not _presentation_run.done and not _presentation_status.is_empty() else state)
	_sync_cards()
	if interaction.get("state", "") == "choosing_deploy": _row_preview_key = ""
	_stop_row_tweens()
	if not interaction.get("presentation_busy", false):
		for key in _row_return_from:
			if not _controls.has(key): continue
			var target: Dictionary = _controls[key].pose()
			_controls[key].apply_pose(_row_return_from[key])
			_row_slide(key, target)
	_row_return_from.clear()
	if _presentation_hidden.is_empty(): presentation_set_frontline_y(_frontline_y())
	for key in _presentation_hidden.keys(): presentation_hide_card(str(key))
	_update_targets()
	_sync_modal()
	for key in ["end_turn", "settings", "restart", "main_menu", "mulligan_confirm", "modal_close"]: _controls[key].refresh()
	queue_redraw()
	if idle and not is_modal_open(): update_hover(_cursor)
	else:
		_hover_id = ""
		_hide_detail()


func presentation_set_status(state: Dictionary) -> void:
	_presentation_status = state
	if state.is_empty(): return
	var player: Dictionary = state.sides.player
	var enemy: Dictionary = state.sides.ai
	var mulligan: bool = state.phase == "mulligan"
	var finished: bool = state.phase == "finished" and not _interaction.get("presentation_busy", false)
	var idle: bool = _interaction.get("state", "idle") == "idle"
	_labels.phase.text = (text.caption("victory") if state.winner == "player" else text.caption("defeat")) if finished else ("" if mulligan else (text.caption("player_turn") if Presenter.player_turn(state) else text.caption("enemy_turn")))
	_labels.phase.show()
	if finished and state.winner == "draw": _labels.phase.text = text.caption("draw")
	if state.phase == "waiting_choice": _labels.phase.text = "选择效果目标" if state.get("pending_choice", {}).get("owner", "") == "player" else "对手选择目标"
	_labels.turn.show()
	_labels.turn.text = (text.caption("first_player") if state.first_side == "player" else text.caption("second_player")) if mulligan else text.caption("turn_number") % state.turn
	var control: String = text.caption("front_neutral") if state.frontline_ids.is_empty() else (text.caption("front_player") if state.units[state.frontline_ids[0]].owner == "player" else text.caption("front_enemy"))
	_labels.front_control.text = text.caption("front_status") % [control, state.frontline_ids.size(), state.limits.frontline_limit]
	_labels.player_counts.text = text.caption("deck_counts") % [player.draw_count, player.discard_count]
	_labels.enemy_counts.text = text.caption("enemy_counts") % [enemy.hand_count, enemy.draw_count, enemy.discard_count]
	for key in ["front_control", "player_counts", "enemy_counts"]: _labels[key].visible = not mulligan
	_controls.end_turn.visible = not mulligan and not finished
	_controls.end_turn.disabled = not (Presenter.player_turn(state) and idle and not is_modal_open())
	_controls.mulligan_confirm.visible = mulligan
	_controls.mulligan_confirm.disabled = not mulligan or player.mulligan_done or is_modal_open() or not idle
	_controls.mulligan_confirm.text = text.caption("mulligan_replace") % _selected.size() if not _selected.is_empty() else text.caption("mulligan_keep")
	for side in ["player", "enemy"]:
		var value: Dictionary = player if side == "player" else enemy
		var cp: Control = _widgets["cp_" + side]
		cp.configure({"available": value.command_points, "capacity": value.max_command_points, "command_unit": text.caption("command_unit")}, "cp", display_profile, geometry)
		_set_rect(cp, _layout.rects["cp_" + side])
		cp.visible = not mulligan
		var deck: Control = _widgets[side + "_deck"]
		deck.configure({"count": value.draw_count}, "deck", display_profile, geometry)
		_set_rect(deck, _layout.rects[side + "_deck"])
		deck.pivot_offset = deck.size * 0.5
		deck.rotation = deg_to_rad(float(geometry.layout.battle_deck_angles[side]))
		deck.tooltip_text = text.caption("deck_counts") % [value.draw_count, value.discard_count]
		deck.visible = not mulligan
	for key in ["end_turn", "mulligan_confirm"]: _controls[key].refresh()


func _sync_cards() -> void:
	_hide_detail()
	_hover_id = ""
	for key in _controls.keys():
		if str(key).begins_with("hand:") or str(key).begins_with("unit:") or _is_gap(str(key)): _controls.erase(key)
	_stop_hover()
	for card in _cards.values():
		card.hide()
		card.modulate = Color.WHITE
	for gap in _gap_nodes.values(): gap.hide()
	_hand_poses.clear()
	_gap_points.clear()
	var mulligan: bool = _state.phase == "mulligan"
	_sync_effect_regions(not mulligan)
	for side in ["player", "ai"]: _controls["hq:" + side].visible = not mulligan
	if not mulligan:
		_layout_support("ai", "enemy")
		_layout_support("player", "player")
		var front: Array = _state.frontline_ids
		for index in range(front.size()): _place_card(str(front[index]), Layout.row_pose(_layout, "frontline", "field", index, front.size()), false, int(geometry.layout.layers.field_card) + index)
		_make_gaps("frontline:", "frontline", front.size())
	var hand: Array = _state.sides.player.hand_ids
	for index in range(hand.size()):
		var id: String = str(hand[index])
		var value: Dictionary = Layout.mulligan_pose(_layout, hand.size(), index) if mulligan else Layout.hand_pose(_layout, hand.size(), index)
		_hand_poses[id] = value
		_place_card(id, value, true, int(geometry.layout.layers.hand_card) + index)
	var enemy_count: int = int(_state.sides.ai.hand_count)
	while _back_cards.size() < enemy_count:
		var created := CardView.new()
		_card_layer.add_child(created)
		_back_cards.append(created)
	for index in range(_back_cards.size()):
		var back: Control = _back_cards[index]
		back.configure({}, "back", display_profile, geometry.template("back"))
		back.apply_pose(Layout.enemy_back_pose(_layout, index, enemy_count))
		back.z_index = int(geometry.layout.layers.enemy_hand) + index
		back.visible = index < enemy_count and not mulligan


func _sync_effect_regions(shown: bool) -> void:
	for side in ["player", "ai"]:
		for row in ["support", "frontline"]:
			var key: String = "row:%s:%s" % [side, row]
			if not _effect_regions.has(key):
				var region := Control.new()
				region.mouse_filter = Control.MOUSE_FILTER_IGNORE
				add_child(region)
				_effect_regions[key] = region
			var y: float = _layout.front_y if row == "frontline" else (_layout.player_y if side == "player" else _layout.enemy_y)
			_set_rect(_effect_regions[key], Rect2(_layout.row_left, y, _layout.row_right - _layout.row_left, _layout.field_size.y))
			_effect_regions[key].visible = shown
			_controls[key] = _effect_regions[key]
	if not _effect_regions.has("cast:player"):
		var region := Control.new()
		region.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(region)
		_effect_regions["cast:player"] = region
	_set_rect(_effect_regions["cast:player"], Layout.rect(_layout, Rect2(770, 417, 115, 60)))
	_effect_regions["cast:player"].visible = shown
	_controls["cast:player"] = _effect_regions["cast:player"]


func _layout_support(side: String, row: String) -> void:
	var value: Dictionary = _state.sides[side]
	var display: Array = value.support_ids.duplicate()
	display.insert(int(value.hq_index), "hq:" + side)
	for index in range(display.size()):
		var key: String = str(display[index])
		if key.begins_with("hq:"):
			var card: Control = _controls[key]
			card.configure(Presenter.hq_data(_state, side, text), "hq", display_profile, geometry.template("hq"))
			card.apply_pose(Layout.row_pose(_layout, row, "hq", index, display.size()))
			card.z_index = int(geometry.layout.layers.field_card) + index
		else: _place_card(key, Layout.row_pose(_layout, row, "field", index, display.size()), false, int(geometry.layout.layers.field_card) + index)
	if side == "player": _make_gaps("support:player:", row, display.size())


func _make_gaps(prefix: String, row: String, count: int) -> void:
	for index in range(count + 1):
		var key: String = prefix + str(index)
		var geometry: Dictionary = Layout.gap_geometry(_layout, row, index, count)
		if not _gap_nodes.has(key):
			var node := Control.new()
			node.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(node)
			_gap_nodes[key] = node
		var gap: Control = _gap_nodes[key]
		_set_rect(gap, geometry.rect)
		gap.show()
		_controls[key] = gap
		_gap_points[key] = geometry.hit_point


func _place_card(id: String, value: Dictionary, hand: bool, order: int) -> void:
	if not _cards.has(id):
		var created := CardView.new()
		created.name = id.replace("-", "_")
		_card_layer.add_child(created)
		_cards[id] = created
	var card: Control = _cards[id]
	card.configure(Presenter.unit_data(_state, id, _actions, text, _selected), "full" if hand else "field", display_profile, geometry.template("full" if hand else "field"))
	card.apply_pose(value)
	card.set_meta("hover_pose", "base")
	card.z_index = order
	card.show()
	_controls[("hand:" if hand else "unit:") + id] = card


func _player_turn() -> bool:
	return Presenter.player_turn(_state)


func _source_legal(id: String) -> bool:
	return Presenter.source_legal(_actions, id)


func is_modal_open() -> bool:
	return _menu_open or _state.get("phase", "") == "finished"


func _open_menu() -> void:
	if _state.get("phase", "") == "finished": return
	_menu_open = true
	clear_drag()
	_sync_modal()
	modal_changed.emit(true)


func close_modal() -> void:
	if not _menu_open: return
	_menu_open = false
	_sync_modal()
	modal_changed.emit(false)


func _modal_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close_modal()


func _sync_modal() -> void:
	if not is_instance_valid(_modal_blocker): return
	var finished: bool = _state.get("phase", "") == "finished" and not _interaction.get("presentation_busy", false)
	var shown: bool = _menu_open or finished
	_modal_blocker.visible = shown
	_menu_panel.visible = _menu_open and not finished
	_modal_panel.visible = finished
	_labels.modal_title.visible = finished
	_labels.modal_text.visible = finished
	_controls.settings.visible = not _state.is_empty() and not is_modal_open()
	_controls.settings.disabled = is_modal_open()
	_controls.modal_close.visible = _menu_open and not finished
	_controls.restart.visible = shown
	_controls.main_menu.visible = shown
	_set_rect(_controls.main_menu, _layout.rects.modal_main_menu if finished else _layout.rects.main_menu)
	_set_rect(_controls.restart, _layout.rects.modal_restart if finished else _layout.rects.restart)
	if finished:
		_labels.modal_title.text = text.caption("victory") if _state.get("winner", "") == "player" else text.caption("defeat")
		_labels.modal_text.text = text.caption("victory_detail") if _state.get("winner", "") == "player" else text.caption("defeat_detail")
		if _state.get("winner", "") == "draw":
			_labels.modal_title.text = text.caption("draw")
			_labels.modal_text.text = text.caption("draw_detail")
	_controls.restart.refresh()
	_controls.settings.refresh()


func is_ui_point(point: Vector2) -> bool:
	if is_modal_open(): return true
	for key in ["end_turn", "restart", "main_menu", "mulligan_confirm", "settings", "modal_close"]:
		var control: Control = _controls[key]
		if control.is_visible_in_tree() and control.get_global_rect().has_point(point): return true
	return false


func pick_source(point: Vector2) -> String:
	if is_ui_point(point): return ""
	var hand: Array = _state.get("sides", {}).get("player", {}).get("hand_ids", [])
	for index in range(hand.size() - 1, -1, -1):
		var id: String = str(hand[index])
		if _hand_poses.has(id) and _pose_contains(_hand_poses[id], point): return "hand:" + id
	if not _hover_id.is_empty() and _cards.has(_hover_id) and _cards[_hover_id].contains_point(point): return "hand:" + _hover_id
	var candidates: Array = []
	for key in _controls:
		if str(key).begins_with("unit:"): candidates.append(key)
	candidates.sort_custom(func(a: String, b: String) -> bool: return _controls[a].z_index > _controls[b].z_index)
	for key in candidates:
		if _controls[key].contains_point(point): return str(key)
	return ""


func pick_drop(point: Vector2) -> String:
	if is_ui_point(point): return ""
	var legal: Array = _interaction.get("legal_target_keys", [])
	for key in _controls:
		if not legal.has(key): continue
		if (str(key).begins_with("unit:") or str(key).begins_with("hq:")) and _controls[key].contains_point(point): return str(key)
	for key in _effect_regions:
		if legal.has(key) and _effect_regions[key].get_global_rect().has_point(point): return str(key)
	for key in _gap_points:
		if legal.has(key) and _controls[key].get_global_rect().has_point(point): return str(key)
	return ""


func _is_gap(key: String) -> bool:
	return key.begins_with("support:player:") or key.begins_with("frontline:")


func source_pose(key: String) -> Dictionary:
	return _controls[key].pose() if _controls.has(key) else {}


func capture_poses() -> Dictionary:
	var result: Dictionary = {"_scale": _layout.art_scale, "_frontline_y": _frontline_y()}
	for key in _controls:
		if (str(key).begins_with("unit:") or str(key).begins_with("hand:") or str(key).begins_with("hq:")) and _controls[key].visible:
			result[key] = _controls[key].pose()
			result[key]["display_data"] = _controls[key].display_data.duplicate(true)
	for index in range(_back_cards.size()):
		if _back_cards[index].visible: result["back:ai:%d" % index] = _back_cards[index].pose()
	for side in ["player", "ai"]:
		var deck: Control = _widgets["player_deck" if side == "player" else "enemy_deck"]
		result["deck:" + side] = {"position": deck.position, "size": deck.size, "rotation": deck.rotation, "scale": Vector2.ONE}
	return result


func _frontline_y() -> float:
	var owner: String = "neutral"
	if not _state.get("frontline_ids", []).is_empty():
		owner = "player" if _state.units[_state.frontline_ids[0]].owner == "player" else "enemy"
	return float(geometry.layout["frontline_" + owner + "_y"])


func presentation_set_frontline_y(value: float) -> void:
	_board.frontline_y = value
	_board.queue_redraw()


func _hover_pose(id: String) -> Dictionary:
	return _hand_poses[id].duplicate(true) if _state.phase == "mulligan" else Layout.hover_pose(_layout, _hand_poses[id])


func _pose_transform(value: Dictionary) -> Transform2D:
	var card_scale: Vector2 = value.get("scale", Vector2.ONE)
	var angle: float = float(value.get("rotation", 0.0))
	var x_axis: Vector2 = Vector2.RIGHT.rotated(angle) * card_scale.x
	var y_axis: Vector2 = Vector2.DOWN.rotated(angle) * card_scale.y
	var pivot: Vector2 = value.size * 0.5
	return Transform2D(x_axis, y_axis, value.position + pivot - x_axis * pivot.x - y_axis * pivot.y)


func _pose_contains(value: Dictionary, point: Vector2) -> bool:
	return Rect2(Vector2.ZERO, value.size).has_point(_pose_transform(value).affine_inverse() * point)


func update_hover(point: Vector2) -> void:
	_cursor = point
	if _state.is_empty() or _interaction.get("state", "idle") != "idle" or is_modal_open(): return
	var key: String = pick_source(point)
	if _state.phase == "mulligan": key = ""
	var candidate: String = key.get_slice(":", 1) if key.begins_with("hand:") else ""
	if candidate != _hover_id or key != _detail_key:
		_hide_detail()
		if _hover_id != candidate:
			_hover_id = candidate
			_apply_hover_pose()
		if key.begins_with("unit:") or key.begins_with("hand:"):
			_detail_key = key
			_detail_started_msec = Time.get_ticks_msec()


func _apply_hover_pose() -> void:
	var hand: Array = _state.sides.player.hand_ids
	for index in range(hand.size()):
		var id: String = str(hand[index])
		var card: Control = _cards[id]
		var target: Dictionary = _hover_pose(id) if id == _hover_id else _hand_poses[id]
		var token: String = "raised" if id == _hover_id else "base"
		if card.get_meta("hover_pose", "") != token:
			card.set_meta("hover_pose", token)
			if _hover_tweens.has(id) and _hover_tweens[id].is_valid(): _hover_tweens[id].kill()
			var tween: Tween = create_tween().set_parallel(true)
			_hover_tweens[id] = tween
			tween.tween_property(card, "position", target.position, motion.hover_seconds).set_trans(motion.tween_transition()).set_ease(Tween.EASE_OUT)
			tween.tween_property(card, "rotation", target.rotation, motion.hover_seconds)
			tween.finished.connect(func():
				if _detail_key == "hand:" + id and _rules_detail.visible: _update_detail(_detail_key))
		card.z_index = int(geometry.layout.layers.hand_card) + index
		card.display_data.highlighted = id == _hover_id or _selected.has(id)
		card.queue_redraw()


func _hide_detail() -> void:
	_detail_key = ""
	_detail_started_msec = 0
	if is_instance_valid(_detail): _detail.hide()
	if is_instance_valid(_rules_detail): _rules_detail.hide()
	_detail_geometry.clear()


func _update_detail(key: String) -> void:
	if not key.begins_with("unit:") and not key.begins_with("hand:"):
		_hide_detail()
		return
	var id: String = key.get_slice(":", 1)
	if not _state.units.has(id):
		_hide_detail()
		return
	if _state.phase == "mulligan":
		_hide_detail()
		return
	var data: Dictionary = Presenter.unit_data(_state, id, _actions, text, _selected)
	_rules_text.text = str(data.name) + "\n" + ("指令" if data.get("card_type", "unit") == "order" else str(data.type_name))
	if not str(data.get("detail_text", "")).is_empty(): _rules_text.text += "\n\n" + str(data.detail_text)
	if data.get("suppressed", false): _rules_text.text += "\n\n压制：直到该单位拥有者的下个回合结束，不能主动移动或攻击；原有反击与被动保护仍生效。"
	_rules_text.add_theme_font_size_override("font_size", _layout.body_font)
	var padding: float = float(geometry.layout.detail_padding) * float(_layout.art_scale)
	var width: float = float(_layout.rects.detail_rules.size.x)
	var text_size: Vector2 = display_profile.visual_theme.surface.font.get_multiline_string_size(_rules_text.text, HORIZONTAL_ALIGNMENT_LEFT, width - padding * 2.0, _layout.body_font, -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
	var panel_size: Vector2 = _layout.rects.detail_rules.size
	panel_size.y = minf(maxf(panel_size.y, text_size.y + padding * 2.0), size.y - padding * 2.0)
	var detail_geometry: Dictionary = Layout.detail_geometry(_layout, _controls[key].screen_rect(), panel_size, true, _fixed_ui_rects())
	_detail_geometry = detail_geometry.duplicate(true)
	_detail_geometry["text_height"] = text_size.y
	_detail_geometry["padding"] = padding
	_detail.configure(data, "full", display_profile, self.geometry.template("full"))
	_detail.apply_pose(detail_geometry.card)
	_detail.show()
	_set_rect(_rules_detail, detail_geometry.rules)
	_rules_text.position = Vector2.ONE * padding
	_rules_text.size = _rules_detail.size - Vector2.ONE * padding * 2.0
	_rules_detail.show()


func detail_snapshot() -> Dictionary:
	var result: Dictionary = _detail_geometry.duplicate(true)
	result["visible"] = _rules_detail.visible
	result["rules_rect"] = _rules_detail.get_global_rect() if _rules_detail.visible else Rect2()
	result["card_rect"] = _detail.screen_rect() if _detail.visible else Rect2()
	result["font_size"] = _layout.body_font
	result["text"] = _rules_text.text
	return result


func _fixed_ui_rects() -> Array[Rect2]:
	var result: Array[Rect2] = []
	for key in ["cp_player", "cp_enemy"]:
		if _widgets[key].is_visible_in_tree(): result.append(_widgets[key].get_global_rect())
	for key in ["end_turn", "settings", "mulligan_confirm"]:
		if _controls[key].is_visible_in_tree(): result.append(_controls[key].get_global_rect())
	for key in ["phase", "turn"]:
		if _labels[key].is_visible_in_tree(): result.append(_labels[key].get_global_rect())
	return result


func _safe_card_point(key: String) -> Vector2:
	var card: Control = _controls[key]
	var hand: bool = key.begins_with("hand:")
	var id: String = key.get_slice(":", 1)
	var transform: Transform2D = _pose_transform(_hand_poses[id]) if hand else card.get_global_transform()
	var future: Transform2D = _pose_transform(_hover_pose(id)) if hand else transform
	var bounds: Rect2 = _layout.viewport_rect.grow(-float(geometry.layout.popup_margin) * float(_layout.art_scale))
	for exposed in [true, false]:
		for fy in [0.2, 0.35, 0.1, 0.45, 0.5, 0.65, 0.78, 0.88, 0.04]:
			for fx in [0.12, 0.28, 0.5, 0.72, 0.88, 0.04, 0.96]:
				var point: Vector2 = transform * Vector2(card.size.x * fx, card.size.y * fy)
				if not bounds.has_point(point): continue
				if hand and not Rect2(Vector2.ZERO, card.size).has_point(future.affine_inverse() * point): continue
				if pick_source(point) == key and (not exposed or _card_point_visible(key, point)): return point
	return card.screen_rect().intersection(bounds).get_center() if is_modal_open() else Vector2(-1, -1)


func _card_point_visible(key: String, point: Vector2) -> bool:
	var card: Control = _controls[key]
	for other_key in _controls:
		if other_key == key: continue
		if not str(other_key).begins_with("hand:") and not str(other_key).begins_with("unit:"): continue
		var other: Control = _controls[other_key]
		if other.z_index > card.z_index and other.contains_point(point): return false
	return true


func snapshot_controls() -> Dictionary:
	var result: Dictionary = {}
	for key in _controls:
		var control: Control = _controls[key]
		if not control.is_visible_in_tree(): continue
		var card: bool = str(key).begins_with("hand:") or str(key).begins_with("unit:")
		var headquarters: bool = str(key).begins_with("hq:")
		var rect: Rect2 = control.screen_rect() if card or headquarters else control.get_global_rect()
		var draggable: bool = card and not is_modal_open() and _interaction.get("state", "idle") == "idle" and _player_turn() and _source_legal(str(key).get_slice(":", 1))
		var drop: bool = not is_modal_open() and _interaction.get("state", "idle") in ["dragging", "choosing_deploy", "choosing_choice"] and _interaction.get("legal_target_keys", []).has(key)
		var enabled: bool = draggable or drop
		if control is BaseButton: enabled = not control.disabled
		elif str(key).begins_with("hand:") and _state.phase == "mulligan": enabled = not _state.sides.player.mulligan_done and not is_modal_open()
		var point: Vector2 = _safe_card_point(str(key)) if card else _gap_points.get(key, rect.get_center())
		result[key] = {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y, "enabled": enabled, "draggable": draggable, "drop_enabled": drop, "hit_point": {"x": point.x, "y": point.y}, "rotation": control.rotation}
	return result


func _update_targets() -> void:
	var dragging: bool = _interaction.get("state", "idle") in ["dragging", "choosing_deploy", "choosing_choice"] and not is_modal_open()
	var legal: Array = _interaction.get("legal_target_keys", [])
	_overlay.regions = []
	for key in _effect_regions:
		if dragging and legal.has(key):
			_overlay.regions.append({"rect": _effect_regions[key].get_global_rect(), "caption": "松开施放" if key == "cast:player" else "选择此阵线"})
	_overlay.active = dragging
	_overlay.hint = "选择效果目标 · 右键或 Esc 取消" if _interaction.get("state", "") == "choosing_deploy" else ("选择效果目标" if _interaction.get("state", "") == "choosing_choice" else "")
	for key in _controls:
		if _is_gap(str(key)): continue
		elif str(key).begins_with("unit:"):
			var id: String = str(key).get_slice(":", 1)
			var card: Control = _cards[id]
			card.display_data.highlighted = dragging and legal.has(key)
			card.queue_redraw()
		elif str(key).begins_with("hq:"):
			_controls[key].display_data.highlighted = dragging and legal.has(key)
			_controls[key].queue_redraw()
	_overlay.queue_redraw()


func show_drag(interaction: Dictionary, cursor: Vector2, source: Dictionary) -> void:
	if is_modal_open(): return
	_interaction = interaction
	_hide_detail()
	var target_key: String = str(interaction.hover_target_key)
	var legal: bool = interaction.legal_target_keys.has(target_key)
	_overlay.active = true
	var choosing: bool = str(interaction.state) in ["choosing_deploy", "choosing_choice"]
	var source_data: Dictionary = _state.units.get(str(interaction.source_id), {})
	_overlay.arrow = interaction.source_zone != "hand" or choosing or source_data.get("card_type", "unit") == "order"
	_overlay.legal = legal
	_overlay.start = source.position + source.size * 0.5
	_overlay.cursor = cursor
	var provisional: Dictionary = {}
	if interaction.state == "choosing_deploy":
		var index: int = int(interaction.candidate_actions[0].insert_index)
		var reserved_key: String = "support:player:%d" % index
		_preview_insertion(reserved_key)
		provisional = Layout.row_pose(_layout, "player", "field", index, _state.sides.player.support_ids.size() + 2)
		_overlay.start = provisional.position + provisional.size * 0.5
	else: _preview_insertion(target_key if legal and _is_gap(target_key) else "")
	_drag_preview.visible = interaction.source_zone == "hand" and not choosing and source_data.get("card_type", "unit") != "order"
	var id: String = str(interaction.source_id)
	if _cards.has(id):
		_cards[id].modulate.a = float(display_profile.visual_theme.surface.strokes.drag_source_alpha) if interaction.source_zone == "hand" else 1.0
		var data: Dictionary = Presenter.unit_data(_state, id, _actions, text, _selected)
		data.highlighted = true
		_drag_preview.configure(data, "full" if interaction.source_zone == "hand" else "field", display_profile, geometry.template("full" if interaction.source_zone == "hand" else "field"))
		var preview_size: Vector2 = _layout.full_size if interaction.source_zone == "hand" else _layout.field_size
		_drag_preview.apply_pose({"position": cursor - preview_size * 0.5, "size": preview_size, "rotation": 0.0, "scale": Vector2.ONE})
		if not provisional.is_empty():
			_drag_preview.configure(data, "field", display_profile, geometry.template("field"))
			_drag_preview.apply_pose(provisional)
			_drag_preview.show()
	_update_targets()


func drag_pose() -> Dictionary:
	return {"attack": _overlay.arrow, "pose": _drag_preview.pose(), "mode": _drag_preview.mode, "all_poses": capture_poses()}


func clear_drag() -> void:
	for key in _row_base:
		if _controls.has(key): _row_return_from[key] = _controls[key].pose()
	_stop_row_tweens()
	_row_base.clear()
	_row_preview_key = ""
	_hover_id = ""
	if not is_instance_valid(_overlay): return
	_overlay.active = false
	_overlay.queue_redraw()
	_drag_preview.hide()
	_hide_detail()
	for card in _cards.values(): card.modulate = Color.WHITE


func stop_presentation() -> void:
	_hide_detail()
	_player.cancel()
	if _presentation_run != null and not _presentation_run.done: _presentation_run.cancel()
	_stop_hover()


func _stop_hover() -> void:
	for tween in _hover_tweens.values():
		if tween.is_valid(): tween.kill()
	_hover_tweens.clear()


func animate_cancel(id: String, drag: Dictionary) -> RefCounted:
	stop_presentation()
	var run := PresentationRun.new()
	_presentation_run = run
	var key: String = ("hand:" if _state.units[id].zone == "hand" else "unit:") + id
	if drag.get("attack", true) or not _controls.has(key):
		# The source never moved, but the neighboring row is still returning.
		var duration: float = float(motion.insertion_seconds)
		run.update_stage("cancel_return", 0.0, 0.0, duration)
		_tween = create_tween()
		_tween.tween_method(func(t: float): run.update_stage("cancel_return", t, duration * t, duration), 0.0, 1.0, duration)
		run.bind_cancel(func():
			if _tween != null and _tween.is_valid(): _tween.kill()
			run.complete(true))
		_tween.finished.connect(func(): run.complete())
		return run
	var target: Dictionary = _controls[key].pose()
	var ghost: Control = presentation_create_card(key, _state, drag.pose)
	presentation_hide_card(key)
	_tween = create_tween().set_parallel(true)
	var duration: float = float(motion.cancel_seconds)
	run.update_stage("cancel_return", 0.0, 0.0, duration)
	_tween.tween_property(ghost, "position", target.position, duration).set_trans(motion.tween_transition()).set_ease(Tween.EASE_OUT)
	_tween.tween_property(ghost, "rotation", target.rotation, duration)
	_tween.tween_property(ghost, "size", target.size, duration)
	_tween.tween_method(func(t: float): run.update_stage("cancel_return", t, duration * t, duration), 0.0, 1.0, duration)
	var cleanup: Callable = func(cancelled: bool):
		if _tween != null and _tween.is_valid(): _tween.kill()
		if is_instance_valid(ghost):
			ghost.hide()
			ghost.queue_free()
		presentation_restore()
		run.complete(cancelled)
	run.bind_cancel(func(): cleanup.call(true))
	_tween.finished.connect(func(): cleanup.call(false))
	return run


func animate_action(action: Dictionary, events: Array, before: Dictionary, old_poses: Dictionary) -> RefCounted:
	stop_presentation()
	_presentation_run = _player.play(self, action, events, before, _state, old_poses, capture_poses(), motion)
	return _presentation_run


func presentation_create_card(key: String, state: Dictionary, value: Dictionary) -> Control:
	var ghost := CardView.new()
	presentation_update_card(ghost, key, state)
	if value.has("display_data"): ghost.display_data = value.display_data.duplicate(true)
	ghost.apply_pose(value)
	ghost.z_index = int(geometry.layout.layers.ghost)
	add_child(ghost)
	return ghost


func presentation_update_card(card: Control, key: String, state: Dictionary) -> void:
	var mode: String = "field"
	var data: Dictionary = {}
	if key.begins_with("hq:"):
		mode = "hq"
		data = Presenter.hq_data(state, key.get_slice(":", 1), text)
	elif key.begins_with("back:"): mode = "back"
	else:
		mode = "full" if key.begins_with("hand:") else "field"
		data = Presenter.unit_data(state, key.get_slice(":", 1), _actions, text)
	card.configure(data, mode, display_profile, geometry.template(mode))


func presentation_hide_card(key: String) -> void:
	_presentation_hidden[key] = true
	if key.begins_with("back:ai:"):
		var index: int = int(key.get_slice(":", 2))
		if index < _back_cards.size(): _back_cards[index].modulate.a = 0.0
	elif _controls.has(key): _controls[key].modulate.a = 0.0


func presentation_restore() -> void:
	_presentation_hidden.clear()
	if not _state.is_empty(): presentation_set_status(_state)
	for card in _back_cards: card.modulate = Color.WHITE
	for control in _controls.values():
		if is_instance_valid(control): control.modulate = Color.WHITE
	presentation_set_frontline_y(_frontline_y())


func presentation_snapshot() -> Dictionary:
	return {
		"geometry_id": geometry.geometry_id, "geometry_fingerprint": Fingerprint.of(geometry.spec()),
		"motion_id": motion.motion_id, "motion_fingerprint": Fingerprint.of(motion.spec()),
		"profile_id": profile.profile_id, "render_mode": "geometry_debug" if geometry_debug else "material",
		"background_texture": display_profile.visual_theme.background_texture.resource_path if display_profile.visual_theme.background_texture != null else "",
		"material_fingerprint": Fingerprint.of(profile),
		"appearance_fingerprint": Fingerprint.of(display_profile),
		"motion": motion.spec(), "viewport": {"width": size.x, "height": size.y},
		"frontline_y": _board.frontline_y,
		"playback": _presentation_run.snapshot() if _presentation_run != null else {"done": true, "cancelled": false, "stage": "idle", "progress": 1.0, "elapsed": 0.0, "duration": 0.0},
	}


func reset_presentation() -> void:
	stop_presentation()
	clear_drag()
	_stop_row_tweens()
	_state = {}
	_actions = []
	_interaction = {}
	_selected = []
	_presentation_status = {}
	_presentation_hidden.clear()
	_presentation_run = null
	_row_return_from.clear()
	_hand_poses.clear()
	_gap_points.clear()
	for card in _cards.values(): card.hide()
	for card in _back_cards: card.hide()
	for gap in _gap_nodes.values(): gap.hide()
	for key in _controls.keys():
		if str(key).begins_with("hand:") or str(key).begins_with("unit:") or _is_gap(str(key)): _controls.erase(key)
		else: _controls[key].hide()
	for widget in _widgets.values(): widget.hide()
	for label in _labels.values(): label.hide()
	if is_instance_valid(_modal_blocker):
		_menu_open = false
		_sync_modal()
