extends Control
## In-scene confirmation surface with physical-pixel typography and modal focus.
signal confirmed
signal canceled
signal discarded

class FixedPanel extends Control:
	var plate: StyleBox
	func _draw() -> void:
		if plate != null: draw_style_box(plate, Rect2(Vector2.ZERO, size))

class MetalButton extends Button:
	var appearance: Resource
	var caption: Label
	func _ready() -> void:
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			add_theme_stylebox_override(state, StyleBoxEmpty.new())
		mouse_entered.connect(queue_redraw)
		mouse_exited.connect(queue_redraw)
		button_down.connect(queue_redraw)
		button_up.connect(queue_redraw)
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
	func _draw() -> void:
		if appearance == null: return
		var suffix := "_disabled" if disabled else ("_pressed" if is_pressed() else ("_hover" if is_hovered() or has_focus() else ""))
		draw_style_box(appearance.style("end_turn_face" + suffix), Rect2(Vector2.ZERO, size))

var buttons: Dictionary = {}
var _profile: Resource
var _kind := "guard"
var _panel: FixedPanel
var _title: Label
var _body: Label
var _error_label: Label
var _error := ""
var _previous_focus: WeakRef
var _font_pixels: Dictionary = {}

func configure(profile: Resource, kind: String = "guard") -> void:
	_profile = profile
	_kind = kind
	if _panel == null: _build()
	_apply_appearance()
	if is_inside_tree(): _layout()

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	visible = false
	_panel = FixedPanel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)
	_title = _label()
	_body = _label()
	_error_label = _label()
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for key in ["cancel", "discard", "confirm"]:
		var button := MetalButton.new()
		button.focus_mode = Control.FOCUS_ALL
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		button.caption = Label.new()
		button.caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		button.add_child(button.caption)
		button.caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_panel.add_child(button)
		buttons[key] = button
	buttons.cancel.pressed.connect(_cancel)
	buttons.discard.pressed.connect(func(): discarded.emit())
	buttons.confirm.pressed.connect(func(): confirmed.emit())

func _label() -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_panel.add_child(label)
	return label

func _apply_appearance() -> void:
	var appearance: Resource = _profile.visual_theme
	_panel.plate = appearance.style("well")
	_panel.queue_redraw()
	_title.text = "删除卡牌？" if _kind == "delete" else "保存修改？"
	_body.text = "删除这张收藏卡？" if _kind == "delete" else "当前卡牌有未保存修改。"
	buttons.cancel.caption.text = "取消"
	buttons.discard.caption.text = "放弃修改"
	buttons.confirm.caption.text = "删除" if _kind == "delete" else "保存"
	buttons.discard.visible = _kind != "delete"
	for label in [_title, _body, _error_label]:
		label.add_theme_font_override("font", appearance.surface.font)
		label.add_theme_color_override("font_color", appearance.color("control_danger" if label == _error_label else "control_text"))
	for key in buttons:
		var button: MetalButton = buttons[key]
		button.appearance = appearance
		button.caption.add_theme_font_override("font", appearance.surface.font)
		var color_role := "control_text"
		if key == "discard" or (key == "confirm" and _kind == "delete"): color_role = "control_danger"
		elif key == "confirm": color_role = "control_gold"
		button.caption.add_theme_color_override("font_color", appearance.color(color_role))
		button.queue_redraw()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_layout)
	get_window().size_changed.connect(_layout)
	_layout()

func popup_centered() -> void:
	_previous_focus = weakref(get_viewport().gui_get_focus_owner()) if get_viewport().gui_get_focus_owner() != null else null
	_error = ""
	visible = true
	move_to_front()
	_layout()
	buttons.cancel.grab_focus()

func dismiss() -> void:
	hide()
	if _previous_focus != null:
		var old_focus = _previous_focus.get_ref()
		if is_instance_valid(old_focus) and old_focus.is_visible_in_tree(): old_focus.grab_focus()
	_previous_focus = null

func _cancel() -> void:
	dismiss()
	canceled.emit()

func show_error(message: String) -> void:
	_error = message
	_layout()

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree(): return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel()
		get_viewport().set_input_as_handled()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouse: accept_event()

