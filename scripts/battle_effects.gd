class_name BattleEffects
extends RefCounted
## Pure public-state queries shared by command validation, resolution and AI.


static func board_ids(state: Dictionary, owner: String) -> Array:
	var result: Array = []
	for id in state.get("frontline_ids", []):
		if state.units[id].owner == owner:
			result.append(id)
	result.append_array(state.get("sides", {}).get(owner, {}).get("support_ids", []))
	return result


static func candidates(selector: String, owner: String, state: Dictionary) -> Array:
	var enemy: String = "ai" if owner == "player" else "player"
	match selector:
		"chosen_enemy_unit": return board_ids(state, enemy)
		"chosen_friendly_unit": return board_ids(state, owner)
		"chosen_friendly":
			var result: Array = board_ids(state, owner)
			result.append("hq:" + owner)
			return result
		"chosen_enemy_row":
			var result: Array = []
			for row in ["support", "frontline"]:
				if not row_ids(state, enemy, row).is_empty():
					result.append("row:%s:%s" % [enemy, row])
			return result
	return []


static func row_ids(state: Dictionary, owner: String, row: String) -> Array:
	if row == "support":
		return state.sides[owner].support_ids.duplicate()
	var result: Array = []
	if row == "frontline":
		for id in state.frontline_ids:
			if state.units[id].owner == owner:
				result.append(id)
	return result


static func targets(selector: String, owner: String, chosen: String, state: Dictionary) -> Array:
	var enemy: String = "ai" if owner == "player" else "player"
	if selector.begins_with("chosen_"):
		if not candidates(selector, owner, state).has(chosen):
			return []
		if selector == "chosen_enemy_row":
			var parts: PackedStringArray = chosen.split(":")
			return row_ids(state, parts[1], parts[2])
		return [chosen]
	match selector:
		"owner": return [owner]
		"owner_hq": return ["hq:" + owner]
		"enemy_hq": return ["hq:" + enemy]
		"friendly_units": return board_ids(state, owner)
		"enemy_units": return board_ids(state, enemy)
		"all_units":
			var result: Array = board_ids(state, owner)
			result.append_array(board_ids(state, enemy))
			return result
		"all_hqs": return ["hq:" + owner, "hq:" + enemy]
	return []


static func armor(unit: Dictionary) -> int:
	return maxi(0, int(unit.get("keywords", {}).get("armor", 0)))


static func combat_damage(amount: int, target: Dictionary) -> int:
	return maxi(0, amount - armor(target))
