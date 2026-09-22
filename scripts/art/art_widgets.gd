extends Control
## Presentation widgets receive geometry, appearance and visible text independently.

var display_data: Dictionary = {}
var role: String = ""
var profile: Resource
var geometry: Resource
var _text_geometry: Dictionary = {}


func configure(data: Dictionary, widget_role: String, art_profile: Resource, presentation_geometry: Resource) -> void:
	display_data = data.duplicate(true)
	role = widget_role
	profile = art_profile
	geometry = presentation_geometry
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var definition: Resource = _template()
	if definition != null:
		size = definition.size
		pivot_offset = size * 0.5
	queue_redraw()


func _template() -> Resource:
	if geometry == null:
		return null
	return geometry.template(role)


func _draw() -> void:
	_text_geometry.clear()
	clear_diagnostics(self)
	var definition: Resource = _template()
	if definition == null:
		record_missing(self, "template", role)
		return
	if profile == null or profile.visual_theme == null or profile.visual_theme.renderer == null:
		record_missing(self, "appearance", "renderer")
		return
	var visual_theme: Resource = profile.visual_theme
	draw_set_transform(Vector2.ZERO, 0.0, size / definition.size)
	match role:
		"cp": _draw_cp(definition, visual_theme)
		"end_turn": _draw_end_turn(definition, visual_theme)
		"deck": _draw_deck(definition, visual_theme)
		"settings":
			draw_plate(self, visual_theme, "settings", Rect2(Vector2.ZERO, definition.size))
			_text("text", str(display_data.get("text", "")), definition, visual_theme, "text")
	draw_set_transform(Vector2.ZERO)


func _draw_cp(definition: Resource, visual_theme: Resource) -> void:
	draw_plate(self, visual_theme, "cp_face", Rect2(Vector2.ZERO, definition.size))
	draw_plate(self, visual_theme, "cp_well", slot(definition, "well"))
	draw_plate(self, visual_theme, "cp_divider", slot(definition, "capacity_divider"))
	_text("available", str(display_data.get("available", 0)), definition, visual_theme, "gold", true)
	_text("unit", str(display_data.get("command_unit", "")), definition, visual_theme, "muted", true)
	_text("capacity", str(display_data.get("capacity", 0)), definition, visual_theme, "text", true)


func _draw_end_turn(definition: Resource, visual_theme: Resource) -> void:
	var state_style: String = "end_turn_face"
	if display_data.get("pressed", false):
		state_style += "_pressed"
	elif display_data.get("hovered", false):
		state_style += "_hover"
	draw_plate(self, visual_theme, state_style, Rect2(Vector2.ZERO, definition.size))
	draw_plate(self, visual_theme, "end_turn_well", slot(definition, "well"))
	_text("text", str(display_data.get("text", "")), definition, visual_theme, "muted" if display_data.get("disabled", false) else "text")


func _draw_deck(definition: Resource, visual_theme: Resource) -> void:
	draw_plate(self, visual_theme, "deck_leaf_far", slot(definition, "leaf_far"))
	draw_plate(self, visual_theme, "deck_leaf_near", slot(definition, "leaf_near"))
	var back_template: Resource = geometry.template("back")
	if back_template == null:
		return
	var face: Rect2 = slot(definition, "face")
	var ratio: Vector2 = size / definition.size
	draw_set_transform(face.position * ratio, 0.0, face.size / back_template.size * ratio)
	draw_back(self, visual_theme, back_template)
	draw_set_transform(Vector2.ZERO, 0.0, ratio)


func _text(key: String, value: String, definition: Resource, visual_theme: Resource, color_role: String, numeric: bool = false) -> void:
	_text_geometry[key] = draw_fitted_text(self, visual_theme, definition, key, value, color_role, numeric)


func contains_point(global_point: Vector2) -> bool:
	return is_visible_in_tree() and Rect2(Vector2.ZERO, size).has_point(get_global_transform().affine_inverse() * global_point)


func screen_rect() -> Rect2:
	return transformed_rect(Rect2(Vector2.ZERO, size), get_global_transform())


func geometry_snapshot() -> Dictionary:
	var definition: Resource = _template()
	return {"role": role, "rect": screen_rect(), "template": definition.spec() if definition != null else {}, "text": _text_geometry.duplicate(true), "diagnostics": diagnostics(self)}


static func slot(definition: Resource, key: String) -> Rect2:
	return definition.slots.get(key, Rect2())


static func draw_plate(canvas: CanvasItem, visual_theme: Resource, style_role: String, rect: Rect2) -> void:
	visual_theme.renderer.draw_plate(canvas, visual_theme, style_role, rect)


