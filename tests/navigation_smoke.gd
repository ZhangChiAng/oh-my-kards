extends "res://tests/ui_smoke.gd"

func _run() -> void:
	root.mode = Window.MODE_WINDOWED
	root.size = MAIN_WINDOW
	Input.use_accumulated_input = false
	_check(ProjectSettings.get_setting("application/run/main_scene") == "res://scenes/main_menu.tscn", "Default entry is main menu")
	change_scene_to_file("res://scenes/main_menu.tscn")
	await _frames(8)
	await _menu_capture()
	for dimensions in [Vector2i(1024, 640), Vector2i(3440, 1440), MAIN_WINDOW]:
		root.size = dimensions
		await _frames(5)
		var first: Control = current_scene.find_child("battle", true, false)
		var second: Control = current_scene.find_child("card_workshop", true, false)
		_check(root.get_visible_rect().encloses(first.get_global_rect()) and root.get_visible_rect().encloses(second.get_global_rect()), "Menu buttons fit " + str(dimensions))
		_check(is_equal_approx(first.get_global_rect().get_center().x, root.get_visible_rect().get_center().x), "Menu centered " + str(dimensions))
	await _tap(current_scene.find_child("card_workshop", true, false))
	_check(current_scene.scene_file_path == "res://scenes/card_workshop.tscn", "Workshop target opens")
	var workshop = current_scene.workshop
	await _tap(workshop.controls.name)
	var typed := InputEventKey.new()
	typed.keycode = KEY_A
	typed.unicode = 97
	typed.pressed = true
	Input.parse_input_event(typed)
	await _frames(2)
	if not _check(workshop.dirty(), "Real editing creates unsaved draft"):
		quit(1)
		return
	await _tap(workshop.controls.close)
	_check(workshop._guard.visible, "Exit guards unsaved changes")
	await _tap(workshop.controls.guard_cancel)
	_check(current_scene.workshop == workshop and workshop.dirty(), "Cancel preserves draft")
	await _tap(workshop.controls.close)
	await _tap(workshop.controls.guard_discard)
	_check(current_scene.scene_file_path == "res://scenes/main_menu.tscn", "Discard returns to menu")
	for terminal in [false, true]:
		await _tap(current_scene.find_child("battle", true, false))
		battle = current_scene
		_check(battle.scene_file_path == SCENE_PATH and _domain().phase == "mulligan", "Start creates fresh battle")
		_check(_no_development_entries(), "Battle has no workshop instances")
		var old_battle = weakref(battle)
		if terminal:
			var fixture := _fixture()
			fixture.phase = "finished"
			fixture.winner = "player"
			fixture.sides.ai.hq_hp = 0
			await _load_fixture(fixture)
		else:
			await _click("settings")
		await _click("main_menu", false)
		await _frames(8)
		_check(current_scene.scene_file_path == "res://scenes/main_menu.tscn" and old_battle.get_ref() == null, "Return releases battle, terminal=" + str(terminal))
	await create_timer(0.5).timeout
	_check(get_nodes_in_group("mcp_watch").is_empty(), "No battle remains on menu")
	var result := {"run_id": run_id, "status": "passed" if failures.is_empty() else "failed", "assertions": assertions, "failures": failures, "screenshots": screenshots, "trace": trace}
	var output := FileAccess.open(output_dir.path_join("navigation-result.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	quit(0 if failures.is_empty() else 1)

func _tap(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	if control.get_window() != root: point += Vector2(control.get_window().position)
	_motion(point)
	await _frames(1)
	_button(point, true)
	await _frames(1)
	_button(point, false)
	await _frames(8)

func _menu_capture() -> void:
	battle = current_scene
	if not await _draw_frame("main-menu"): return
	var filename := "main-menu.png"
	_check(root.get_texture().get_image().save_png(output_dir.path_join(filename)) == OK, "Main menu screenshot saved")
	screenshots.append(filename)
	var evidence := {"run_id": run_id, "state": {"scene_path": current_scene.scene_file_path}, "viewport": {"size": str(root.size)}, "profile": "ancient_metal", "background": current_scene.get_child(0).texture.resource_path}
	var output := FileAccess.open(output_dir.path_join(filename + ".json"), FileAccess.WRITE)
	output.store_string(JSON.stringify(evidence, "\t"))
	output.close()
