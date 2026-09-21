extends Resource
## Appearance only. Geometry and animation are independent resources.
@export var render_mode: String = ""
@export var palette: Dictionary = {}
@export var font: Font
@export var number_font: Font
@export var styles: Dictionary = {}
@export var renderer: Resource
## Line widths, antialiasing and other appearance values, without geometry.
@export var wireframe: Dictionary = {}


func color(role: String) -> Color:
	assert(palette.get(role) is Color, "Missing theme color: " + role)
	return palette[role]


func style(role: String) -> StyleBox:
	return styles.get(role) as StyleBox
