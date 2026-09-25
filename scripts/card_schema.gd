class_name CardSchema
extends RefCounted
## Shared definition validation and player-facing ability text.

const Catalog = preload("res://scripts/card_catalog.gd")
const UNIT_TYPES = ["infantry", "tank", "artillery", "fighter", "bomber"]
const TARGETS = ["chosen_enemy_unit", "chosen_friendly", "chosen_friendly_unit", "chosen_enemy_row", "owner", "owner_hq", "enemy_hq", "friendly_units", "enemy_units", "all_units", "all_hqs"]
const INTEGER_FIELDS = ["deploy_cost", "action_cost", "attack", "max_hp"]


static func normalize_definition(definition: Dictionary) -> Dictionary:
	var result: Dictionary = definition.duplicate(true)
	if not result.has("card_type"): result.card_type = "unit"
	for key in ["keywords", "abilities", "auras"]:
		if not result.has(key): result[key] = {} if key == "keywords" else []
	for key in INTEGER_FIELDS:
		if result.has(key): result[key] = _normalize_integer(result[key])
	if result.keywords is Dictionary and result.keywords.has("armor"):
		result.keywords.armor = _normalize_integer(result.keywords.armor)
	if result.abilities is Array:
		for index in range(result.abilities.size()):
			var ability: Variant = result.abilities[index]
			if not ability is Dictionary or not ability.get("effects") is Array: continue
			if not ability.has("id"): ability.id = "%s_%d" % [str(ability.get("trigger", "ability")), index]
			for effect: Variant in ability.effects:
				if not effect is Dictionary: continue
				for key in ["amount", "attack", "health"]:
					if effect.has(key): effect[key] = _normalize_integer(effect[key])
	return result


static func _normalize_integer(value: Variant) -> Variant:
	if value is float and is_finite(value) and value == floor(value): return int(value)
	return value


static func validate_definition(definition: Dictionary, allow_fixture_choices: bool = false) -> String:
	var d: Dictionary = normalize_definition(definition)
	if d.get("card_type") not in ["unit", "order"]: return "卡牌类型无效"
	if not d.get("name") is String or d.name.strip_edges().is_empty() or "\n" in d.name or (d.name.length() > 16 and not allow_fixture_choices): return "名称须为 1–16 字"
	if not _integer_in(d.get("deploy_cost"), 0, 12): return "使用费用须为 0–12 的整数"
	if d.card_type == "unit":
		if d.get("unit_type") not in UNIT_TYPES: return "请选择兵种"
		if not _integer_in(d.get("action_cost"), 0, 12): return "行动费用须为 0–12 的整数"
		if not _integer_in(d.get("attack"), 0, 99) or not _integer_in(d.get("max_hp"), 1, 99): return "攻血数值超出范围"
	if not d.keywords is Dictionary or not d.abilities is Array or not d.auras is Array: return "能力数据损坏"
	for key: Variant in d.keywords:
		if key in ["raid", "guard"]:
			if not d.keywords[key] is bool: return "特性取值无效"
		elif key == "armor":
			if not _integer_in(d.keywords[key], 0, 99): return "装甲值须为非负整数"
		else: return "未知特性"
	if d.card_type == "order" and (not d.keywords.is_empty() or not d.auras.is_empty()): return "指令不能具有单位特性"
	var ability_ids: Array[String] = []
	var initial_selectors: Array[String] = []
	for ability: Variant in d.abilities:
		if not ability is Dictionary or ability.get("trigger") not in ["deploy", "aftermath", "play"] or not ability.get("effects") is Array or ability.effects.is_empty(): return "触发能力无效"
		if not ability.get("id") is String or ability.id.is_empty() or ability_ids.has(ability.id): return "能力标识无效"
		ability_ids.append(ability.id)
		var condition: Variant = ability.get("condition", {})
		if not condition is Dictionary or (not condition.is_empty() and condition.get("kind") not in ["source_owner_active", "owner_hq_damaged"]): return "能力条件无效"
		if (d.card_type == "order") != (ability.trigger == "play"): return "触发时机与卡牌类型不符"
		var choice_target: String = ""
		var before_choice: bool = true
		for effect: Variant in ability.effects:
			if not effect is Dictionary or effect.get("target") not in TARGETS: return "效果目标无效"
			if not _valid_effect_target(str(effect.get("op", "")), str(effect.target)): return "效果与目标类型不符"
			if ability.trigger == "aftermath" and str(effect.target).begins_with("chosen_") and effect.get("op") != "choose" and choice_target != str(effect.target): return "定向余波需要显式选择阶段"
			if effect.has("duration") and (effect.get("op") != "modify_stats" or effect.duration not in ["permanent", "until_next_owner_turn_end", "while_source_on_battlefield"]): return "效果持续时间无效"
			if ability.trigger in ["deploy", "play"] and before_choice and effect.get("op") != "choose" and str(effect.target).begins_with("chosen_") and not initial_selectors.has(str(effect.target)):
				initial_selectors.append(str(effect.target))
			match str(effect.get("op", "")):
				"damage", "draw", "heal":
					if not _integer_in(effect.get("amount"), 1, 99): return "效果数量须为正整数"
				"modify_stats":
					if not _integer_in(effect.get("attack"), -99, 99) or not _integer_in(effect.get("health"), -99, 99): return "增益数值无效"
					if effect.attack == 0 and effect.health == 0: return "增益不能为空"
				"suppress": pass
				"choose":
					if not allow_fixture_choices: return "测试能力不能写入牌库"
					choice_target = str(effect.target)
					before_choice = false
				_: return "未知效果"
	if d.card_type == "order" and d.abilities.is_empty(): return "指令必须具有效果"
	if initial_selectors.size() > 1:
		for selector: String in initial_selectors:
			if selector not in ["chosen_friendly", "chosen_friendly_unit"]: return "同次出牌的指定效果必须共用兼容目标"
	for aura: Variant in d.auras:
		if not aura is Dictionary or aura.get("kind") != "aftermath_twice": return "持续能力无效"
	return ""


