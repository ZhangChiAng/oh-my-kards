extends Control
## Text is painted inside a geometry-owned slot and never supplies a minimum size.
const TextLayout = preload("res://scripts/art/art_widgets.gd")

var text: String = "":
	set(value):
		text = value
		queue_redraw()
var horizontal_alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER
var vertical_alignment: VerticalAlignment = VERTICAL_ALIGNMENT_CENTER
var autowrap_mode: TextServer.AutowrapMode = TextServer.AUTOWRAP_OFF


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	resized.connect(queue_redraw)
	theme_changed.connect(queue_redraw)


func _draw() -> void:
	var font: Font = get_theme_font("font")
	var chosen: int = get_theme_font_size("font_size")
	var lines: Array[String] = []
	while chosen > 1:
		if autowrap_mode != TextServer.AUTOWRAP_OFF: lines = TextLayout.wrap_lines(font, text, chosen, size.x)
		else: lines.assign(text.split("\n"))
		var fits: bool = font.get_height(chosen) * lines.size() <= size.y
		for line in lines: fits = fits and font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, chosen).x <= size.x
		if fits: break
		chosen -= 1
	var height: float = font.get_height(chosen)
	var top: float = 0.0 if vertical_alignment == VERTICAL_ALIGNMENT_TOP else maxf(0.0, (size.y - height * lines.size()) * (1.0 if vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM else 0.5))
	for index in range(lines.size()):
		var point := Vector2(0, top + height * index + font.get_ascent(chosen))
		if has_theme_constant_override("outline_size"):
			draw_string_outline(font, point, lines[index], horizontal_alignment, size.x, chosen, get_theme_constant("outline_size"), get_theme_color("font_outline_color"))
		draw_string(font, point, lines[index], horizontal_alignment, size.x, chosen, get_theme_color("font_color"))
