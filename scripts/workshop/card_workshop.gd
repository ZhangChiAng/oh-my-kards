extends Control
signal closed
const Store = preload("res://scripts/workshop/card_store.gd")
const MetalConfirm = preload("res://scripts/workshop/metal_confirm.gd")
const InlineEditor = preload("res://scripts/workshop/inline_card_editor.gd")
const IllustrationThumbnail = preload("res://scripts/workshop/illustration_thumbnail.gd")
const CardView = preload("res://scripts/art/art_card.gd")
const Catalog = preload("res://scripts/card_catalog.gd")
const Schema = preload("res://scripts/card_schema.gd")
const ArtworkResolver = preload("res://scripts/art/card_artwork_resolver.gd")
const Crop = preload("res://scripts/art/artwork_crop.gd")
const UnitIcon = preload("res://scripts/art/unit_icon.gd")
const Profile = preload("res://resources/art/ancient_metal_profile.tres")
const Library = preload("res://resources/art/illustrations/library.tres")
const DefaultGeometry = preload("res://resources/art/battle_geometry.tres")
var store = Store.new()
var draft: Dictionary = {}
var baseline: Dictionary = {}
var imported: Image
var profile: Resource
var geometry: Resource = DefaultGeometry
var controls: Dictionary = {}
var _list: VBoxContainer
var _collection: ScrollContainer
var _gallery: ScrollContainer
var _gallery_grid: HFlowContainer
var _notice: Label
var _full: Control
var _field: Control
var _file: FileDialog
var _guard: MetalConfirm
var _delete: MetalConfirm
var _pending: Callable
var _cached_source: String = ""
var _cached_texture: Texture2D
var _editor: InlineEditor
var _edit_key := ""
var _edit_before: Variant
var _type_menu: PopupPanel
var _dragging := false
var _drag_start := Vector2.ZERO
var _drag_crop := Rect2()
var _scale := 1.0

