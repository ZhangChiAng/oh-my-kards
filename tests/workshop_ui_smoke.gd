extends SceneTree
## Independent component harness. User edits use genuine Input events.
const Workshop = preload("res://scripts/workshop/card_workshop.gd")
const Fingerprint = preload("res://scripts/art_battle/config_fingerprint.gd")
const Widgets = preload("res://scripts/art/art_widgets.gd")
const MAIN_WINDOW := Vector2i(1920, 1080)
var run_id: String = ""
var output_dir: String = ""
var assertions: int = 0
var failures: Array[String] = []
var trace: Array = []
var screenshots: Array[String] = []
var workshop: Control
var _mouse := Vector2.ZERO

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size() - 1):
		if args[index] == "--run-id": run_id = args[index + 1]
		elif args[index] == "--output-dir": output_dir = args[index + 1]
	call_deferred("_run")

func _run() -> void:
	if run_id.is_empty() or output_dir.is_empty():
		push_error("Workshop UI test requires run identity and output directory.")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output_dir)
	if not _check(DisplayServer.get_name() != "headless", "Workshop requires a graphical display"):
		_finish()
		return
	root.mode = Window.MODE_WINDOWED
	root.size = MAIN_WINDOW
	Input.use_accumulated_input = false
	var host := Control.new()
	root.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	current_scene = host
	workshop = Workshop.new()
	host.add_child(workshop)
	workshop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _frames(3)
	var collection_tests = preload("res://tests/workshop_store_test.gd").new()
	for result in collection_tests.run(output_dir):
		_check(result.ok, result.caption)
	await _workshop_collection()
	_finish()

