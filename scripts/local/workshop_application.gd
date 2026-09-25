extends Control
const Workshop = preload("res://scripts/workshop/card_workshop.gd")
var workshop: Control

func _ready() -> void:
	workshop = Workshop.new()
	# Resolve the shared library override before the first load or initialization.
	workshop.store.configure_from_args(OS.get_cmdline_user_args())
	add_child(workshop)
	workshop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	workshop.closed.connect(func(): get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn"))
	workshop.open()

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		workshop.request_close()
		get_viewport().set_input_as_handled()