func _ready() -> void:
	get_viewport().gui_embed_subwindows = true
	profile = Profile.duplicate(true)
	profile.artworks = Library.duplicate(true)
	var ui_theme := Theme.new()
	ui_theme.default_font = profile.visual_theme.surface.font
	ui_theme.default_font_size = 22
	for state in ["normal", "hover", "pressed", "disabled"]:
		ui_theme.set_stylebox(state, "Button", profile.visual_theme.style("end_turn_face" + ("" if state == "normal" else "_" + state)))
	ui_theme.set_color("font_color", "Button", profile.visual_theme.color("control_text"))
	self.theme = ui_theme
	var background := TextureRect.new()
	background.texture = profile.visual_theme.background_texture
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_button(self, "new", "＋ 新建卡牌", func(): _request(func(): _load(store.new_card())))
	_collection = ScrollContainer.new()
	_collection.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_collection)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	_collection.add_child(_list)
	_full = CardView.new()
	_field = CardView.new()
	add_child(_full)
	add_child(_field)
	var art := Control.new()
	art.mouse_default_cursor_shape = Control.CURSOR_DRAG
	art.gui_input.connect(_art_input)
	add_child(art)
	controls.artwork = art
	for key in ["name", "deploy_cost", "action_cost", "attack", "max_hp", "unit_type"]:
		var hit := _button(self, key, "", func(): _choose_type() if key == "unit_type" else _begin_edit(key))
		hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if key == "unit_type" else Control.CURSOR_IBEAM
		for state in ["normal", "hover", "pressed", "disabled", "focus"]: hit.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	_button(self, "save", "保存", _save)
	var delete_button := _button(self, "delete", "删除", func(): _delete.popup_centered())
	delete_button.modulate.a = 0.72
	var close_button := _button(self, "close", "", request_close)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var suffix: String = "" if state == "normal" else "_hover" if state == "focus" else "_" + state
		close_button.add_theme_stylebox_override(state, profile.visual_theme.style("settings" + suffix))
	close_button.tooltip_text = "返回主界面"
	var close_icon := Control.new()
	close_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_icon.modulate = profile.visual_theme.color("control_danger")
	close_button.add_child(close_icon)
	close_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	close_icon.draw.connect(func(): close_icon.draw_style_box(profile.visual_theme.style("close_icon"), Rect2(close_icon.size * 0.08, close_icon.size * 0.84)))
	close_icon.resized.connect(close_icon.queue_redraw)
	_gallery = ScrollContainer.new()
	_gallery.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_gallery)
	_gallery_grid = HFlowContainer.new()
	_gallery_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gallery.add_child(_gallery_grid)
	for entry in profile.artworks.entries():
		var thumbnail := IllustrationThumbnail.new()
		thumbnail.texture = entry.texture
		thumbnail.visual_theme = profile.visual_theme
		thumbnail.toggle_mode = true
		thumbnail.custom_minimum_size = Vector2(172, 144)
		thumbnail.pressed.connect(func(): _select_art(entry.source))
		controls["art:" + entry.id] = thumbnail
		_gallery_grid.add_child(thumbnail)
	_button(self, "import", "从本地导入", _open_file)
	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_notice)
	_editor = InlineEditor.new()
	add_child(_editor)
	_editor.hide()
	_editor.text_changed.connect(_editor_changed)
	_editor.text_submitted.connect(func(_value): _end_edit())
	_editor.gui_input.connect(func(event):
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and not _editor.is_composing():
			_end_edit(true)
			get_viewport().set_input_as_handled())
	_editor.focus_exited.connect(func(): _end_edit())
	_type_menu = PopupPanel.new()
	add_child(_type_menu)
	var kinds := VBoxContainer.new()
	_type_menu.add_child(kinds)
	for kind in Store.TYPES:
		var option := _button(kinds, "type:" + kind, "      " + Catalog.type_name(kind), func():
			draft.definition.unit_type = kind
			_type_menu.hide()
			_preview())
		option.custom_minimum_size = Vector2(220, 48)
		option.draw.connect(func(): UnitIcon.draw(option, kind, Rect2(12, 8, 30, 30), profile.visual_theme.color("control_text")))
	_file = FileDialog.new()
	_file.use_native_dialog = false
	_file.access = FileDialog.ACCESS_FILESYSTEM
	_file.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp ; 图片"])
	add_child(_file)
	_file.file_selected.connect(_import_image)
	_guard = MetalConfirm.new()
	_guard.configure(profile, "guard")
	add_child(_guard)
	controls.guard_save = _guard.buttons.confirm
	controls.guard_cancel = _guard.buttons.cancel
	controls.guard_discard = _guard.buttons.discard
	_guard.confirmed.connect(func():
		if _save():
			_guard.dismiss()
			_run_pending()
		else:
			_guard.show_error(_notice.text)
			_notice.text = "")
	_guard.discarded.connect(func():
		_guard.dismiss()
		_load(baseline if baseline.has("definition") else store.new_card())
		_run_pending())
	_guard.canceled.connect(func(): _pending = Callable())
	_delete = MetalConfirm.new()
	_delete.configure(profile, "delete")
	add_child(_delete)
	controls.delete_confirm = _delete.buttons.confirm
	controls.delete_cancel = _delete.buttons.cancel
	controls.file_cancel = _file.get_cancel_button()
	controls.file_path = _file.get_line_edit()
	controls.file_open = _file.get_ok_button()
	_delete.confirmed.connect(_delete_card)
	resized.connect(_adapt_layout)
	get_window().focus_exited.connect(func():
		_dragging = false
		_end_edit())
	_adapt_layout.call_deferred()
	hide()

