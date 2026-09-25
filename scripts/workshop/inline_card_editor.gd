extends LineEdit
## Native text editing with the exact same glyph layout as the card renderer.
const Widgets = preload("res://scripts/art/art_widgets.gd")

var _visual_theme: Resource
var _definition: Resource
var _key := ""
var _numeric := false
var _wrap := false
var _canvas: Control
var _selecting := false
var _anchor := 0
var _last_paint := ""

func _ready() -> void:
	# LineEdit keeps keyboard, clipboard, selection and operating-system IME state.
	# Its own glyphs and decorations are transparent; the child draws card glyphs.
	for role in ["normal", "focus", "read_only"]:
		add_theme_stylebox_override(role, StyleBoxEmpty.new())
	for role in ["font_color", "font_selected_color", "font_uneditable_color", "font_placeholder_color", "font_outline_color", "caret_color", "selection_color"]:
		add_theme_color_override(role, Color.TRANSPARENT)
	add_theme_constant_override("outline_size", 0)
	add_theme_constant_override("minimum_character_width", 0)
	add_theme_font_size_override("font_size", 1)
	clear_button_enabled = false
	clip_contents = false
	select_all_on_focus = false
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	_canvas.mouse_default_cursor_shape = Control.CURSOR_IBEAM
	add_child(_canvas)
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_paint)
	_canvas.gui_input.connect(_mouse_input)
	focus_exited.connect(func(): _selecting = false)
	# LineEdit updates the candidate anchor during its native draw notification.
	# Restore our wrapped/scaled caret anchor after that drawing has completed.
	RenderingServer.frame_post_draw.connect(_position_ime)

func configure(visual_theme: Resource, definition: Resource, key: String, numeric: bool = false, wrap: bool = false) -> void:
	_visual_theme = visual_theme
	_definition = definition
	_key = key
	_numeric = numeric
	_wrap = wrap
	_selecting = false
	_last_paint = ""
	if _canvas != null: _canvas.queue_redraw()

func is_composing() -> bool:
	return has_focus() and has_ime_text()

func _display_text() -> String:
	if not is_composing(): return text
	return text.left(caret_column) + DisplayServer.ime_get_text() + text.substr(caret_column)

func layout_snapshot() -> Dictionary:
	if _definition == null: return {}
	return Widgets.fitted_text_layout(_visual_theme, _definition, _key, _display_text(), _numeric, _wrap)

func _process(_delta: float) -> void:
	if not is_visible_in_tree() or _canvas == null or _definition == null: return
	var selection_start := get_selection_from_column() if has_selection() else -1
	var selection_end := get_selection_to_column() if has_selection() else -1
	var stamp := "%s|%s|%s|%s|%s|%s" % [_display_text(), caret_column, selection_start, selection_end, has_focus(), DisplayServer.ime_get_selection() if is_composing() else Vector2i.ZERO]
	if stamp != _last_paint:
		_last_paint = stamp
		_canvas.queue_redraw()

func _position_ime() -> void:
	if is_visible_in_tree() and has_focus() and DisplayServer.has_feature(DisplayServer.FEATURE_IME):
		var layout := layout_snapshot()
		if layout.has("font"):
			var caret := _caret_point(layout, _display_caret())
			var local := caret - Vector2(layout.slot.position) + Vector2(0, layout.font.get_descent(layout.font_size))
			DisplayServer.window_set_ime_position(get_screen_transform() * local, get_window().get_window_id())

func _display_caret() -> int:
	if not is_composing(): return caret_column
	var selection := DisplayServer.ime_get_selection()
	return caret_column + selection.x + selection.y

func _line_for_column(layout: Dictionary, column: int) -> int:
	for index in range(layout.lines.size() - 1, -1, -1):
		if column >= int(layout.indexes[index]): return index
	return 0

func _width(layout: Dictionary, value: String) -> float:
	return layout.font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, layout.font_size).x

func _caret_point(layout: Dictionary, column: int) -> Vector2:
	var index := _line_for_column(layout, column)
	var line: String = layout.lines[index]
	var offset := clampi(column - int(layout.indexes[index]), 0, line.length())
	return Vector2(layout.baselines[index]) + Vector2(_width(layout, line.left(offset)), 0)

func _paint() -> void:
	var layout := layout_snapshot()
	if not layout.has("font"): return
	var font: Font = layout.font
	var font_size: int = layout.font_size
	var origin: Vector2 = layout.slot.position
	var ink: Color = _visual_theme.color("card_muted" if _key in ["deploy_cost", "action_cost"] else "card_text")
	var accent: Color = _visual_theme.color("control_gold")
	var selection_ink := Color(accent, 0.28)
	var ascent := font.get_ascent(font_size)
	for index in range(layout.lines.size()):
		var line: String = layout.lines[index]
		var baseline: Vector2 = Vector2(layout.baselines[index]) - origin
		var start: int = layout.indexes[index]
		if has_focus() and has_selection() and not is_composing():
			var first := clampi(get_selection_from_column() - start, 0, line.length())
			var last := clampi(get_selection_to_column() - start, 0, line.length())
			if last > first:
				var left := _width(layout, line.left(first))
				var right := _width(layout, line.left(last))
				_canvas.draw_rect(Rect2(baseline + Vector2(left, -ascent), Vector2(right - left, layout.line_height)), selection_ink)
		_canvas.draw_string(font, baseline, line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ink)
		if is_composing():
			var first := clampi(caret_column - start, 0, line.length())
			var last := clampi(caret_column + DisplayServer.ime_get_text().length() - start, 0, line.length())
			if last > first:
				_canvas.draw_line(baseline + Vector2(_width(layout, line.left(first)), 1), baseline + Vector2(_width(layout, line.left(last)), 1), accent, 0.5, true)
	if has_focus():
		var caret := _caret_point(layout, _display_caret()) - origin
		_canvas.draw_line(caret - Vector2(0, ascent), caret + Vector2(0, font.get_descent(font_size)), accent, 0.5, true)

func _column_at(point: Vector2) -> int:
	var layout := layout_snapshot()
	if not layout.has("font"): return 0
	var target := point + Vector2(layout.slot.position)
	var best_line := 0
	var distance := INF
	for index in range(layout.lines.size()):
		var center_y: float = layout.baselines[index].y - layout.font.get_ascent(layout.font_size) + layout.line_height * 0.5
		if absf(target.y - center_y) < distance:
			distance = absf(target.y - center_y)
			best_line = index
	var line: String = layout.lines[best_line]
	var x: float = target.x - layout.baselines[best_line].x
	var previous := 0.0
	for column in range(1, line.length() + 1):
		var edge := _width(layout, line.left(column))
		if x < (previous + edge) * 0.5: return int(layout.indexes[best_line]) + column - 1
		previous = edge
	return int(layout.indexes[best_line]) + line.length()

func _mouse_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if is_composing(): apply_ime()
			grab_focus()
			edit()
			var column := _column_at(event.position)
			_anchor = caret_column if event.shift_pressed else column
			caret_column = column
			if event.double_click:
				select_all()
				_selecting = false
			else:
				deselect()
				if event.shift_pressed: select(mini(_anchor, column), maxi(_anchor, column))
				_selecting = true
		else:
			_selecting = false
		_canvas.accept_event()
		_canvas.queue_redraw()
	elif event is InputEventMouseMotion and _selecting:
		var column := _column_at(event.position)
		caret_column = column
		select(mini(_anchor, column), maxi(_anchor, column))
		_canvas.accept_event()
		_canvas.queue_redraw()
