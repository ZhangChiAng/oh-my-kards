extends Control

const Profile = preload("res://resources/art/ancient_metal_profile.tres")
const Geometry = preload("res://resources/art/battle_geometry.tres")
const WidgetButton = preload("res://scripts/art_battle/widget_button.gd")
var _leaving := false

func _ready() -> void:
	var background := TextureRect.new()
	background.texture = Profile.visual_theme.background_texture
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var buttons := VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 28)
	center.add_child(buttons)
	for entry in [["开始游戏", "battle"], ["卡牌制作台", "card_workshop"]]:
		var button := WidgetButton.new()
		button.name = entry[1]
		button.text = entry[0]
		button.profile = Profile
		button.geometry = Geometry
		button.keyboard_focus = true
		button.custom_minimum_size = Vector2(360, 88)
		buttons.add_child(button)
		button.pressed.connect(func(): _open(entry[1]))

func _open(destination: String) -> void:
	if _leaving: return
	_leaving = true
	var error := get_tree().change_scene_to_file("res://scenes/" + destination + ".tscn")
	if error != OK:
		_leaving = false
		push_error("Cannot open scene: " + destination)
