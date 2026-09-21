extends Control
## The caller positions the public frontline; appearance only paints it.
const Widgets = preload("res://scripts/art/art_widgets.gd")
var profile: Resource
var geometry: Resource
var frontline_y: float:
	set(value):
		frontline_y = value
		queue_redraw()


func configure(art_profile: Resource, presentation_geometry: Resource) -> void:
	profile = art_profile
	geometry = presentation_geometry
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if geometry != null:
		size = geometry.layout.stage_size
	queue_redraw()


func _draw() -> void:
	Widgets.clear_diagnostics(self)
	if profile == null or profile.visual_theme == null or geometry == null:
		return
	var visual_theme: Resource = profile.visual_theme
	if visual_theme.renderer == null:
		Widgets.record_missing(self, "appearance", "renderer")
		return
	visual_theme.renderer.draw_background(self, visual_theme, Rect2(Vector2.ZERO, size))
	var span: Vector2 = geometry.layout.frontline_span
	visual_theme.renderer.draw_frontline(self, visual_theme, Vector2(span.x, frontline_y), Vector2(span.y, frontline_y))


func geometry_snapshot() -> Dictionary:
	return {"size": size, "frontline_y": frontline_y, "diagnostics": Widgets.diagnostics(self)}
