@abstract
extends Resource
## Appearance paints caller-owned geometry and never chooses layout or timing.


@abstract func draw_background(canvas: CanvasItem, visual_theme: Resource, rect: Rect2) -> void


@abstract func draw_plate(canvas: CanvasItem, visual_theme: Resource, role: String, rect: Rect2) -> void


@abstract func draw_artwork(canvas: CanvasItem, visual_theme: Resource, artworks: Resource, data: Dictionary, mode: String, rect: Rect2) -> void


@abstract func draw_frontline(canvas: CanvasItem, visual_theme: Resource, start: Vector2, end: Vector2) -> void
