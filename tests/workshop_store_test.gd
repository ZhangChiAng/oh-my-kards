extends RefCounted
const Store = preload("res://scripts/workshop/card_store.gd")
const Catalog = preload("res://scripts/card_catalog.gd")
const Schema = preload("res://scripts/card_schema.gd")
const ArtworkResolver = preload("res://scripts/art/card_artwork_resolver.gd")
var checks: Array = []


func check(ok: bool, caption: String) -> void:
	checks.append({"ok": ok, "caption": caption})


func run(directory: String) -> Array:
	checks.clear()
	var store = Store.new()
	store.configure_from_args(PackedStringArray(["--card-library-root", directory.path_join("collection"), "--workshop-store", directory.path_join("must-not-create")]))
	check(store.root_path == directory.path_join("collection"), "Shared library override takes priority over legacy workshop override")
	check(store.load_collection().is_empty() and store.records.size() == 20 and store.preset_deck().size() == 40, "Fresh library seeds twenty definitions and forty cards")
	check(not DirAccess.dir_exists_absolute(directory.path_join("must-not-create")), "Unused legacy override is never initialized")
	var composition: Dictionary = {}
	for id: String in store.preset_deck(): composition[id] = int(composition.get(id, 0)) + 1
	check(composition.size() == 20 and composition.values().all(func(count: Variant): return count == 2), "Every initial definition appears twice")
	check(store.records.all(func(record: Variant): return record.artwork.source.is_empty()), "All twenty initial illustrations are empty")
	check(not store.definitions().has("militia") and not store.definitions().has("pathfinder"), "Old built-in definitions are absent")
	var initial_file: String = FileAccess.get_file_as_string(store.root_path.path_join("cards.json"))
	check(not store.delete_card("std_infantry").is_empty() and FileAccess.get_file_as_string(store.root_path.path_join("cards.json")) == initial_file, "Preset references prevent deletion at the storage boundary")

	var detached: Dictionary = store.definitions()
	detached.std_infantry.name = "外部快照"
	check(store.definitions().std_infantry.name == "标准步兵", "Definitions are detached copies")
	var deployed: Dictionary = _record(store, "deploy_draw_infantry")
	var effect_before: Array = deployed.definition.abilities.duplicate(true)
	deployed.definition.name = "编辑后的部署步兵"
	deployed.definition.attack = 6
	check(store.save_card(deployed).is_empty(), "Existing seeded cards can be edited")
	check(store.load_collection().is_empty(), "Version three reload succeeds")
	var restored: Dictionary = _record(store, deployed.id)
	check(restored.definition.name == "编辑后的部署步兵" and restored.definition.attack == 6 and restored.definition.abilities == effect_before, "Reload retains edits and the complete readonly ability")
	check(restored.definition.abilities[0].effects[0].amount is int and restored.definition.attack is int, "Nested effect and stat values normalize back to integers")
	check(_record(store, "armor_tank").definition.keywords.armor is int, "Armor values normalize back to integers")
	check(store.definitions().aftermath_support_infantry.auras == [{"kind": "aftermath_twice"}], "Aura definitions survive persistence")
	check(detached.deploy_draw_infantry.attack == 2, "An older battle definition snapshot is unaffected by later edits")

	var order: Dictionary = _record(store, "order_buff")
	var order_abilities: Array = order.definition.abilities.duplicate(true)
	order.definition.name = "修改后的强化指令"
	order.definition.deploy_cost = 1
	check(store.save_card(order).is_empty() and store.load_collection().is_empty(), "Orders save and reload without unit-only fields")
	check(_record(store, order.id).definition.abilities == order_abilities and not _record(store, order.id).definition.has("max_hp"), "Readonly order effects remain intact without fabricated unit stats")

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
	check(store.save_card(card).is_empty() and store.records.size() == 21, "New vanilla units join the common library")
	check(not store.preset_deck().has(card.id), "Saving a card does not change the fixed deck")
	for source_value in ["library:", "library:../outside", "image:123", "unknown"]:
		var invalid_art: Dictionary = card.duplicate(true)
		invalid_art.artwork.source = source_value
		check(not store.save_card(invalid_art).is_empty() and _record(store, card.id) == card, "Invalid artwork reference rejected: " + source_value)
	for pair in [["attack", -1], ["attack", 100], ["max_hp", 0], ["deploy_cost", 13], ["action_cost", 1.5], ["name", "一".repeat(17)]]:
		var invalid: Dictionary = card.duplicate(true)
		invalid.definition[pair[0]] = pair[1]
		check(not store.save_card(invalid).is_empty() and _record(store, card.id) == card, "Invalid field rejected without mutation: " + str(pair))
	var incompatible: Dictionary = order.duplicate(true)
	incompatible.definition.abilities[0].effects = [{"op": "draw", "target": "chosen_enemy_unit", "amount": 2}]
	check(not store.save_card(incompatible).is_empty(), "Incompatible operations and targets cannot enter the library")
	var fixture: Dictionary = Catalog.card("deploy_damage_artillery")
	fixture.abilities[0].effects.push_front({"op": "choose", "target": "chosen_enemy_unit"})
	check(not Schema.validate_definition(fixture).is_empty() and Schema.validate_definition(fixture, true).is_empty(), "Fixture choice operations stay out of persisted definitions")
	var aftermath_choice: Dictionary = Catalog.card("aftermath_draw_infantry")
	aftermath_choice.abilities[0].effects = [{"op": "damage", "target": "chosen_enemy_unit", "amount": 2}]
	check(not Schema.validate_definition(aftermath_choice).is_empty() and not Schema.validate_definition(aftermath_choice, true).is_empty(), "Targeted aftermath cannot silently omit its choice stage")
	aftermath_choice.abilities[0].effects.push_front({"op": "choose", "target": "chosen_enemy_unit"})
	check(Schema.validate_definition(aftermath_choice, true).is_empty(), "Explicit fixture choice makes targeted aftermath valid")
	var mixed_targets: Dictionary = Catalog.card("deploy_damage_artillery")
	mixed_targets.abilities.append({"trigger": "deploy", "effects": [{"op": "heal", "target": "chosen_friendly_unit", "amount": 2}]})
	check(not Schema.validate_definition(mixed_targets).is_empty(), "Separate deployment abilities cannot require incompatible initial targets")
	var friendly_targets: Dictionary = Catalog.card("order_heal")
	friendly_targets.abilities[0].effects.append({"op": "modify_stats", "target": "chosen_friendly_unit", "attack": 1, "health": 2})
	check(Schema.validate_definition(friendly_targets).is_empty(), "Friendly target selectors may narrow to their shared unit intersection")
	var conditional: Dictionary = Catalog.card("order_buff")
	conditional.abilities[0].condition = {"kind": "owner_hq_damaged"}
	conditional.abilities[0].effects[0].duration = "until_next_owner_turn_end"
	check(Schema.validate_definition(conditional).is_empty(), "Known ability conditions and modifier durations validate")
	conditional.abilities[0].condition.kind = "unknown_condition"
	check(not Schema.validate_definition(conditional).is_empty(), "Unknown conditions are rejected instead of ignored")
	conditional.abilities[0].condition.kind = "source_owner_active"
	conditional.abilities[0].effects[0].duration = "unknown_duration"
	check(not Schema.validate_definition(conditional).is_empty(), "Unknown durations are rejected instead of becoming permanent")
	var imported := Image.create(16, 9, false, Image.FORMAT_RGBA8)
	imported.fill(Color("986c43"))
	check(store.save_card(card, imported).is_empty() and card.artwork.source.begins_with("image:"), "Imported artwork saves under a stable image reference")
	var loaded_art: Texture2D = ArtworkResolver.resolve_source(card.artwork.source, store.root_path.path_join("images"))
	check(loaded_art != null and loaded_art.get_size() == Vector2(16, 9), "Shared artwork resolver reads saved imported pixels")
	check(ArtworkResolver.resolve_source("image:../../outside", store.root_path.path_join("images")) == null, "Artwork resolver rejects path traversal")
	check(store.delete_card(card.id).is_empty() and store.load_collection().is_empty() and not store.definitions().has(card.id), "Non-preset deletion persists without reseeding the removed card")

	_test_legacy_reset(directory, 1)
	_test_legacy_reset(directory, 2)
	_test_invalid_files(directory)
	return checks


