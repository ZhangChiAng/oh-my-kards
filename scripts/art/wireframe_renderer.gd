extends "res://scripts/art/appearance_renderer.gd"
## A texture-free implementation of the shared appearance contract.


func draw_background(canvas: CanvasItem, visual_theme: Resource, rect: Rect2) -> void:
	canvas.draw_rect(rect, visual_theme.color("background"))


func draw_plate(canvas: CanvasItem, visual_theme: Resource, role: String, rect: Rect2) -> void:
	if not rect.has_area():
		return
	var appearance: Dictionary = visual_theme.wireframe
	if not role.ends_with("_frame"):
		canvas.draw_rect(rect, visual_theme.color("panel"))
	canvas.draw_rect(rect, visual_theme.color("text"), false, float(appearance.line_width), bool(appearance.antialiased))
	if role == "highlight_frame":
		canvas.draw_rect(rect.grow(-float(appearance.highlight_inset)), visual_theme.color("text"), false, float(appearance.line_width), bool(appearance.antialiased))


func draw_artwork(canvas: CanvasItem, visual_theme: Resource, _artworks: Resource, _data: Dictionary, _mode: String, rect: Rect2) -> void:
	draw_plate(canvas, visual_theme, "artwork_well", rect)


func draw_frontline(canvas: CanvasItem, visual_theme: Resource, start: Vector2, end: Vector2) -> void:
	canvas.draw_line(start, end, visual_theme.color("text"), float(visual_theme.wireframe.board_line_width), bool(visual_theme.wireframe.board_antialiased))
