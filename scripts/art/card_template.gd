extends Resource
## All rectangles are template-local design coordinates, never screen pixels.
@export var mode: String = ""
@export var size: Vector2
@export var inner_rect: Rect2
@export var artwork_rect: Rect2
@export var slots: Dictionary = {}
@export var font_sizes: Dictionary = {}


func spec() -> Dictionary:
	return {
		"mode": mode,
		"size": size,
		"inner_rect": inner_rect,
		"artwork_rect": artwork_rect,
		"slots": slots.duplicate(true),
		"font_sizes": font_sizes.duplicate(true),
	}