func _workshop_collection() -> void:
	workshop.store.root_path = output_dir.path_join("ui-collection")
	var template_before: Dictionary = workshop.geometry.template("full").spec().duplicate(true)
	workshop.open()
	await _frames(3)
	if not _check(_state().workshop.open, "Independent harness opens game workshop"): return
	_check(workshop.profile.visual_theme.background_texture != null and workshop.profile.visual_theme.card_texture != null and workshop.profile.artworks != null, "Workshop uses official material and private illustration library")
	await _begin_checked_edit("name")
	_type_text("中文 卡牌收藏测试")
	_key(KEY_ENTER)
	await _frames(2)
	_check(_state().workshop.draft.definition.name == "中文 卡牌收藏测试", "Chinese and space input edits the full card directly")
	for key in ["deploy_cost", "action_cost", "attack", "max_hp"]:
		await _begin_checked_edit(key)
		_type_text("12" if key.ends_with("cost") else "99")
		_key(KEY_ENTER)
		await _frames(2)
		_check(_state().workshop.draft.definition[key] == (12 if key.ends_with("cost") else 99), "Real input commits card number: " + key)
	await _click("workshop:name")
	_type_text("取消编辑")
	_key(KEY_ESCAPE)
	await _frames(2)
	_check(_state().workshop.draft.definition.name == "中文 卡牌收藏测试", "Escape restores the current edit without closing workshop")
	await _click("workshop:unit_type")
	await _click("workshop:type:artillery")
	_check(workshop._full.display_data.unit_type == "artillery" and workshop._field.display_data.unit_type == "artillery", "Both card icons follow the selected unit type")
	var art_key := "art:infantry-street-assault-v2"
	_check(workshop.controls[art_key].text.is_empty() and workshop.controls[art_key].tooltip_text.is_empty(), "Illustration thumbnail contains no asset name")
	await _click("workshop:" + art_key)
	_check(_state().workshop.draft.artwork.source == "library:infantry-street-assault-v2" and workshop._cached_texture != null, "Library thumbnail immediately displays built-in art")
	await _crop_interaction()
	await _check_field_readonly()
	await _inline_focus_interaction()
	await _click("workshop:save")
	_check(_state().workshop.count == 1 and not _state().workshop.dirty, "Real save persists a collection card")
	var first_id: String = _state().workshop.selected_id
	await _edit("name", "保存后重新选择")
	await _click("workshop:card:" + first_id)
	await _click("workshop:guard_save")
	_check(_state().workshop.draft.definition.name == "保存后重新选择" and not _state().workshop.dirty, "Save before reselecting the same card loads the latest saved record")
	await _edit("name", "中文 卡牌收藏测试")
	await _click("workshop:save")
	await _click("workshop:new")
	_check(workshop._cached_texture == null and _state().workshop.draft.artwork.source.is_empty(), "New card starts without artwork")
	await _click("workshop:card:" + first_id)
	await _capture("workshop.png")
	await _click("workshop:import")
	await _click("workshop:file_cancel")
	_check(not _state().workshop.dirty, "Cancelling image selection preserves saved artwork")
	var imported_path: String = output_dir.path_join("workshop-source.png")
	var fixture_image := Image.create(100, 60, false, Image.FORMAT_RGBA8)
	fixture_image.fill(Color("987445"))
	fixture_image.save_png(imported_path)
	await _choose_workshop_image(imported_path)
	_check(_state().workshop.dirty and _state().workshop.draft.artwork.source.begins_with("image:") and workshop._cached_texture != null, "Real file dialog imports artwork into both card previews")
	await _click("workshop:save")
	var invalid_file := FileAccess.open(imported_path, FileAccess.WRITE)
	invalid_file.store_string("not an image")
	invalid_file.close()
	await _choose_workshop_image(imported_path)
	_check(not _state().workshop.dirty and "无法读取" in _state().workshop.notice, "Invalid image preserves saved card and artwork")
	await _edit("name", "待放弃")
	await _click("workshop:new")
	_check(_state().workshop.dialog_open, "New card protects an unsaved draft")
	await _click("workshop:guard_cancel")
	_check(_state().workshop.dirty, "Cancel keeps the edited draft")
	await _click("workshop:card:" + first_id)
	_check(_state().workshop.dialog_open, "Collection selection protects an unsaved draft")
	await _click("workshop:guard_discard")
	_check(_state().workshop.draft.definition.name == "中文 卡牌收藏测试", "Discard restores the selected saved card")
	await _edit("name", "待退出")
	await _click("workshop:close")
	_check(_state().workshop.dialog_open, "Dirty exit offers confirmation")
	await _check_modal_interaction()
	await _check_modal_save_failure()
	_check_modal_layout(workshop._guard)
	await _capture("workshop-confirm.png")
	await _click("workshop:guard_cancel")
	_check(_state().workshop.open and _state().workshop.dirty, "Cancel retains the open draft")
	await _click("workshop:close")
	await _click("workshop:guard_discard")
	_check(not _state().workshop.open, "Discard closes workshop")
	workshop.open()
	await _frames(3)
	await _click("workshop:card:" + first_id)
	await _edit("name", "一二三四五六七八九十一二三四五六")
	await _begin_checked_edit("name")
	_check(workshop._editor.layout_snapshot().line_count == 2, "Long Chinese name preserves two lines while editing")
	var edit_layout: Dictionary = workshop._editor.layout_snapshot()
	var second_line: Vector2 = edit_layout.baselines[1] - edit_layout.slot.position + Vector2(1, -edit_layout.line_height * 0.4)
	var caret_point: Vector2 = workshop._editor.get_global_transform() * second_line
	_motion(caret_point)
	_button(caret_point, true)
	_button(caret_point, false)
	await _frames(2)
	_check(workshop._editor.has_focus() and not workshop._editor.has_selection() and workshop._editor.caret_column >= int(edit_layout.indexes[1]), "Clicking second wrapped line positions native caret without exiting edit")
	await _capture("workshop-editing.png")
	_key(KEY_ENTER)
	await _frames(2)
	await _draw_frame("maximum card name")
	var full_name: Dictionary = workshop._full.geometry_snapshot().get("text", {}).get("name", {})
	_check(full_name.get("drawn", false) and full_name.get("fits", false) and full_name.get("line_count", 0) == 2, "Maximum Chinese name fits two card lines")
	await _click("workshop:close")
	await _click("workshop:guard_save")
	_check(not _state().workshop.open, "Save-and-exit commits the draft")
	workshop.open()
	await _frames(3)
	await _click("workshop:card:" + first_id)
	_check_layout()
	for dimensions in ([Vector2i(1024, 640), Vector2i(3440, 1440)] if "--sizes" in OS.get_cmdline_user_args() else []):
		root.size = dimensions
		await _frames(4)
		_check_layout()
		var value: int = 8 if dimensions.x == 1024 else 9
		await _edit("attack", str(value))
		_check(_state().workshop.draft.definition.attack == value, "Full card remains editable at " + str(dimensions))
		var area: Control = workshop.controls.artwork
		var point: Vector2 = area.get_global_rect().get_center()
		_motion(point)
		_button(point, true, MOUSE_BUTTON_WHEEL_UP)
		_button(point, false, MOUSE_BUTTON_WHEEL_UP)
		await _frames(2)
		var focus_before: Array = _state().workshop.draft.artwork.focus.duplicate()
		_button(point, true)
		_motion(point + Vector2(20, 12), MOUSE_BUTTON_MASK_LEFT)
		_button(point + Vector2(20, 12), false)
		await _frames(2)
		_check(_state().workshop.draft.artwork.focus != focus_before, "Scaled window coordinates reach artwork drag at " + str(dimensions))
		await _click("workshop:close")
		_check_modal_layout(workshop._guard)
		await _capture("workshop-confirm-%dx%d.png" % [dimensions.x, dimensions.y])
		_key(KEY_ESCAPE)
		await _frames(2)
		_record("workshop-size-" + str(dimensions))
	root.size = MAIN_WINDOW
	await _frames(4)
	_check(workshop.geometry.template("full").spec() == template_before, "Editing and resizing preserve shared card geometry")
	await _click("workshop:delete")
	_check_modal_layout(workshop._delete)
	await _click("workshop:delete_cancel")
	_check(_state().workshop.count == 1, "Cancelling deletion retains collection")
	await _click("workshop:delete")
	await _click("workshop:delete_confirm")
	_check(_state().workshop.count == 0 and workshop.controls.new.is_visible_in_tree(), "Deleting final card keeps new-card entry available")
	await _click("workshop:close")
	_record("workshop")

