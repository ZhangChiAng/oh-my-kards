extends SceneTree
## Each phase runs in a fresh engine through the production menu and workshop scene.
var run_id := ""
var output_dir := ""
var phase := ""
var library_root := ""
var assertions := 0
var failures: Array[String] = []
var workshop: Control

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size() - 1):
		if args[index] == "--run-id": run_id = args[index + 1]
		elif args[index] == "--output-dir": output_dir = args[index + 1]
		elif args[index] == "--phase": phase = args[index + 1]
		elif args[index] == "--card-library-root": library_root = args[index + 1]
	if library_root.is_empty():
		for index in range(args.size() - 1):
			if args[index] == "--workshop-store": library_root = args[index + 1]
	call_deferred("_run")

func _run() -> void:
	if run_id.is_empty() or output_dir.is_empty() or library_root.is_empty() or not phase in ["create", "update", "delete", "empty"]:
		quit(2)
		return
	var isolated_base: String = ProjectSettings.globalize_path(output_dir).replace("\\", "/").simplify_path().trim_suffix("/").to_lower()
	var resolved_library: String = ProjectSettings.globalize_path(library_root).replace("\\", "/").simplify_path().to_lower()
	var artifacts_base: String = ProjectSettings.globalize_path("res://artifacts").replace("\\", "/").simplify_path().trim_suffix("/").to_lower()
	if not isolated_base.begins_with(artifacts_base + "/") or not resolved_library.begins_with(isolated_base + "/"):
		push_error("Persistence tests require a library inside the run output directory.")
		quit(2)
		return
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1920, 1080)
	Input.use_accumulated_input = false
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await _frames(8)
	await _tap(current_scene.find_child("card_workshop", true, false))
	if current_scene.scene_file_path != "res://scenes/card_workshop.tscn":
		_check(false, "Production menu opens workshop")
		_finish()
		return
	workshop = current_scene.workshop
	_check(workshop.store.root_path.replace("\\", "/") == library_root.replace("\\", "/"), "Production workshop uses the explicit isolated shared library")
	if phase == "create":
		await _create()
	elif phase == "empty":
		_check(workshop.store.records.size() == 20 and workshop.store.preset_deck().size() == 40, "Deletion remains effective after restart while preset definitions remain")
	else:
		await _restore()
	_finish()

func _create() -> void:
	await _edit("name", "持久收藏测试")
	for key in ["deploy_cost", "action_cost", "attack", "max_hp"]:
		await _edit(key, "7")
	await _click("unit_type")
	await _click("type:tank")
	var source := output_dir.path_join("persistent-source.png")
	var image := Image.create(160, 90, false, Image.FORMAT_RGBA8)
	image.fill(Color("986c43"))
	image.save_png(source)
	await _click("import")
	await _click("file_path")
	_key(KEY_A, true)
	_type_text(source)
	_key(KEY_ENTER)
	await _frames(4)
	var point: Vector2 = workshop.controls.artwork.get_global_rect().get_center()
	_mouse(point, true, MOUSE_BUTTON_WHEEL_UP)
	_mouse(point, false, MOUSE_BUTTON_WHEEL_UP)
	await _frames(2)
	_mouse(point, true)
	await _frames(1)
	var move := InputEventMouseMotion.new()
	move.position = root.get_final_transform() * (point + Vector2(24, 14))
	move.global_position = move.position
	move.relative = root.get_final_transform().basis_xform(Vector2(24, 14))
	move.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(move)
	await _frames(1)
	_mouse(point + Vector2(24, 14), false)
	await _frames(2)
	await _click("save")
	_check(not workshop.dirty() and workshop.store.records.size() == 21, "Production save adds one persistent record to the shared library")
	_check(workshop.draft.definition == {"card_type": "unit", "name": "持久收藏测试", "unit_type": "tank", "deploy_cost": 7, "action_cost": 7, "attack": 7, "max_hp": 7, "keywords": {}, "abilities": [], "auras": []}, "Saved definition matches requested edits and retains empty ability fields")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(workshop.store.root_path.path_join("cards.json")))
	_check(saved is Dictionary and saved.get("version") == 3, "Production shared library writes version 3")
	_check(workshop.draft.artwork.source.begins_with("image:") and workshop.draft.artwork.zoom > 1, "Saved record includes imported art and non-default crop")
	_write_expected()
	_check(DirAccess.remove_absolute(source) == OK, "Original import source removed before process ends")

