extends PanelContainer
signal closed
const Store = preload("res://scripts/workshop/card_store.gd")
const CardView = preload("res://scripts/art/art_card.gd")
const Catalog = preload("res://scripts/card_catalog.gd")
const DisplayProfile = preload("res://scripts/art/display_profile.gd")
const ImagePreview = preload("res://scripts/workshop/image_preview.gd")
const DefaultGeometry = preload("res://resources/art/battle_geometry.tres")
var store = Store.new()
var draft: Dictionary = {}
var baseline: Dictionary = {}
var imported: Image
var profile: Resource
var geometry: Resource = DefaultGeometry
var controls: Dictionary = {}
var _list: VBoxContainer
var _notice: Label
var _full: Control
var _field: Control
var _file: FileDialog
var _guard: ConfirmationDialog
var _delete: ConfirmationDialog
var _pending: Callable
var _loading: bool = false
var _cached_source: String = ""
var _cached_texture: Texture2D
var _ui_scale: float = 1.0
var _panes: Array[Control] = []
var _holders: Array[Control] = []
var _images: Dictionary = {}

func _ready() -> void:
	get_viewport().gui_embed_subwindows = true
	z_index = 500
	mouse_filter = Control.MOUSE_FILTER_STOP
	profile = DisplayProfile.geometry_only()
	var theme := Theme.new()
	theme.default_font = profile.visual_theme.surface.font
	theme.default_font_size = 20
	self.theme = theme
	add_theme_stylebox_override("panel", profile.visual_theme.style("well"))
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, 20)
	add_child(margin)
	var outer := VBoxContainer.new()
	margin.add_child(outer)
	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := Label.new()
	title.text = "卡牌 DIY 工具台 · 本地收藏"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_button(header, "close", "关闭工具台", func(): _request(_close))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var columns := HFlowContainer.new()
	columns.add_theme_constant_override("separation", 24)
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(columns)
	_list = _pane(columns, 230)
	var edit: VBoxContainer = _pane(columns, 360)
	_label(edit, "卡牌资料")
	var name_edit := LineEdit.new()
	name_edit.max_length = 16
	name_edit.placeholder_text = "名称（1–16 字）"
	edit.add_child(name_edit)
	controls.name = name_edit
	name_edit.text_changed.connect(func(value: String):
		if not _loading:
			draft.definition.name = value
			_preview())
	var kind := OptionButton.new()
	for key in Store.TYPES: kind.add_item(Catalog.type_name(key))
	edit.add_child(kind)
	controls.unit_type = kind
	kind.item_selected.connect(func(index: int):
		if not _loading:
			draft.definition.unit_type = Store.TYPES[index]
			_preview())
	var grid := GridContainer.new()
	grid.columns = 2
	edit.add_child(grid)
	for key in ["deploy_cost", "action_cost", "attack", "max_hp"]:
		_label(grid, {"deploy_cost": "部署费用", "action_cost": "行动费用", "attack": "攻击", "max_hp": "生命"}[key])
		var spin := SpinBox.new()
		spin.min_value = 1 if key == "max_hp" else 0
		spin.max_value = 12 if key.ends_with("cost") else 99
		spin.step = 1
		spin.custom_minimum_size.x = 145
		grid.add_child(spin)
		controls[key] = spin
		spin.value_changed.connect(func(value: float):
			if not _loading:
				draft.definition[key] = int(value)
				_preview())
	_label(edit, "卡图")
	_label(edit, "无内置插画；可导入本地图片")
	_button(edit, "import", "导入本地图片…", _open_file)
	for mode in ["full", "field"]:
		_label(edit, "完整卡取景" if mode == "full" else "场上卡取景")
		for axis in ["x", "y", "zoom"]:
			var row := HBoxContainer.new()
			edit.add_child(row)
			_label(row, {"x": "水平", "y": "垂直", "zoom": "缩放"}[axis])
			var slider := HSlider.new()
			slider.min_value = 1 if axis == "zoom" else 0
			slider.max_value = 8 if axis == "zoom" else 1
			slider.step = 0.01
			slider.custom_minimum_size.x = 230
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(slider)
			controls[mode + "_" + axis] = slider
			slider.value_changed.connect(func(value: float):
				if _loading: return
				if axis == "zoom": draft.artwork[mode + "_zoom"] = value
				else: draft.artwork[mode + "_focus"][0 if axis == "x" else 1] = value
				_preview())
		_button(edit, mode + "_reset", "重置取景", func():
			draft.artwork[mode + "_focus"] = [0.5, 0.5]
			draft.artwork[mode + "_zoom"] = 1.0
			_fill())
	var actions := HBoxContainer.new()
	edit.add_child(actions)
	_button(actions, "save", "保存", _save)
	_button(actions, "duplicate", "复制", func(): _request(_duplicate))
	_button(actions, "delete", "删除", func(): _delete.popup_centered())
	edit.move_child(actions, 1)
	var previews: VBoxContainer = _pane(columns, 530)
	_label(previews, "实时预览")
	var preview_row := HBoxContainer.new()
	preview_row.add_theme_constant_override("separation", 18)
	previews.add_child(preview_row)
	for mode in ["full", "field"]:
		var preview_column := VBoxContainer.new()
		preview_row.add_child(preview_column)
		_label(preview_column, "完整卡" if mode == "full" else "场上卡")
		var holder := Control.new()
		holder.custom_minimum_size = geometry.template(mode).size * (2.5 if mode == "full" else 2.0)
		preview_column.add_child(holder)
		_holders.append(holder)
		var card := CardView.new()
		holder.add_child(card)
		if mode == "full": _full = card
		else: _field = card
		_label(preview_column, "本地图片取景")
		var image_preview := ImagePreview.new()
		image_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
		image_preview.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		image_preview.custom_minimum_size = geometry.template(mode).artwork_rect.size * 2.0
		preview_column.add_child(image_preview)
		_images[mode] = image_preview
	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.custom_minimum_size.y = 30
	outer.add_child(_notice)
	_file = FileDialog.new()
	_file.use_native_dialog = false
	_file.access = FileDialog.ACCESS_FILESYSTEM
	_file.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp ; 图片"])
	add_child(_file)
	_file.file_selected.connect(_import_image)
	_guard = ConfirmationDialog.new()
	_guard.dialog_text = "当前卡牌有未保存修改。"
	_guard.ok_button_text = "保存"
	_guard.cancel_button_text = "取消"
	controls.guard_discard = _guard.add_button("放弃修改", false, "discard")
	add_child(_guard)
	controls.guard_save = _guard.get_ok_button()
	controls.guard_cancel = _guard.get_cancel_button()
	_guard.confirmed.connect(func():
		if _save(): _run_pending())
	_guard.custom_action.connect(func(action: StringName):
		if action == "discard":
			_guard.hide()
			_load(baseline if baseline.has("definition") else store.new_card())
			_run_pending())
	_delete = ConfirmationDialog.new()
	_delete.dialog_text = "删除这张收藏卡？"
	_delete.ok_button_text = "删除"
	_delete.cancel_button_text = "取消"
	add_child(_delete)
	controls.delete_confirm = _delete.get_ok_button()
	controls.delete_cancel = _delete.get_cancel_button()
	controls.file_cancel = _file.get_cancel_button()
	controls.file_path = _file.get_line_edit()
	controls.file_open = _file.get_ok_button()
	_delete.confirmed.connect(_delete_card)
	get_window().size_changed.connect(_adapt_layout)
	_adapt_layout()
	hide()