func _check_modal_interaction() -> void:
	var modal: Control = workshop._guard
	_check(modal.buttons.cancel.has_focus(), "Unsaved modal initially focuses cancel")
	var original: Dictionary = _state().workshop.draft.duplicate(true)
	for key in ["name", "save", "artwork"]:
		var point: Vector2 = workshop.controls[key].get_global_rect().get_center()
		# Use real coordinates even though snapshots disable the covered controls.
		_motion(point)
		_button(point, true)
		_button(point, false)
		await _frames(2)
		_check(modal.visible and _state().workshop.draft == original and _state().workshop.dirty and not workshop._editor.visible, "Modal blocks underlying click: " + key)
	var art_point: Vector2 = workshop.controls.artwork.get_global_rect().position + Vector2(12, 12)
	_motion(art_point)
	_button(art_point, true, MOUSE_BUTTON_WHEEL_UP)
	_button(art_point, false, MOUSE_BUTTON_WHEEL_UP)
	_button(art_point, true)
	_motion(art_point + Vector2(30, 20), MOUSE_BUTTON_MASK_LEFT)
	_button(art_point + Vector2(30, 20), false)
	await _frames(2)
	_check(_state().workshop.draft == original and not workshop._dragging, "Modal blocks underlying crop wheel and drag")
	var outside := Vector2(8, root.get_visible_rect().size.y - 8)
	_motion(outside)
	_button(outside, true)
	_button(outside, false)
	await _frames(2)
	_check(modal.visible, "Clicking backdrop does not dismiss confirmation")
	for index in range(3):
		_key(KEY_TAB)
		await _frames(1)
		var focused: Control = root.gui_get_focus_owner()
		_check(focused != null and modal.is_ancestor_of(focused), "Tab focus remains within confirmation: " + str(index))
	_key(KEY_ESCAPE)
	await _frames(2)
	_check(not modal.visible and _state().workshop.open and _state().workshop.draft == original, "Escape cancels confirmation without changing draft")
	await _click("workshop:close")

