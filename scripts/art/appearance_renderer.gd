@abstract
extends Resource
## Appearance paints caller-owned geometry and never chooses layout or timing.


func draw_tabletop(canvas: CanvasItem, visual_theme: Resource, rect: Rect2) -> void:
	if not rect.has_area(): return
	canvas.draw_rect(rect, visual_theme.color("background"))
	var texture: Texture2D = visual_theme.background_texture
	if texture == null: return
	var texture_size: Vector2 = texture.get_size()
	if texture_size.x <= 0.0 or texture_size.y <= 0.0: return
	var cover_scale: float = maxf(rect.size.x / texture_size.x, rect.size.y / texture_size.y)
	var source_size: Vector2 = rect.size / cover_scale
	var source := Rect2((texture_size - source_size) * 0.5, source_size)
	canvas.draw_texture_rect_region(texture, rect, source)


@abstract func draw_card_background(canvas: CanvasItem, visual_theme: Resource, rect: Rect2) -> void


@abstract func draw_plate(canvas: CanvasItem, visual_theme: Resource, role: String, rect: Rect2) -> void


@abstract func draw_artwork(canvas: CanvasItem, visual_theme: Resource, artworks: Resource, data: Dictionary, mode: String, rect: Rect2) -> void


@abstract func draw_frontline(canvas: CanvasItem, visual_theme: Resource, start: Vector2, end: Vector2) -> void
