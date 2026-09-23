extends BaseButton
## A real GUI button whose surface is painted by the shared art widget.
const Widget = preload("res://scripts/art/art_widgets.gd")

var text: String = "":
	set(value):
		text = value
		refresh()

var profile: Resource
var geometry: Resource
var role: String = "end_turn"
var icon_role: String = ""
var _surface: Control
var _hovered: bool = false


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var empty := StyleBoxEmpty.new()
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		add_theme_stylebox_override(state, empty)
	_surface = Widget.new()
	_surface.show_behind_parent = true
	add_child(_surface)
	mouse_entered.connect(func(): _hovered = true; refresh())
	mouse_exited.connect(func(): _hovered = false; refresh())
	button_down.connect(refresh)
	button_up.connect(refresh)
	resized.connect(refresh)
	refresh()


func refresh() -> void:
	if not is_instance_valid(_surface) or profile == null:
		return
	_surface.configure({"text": text, "icon_role": icon_role, "disabled": disabled, "hovered": _hovered, "pressed": is_pressed()}, role, profile, geometry)
	_surface.size = size
	_surface.position = Vector2.ZERO