func _check_modal_save_failure() -> void:
	var original: Dictionary = _state().workshop.draft.duplicate(true)
	var saved_root: String = workshop.store.root_path
	var blocked_root: String = output_dir.path_join("blocked-ui-save")
	var blocker := FileAccess.open(blocked_root, FileAccess.WRITE)
	if not _check(blocker != null, "Save failure fixture creates a non-directory target"): return
	blocker.store_string("This file prevents collection directory creation.")
	blocker.close()
	workshop.store.root_path = blocked_root
	await _click("workshop:guard_save")
	workshop.store.root_path = saved_root
	_check(workshop._guard.visible and _state().workshop.open and _state().workshop.dirty and _state().workshop.draft == original, "Failed modal save preserves open confirmation and entire draft")
	_check(not str(workshop._guard.layout_snapshot().error).is_empty(), "Failed modal save displays its error inside confirmation")
	_check_modal_layout(workshop._guard)
	await _click("workshop:guard_cancel")
	await _click("workshop:close")
	_check(str(workshop._guard.layout_snapshot().error).is_empty(), "Reopening confirmation clears the previous save error")

func _check_modal_layout(modal: Control) -> void:
	var layout: Dictionary = modal.layout_snapshot()
	var viewport: Rect2 = root.get_visible_rect()
	_check(viewport.encloses(layout.panel_rect), "Metal confirmation fits viewport at " + str(root.size))
	_check(float(layout.font_pixels.title) >= 24.0 and float(layout.font_pixels.body) >= 18.0 and float(layout.font_pixels.button) >= 18.0, "Confirmation uses readable actual pixel font sizes at " + str(root.size))
	for key in ["title_rect", "body_rect"]:
		_check(layout.panel_rect.encloses(layout[key]), "Confirmation text stays within panel: " + key)
	if not str(layout.error).is_empty():
		_check(layout.panel_rect.encloses(layout.error_rect), "Save error stays within expanded confirmation")
		_check(layout.error_rect.end.y <= modal.buttons.cancel.get_global_rect().position.y, "Save error does not overlap confirmation buttons")
	var previous_right: float = -1.0
	for key in ["cancel", "discard", "confirm"]:
		if not modal.buttons.has(key): continue
		var button: Button = modal.buttons[key]
		if not button.is_visible_in_tree(): continue
		_check(layout.panel_rect.encloses(button.get_global_rect()), "Confirmation button fits panel: " + key)
		_check(button.get_global_rect().position.x >= previous_right, "Confirmation buttons keep ordered separate bounds: " + key)
		previous_right = button.get_global_rect().end.x
	trace.append({"step": "confirmation-layout", "window": str(root.size), "layout": layout})

func _edit(key: String, value: String) -> void:
	await _click("workshop:" + key)
	_type_text(value)
	_key(KEY_ENTER)
	await _frames(2)

func _begin_checked_edit(key: String) -> void:
	var slot: String = "health" if key == "max_hp" else key
	var template: Resource = workshop.geometry.template("full")
	var expected: Dictionary = Widgets.fitted_text_layout(workshop.profile.visual_theme, template, slot, str(_state().workshop.draft.definition[key]), key != "name", key == "name")
	await _click("workshop:" + key)
	_check(workshop._editor.visible and workshop._editor.has_focus(), "Card field receives native text focus: " + key)
	var actual: Dictionary = workshop._editor.layout_snapshot()
	_check(actual == expected, "Editor shares exact font, wrapping and baselines with displayed field: " + key)
	var expected_rect := Rect2(workshop._full.global_position + template.slots[slot].position * workshop._full.scale, template.slots[slot].size * workshop._full.scale)
	_check(workshop._editor.get_global_rect().is_equal_approx(expected_rect), "Editor occupies the text slot without added padding: " + key)
	_check(not workshop._full.geometry_snapshot().text.has(slot), "Full card suppresses duplicate text underneath editor: " + key)