static func _integer_in(value: Variant, lower: int, upper: int) -> bool:
	return value is int and value >= lower and value <= upper


static func _valid_effect_target(operation: String, target: String) -> bool:
	if operation == "draw": return target == "owner"
	if operation == "choose": return target.begins_with("chosen_")
	if operation in ["modify_stats", "suppress"]:
		return target in ["chosen_enemy_unit", "chosen_friendly_unit", "chosen_enemy_row", "friendly_units", "enemy_units", "all_units"]
	if operation in ["damage", "heal"]: return target != "owner"
	return false


static func keyword_badges(definition: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var keywords: Dictionary = definition.get("keywords", {})
	if keywords.get("raid", false): result.append("突袭")
	if keywords.get("guard", false): result.append("掩护")
	if int(keywords.get("armor", 0)) > 0: result.append("装甲 %d" % int(keywords.armor))
	return result


static func ability_text(definition: Dictionary) -> String:
	var lines: Array[String] = []
	var badges: Array[String] = keyword_badges(definition)
	if not badges.is_empty(): lines.append(" · ".join(badges))
	for ability: Dictionary in definition.get("abilities", []):
		var parts: Array[String] = []
		for effect: Dictionary in ability.get("effects", []):
			var description: String = _effect_text(effect)
			if not description.is_empty(): parts.append(description)
		var label: String = {"deploy": "部署：", "aftermath": "余波：", "play": ""}.get(ability.get("trigger", ""), "")
		var condition: String = {"source_owner_active": "己方回合时，", "owner_hq_damaged": "己方总部受伤时，"}.get(ability.get("condition", {}).get("kind", ""), "")
		if not parts.is_empty(): lines.append(label + condition + "；".join(parts) + "。")
	for aura: Dictionary in definition.get("auras", []):
		if aura.get("kind") == "aftermath_twice": lines.append("己方单位的余波触发两次。")
	return "\n".join(lines)


static func detail_text(definition: Dictionary) -> String:
	var lines: Array[String] = []
	if definition.get("card_type", "unit") == "unit":
		lines.append(Catalog.type_description(str(definition.get("unit_type", ""))))
	else: lines.append("指令：支付使用费用后结算效果，随后进入弃牌堆。")
	var body: String = ability_text(definition)
	if not body.is_empty(): lines.append(body)
	var keywords: Dictionary = definition.get("keywords", {})
	if keywords.get("raid", false): lines.append("突袭：部署当回合即可主动行动，仍须支付行动费用并遵守兵种规则。")
	if keywords.get("guard", false): lines.append("掩护：保护同一阵线左右相邻的友军单位或总部，使其不能被步兵、坦克和战斗机攻击。掩护单位不互相保护。")
	if int(keywords.get("armor", 0)) > 0: lines.append("装甲：每次受到攻击或反击时减少相应伤害，最低为 0；不减免效果伤害。")
	var triggers: Array[String] = []
	var has_suppress: bool = false
	for ability: Dictionary in definition.get("abilities", []):
		var trigger: String = str(ability.get("trigger", ""))
		if not triggers.has(trigger): triggers.append(trigger)
		for effect: Dictionary in ability.get("effects", []):
			if effect.get("op") == "suppress": has_suppress = true
	if triggers.has("deploy"): lines.append("部署：从手牌部署成功后触发；没有合法目标时跳过指定目标的效果。")
	if triggers.has("aftermath"): lines.append("余波：本单位在战场上被消灭并离场后触发。")
	if has_suppress: lines.append("压制：直到该单位拥有者的下个回合结束，不能主动移动或攻击；仍可反击、掩护及提供战斗机保护。")
	return "\n\n".join(lines)


static func _effect_text(effect: Dictionary) -> String:
	var target: String = str(effect.get("target", ""))
	var object_name: String = {
		"chosen_enemy_unit": "一个敌方单位", "chosen_friendly": "一个友方单位或总部", "chosen_friendly_unit": "一个友方单位",
		"chosen_enemy_row": "敌方一条阵线上的所有单位", "owner_hq": "己方总部", "enemy_hq": "敌方总部",
		"friendly_units": "所有友方单位", "enemy_units": "所有敌方单位", "all_units": "所有单位", "all_hqs": "双方总部",
	}.get(target, "目标")
	match str(effect.get("op", "")):
		"draw": return "抽 %d 张牌" % int(effect.get("amount", 0))
		"damage": return "对%s造成 %d 点伤害" % [object_name, int(effect.get("amount", 0))]
		"heal": return "为%s恢复 %d 点生命" % [object_name, int(effect.get("amount", 0))]
		"modify_stats":
			var duration: String = {"until_next_owner_turn_end": "，直到你的下个回合结束", "while_source_on_battlefield": "，持续至来源单位离场"}.get(effect.get("duration", "permanent"), "")
			return "使%s获得 %+d/%+d%s" % [object_name, int(effect.get("attack", 0)), int(effect.get("health", 0)), duration]
		"suppress": return "压制" + object_name
	return ""