func _pane(parent: Node, width: float) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.set_meta("base_width", width)
	var style := StyleBoxFlat.new()
	style.bg_color = Color.BLACK
	style.border_color = Color.WHITE
	style.set_border_width_all(1)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	_panes.append(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)
	return column

func _adapt_layout() -> void:
	_ui_scale = maxf(1.25, 1.0 / maxf(get_viewport().get_final_transform().x.length(), 0.1))
	theme.default_font_size = roundi(20 * _ui_scale)
	for pane in _panes: pane.custom_minimum_size.x = float(pane.get_meta("base_width")) * _ui_scale
	for key in controls:
		var control: Control = controls[key]
		if control is Button: control.custom_minimum_size.y = 36 * _ui_scale
		if control is SpinBox: control.custom_minimum_size.x = 145 * _ui_scale
	for mode in ["full", "field"]:
		for axis in ["x", "y", "zoom"]: controls[mode + "_" + axis].custom_minimum_size.x = 180 * _ui_scale
	for index in range(_holders.size()):
		_holders[index].custom_minimum_size = geometry.template("full" if index == 0 else "field").size * (2.5 if index == 0 else 2.0) * _ui_scale
	if not draft.is_empty(): _preview()

func _label(parent: Node, text: String) -> void:
	var label := Label.new()
	label.text = text
	parent.add_child(label)

