extends Control
## A skin may paint a panel, but cannot change the slot through style margins.

func _ready() -> void:
	resized.connect(queue_redraw)
	theme_changed.connect(queue_redraw)


func _draw() -> void:
	draw_style_box(get_theme_stylebox("panel"), Rect2(Vector2.ZERO, size))
