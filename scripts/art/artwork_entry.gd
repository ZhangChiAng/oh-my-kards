extends Resource
## Source images and per-view crops; changing an illustration never changes rules.
@export var texture: Texture2D
@export var background_texture: Texture2D
## Normalized point on the source image to keep at the crop center where possible.
@export var full_focus: Vector2
@export var field_focus: Vector2
@export var background_full_focus: Vector2
@export var background_field_focus: Vector2
@export var full_zoom: float
@export var field_zoom: float
@export var background_full_zoom: float
@export var background_field_zoom: float
@export var modulate: Color