func _inline_focus_interaction() -> void:
	var points: Dictionary = {
		"desktop": Vector2(8, root.get_visible_rect().size.y - 8),
		"field preview": workshop._field.get_global_rect().get_center(),
		"artwork": workshop.controls.artwork.get_global_rect().get_center()
	}
	for label in points:
		await _click("workshop:name")
		_type_text("外部点击测试")
		var point: Vector2 = points[label]
		_motion(point)
		_button(point, true)
		_check(not workshop._editor.visible and not workshop._editor.has_focus(), "Outside press immediately ends editing: " + label)
		_check(_state().workshop.draft.definition.name == "外部点击测试", "Outside press synchronously retains latest input: " + label)
		if label == "artwork":
			_check(workshop._dragging, "Clicking artwork while editing also begins the original drag action")
		_button(point, false)
		await _frames(2)
	await _click("workshop:name")
	_type_text("切换字段测试")
	await _click("workshop:attack")
	_check(workshop._edit_key == "attack" and workshop._editor.has_focus() and _state().workshop.draft.definition.name == "切换字段测试", "Outside click commits and immediately opens the next field")
	_type_text("73")
	_key(KEY_ENTER)
	_check(_state().workshop.draft.definition.attack == 73, "Rapid numeric input and Enter retain the final character")
	await _frames(2)
	await _click("workshop:name")
	_type_text("保存按钮测试")
	await _click("workshop:save")
	_check(not workshop._editor.has_focus() and not _state().workshop.dirty and _state().workshop.draft.definition.name == "保存按钮测试", "Save click commits latest input and performs save")
	await _click("workshop:name")
	_type_text("关闭按钮测试")
	await _click("workshop:close")
	_check(not workshop._editor.has_focus() and _state().workshop.dialog_open and _state().workshop.draft.definition.name == "关闭按钮测试", "Red cross commits input and opens unsaved protection")
	await _click("workshop:guard_cancel")
	await _edit("name", "中文 卡牌收藏测试")
	trace.append({"step": "ime-coverage", "status": "not_automated", "reason": "Real Unicode InputEventKey coverage does not exercise the operating system IME candidate window; composition confirmation requires manual verification."})

func _crop_interaction() -> void:
	var cropper = preload("res://scripts/art/artwork_crop.gd")
	var area: Control = workshop.controls.artwork
	var point: Vector2 = area.global_position + area.size * Vector2(0.4, 0.35)
	var previous: Dictionary = _state().workshop.draft.artwork
	var extent: Vector2 = workshop._cached_texture.get_size()
	var source: Rect2 = cropper.source_rect(extent, area.size, Vector2(previous.focus[0], previous.focus[1]), previous.zoom)
	var anchor: Vector2 = source.position + source.size * Vector2(0.4, 0.35)
	_motion(point)
	_button(point, true, MOUSE_BUTTON_WHEEL_UP)
	_button(point, false, MOUSE_BUTTON_WHEEL_UP)
	await _frames(2)
	var changed: Dictionary = _state().workshop.draft.artwork
	var next: Rect2 = cropper.source_rect(extent, area.size, Vector2(changed.focus[0], changed.focus[1]), changed.zoom)
	_check(changed.zoom > previous.zoom and changed.zoom <= 8, "Mouse wheel zooms artwork within allowed range")
	_check((next.position + next.size * Vector2(0.4, 0.35)).distance_to(anchor) < 0.1, "Wheel zoom preserves image point under cursor")
	_button(point, true)
	await _frames(1)
	_motion(point + Vector2(20, 12), MOUSE_BUTTON_MASK_LEFT)
	await _frames(1)
	_button(point + Vector2(20, 12), false)
	await _frames(2)
	var dragged: Dictionary = _state().workshop.draft.artwork
	_check(dragged.focus != changed.focus, "Left drag changes unified artwork focus")
	_check(workshop._full.display_data.artwork == dragged and workshop._field.display_data.artwork == dragged, "Both card forms share the edited artwork and crop")
	for mode in ["full", "field"]:
		var rect: Rect2 = cropper.source_rect(extent, workshop.geometry.template(mode).artwork_rect.size, Vector2(dragged.focus[0], dragged.focus[1]), dragged.zoom)
		_check(rect.has_area() and Rect2(Vector2.ZERO, extent).encloses(rect), "Crop covers card window without empty source edges: " + mode)

