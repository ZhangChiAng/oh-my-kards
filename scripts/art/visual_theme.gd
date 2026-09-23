extends Resource
## Replaceable materials, independent of geometry and diagnostic display.
@export var surface: Resource = preload("res://resources/art/surface_style.tres")
@export var renderer: Resource = preload("res://scripts/art/surface_renderer.gd").new()
@export var background_texture: Texture2D
@export var card_texture: Texture2D
@export var control_skin: Resource


func color(role: String) -> Color:
	if control_skin != null and control_skin.colors.has(role): return control_skin.colors[role]
	assert(surface.palette.get(role) is Color, "Missing theme color: " + role)
	return surface.palette[role]


func has_color(role: String) -> bool:
	return (control_skin != null and control_skin.colors.get(role) is Color) or surface.palette.get(role) is Color


func style(role: String) -> StyleBox:
	if control_skin != null and control_skin.styles.has(role):
		return control_skin.styles[role] as StyleBox
	return surface.styles.get(role) as StyleBox
