extends RefCounted
## One writable library shared by the workshop and new battle sessions.
const Schema = preload("res://scripts/card_schema.gd")
const Catalog = preload("res://scripts/card_catalog.gd")
const TYPES = ["infantry", "tank", "artillery", "fighter", "bomber"]
const VERSION := 3
const LEGACY_BACKUP := "cards.pre-v3.backup.json"
var root_path: String = "user://card_workshop"
var records: Array = []
var warnings: Array[String] = []
var writable: bool = true
var load_error: String = ""
var _deck_ids: Array[String] = []
var _loaded: bool = false


func configure_from_args(args: PackedStringArray) -> void:
	var legacy_root: String = ""
	var library_root: String = ""
	for index in range(args.size() - 1):
		if args[index] == "--card-library-root": library_root = args[index + 1]
		elif args[index] == "--workshop-store": legacy_root = args[index + 1]
	if not library_root.is_empty(): root_path = library_root
	elif not legacy_root.is_empty(): root_path = legacy_root


func new_card() -> Dictionary:
	return {"id": Crypto.new().generate_random_bytes(16).hex_encode(), "definition": Schema.normalize_definition({"name": "", "unit_type": "infantry", "deploy_cost": 1, "action_cost": 1, "attack": 1, "max_hp": 1}), "artwork": {"source": "", "focus": [0.5, 0.5], "zoom": 1.0}}


func validate(card: Dictionary) -> String:
	if not card.get("id") is String or str(card.id).is_empty(): return "卡牌标识无效"
	if not card.get("definition") is Dictionary or not card.get("artwork") is Dictionary: return "卡牌记录损坏"
	var definition_error: String = Schema.validate_definition(card.definition)
	if not definition_error.is_empty(): return definition_error
	var artwork: Dictionary = card.artwork
	if not artwork.get("source") is String: return "卡图引用无效"
	var source: String = artwork.source
	var library_id: String = source.trim_prefix("library:")
	var library_valid: bool = source.begins_with("library:") and not library_id.is_empty()
	for character in library_id:
		if not character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-": library_valid = false
	if not source.is_empty() and not library_valid and not (source.begins_with("image:") and source.trim_prefix("image:").is_valid_hex_number(false) and source.length() == 38): return "卡图引用无效"
	var focus: Variant = artwork.get("focus")
	if not focus is Array or focus.size() != 2: return "取景位置无效"
	for value: Variant in focus:
		if not (value is int or value is float) or not is_finite(float(value)) or value < 0 or value > 1: return "取景位置无效"
	var zoom: Variant = artwork.get("zoom")
	if not (zoom is int or zoom is float) or not is_finite(float(zoom)) or zoom < 1 or zoom > 8: return "缩放无效"
	return ""


func load_collection() -> String:
	records.clear()
	_deck_ids.clear()
	warnings.clear()
	load_error = ""
	writable = true
	_loaded = false
	var path: String = root_path.path_join("cards.json")
	if not FileAccess.file_exists(path):
		var initialize_error: String = _initialize_factory()
		return _fail_load(initialize_error) if not initialize_error.is_empty() else ""
	var parser := JSON.new()
	var parse_error: Error = parser.parse(FileAccess.get_file_as_string(path))
	var parsed: Variant = parser.data if parse_error == OK else null
	if not parsed is Dictionary or not parsed.get("cards") is Array:
		return _fail_load("牌库文件无法读取，原文件已保留；本次禁止覆盖保存。")
	var raw_version: Variant = parsed.get("version")
	if not (raw_version is int or raw_version is float) or not is_finite(float(raw_version)) or float(raw_version) != floor(float(raw_version)):
		return _fail_load("牌库版本无效，原文件已保留。")
	var version: int = int(raw_version)
	if version in [1, 2]:
		var legacy_error: String = _validate_legacy(parsed.cards, version)
		if not legacy_error.is_empty(): return _fail_load(legacy_error + "；原文件已保留。")
		var backup_error: String = _backup_legacy(path)
		if not backup_error.is_empty(): return _fail_load(backup_error)
		var initialize_error: String = _initialize_factory()
		if not initialize_error.is_empty(): return _fail_load(initialize_error)
		warnings.append("旧卡牌已备份并清空，现已载入统一牌库。")
		return ""
	if version != VERSION or not parsed.get("preset_deck") is Array:
		return _fail_load("牌库版本或固定牌组无效，原文件已保留。")
	var next: Array = _normalize_records(parsed.cards)
	var validation_error: String = _validate_document(next, parsed.preset_deck)
	if not validation_error.is_empty(): return _fail_load(validation_error + "；原文件已保留。")
	records = next
	_deck_ids.assign(parsed.preset_deck)
	_loaded = true
	return ""


func _initialize_factory() -> String:
	var initial: Array = []
	for id: String in Catalog.CARDS:
		initial.append({"id": id, "definition": Schema.normalize_definition(Catalog.CARDS[id]), "artwork": {"source": "", "focus": [0.5, 0.5], "zoom": 1.0}})
	_deck_ids = Catalog.preset_deck()
	return _commit(initial)