func _check_field_readonly() -> void:
	var original: Dictionary = _state().workshop.draft.duplicate(true)
	var point: Vector2 = workshop._field.get_global_rect().get_center()
	_motion(point)
	_button(point, true, MOUSE_BUTTON_WHEEL_UP)
	_button(point, false, MOUSE_BUTTON_WHEEL_UP)
	_button(point, true)
	await _frames(1)
	_motion(point + Vector2(20, 10), MOUSE_BUTTON_MASK_LEFT)
	_button(point + Vector2(20, 10), false)
	await _frames(2)
	_check(_state().workshop.draft == original and not workshop._editor.visible, "Field preview ignores editing, wheel and dragging")

func _check_layout() -> void:
	var viewport: Rect2 = root.get_visible_rect()
	for card in [workshop._full, workshop._field]:
		_check(viewport.encloses(card.get_global_rect()), "Entire card stays visible at " + str(root.size))
		_check(is_equal_approx(card.scale.x, card.scale.y), "Card aspect is preserved")
	for key in ["new", "close", "save", "delete", "import", "name", "unit_type", "attack", "max_hp"]:
		_check(viewport.encloses(workshop.controls[key].get_global_rect()), "Control stays in viewport: " + key)
	_check(not workshop._full.get_global_rect().intersects(workshop._field.get_global_rect()), "Full editor and field preview do not overlap")
	_check(not workshop.controls.close.get_global_rect().intersects(workshop._field.get_global_rect()), "Metal close button does not cover field preview")

func _choose_workshop_image(path: String) -> void:
	await _click("workshop:import")
	await _click("workshop:file_path")
	_select_all()
	_type_text(ProjectSettings.globalize_path(path))
	_key(KEY_ENTER)
	await _frames(4)

func _type_text(text: String) -> void:
	for character in text:
		for down in [true, false]:
			var event := InputEventKey.new()
			event.unicode = character.unicode_at(0)
			event.pressed = down
			Input.parse_input_event(event)

func _select_all() -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_A
		event.ctrl_pressed = true
		event.pressed = down
		Input.parse_input_event(event)

func _point(key: String) -> Vector2:
	var control: Dictionary = _state().ui_controls.get(key, {})
	if not control.has("hit_point"):
		_check(false, "Missing safe input point: " + key)
		return Vector2(-1, -1)
	var point := Vector2(float(control.hit_point.x), float(control.hit_point.y))
	if not root.get_visible_rect().has_point(point):
		_check(false, "Input point outside viewport: " + key)
		return Vector2(-1, -1)
	return point

func _motion(point: Vector2, mask: int = 0) -> void:
	var transform: Transform2D = root.get_final_transform()
	var event := InputEventMouseMotion.new()
	event.position = transform * point
	event.global_position = event.position
	event.relative = transform * point - transform * _mouse
	event.button_mask = mask
	_mouse = point
	Input.parse_input_event(event)

func _button(point: Vector2, down: bool, button: int = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = root.get_final_transform() * point
	event.global_position = event.position
	event.button_index = button
	event.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if down and button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT] else 0
	event.pressed = down
	Input.parse_input_event(event)

func _key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		Input.parse_input_event(event)