func _button(parent: Node, key: String, caption: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size.y = 44
	parent.add_child(button)
	button.pressed.connect(action)
	controls[key] = button
	return button

func _place(control: Control, rect: Rect2) -> void:
	control.position = rect.position
	control.size = rect.size

func _adapt_layout() -> void:
	_dragging = false
	_end_edit()
	if not is_instance_valid(_full): return
	var margin := 28.0
	var left := clampf(size.x * 0.18, 230, 340)
	var right := maxf(340, (size.x - left) * 0.40)
	var center := size.x - left - right - margin * 4
	_place(controls.new, Rect2(margin, margin, left, 54))
	_place(_collection, Rect2(margin, 96, left, maxf(0, size.y - 124)))
	var pixel_scale := maxf(get_viewport().get_final_transform().x.length(), 0.01)
	var button_scale := clampf(float(get_window().size.y) / 1080.0, 0.82, 1.25) / pixel_scale
	var close_size := 56.0 * button_scale
	_place(controls.close, Rect2(size.x - 24.0 * button_scale - close_size, 18.0 * button_scale, close_size, close_size))
	_scale = minf(center / geometry.template("full").size.x, (size.y - 130) / geometry.template("full").size.y)
	var full_size: Vector2 = geometry.template("full").size * _scale
	_full.position = Vector2(left + margin * 2 + (center - full_size.x) / 2, (size.y - full_size.y - 74) / 2)
	_full.scale = Vector2.ONE * _scale
	var field_scale: float = minf((right - 60) / 90, (size.y * 0.55 - 35) / 123)
	_field.scale = Vector2.ONE * field_scale
	var rx := size.x - right - margin
	_field.position = Vector2(rx + (right - 90 * field_scale) / 2, 46)
	_field.position.x = minf(_field.position.x, controls.close.position.x - 90 * field_scale - 16 * button_scale)
	_place(controls.save, Rect2(_full.position.x, _full.position.y + full_size.y + 18, full_size.x * 0.62 - 6, 48))
	_place(controls.delete, Rect2(_full.position.x + full_size.x * 0.62 + 6, _full.position.y + full_size.y + 18, full_size.x * 0.38 - 6, 48))
	var gy: float = _field.position.y + 123 * field_scale + 30 if _field.visible else 96.0
	_place(_gallery, Rect2(rx, gy, right, maxf(80, size.y - gy - 100)))
	_place(controls.import, Rect2(rx, size.y - 68, right, 44))
	_place(_notice, Rect2(left + margin * 2, size.y - 30, center, 28))
	var template: Resource = geometry.template("full")
	_place(controls.artwork, Rect2(_full.position + template.artwork_rect.position * _scale, template.artwork_rect.size * _scale))
	for key in ["name", "deploy_cost", "action_cost", "attack", "max_hp", "unit_type"]:
		var slot: String = {"max_hp": "health", "unit_type": "type_icon_box"}.get(key, key)
		var rect: Rect2 = template.slots[slot]
		controls[key].custom_minimum_size = Vector2.ZERO
		_place(controls[key], Rect2(_full.position + rect.position * _scale, rect.size * _scale))

func open() -> void:
	store.load_collection()
	show()
	_refresh_list()
	_load(store.new_card())
	_notice.text = "；".join(store.warnings)

func dirty() -> bool:
	return draft != baseline or imported != null

func _request(action: Callable) -> void:
	_end_edit()
	if dirty():
		_pending = action
		_dragging = false
		_type_menu.hide()
		_guard.popup_centered()
	else: action.call()

func request_close() -> void:
	if _file.visible or _guard.visible or _delete.visible: return
	_request(_close)

func _run_pending() -> void:
	var action: Callable = _pending
	_pending = Callable()
	if action.is_valid(): action.call()

func _close() -> void:
	hide()
	closed.emit()

func _load(card: Dictionary) -> void:
	_end_edit()
	draft = card.duplicate(true)
	baseline = draft.duplicate(true)
	imported = null
	_cached_source = ""
	_cached_texture = null
	_notice.text = ""
	_preview()
	_adapt_layout()
	_scroll_to_selected.call_deferred()

func _input(event: InputEvent) -> void:
	if not visible or _edit_key.is_empty(): return
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		if not _editor.get_global_rect().has_point(event.position):
			_end_edit()

func _begin_edit(key: String) -> void:
	if draft.get("definition", {}).get("card_type", "unit") == "order" and key not in ["name", "deploy_cost"]: return
	_end_edit()
	_edit_key = key
	_edit_before = draft.definition[key]
	_editor.max_length = 16 if key == "name" else 2
	_editor.text = str(_edit_before)
	var slot := "health" if key == "max_hp" else key
	_editor.configure(profile.visual_theme, geometry.template("full"), slot, key != "name", key == "name")
	_editor.position = controls[key].position
	_editor.size = geometry.template("full").slots[slot].size
	_editor.scale = Vector2.ONE * _scale
	_editor.show()
	_editor.grab_focus()
	_editor.select_all()
	_preview()

func _editor_changed(value: String) -> void:
	if _edit_key.is_empty(): return
	if _edit_key == "name": draft.definition[_edit_key] = value
	elif value.is_valid_int():
		var low := 1 if _edit_key == "max_hp" else 0
		var high := 12 if _edit_key.ends_with("cost") else 99
		draft.definition[_edit_key] = clampi(int(value), low, high)
	_preview()

func _end_edit(cancel: bool = false) -> void:
	if _edit_key.is_empty(): return
	if cancel: draft.definition[_edit_key] = _edit_before
	else:
		if _editor.is_composing(): _editor.apply_ime()
		_editor_changed(_editor.text)
	_edit_key = ""
	_editor.release_focus()
	_editor.hide()
	_preview()

func _choose_type() -> void:
	if draft.get("definition", {}).get("card_type", "unit") == "order": return
	_end_edit()
	_type_menu.popup(Rect2i(Vector2i(controls.unit_type.global_position), Vector2i(220, 260)))

func _select_art(source: String) -> void:
	imported = null
	_cached_source = ""
	draft.artwork = {"source": source, "focus": [0.5, 0.5], "zoom": 1.0}
	_preview()

func _preview() -> void:
	if draft.is_empty(): return
	var source: String = draft.artwork.source
	if _cached_source != source:
		_cached_source = source
		_cached_texture = null
		if source.begins_with("image:"):
			_cached_texture = ImageTexture.create_from_image(imported) if imported != null else ArtworkResolver.resolve_source(source, store.root_path.path_join("images"))
			profile.artworks.register_texture(source, _cached_texture)
		else: _cached_texture = ArtworkResolver.resolve_source(source, store.root_path.path_join("images"))
	if not source.is_empty() and _cached_texture == null:
		_notice.text = "卡图缺失，请重新选择插画。"
	elif _notice.text == "卡图缺失，请重新选择插画。":
		_notice.text = ""
	var data: Dictionary = draft.definition.duplicate(true)
	var order: bool = data.get("card_type", "unit") == "order"
	data.card_id = draft.id
	if not order: data.hp = data.max_hp
	data.wrap_name = true
	data.artwork = draft.artwork.duplicate(true)
	data.ability_text = Schema.ability_text(data)
	data.detail_text = Schema.detail_text(data)
	var badges: Array[String] = Schema.keyword_badges(data)
	for ability: Dictionary in data.get("abilities", []):
		var badge: String = {"deploy": "部署", "aftermath": "余波"}.get(ability.get("trigger", ""), "")
		if not badge.is_empty() and not badges.has(badge): badges.append(badge)
	if not data.get("auras", []).is_empty(): badges.append("协同")
	data.keyword_text = " · ".join(badges)
	data.type_name = "指令" if order else Catalog.type_name(str(data.unit_type))
	_field.visible = not order
	if not order: _field.configure(data, "field", profile, geometry.template("field"))
	for key in ["action_cost", "attack", "max_hp", "unit_type"]: controls[key].visible = not order
	data.editing_slot = "health" if _edit_key == "max_hp" else _edit_key
	_full.configure(data, "full", profile, geometry.template("full"))
	_full.pivot_offset = Vector2.ZERO
	_field.pivot_offset = Vector2.ZERO
	controls.unit_type.tooltip_text = "" if order else Catalog.type_name(draft.definition.unit_type)
	controls.save.disabled = not store.writable or not store.validate(draft).is_empty()
	var preset: bool = store.is_preset_card(str(draft.id))
	controls.delete.disabled = preset or not store.writable or not store.records.any(func(record: Variant): return record is Dictionary and record.get("id") == draft.id)
	controls.delete.tooltip_text = "该卡用于当前固定牌组，不能删除" if preset else ""
	for key in controls:
		if str(key).begins_with("card:"): controls[key].set_pressed_no_signal(str(key) == "card:" + str(draft.id))
		if str(key).begins_with("art:"):
			controls[key].set_pressed_no_signal(source == "library:" + str(key).trim_prefix("art:"))
			controls[key].queue_redraw()

func _art_input(event: InputEvent) -> void:
	if _cached_texture == null: return
	var area: Control = controls.artwork
	var extent := Vector2(_cached_texture.get_size())
	var focus := Vector2(draft.artwork.focus[0], draft.artwork.focus[1])
	var crop: Rect2 = Crop.source_rect(extent, area.size, focus, draft.artwork.zoom)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_end_edit()
			_dragging = event.pressed
			_drag_start = event.position
			_drag_crop = crop
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var uv: Vector2 = event.position / area.size
			var anchor: Vector2 = crop.position + uv * crop.size
			draft.artwork.zoom = clampf(draft.artwork.zoom * (1.12 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12), 1, 8)
			var next: Rect2 = Crop.source_rect(extent, area.size, focus, draft.artwork.zoom)
			var origin: Vector2 = (anchor - uv * next.size).clamp(Vector2.ZERO, extent - next.size)
			var center: Vector2 = (origin + next.size / 2) / extent
			draft.artwork.focus = [center.x, center.y]
			_preview()
	elif event is InputEventMouseMotion and _dragging:
		var origin: Vector2 = (_drag_crop.position - (event.position - _drag_start) / area.size * _drag_crop.size).clamp(Vector2.ZERO, extent - _drag_crop.size)
		var center: Vector2 = (origin + _drag_crop.size / 2) / extent
		draft.artwork.focus = [center.x, center.y]
		_preview()
	area.accept_event()

func _refresh_list() -> void:
	for key in controls.keys():
		if str(key).begins_with("card:"): controls.erase(key)
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	for record: Variant in store.records:
		if not record is Dictionary or not store.validate(record).is_empty():
			var warning := Label.new()
			warning.text = "损坏记录（已保留）"
			_list.add_child(warning)
			continue
		var button := _button(_list, "card:" + str(record.id), str(record.definition.name), func(): _request(func(): _load_saved(record.id)))
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.clip_text = true
		button.toggle_mode = true
		button.custom_minimum_size.y = 56

func _load_saved(id: String) -> void:
	for record: Variant in store.records:
		if record is Dictionary and record.get("id") == id:
			_load(record)
			return

func _scroll_to_selected() -> void:
	var selected: Control = controls.get("card:" + str(draft.get("id", "")))
	if is_instance_valid(selected): _collection.ensure_control_visible(selected)

func _save() -> bool:
	_end_edit()
	var error: String = store.save_card(draft, imported)
	if not error.is_empty():
		_notice.text = error
		return false
	imported = null
	_cached_source = ""
	baseline = draft.duplicate(true)
	_refresh_list()
	_preview()
	_scroll_to_selected.call_deferred()
	_notice.text = ""
	return true

func _delete_card() -> void:
	var error: String = store.delete_card(draft.id)
	if not error.is_empty():
		_notice.text = error
		_delete.show_error(error)
		_notice.text = ""
		return
	_delete.dismiss()
	_refresh_list()
	_load(store.new_card())

func _open_file() -> void:
	_end_edit()
	_file.popup_centered_ratio(0.75)

func _import_image(path: String) -> void:
	if not path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
		_notice.text = "请选择 PNG、JPEG 或 WebP 图片"
		return
	var source_file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if source_file == null:
		_notice.text = "图片无法读取，原卡图已保留"
		return
	var header: PackedByteArray = source_file.get_buffer(12)
	source_file.close()
	var recognized: bool = header.size() >= 12 and (header.slice(0, 8).hex_encode() == "89504e470d0a1a0a" or header.slice(0, 2).hex_encode() == "ffd8" or (header.slice(0, 4).get_string_from_ascii() == "RIFF" and header.slice(8, 12).get_string_from_ascii() == "WEBP"))
	if not recognized:
		_notice.text = "图片无法读取，原卡图已保留"
		return
	var candidate := Image.new()
	if candidate.load(path) != OK or candidate.is_empty():
		_notice.text = "图片无法读取，原卡图已保留"
		return
	if candidate.get_width() > 8192 or candidate.get_height() > 8192:
		_notice.text = "图片边长请勿超过 8192 像素"
		return
	imported = candidate
	_cached_source = ""
	draft.artwork.source = "image:" + "0".repeat(32)
	draft.artwork.focus = [0.5, 0.5]
	draft.artwork.zoom = 1.0
	_preview()

func snapshot() -> Dictionary:
	return {"open": visible, "dirty": dirty(), "selected_id": draft.get("id", ""), "count": store.records.size(), "draft": draft.duplicate(true) if visible else {}, "notice": _notice.text, "dialog_open": _file.visible or _guard.visible or _delete.visible}

func snapshot_controls() -> Dictionary:
	var result: Dictionary = {}
	if not visible: return result
	for key in controls:
		var control: Control = controls[key]
		if not control.is_visible_in_tree(): continue
		var rect: Rect2 = control.get_global_rect()
		var ancestor: Node = control.get_parent()
		var hidden: bool = false
		while ancestor != self:
			if ancestor is Window:
				rect.position += Vector2(ancestor.position)
				if not ancestor.visible: hidden = true
			if ancestor is ScrollContainer: rect = rect.intersection(ancestor.get_global_rect())
			ancestor = ancestor.get_parent()
		if hidden: continue
		rect = rect.intersection(get_global_rect())
		if not rect.has_area(): continue
		var point: Vector2 = rect.get_center()
		var modal: Node = _guard if _guard.visible else _delete if _delete.visible else _file if _file.visible else null
		var enabled: bool = not (control is BaseButton and control.disabled) and (modal == null or modal.is_ancestor_of(control))
		result["workshop:" + str(key)] = {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y, "hit_point": {"x": point.x, "y": point.y}, "rotation": 0, "enabled": enabled, "draggable": false, "drop_enabled": false}
	return result