func _restore() -> void:
	var expected: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output_dir.path_join("persistent-expected.json")))
	if not _check(workshop.store.records.size() == 21, "Fresh process restores the saved card alongside preset definitions"): return
	var saved_control: Control = workshop.controls.get("card:" + str(expected.id))
	if saved_control != null:
		workshop._collection.ensure_control_visible(saved_control)
		await _frames(2)
	await _click("card:" + str(expected.id))
	var actual: Variant = JSON.parse_string(JSON.stringify(workshop.draft))
	_check(actual == expected, "Identity, complete definition, illustration reference and crop survive restart")
	_check(not FileAccess.file_exists(output_dir.path_join("persistent-source.png")) and workshop._cached_texture != null and workshop._cached_texture.get_size() == Vector2(160, 90), "Saved local illustration reloads without original source")
	if phase == "update":
		await _edit("name", "重启后修改")
		await _click("save")
		_check(not workshop.dirty(), "Restored card can be updated and saved")
		_check(workshop.draft.definition.name == "重启后修改", "Updated name matches the requested input")
		_write_expected()
	else:
		await _click("delete")
		await _click("delete_confirm")
		_check(workshop.store.records.size() == 20 and not workshop.store.definitions().has(expected.id), "Confirmation deletes the restored custom card while preserving preset definitions")

func _write_expected() -> void:
	var file := FileAccess.open(output_dir.path_join("persistent-expected.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(workshop.draft))
	file.close()

func _edit(key: String, value: String) -> void:
	await _click(key)
	_type_text(value)
	_key(KEY_ENTER)
	await _frames(2)

func _click(key: String) -> void:
	var entry: Dictionary = workshop.snapshot_controls().get("workshop:" + key, {})
	if not entry.has("hit_point") or not entry.get("enabled", false):
		_check(false, "Input target unavailable: " + key)
		return
	await _tap_at(Vector2(entry.hit_point.x, entry.hit_point.y))

func _tap(control: Control) -> void:
	await _tap_at(control.get_global_rect().get_center())

func _tap_at(point: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = root.get_final_transform() * point
	move.global_position = move.position
	Input.parse_input_event(move)
	await _frames(1)
	_mouse(point, true)
	await _frames(1)
	_mouse(point, false)
	await _frames(8)

func _mouse(point: Vector2, down: bool, button: int = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = root.get_final_transform() * point
	event.global_position = event.position
	event.button_index = button
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down and button == MOUSE_BUTTON_LEFT else 0
	event.pressed = down
	Input.parse_input_event(event)

func _type_text(value: String) -> void:
	for character in value:
		for down in [true, false]:
			var event := InputEventKey.new()
			event.unicode = character.unicode_at(0)
			event.pressed = down
			Input.parse_input_event(event)

func _key(code: Key, control := false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.ctrl_pressed = control
		event.pressed = down
		Input.parse_input_event(event)

func _frames(count: int) -> void:
	for index in range(count): await process_frame

func _check(ok: bool, caption: String) -> bool:
	assertions += 1
	if not ok: failures.append(caption)
	return ok

func _finish() -> void:
	var file := FileAccess.open(output_dir.path_join("workshop-persistence-" + phase + "-result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"run_id": run_id, "status": "passed" if failures.is_empty() else "failed", "assertions": assertions, "failures": failures, "trace": [{"phase": phase, "process_id": OS.get_process_id(), "entry": "res://scenes/main_menu.tscn"}]}))
	file.close()
	quit(0 if failures.is_empty() else 1)
