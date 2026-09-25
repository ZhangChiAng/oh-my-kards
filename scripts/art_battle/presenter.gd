extends RefCounted
## Read-only projection of public battle data; legality comes from rule actions.

const CardSchema = preload("res://scripts/card_schema.gd")


static func player_turn(state: Dictionary) -> bool:
	return state.get("phase", "") == "active" and state.get("active_side", "") == "player"


static func source_legal(actions: Array, id: String) -> bool:
	for action in actions:
		if str(action.get("unit_id", "")) == id: return true
	return false


static func unit_data(state: Dictionary, id: String, actions: Array, text: Resource, selected: Array = []) -> Dictionary:
	var source: Dictionary = state.get("units", {}).get(id, {})
	if source.is_empty(): return {}
	var result: Dictionary = source.duplicate(true)
	result.instance_id = id
	var kind: String = str(source.get("unit_type", ""))
	result.type_name = text.type_name(kind)
	result.rule_description = text.type_description(kind)
	result.ability_text = CardSchema.ability_text(source)
	result.detail_text = CardSchema.detail_text(source)
	var badges: Array[String] = CardSchema.keyword_badges(source)
	for ability in source.get("abilities", []):
		var badge: String = {"deploy": "部署", "aftermath": "余波"}.get(str(ability.get("trigger", "")), "")
		if not badge.is_empty() and not badges.has(badge): badges.append(badge)
	if not source.get("auras", []).is_empty(): badges.append("协同")
	if source.get("suppressed", false): badges.append("压制")
	result.keyword_text = " · ".join(badges)
	result.command_unit = text.caption("command_unit")
	result.enemy = source.get("owner", "") != "player"
	result.ready = not result.enemy and player_turn(state) and source_legal(actions, id)
	result.selected = selected.has(id)
	result.highlighted = result.selected
	return result


static func hq_data(state: Dictionary, side: String, text: Resource) -> Dictionary:
	var value: Dictionary = state.get("sides", {}).get(side, {})
	return {"name": text.caption("hq_player" if side == "player" else "hq_enemy"), "unit_type": "hq", "hp": value.get("hq_hp", 0), "max_hp": value.get("hq_max_hp", 0), "enemy": side != "player", "owner": side}
