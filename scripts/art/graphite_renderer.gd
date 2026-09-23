extends "res://scripts/art/surface_renderer.gd"
## Card materials paint supplied rectangles; other UI keeps the diagnostic-era surface.


func draw_card_background(canvas: CanvasItem, visual_theme: Resource, rect: Rect2) -> void:
	if not rect.has_area(): return
	canvas.draw_rect(rect, visual_theme.color("card_paper"))
	var texture: Texture2D = visual_theme.card_texture
	if texture == null: return
	var texture_size: Vector2 = texture.get_size()
	if texture_size.x <= 0.0 or texture_size.y <= 0.0: return
	var cover_scale: float = maxf(rect.size.x / texture_size.x, rect.size.y / texture_size.y)
	var source_size: Vector2 = rect.size / cover_scale
	canvas.draw_texture_rect_region(texture, rect, Rect2((texture_size - source_size) * 0.5, source_size))


func draw_plate(canvas: CanvasItem, visual_theme: Resource, role: String, rect: Rect2) -> void:
	if not rect.has_area(): return
	if role == "back_face" or role.begins_with("deck_leaf_"):
		draw_card_background(canvas, visual_theme, rect)
		_draw_border(canvas, visual_theme, rect)
		return
	if role in ["card_frame", "back_inner"]:
		_draw_border(canvas, visual_theme, rect)
		return
	var material_role: String = "card_" + role
	if visual_theme.surface.palette.has(material_role):
		canvas.draw_rect(rect, visual_theme.color(material_role))
		return
	super.draw_plate(canvas, visual_theme, role, rect)


func draw_artwork(canvas: CanvasItem, visual_theme: Resource, _artworks: Resource, _data: Dictionary, _mode: String, rect: Rect2) -> void:
	if not rect.has_area(): return
	canvas.draw_rect(rect, visual_theme.color("card_artwork_well"))
	canvas.draw_line(Vector2(rect.position.x, rect.end.y), rect.end, visual_theme.color("card_rim"), float(visual_theme.surface.strokes.card_line_width), true)


func _draw_border(canvas: CanvasItem, visual_theme: Resource, rect: Rect2) -> void:
	var width: float = float(visual_theme.surface.strokes.card_line_width)
	canvas.draw_rect(rect.grow(-width * 0.5), visual_theme.color("card_rim"), false, width, true)