func _backup_legacy(path: String) -> String:
	var original: PackedByteArray = FileAccess.get_file_as_bytes(path)
	var backup_path: String = root_path.path_join(LEGACY_BACKUP)
	if FileAccess.file_exists(backup_path):
		return "" if FileAccess.get_file_as_bytes(backup_path) == original else "旧牌库备份不匹配，原文件已保留。"
	var backup := FileAccess.open(backup_path, FileAccess.WRITE)
	if backup == null: return "无法备份旧牌库，原文件已保留。"
	backup.store_buffer(original)
	backup.flush()
	var status: Error = backup.get_error()
	backup.close()
	if status != OK or FileAccess.get_file_as_bytes(backup_path) != original: return "旧牌库备份失败，原文件已保留。"
	return ""


func _validate_legacy(values: Array, version: int) -> String:
	var ids: Dictionary = {}
	for original: Variant in values:
		if not original is Dictionary or not original.get("definition") is Dictionary or not original.get("artwork") is Dictionary: return "旧牌库记录损坏"
		var record: Dictionary = original.duplicate(true)
		if version == 1:
			record.artwork = {"source": original.artwork.get("source"), "focus": original.artwork.get("full_focus"), "zoom": original.artwork.get("full_zoom")}
		if record.artwork.get("source") in TYPES: record.artwork.source = ""
		var error: String = validate(record)
		if not error.is_empty(): return "旧牌库记录损坏：" + error
		if ids.has(record.id): return "旧牌库包含重复标识"
		ids[record.id] = true
		if version == 1:
			record.artwork.focus = original.artwork.get("field_focus")
			record.artwork.zoom = original.artwork.get("field_zoom")
			if not validate(record).is_empty(): return "旧牌库取景数据损坏"
	return ""


func _fail_load(message: String) -> String:
	load_error = message
	warnings.append(message)
	writable = false
	_loaded = false
	records.clear()
	_deck_ids.clear()
	return message


func _normalize_records(values: Array) -> Array:
	var result: Array = values.duplicate(true)
	for record: Variant in result:
		if record is Dictionary and record.get("definition") is Dictionary:
			record.definition = Schema.normalize_definition(record.definition)
	return result


func _validate_document(values: Array, deck: Array) -> String:
	var ids: Dictionary = {}
	for record: Variant in values:
		if not record is Dictionary: return "牌库记录损坏"
		var error: String = validate(record)
		if not error.is_empty(): return error
		if ids.has(record.id): return "牌库包含重复标识"
		ids[record.id] = true
	if deck.size() != 40: return "固定牌组必须恰好包含 40 张卡"
	for id: Variant in deck:
		if not id is String or not ids.has(id): return "固定牌组引用了不存在的卡牌"
	return ""


func definitions() -> Dictionary:
	var result: Dictionary = {}
	if not _loaded: return result
	for record: Dictionary in records:
		var definition: Dictionary = record.definition.duplicate(true)
		definition.artwork = record.artwork.duplicate(true)
		result[record.id] = definition
	return result


func preset_deck() -> Array[String]:
	return _deck_ids.duplicate()


func is_preset_card(id: String) -> bool:
	return _deck_ids.has(id)


func image_path(source: String) -> String:
	return root_path.path_join("images").path_join(source.trim_prefix("image:") + ".png")


func save_card(card: Dictionary, imported: Image = null) -> String:
	if not writable or not _loaded: return "牌库不可写，草稿已保留"
	var saved: Dictionary = card.duplicate(true)
	if saved.get("definition") is Dictionary: saved.definition = Schema.normalize_definition(saved.definition)
	var error: String = validate(saved)
	if not error.is_empty(): return error
	if imported != null:
		var image_id: String = Crypto.new().generate_random_bytes(16).hex_encode()
		saved.artwork.source = "image:" + image_id
		if DirAccess.make_dir_recursive_absolute(root_path.path_join("images")) != OK: return "无法创建图片目录"
		if imported.save_png(image_path(saved.artwork.source)) != OK: return "无法保存图片，草稿已保留"
	var next: Array = records.duplicate(true)
	var found: bool = false
	for index in range(next.size()):
		if next[index].id == saved.id:
			next[index] = saved
			found = true
			break
	if not found: next.append(saved)
	error = _commit(next)
	if error.is_empty(): card.assign(saved)
	elif imported != null: DirAccess.remove_absolute(image_path(saved.artwork.source))
	return error


func delete_card(id: String) -> String:
	if not writable or not _loaded: return "牌库不可写"
	if is_preset_card(id): return "该卡用于当前固定牌组，不能删除"
	var next: Array = records.filter(func(record: Variant): return record.id != id)
	return _commit(next)


func _commit(next: Array) -> String:
	if not writable: return "牌库不可写，草稿已保留"
	var validation_error: String = _validate_document(next, _deck_ids)
	if not validation_error.is_empty(): return validation_error
	if DirAccess.make_dir_recursive_absolute(root_path) != OK: return "无法创建牌库目录"
	var target: String = root_path.path_join("cards.json")
	var temporary: String = root_path.path_join("cards.json.tmp")
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return "无法写入牌库，草稿已保留"
	file.store_string(JSON.stringify({"version": VERSION, "cards": next, "preset_deck": _deck_ids}, "\t"))
	file.flush()
	var status: Error = file.get_error()
	file.close()
	if status != OK: return "牌库写入失败，原数据和草稿已保留"
	if DirAccess.rename_absolute(temporary, target) != OK: return "无法替换牌库文件，原数据和草稿已保留"
	records = next.duplicate(true)
	_loaded = true
	return ""