static func draw_frame(canvas: CanvasItem, visual_theme: Resource, definition: Resource) -> void:
	draw_plate(canvas, visual_theme, "card_frame", Rect2(Vector2.ZERO, definition.size))


static func draw_back(canvas: CanvasItem, visual_theme: Resource, definition: Resource) -> void:
	draw_plate(canvas, visual_theme, "back_face", Rect2(Vector2.ZERO, definition.size))
	draw_plate(canvas, visual_theme, "back_inner", slot(definition, "inner"))


static func transformed_rect(rect: Rect2, transform: Transform2D) -> Rect2:
	var result := Rect2(transform * rect.position, Vector2.ZERO)
	for point in [Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		result = result.expand(transform * point)
	return result


static func clear_diagnostics(canvas: CanvasItem) -> void:
	canvas.set_meta("_art_missing_roles", [])


static func record_missing(canvas: CanvasItem, category: String, key: String) -> void:
	var missing: Array = canvas.get_meta("_art_missing_roles", [])
	var issue: String = category + ":" + key
	if not missing.has(issue):
		missing.append(issue)
	canvas.set_meta("_art_missing_roles", missing)


static func diagnostics(canvas: CanvasItem) -> Array:
	return canvas.get_meta("_art_missing_roles", []).duplicate()


static func theme_color(canvas: CanvasItem, visual_theme: Resource, color_role: String) -> Color:
	if not visual_theme.surface.palette.get(color_role) is Color:
		record_missing(canvas, "color", color_role)
	return visual_theme.color(color_role)


static func draw_fitted_text(canvas: CanvasItem, visual_theme: Resource, definition: Resource, key: String, value: String, color_role: String, numeric: bool = false, wrap: bool = false, alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Dictionary:
	var rect: Rect2 = slot(definition, key)
	var preferred: int = int(definition.font_sizes.get(key, 0))
	var minimum: int = clampi(int(definition.font_sizes.get(key + "_min", preferred)), 1, maxi(1, preferred))
	var font: Font = visual_theme.surface.number_font if numeric else visual_theme.surface.font
	if not value.is_empty():
		if font == null: record_missing(canvas, "font", "number_font" if numeric else "font")
		if not rect.has_area(): record_missing(canvas, "slot", key)
		if preferred <= 0: record_missing(canvas, "font_size", key)
	if font == null or not rect.has_area() or value.is_empty() or preferred <= 0:
		return {"slot": rect, "text": value, "drawn": false}
	var maximum_lines: int = int(definition.font_sizes.rule_lines) if wrap else 1
	var chosen: int = maxi(1, preferred)
	var lines: Array[String] = []
	var fits: bool = false
	while chosen >= maxi(1, minimum):
		if wrap:
			lines = wrap_lines(font, value, chosen, rect.size.x)
		else:
			lines.assign([value])
		fits = lines.size() <= maximum_lines and font.get_height(chosen) * lines.size() <= rect.size.y + 0.01
		for line in lines:
			fits = fits and font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, chosen).x <= rect.size.x + 0.01
		if fits or chosen == maxi(1, minimum):
			break
		chosen -= 1
	var line_height: float = font.get_height(chosen)
	var text_height: float = line_height * lines.size()
	var baseline: float = rect.position.y + (rect.size.y - text_height) * 0.5 + font.get_ascent(chosen)
	var measured := Rect2(Vector2.ZERO, Vector2.ZERO)
	for index in range(lines.size()):
		var width: float = font.get_string_size(lines[index], HORIZONTAL_ALIGNMENT_LEFT, -1, chosen).x
		var align_offset: float = 0.0 if alignment == HORIZONTAL_ALIGNMENT_LEFT else (rect.size.x - width) * (1.0 if alignment == HORIZONTAL_ALIGNMENT_RIGHT else 0.5)
		var line_rect := Rect2(Vector2(rect.position.x + align_offset, baseline - font.get_ascent(chosen)), Vector2(width, line_height))
		measured = line_rect if index == 0 else measured.merge(line_rect)
		canvas.draw_string(font, Vector2(rect.position.x, baseline), lines[index], alignment, rect.size.x, chosen, theme_color(canvas, visual_theme, color_role))
		baseline += line_height
	return {"slot": rect, "glyph_rect": measured, "text": value, "font_size": chosen, "line_count": lines.size(), "fits": fits, "drawn": true}


static func wrap_lines(font: Font, value: String, font_size: int, width: float) -> Array[String]:
	var result: Array[String] = []
	for paragraph in value.split("\n"):
		var line: String = ""
		for character in paragraph:
			var candidate: String = line + character
			if not line.is_empty() and font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > width:
				result.append(line)
				line = character
			else:
				line = candidate
		result.append(line)
	return result
