extends Control
## One presentation component for hands, field cards, hover, drag and animation.
## Every visible value and layout is injected; this file has no game-rule dependency.

const Widgets = preload("res://scripts/art/art_widgets.gd")

var display_data: Dictionary = {}
var mode: String = ""
var profile: Resource
var _definition: Resource
var _text_geometry: Dictionary = {}


func configure(data: Dictionary, presentation_mode: String, art_profile: Resource, template_definition: Resource) -> void:
	display_data = data.duplicate(true)
	mode = presentation_mode
	profile = art_profile
	_definition = template_definition
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var definition: Resource = _template()
	if definition != null:
		size = definition.size
		pivot_offset = size * 0.5
	queue_redraw()


func _template() -> Resource:
	return _definition


func _draw() -> void:
	_text_geometry.clear()
	Widgets.clear_diagnostics(self)
	var definition: Resource = _template()
	if definition == null or definition.size.x <= 0.0 or definition.size.y <= 0.0:
		Widgets.record_missing(self, "template", mode)
		return
	if profile == null or profile.visual_theme == null or profile.visual_theme.renderer == null:
		Widgets.record_missing(self, "appearance", "renderer")
		return
	var visual_theme: Resource = profile.visual_theme
	draw_set_transform(Vector2.ZERO, 0.0, size / definition.size)
	visual_theme.renderer.draw_card_background(self, visual_theme, Rect2(Vector2.ZERO, definition.size))
	match mode:
		"full": _draw_full(definition, visual_theme)
		"field": _draw_field(definition, visual_theme)
		"hq": _draw_hq(definition, visual_theme)
		"back": Widgets.draw_back(self, visual_theme, definition)
	if display_data.get("highlighted", false):
		Widgets.draw_plate(self, visual_theme, "highlight_frame", Rect2(Vector2.ZERO, definition.size))
	draw_set_transform(Vector2.ZERO)


func _draw_full(definition: Resource, visual_theme: Resource) -> void:
	Widgets.draw_plate(self, visual_theme, "full_face", Rect2(Vector2.ZERO, definition.size))
	Widgets.draw_plate(self, visual_theme, _faction_style("header"), _slot("header"))
	Widgets.draw_plate(self, visual_theme, "deploy_box", _slot("deploy_box"))
	_text("deploy_cost", str(display_data.get("deploy_cost", 0)), definition, visual_theme, "gold" if display_data.get("ready", false) else "muted", true)
	_text("deploy_unit", str(display_data.get("command_unit", "")), definition, visual_theme, "muted", true)
	_text("action_cost", str(display_data.get("action_cost", 0)), definition, visual_theme, "muted", true)
	_text("name", str(display_data.get("name", "")), definition, visual_theme, "text", false, display_data.get("wrap_name", false))
	visual_theme.renderer.draw_artwork(self, visual_theme, profile.artworks, display_data, mode, definition.artwork_rect)
	for box in ["attack_box", "type_icon_box", "health_box"]:
		Widgets.draw_plate(self, visual_theme, "full_stats", _slot(box))
	_text("attack", str(display_data.get("attack", 0)), definition, visual_theme, "text", true)
	_text("health", str(display_data.get("hp", 0)), definition, visual_theme, _health_color(), true)
	_text("type_name", str(display_data.get("type_name", "")), definition, visual_theme, "ink")
	_text("rule_text", str(display_data.get("rule_text", "")), definition, visual_theme, "ink", false, true)
	Widgets.draw_frame(self, visual_theme, definition)


func _draw_field(definition: Resource, visual_theme: Resource) -> void:
	Widgets.draw_plate(self, visual_theme, "field_face", definition.inner_rect)
	visual_theme.renderer.draw_artwork(self, visual_theme, profile.artworks, display_data, mode, definition.artwork_rect)
	Widgets.draw_plate(self, visual_theme, _faction_style("header"), _slot("banner"))
	Widgets.draw_plate(self, visual_theme, "operation_box", _slot("action_box"))
	_text("action_cost", str(display_data.get("action_cost", 0)), definition, visual_theme, "gold" if display_data.get("ready", false) else "muted", true)
	_text("name", str(display_data.get("name", "")), definition, visual_theme, "text")
	Widgets.draw_plate(self, visual_theme, _faction_style("faction"), _slot("faction"))
	Widgets.draw_plate(self, visual_theme, "field_number", _slot("attack_box"))
	Widgets.draw_plate(self, visual_theme, "field_number", _slot("health_box"))
	Widgets.draw_plate(self, visual_theme, "type_icon_box", _slot("type_icon_box"))
	_text("attack", str(display_data.get("attack", 0)), definition, visual_theme, "text", true)
	_text("health", str(display_data.get("hp", 0)), definition, visual_theme, _health_color(), true)
	_text("type_name", str(display_data.get("type_name", "")), definition, visual_theme, "text")
	Widgets.draw_frame(self, visual_theme, definition)


func _draw_hq(definition: Resource, visual_theme: Resource) -> void:
	Widgets.draw_plate(self, visual_theme, "hq_face", definition.inner_rect)
	visual_theme.renderer.draw_artwork(self, visual_theme, profile.artworks, display_data, mode, definition.artwork_rect)
	_text("name", str(display_data.get("name", "")), definition, visual_theme, "ink")
	Widgets.draw_plate(self, visual_theme, "hq_health", _slot("health_box"))
	_text("health", str(display_data.get("hp", 0)), definition, visual_theme, _health_color(), true)
	Widgets.draw_frame(self, visual_theme, definition)


func _text(key: String, value: String, definition: Resource, visual_theme: Resource, color_role: String, numeric: bool = false, wrap: bool = false) -> void:
	_text_geometry[key] = Widgets.draw_fitted_text(self, visual_theme, definition, key, value, color_role, numeric, wrap)


func _slot(key: String) -> Rect2:
	var definition: Resource = _template()
	return Widgets.slot(definition, key) if definition != null else Rect2()


func _faction_style(prefix: String) -> String:
	return prefix + ("_enemy" if display_data.get("enemy", false) else "_player")


func _health_color() -> String:
	return "hurt" if int(display_data.get("hp", 0)) < int(display_data.get("max_hp", display_data.get("hp", 0))) else "text"


func contains_point(global_point: Vector2) -> bool:
	return is_visible_in_tree() and Rect2(Vector2.ZERO, size).has_point(get_global_transform().affine_inverse() * global_point)


func screen_rect() -> Rect2:
	return Widgets.transformed_rect(Rect2(Vector2.ZERO, size), get_global_transform())


func template_spec() -> Dictionary:
	var definition: Resource = _template()
	return definition.spec().duplicate(true) if definition != null else {}


func geometry_snapshot() -> Dictionary:
	return {"mode": mode, "rect": screen_rect(), "rotation": rotation, "template": template_spec(), "text": _text_geometry.duplicate(true), "diagnostics": Widgets.diagnostics(self)}


func pose() -> Dictionary:
	return {"position": position, "size": size, "rotation": rotation, "scale": scale}


func apply_pose(value: Dictionary) -> void:
	position = value.get("position", position)
	size = value.get("size", size)
	pivot_offset = size * 0.5
	rotation = value.get("rotation", rotation)
	scale = value.get("scale", scale)
	queue_redraw()