func _draw() -> void:
	if _profile == null: return
	var tint: Color = _profile.visual_theme.color("shadow")
	tint.a = float(_profile.visual_theme.surface.strokes.get("modal_alpha", 0.77))
	draw_rect(Rect2(Vector2.ZERO, size), tint)

func _layout() -> void:
	if not is_inside_tree() or _profile == null or _panel == null: return
	var final_scale := absf(get_viewport().get_final_transform().get_scale().y)
	final_scale = maxf(final_scale, 0.001)
	var physical_scale := clampf(float(get_window().size.y) / 1080.0, 0.82, 1.25)
	var unit := physical_scale / final_scale
	var metrics: Dictionary = _profile.visual_theme.control_skin.metrics
	var title_size := int(ceil(maxf(float(metrics.get("modal_title_size", 28.0)) * physical_scale, float(metrics.get("min_title", 24.0))) / final_scale))
	var text_size := int(ceil(maxf(float(metrics.get("modal_text_size", 22.0)) * physical_scale, float(metrics.get("min_text", 18.0))) / final_scale))
	var button_size := int(ceil(maxf(float(metrics.get("modal_button_size", 22.0)) * physical_scale, float(metrics.get("min_button", 18.0))) / final_scale))
	_font_pixels = {"title": title_size * final_scale, "body": text_size * final_scale, "button": button_size * final_scale}
	_title.add_theme_font_size_override("font_size", title_size)
	_body.add_theme_font_size_override("font_size", text_size)
	_error_label.add_theme_font_size_override("font_size", text_size)
	var width := minf(600.0 * unit, size.x - 32.0 * unit)
	var pad := 36.0 * unit
	var content_width := width - 2.0 * pad
	var title_height := maxf(42.0 * unit, _title.get_theme_font("font").get_height(title_size))
	var body_height := _wrapped_height(_body.text, content_width, text_size)
	var error_height := _wrapped_height(_error, content_width, text_size) if not _error.is_empty() else 0.0
	var button_height := 52.0 * unit
	var height := maxf(260.0 * unit, 2.0 * pad + title_height + 12.0 * unit + body_height + button_height + 28.0 * unit)
	if error_height > 0.0: height += error_height + 12.0 * unit
	_panel.position = (size - Vector2(width, height)) * 0.5
	_panel.size = Vector2(width, height)
	_panel.queue_redraw()
	_title.position = Vector2(pad, pad)
	_title.size = Vector2(content_width, title_height)
	_body.position = Vector2(pad, pad + title_height + 12.0 * unit)
	_body.size = Vector2(content_width, body_height)
	_error_label.visible = not _error.is_empty()
	_error_label.text = _error
	_error_label.position = Vector2(pad, _body.position.y + body_height + 12.0 * unit)
	_error_label.size = Vector2(content_width, error_height)
	var active: Array = [buttons.cancel, buttons.confirm] if _kind == "delete" else [buttons.cancel, buttons.discard, buttons.confirm]
	var gap := 12.0 * unit
	var button_width := (content_width - gap * (active.size() - 1)) / active.size()
	for index in active.size():
		var button: MetalButton = active[index]
		button.position = Vector2(pad + index * (button_width + gap), height - pad - button_height)
		button.size = Vector2(button_width, button_height)
		button.caption.add_theme_font_size_override("font_size", button_size)
		var previous: Control = active[posmod(index - 1, active.size())]
		var next: Control = active[(index + 1) % active.size()]
		button.focus_previous = button.get_path_to(previous)
		button.focus_next = button.get_path_to(next)
		button.focus_neighbor_left = button.focus_previous
		button.focus_neighbor_top = button.focus_previous
		button.focus_neighbor_right = button.focus_next
		button.focus_neighbor_bottom = button.focus_next
	queue_redraw()

func _wrapped_height(value: String, width: float, font_size: int) -> float:
	var paragraph := TextParagraph.new()
	paragraph.add_string(value, _body.get_theme_font("font"), font_size)
	paragraph.width = width
	paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	return maxf(paragraph.get_size().y, _body.get_theme_font("font").get_height(font_size))

func layout_snapshot() -> Dictionary:
	return {"panel_rect": _panel.get_global_rect(), "font_pixels": _font_pixels.duplicate(), "error": _error,
		"title_rect": _title.get_global_rect(), "body_rect": _body.get_global_rect(), "error_rect": _error_label.get_global_rect()}
