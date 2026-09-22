extends Resource
## Replaceable materials, independent of geometry and diagnostic display.
@export var surface: Resource = preload("res://resources/art/surface_style.tres")
@export var renderer: Resource = preload("res://scripts/art/surface_renderer.gd").new()
@export var background_texture: Texture2D


func color(role: String) -> Color:
	assert(surface.palette.get(role) is Color, "Missing theme color: " + role)
	return surface.palette[role]


func style(role: String) -> StyleBox:
	return surface.styles.get(role) as StyleBox
