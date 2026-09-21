extends RefCounted
## Read-only projection of public battle data; legality comes from rule actions.


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
	result.rule_text = text.type_brief(kind)
	result.rule_description = text.type_description(kind)
	result.command_unit = text.caption("command_unit")
	result.enemy = source.get("owner", "") != "player"
	result.ready = not result.enemy and player_turn(state) and source_legal(actions, id)
	result.selected = selected.has(id)
	result.highlighted = result.selected
	return result


static func hq_data(state: Dictionary, side: String, text: Resource) -> Dictionary:
	var value: Dictionary = state.get("sides", {}).get(side, {})
	return {"name": text.caption("hq_player" if side == "player" else "hq_enemy"), "unit_type": "hq", "hp": value.get("hq_hp", 0), "max_hp": value.get("hq_max_hp", 0), "enemy": side != "player", "owner": side}