func _state() -> Dictionary:
	return {"run_id": run_id, "workshop": workshop.snapshot(), "ui_controls": workshop.snapshot_controls()}

func _click(key: String) -> bool:
	var point: Vector2 = _point(key)
	if point.x < 0: return false
	_motion(point)
	await _frames(1)
	_button(point, true)
	await _frames(1)
	_button(point, false)
	await _frames(3)
	return true

func _frames(count: int = 2) -> void:
	for index in range(count): await process_frame

func _draw_frame(label: String) -> bool:
	await _frames()
	var receipt: Dictionary = {"drawn": false}
	var on_draw: Callable = func(): receipt.drawn = true
	RenderingServer.frame_post_draw.connect(on_draw, CONNECT_ONE_SHOT)
	workshop.queue_redraw()
	var deadline: int = Time.get_ticks_msec() + 5000
	var next_draw: int = Time.get_ticks_msec() + 100
	var forced_draws: int = 0
	while not receipt.drawn and Time.get_ticks_msec() < deadline:
		if Time.get_ticks_msec() >= next_draw and forced_draws < 20:
			forced_draws += 1
			next_draw = Time.get_ticks_msec() + 250
			RenderingServer.force_draw(false)
		if not receipt.drawn: await process_frame
	if RenderingServer.frame_post_draw.is_connected(on_draw): RenderingServer.frame_post_draw.disconnect(on_draw)
	if forced_draws > 0: trace.append({"step": "actual-draw-request", "label": label, "forced_draws": forced_draws, "frame_post_draw": receipt.drawn})
	return _check(receipt.drawn, "Visual evidence receives frame_post_draw: " + label)

func _capture(filename: String) -> void:
	if not await _draw_frame(filename): return
	var frame: Image = root.get_texture().get_image()
	if not _check(frame != null and not frame.is_empty(), "Workshop screenshot contains pixels: " + filename): return
	if not _check(frame.get_size() == root.size, "Workshop screenshot retains native window dimensions: " + filename): return
	if _check(frame.save_png(output_dir.path_join(filename)) == OK, "Workshop screenshot saved: " + filename):
		screenshots.append(filename)
		var sidecar := FileAccess.open(output_dir.path_join(filename + ".json"), FileAccess.WRITE)
		if not _check(sidecar != null, "Workshop screenshot sidecar opens: " + filename): return
		var configuration: Dictionary = {"profile_id": workshop.profile.profile_id, "render_mode": "material", "appearance_fingerprint": Fingerprint.of(workshop.profile), "geometry_id": workshop.geometry.geometry_id, "geometry_fingerprint": Fingerprint.of(workshop.geometry)}
		sidecar.store_string(JSON.stringify({"run_id": run_id, "component": "CardWorkshop", "configuration": configuration, "viewport": {"width": root.size.x, "height": root.size.y, "logical_width": root.get_visible_rect().size.x, "logical_height": root.get_visible_rect().size.y}, "state": _state()}, "\t"))
		sidecar.close()

func _record(label: String) -> void:
	trace.append({"step": label, "elapsed_ms": Time.get_ticks_msec(), "state": _state()})
	print(JSON.stringify({"event": "workshop_ui_step", "run_id": run_id, "step": label}))

func _check(condition: bool, label: String) -> bool:
	assertions += 1
	if not condition:
		failures.append(label)
		printerr("UI ASSERTION FAILED: " + label)
	return condition

func _finish() -> void:
	var result: Dictionary = {"run_id": run_id, "component": "CardWorkshop", "status": "passed" if failures.is_empty() else "failed", "assertions": assertions, "failures": failures, "trace": trace, "screenshots": screenshots, "renderer": DisplayServer.get_name()}
	var output := FileAccess.open(output_dir.path_join("workshop-ui-result.json"), FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print(JSON.stringify({"event": "workshop_ui_complete", "run_id": run_id, "status": result.status, "assertions": assertions}))
	quit(0 if failures.is_empty() else 1)