func _record(store, id: String) -> Dictionary:
	for record: Dictionary in store.records:
		if record.id == id: return record.duplicate(true)
	return {}


func _write_text(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	check(file != null, "Fixture file opens in the isolated test directory")
	if file == null: return
	file.store_string(value)
	file.close()


func _test_legacy_reset(directory: String, version: int) -> void:
	var store = Store.new()
	store.root_path = directory.path_join("legacy-v%d" % version)
	var legacy: Dictionary = store.new_card()
	legacy.id = "old-personal-card"
	legacy.definition.name = "旧个人卡"
	legacy.definition.erase("card_type")
	legacy.definition.erase("keywords")
	legacy.definition.erase("abilities")
	legacy.definition.erase("auras")
	if version == 1:
		legacy.artwork = {"source": "infantry", "full_focus": [0.2, 0.8], "full_zoom": 2.0, "field_focus": [0.7, 0.1], "field_zoom": 4.0}
	var original: String = JSON.stringify({"version": version, "cards": [legacy]}, "\t")
	var path: String = store.root_path.path_join("cards.json")
	_write_text(path, original)
	_write_text(store.root_path.path_join("cards.v1.backup.json"), "An earlier independent backup.")
	var reset_error: String = store.load_collection()
	check(reset_error.is_empty() and store.records.size() == 20 and not store.definitions().has(legacy.id), "Legacy v%d resets instead of importing old cards: %s" % [version, reset_error])
	if not reset_error.is_empty(): return
	check(FileAccess.get_file_as_string(store.root_path.path_join(Store.LEGACY_BACKUP)) == original, "Legacy v%d reset preserves exact original backup" % version)
	check(FileAccess.get_file_as_string(store.root_path.path_join("cards.v1.backup.json")) == "An earlier independent backup.", "Version three backup leaves an older backup intact")
	var updated: Dictionary = _record(store, "aftermath_draw_infantry")
	updated.definition.name = "重置后的保存"
	check(store.save_card(updated).is_empty() and store.load_collection().is_empty() and _record(store, updated.id).definition.name == updated.definition.name, "Version three does not rerun the legacy reset")
	check(FileAccess.get_file_as_string(store.root_path.path_join(Store.LEGACY_BACKUP)) == original, "Later saves keep the first legacy backup")


func _test_invalid_files(directory: String) -> void:
	var store = Store.new()
	store.root_path = directory.path_join("invalid-files")
	var path: String = store.root_path.path_join("cards.json")
	for invalid in ["broken-json", JSON.stringify({"version": 2, "cards": [42]}), JSON.stringify({"version": 2.5, "cards": []}), JSON.stringify({"version": 7, "cards": []}), JSON.stringify({"version": 3, "cards": [], "preset_deck": []})]:
		_write_text(path, invalid)
		check(not store.load_collection().is_empty() and not store.writable and store.definitions().is_empty() and store.preset_deck().is_empty(), "Invalid library blocks all battle definitions")
		check(FileAccess.get_file_as_string(path) == invalid, "Invalid library is never overwritten or reset")

	var seed = Store.new()
	seed.root_path = directory.path_join("reference-seed")
	check(seed.load_collection().is_empty(), "Reference fixture initializes")
	var valid: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(seed.root_path.path_join("cards.json")))
	valid.cards.pop_back()
	var missing: String = JSON.stringify(valid)
	_write_text(path, missing)
	check(not store.load_collection().is_empty() and FileAccess.get_file_as_string(path) == missing, "Missing fixed-deck reference is rejected without silently restoring a seed card")

	var blocked = Store.new()
	blocked.root_path = directory.path_join("blocked-backup")
	var legacy: Dictionary = blocked.new_card()
	legacy.definition.name = "待重置旧卡"
	var legacy_text: String = JSON.stringify({"version": 2, "cards": [legacy]})
	var legacy_path: String = blocked.root_path.path_join("cards.json")
	_write_text(legacy_path, legacy_text)
	DirAccess.make_dir_absolute(blocked.root_path.path_join(Store.LEGACY_BACKUP))
	check(not blocked.load_collection().is_empty() and FileAccess.get_file_as_string(legacy_path) == legacy_text, "Backup failure leaves the old collection untouched")