func _button(parent: Node, key: String, caption: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size.y = 36
	parent.add_child(button)
	button.pressed.connect(action)
	controls[key] = button
	return button

func open() -> void:
	store.load_collection()
	show()
	_refresh_list()
	_load(store.new_card())
	_notice.text = "；".join(store.warnings)

func dirty() -> bool:
	return draft != baseline or imported != null

func _request(action: Callable) -> void:
	if dirty():
		_pending = action
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
	draft = card.duplicate(true)
	baseline = draft.duplicate(true)
	imported = null
	_cached_source = ""
	_cached_texture = null
	_fill()

func _fill() -> void:
	_loading = true
	controls.name.text = draft.definition.name
	controls.unit_type.select(Store.TYPES.find(draft.definition.unit_type))
	for key in ["deploy_cost", "action_cost", "attack", "max_hp"]: controls[key].value = draft.definition[key]
	for mode in ["full", "field"]:
		controls[mode + "_x"].value = draft.artwork[mode + "_focus"][0]
		controls[mode + "_y"].value = draft.artwork[mode + "_focus"][1]
		controls[mode + "_zoom"].value = draft.artwork[mode + "_zoom"]
	_loading = false
	_preview()

func _preview() -> void:
	var source: String = draft.artwork.source
	var missing: bool = false
	if _cached_source != source:
		_cached_source = source
		_cached_texture = null
		if source.begins_with("image:"):
			var img: Image = imported
			if img == null: img = Image.load_from_file(store.image_path(source)) if FileAccess.file_exists(store.image_path(source)) else null
			if img != null and not img.is_empty(): _cached_texture = ImageTexture.create_from_image(img)
	missing = source.begins_with("image:") and _cached_texture == null
	for mode in ["full", "field"]:
		var focus: Array = draft.artwork[mode + "_focus"]
		_images[mode].configure(_cached_texture, Vector2(focus[0], focus[1]), draft.artwork[mode + "_zoom"])
	var data: Dictionary = draft.definition.duplicate(true)
	data.card_id = draft.id
	data.hp = data.max_hp
	data.type_name = Catalog.type_name(data.unit_type)
	data.rule_text = ""
	data.wrap_name = true
	_full.configure(data, "full", profile, geometry.template("full"))
	_full.pivot_offset = Vector2.ZERO
	_full.scale = Vector2.ONE * 2.5 * _ui_scale
	_field.configure(data, "field", profile, geometry.template("field"))
	_field.pivot_offset = Vector2.ZERO
	_field.scale = Vector2.ONE * 2.0 * _ui_scale
	controls.save.disabled = not store.writable or not store.validate(draft).is_empty()
	controls.delete.disabled = not store.writable or not store.records.any(func(record: Variant): return record is Dictionary and record.get("id") == draft.id)
	for key in controls:
		if str(key).begins_with("card:"): controls[key].set_pressed_no_signal(str(key) == "card:" + str(draft.id))
	var status: String = "卡图缺失，请重新选择图片。" if missing else ("未保存修改" if dirty() else "已保存" if not controls.delete.disabled else "填写资料后保存到本地收藏")
	_notice.text = "；".join(store.warnings + [status])

func _refresh_list() -> void:
	for key in controls.keys():
		if str(key).begins_with("card:"): controls.erase(key)
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_button(_list, "new", "＋ 新建卡牌", func(): _request(func(): _load(store.new_card())))
	if store.records.is_empty(): _label(_list, "暂无收藏")
	for record: Variant in store.records:
		if not record is Dictionary or not store.validate(record).is_empty():
			_label(_list, "损坏记录（已保留）")
			continue
		var button: Button = _button(_list, "card:" + str(record.id), str(record.definition.name), func(): _request(func(): _load(record)))
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.clip_text = true
		button.toggle_mode = true
		button.custom_minimum_size.y = 36 * _ui_scale
		button.tooltip_text = str(record.definition.name)

func _save() -> bool:
	# Commit a SpinBox's focused text before saving.
	for key in ["deploy_cost", "action_cost", "attack", "max_hp"]: controls[key].apply()
	var error: String = store.save_card(draft, imported)
	if not error.is_empty():
		_notice.text = error
		return false
	imported = null
	baseline = draft.duplicate(true)
	_refresh_list()
	_preview()
	return true

func _duplicate() -> void:
	draft = draft.duplicate(true)
	draft.id = store.new_card().id
	baseline = {}
	_fill()

func _delete_card() -> void:
	var error: String = store.delete_card(draft.id)
	if not error.is_empty():
		_notice.text = error
		return
	_refresh_list()
	_load(store.new_card())

func _open_file() -> void:
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
	_fill()

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
		var modal: Window = _guard if _guard.visible else _delete if _delete.visible else _file if _file.visible else null
		var enabled: bool = not (control is BaseButton and control.disabled) and (modal == null or control.get_window() == modal)
		result["workshop:" + str(key)] = {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y, "hit_point": {"x": point.x, "y": point.y}, "rotation": 0, "enabled": enabled, "draggable": false, "drop_enabled": false}
	return result
