extends RefCounted
const Store = preload("res://scripts/workshop/card_store.gd")
var checks: Array = []
func check(ok: bool, caption: String) -> void:
	checks.append({"ok": ok, "caption": caption})

func run(directory: String) -> Array:
	checks.clear()
	var store = Store.new()
	store.root_path = directory.path_join("collection")
	store.load_collection()
	var card: Dictionary = store.new_card()
	check(not store.validate(card).is_empty(), "Blank names cannot be saved")
	card.definition.name = "中文收藏卡牌测试"
	card.definition.attack = 99
	card.definition.max_hp = 99
	card.definition.deploy_cost = 0
	card.definition.action_cost = 12
	card.artwork.focus = [0.0, 1.0]
	card.artwork.zoom = 8.0
	card.artwork.source = "library:infantry-street-assault-v2"
	check(store.save_card(card).is_empty(), "Boundary values and crop are accepted for saving")
	for source in ["library:", "library:../outside", "image:123", "unknown"]:
		var invalid_art: Dictionary = card.duplicate(true)
		invalid_art.artwork.source = source
		check(not store.save_card(invalid_art).is_empty() and store.records[0] == card, "Invalid artwork reference rejected: " + source)
	for pair in [["attack", -1], ["attack", 100], ["max_hp", 0], ["deploy_cost", 13], ["action_cost", 1.5], ["name", "一".repeat(17)]]:
		var invalid: Dictionary = card.duplicate(true)
		invalid.definition[pair[0]] = pair[1]
		check(not store.save_card(invalid).is_empty() and store.records[0] == card, "Invalid field rejected without mutation: " + str(pair))
	store.root_path = directory.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(store.root_path)
	var corrupt := FileAccess.open(store.root_path.path_join("cards.json"), FileAccess.WRITE)
	corrupt.store_string("broken-json")
	corrupt.close()
	store.load_collection()
	check(not store.writable and not store.warnings.is_empty() and not store.save_card(card).is_empty(), "Corrupt collection cannot be overwritten")
	check(FileAccess.get_file_as_string(store.root_path.path_join("cards.json")) == "broken-json", "Corrupt source file remains intact")
	corrupt = FileAccess.open(store.root_path.path_join("cards.json"), FileAccess.WRITE)
	corrupt.store_string(JSON.stringify({"version": 2, "cards": [42, card]}))
	corrupt.close()
	store.load_collection()
	check(store.writable and store.records.size() == 2 and not store.warnings.is_empty(), "Invalid individual records are retained alongside valid cards")
	check(store.save_card(card).is_empty() and store.records[0] == 42, "Saving a valid card preserves corrupt records")
	store.root_path = directory.path_join("migration")
	DirAccess.make_dir_recursive_absolute(store.root_path)
	var legacy: Dictionary = card.duplicate(true)
	legacy.artwork = {"source": "infantry", "full_focus": [0.2, 0.8], "full_zoom": 2.0, "field_focus": [0.7, 0.1], "field_zoom": 4.0}
	var invalid_legacy: Dictionary = legacy.duplicate(true)
	invalid_legacy.id = "invalid-legacy"
	invalid_legacy.artwork.field_zoom = 0.0
	var legacy_text: String = JSON.stringify({"version": 1, "cards": [legacy, invalid_legacy, 42]}, "\t")
	# JSON decodes numbers as floats; compare retained records with that source representation.
	var original_invalid: Dictionary = JSON.parse_string(legacy_text).cards[1]
	var legacy_file := FileAccess.open(store.root_path.path_join("cards.json"), FileAccess.WRITE)
	legacy_file.store_string(legacy_text)
	legacy_file.close()
	store.load_collection()
	check(store.writable and store.records.size() == 3, "Version 1 JSON collection is accepted before migration checks")
	if store.records.size() != 3: return checks
	var migrated: Dictionary = store.records[0].duplicate(true)
	check(migrated.id == legacy.id and migrated.artwork == {"source": "infantry", "focus": [0.2, 0.8], "zoom": 2.0}, "Version 1 uses full-card crop and preserves legacy missing-image reference")
	check(store.records[1] == original_invalid and store.records[2] == 42, "Migration preserves invalid original records")
	check(FileAccess.get_file_as_string(store.root_path.path_join("cards.json")) == legacy_text and not FileAccess.file_exists(store.root_path.path_join("cards.v1.backup.json")), "Loading legacy collection does not rewrite or back it up")
	var backup_path: String = store.root_path.path_join("cards.v1.backup.json")
	DirAccess.make_dir_absolute(backup_path)
	check(not store.save_card(migrated).is_empty() and FileAccess.get_file_as_string(store.root_path.path_join("cards.json")) == legacy_text, "Backup failure blocks migration without changing the source")
	DirAccess.remove_absolute(backup_path)
	check(store.save_card(migrated).is_empty() and FileAccess.get_file_as_string(backup_path) == legacy_text, "First successful migration retains exact original backup")
	store.load_collection()
	check(store.records.size() == 3 and store.records[0] == migrated and store.records[1] == original_invalid and store.records[2] == 42, "Migrated collection reloads while keeping damaged records")
	migrated.definition.name = "迁移后编辑"
	check(store.save_card(migrated).is_empty() and FileAccess.get_file_as_string(backup_path) == legacy_text, "Later saves preserve the original migration backup")
	return checks
