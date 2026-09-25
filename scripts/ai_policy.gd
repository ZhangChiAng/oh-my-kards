class_name BattleAI
extends RefCounted
## Reads only the public side view, and always returns an offered legal action.
const Effects = preload("res://scripts/battle_effects.gd")


func choose_action(actions: Array, state: Dictionary) -> Dictionary:
	if actions.is_empty():
		return {}
	if state.phase == "waiting_choice":
		var choices: Array = actions.duplicate(true)
		choices.sort_custom(func(a: Dictionary, b: Dictionary): return str(a.target_id) < str(b.target_id))
		return choices[0]
	if state.phase == "mulligan":
		for action in actions:
			if action.type == "mulligan" and action.unit_ids.is_empty():
				return action.duplicate(true)
		return {}
	var actor: String = str(state.active_side)
	var enemy: String = "ai" if actor == "player" else "player"
	var sources: Array = _board_order(state, actor)
	for id in sources:
		var action: Dictionary = _find(actions, "attack", str(id), "hq:" + enemy)
		if not action.is_empty() and int(state.units[id].attack) > 0:
			return action
	var order: Dictionary = _best_play(actions, state, "order")
	if not order.is_empty(): return order
	for id in sources:
		var action: Dictionary = _find(actions, "move", str(id), "", state.frontline_ids.size())
		if not action.is_empty():
			return action
	var best: Dictionary = {}
	for target in _board_order(state, enemy):
		if not best.is_empty() and int(state.units[target].hp) >= int(state.units[best.target_id].hp):
			continue
		for id in sources:
			var action: Dictionary = _find(actions, "attack", str(id), str(target))
			if not action.is_empty() and Effects.combat_damage(int(state.units[id].attack), state.units[target]) > 0:
				best = action
				break
	if not best.is_empty():
		return best
	best = _best_play(actions, state, "deploy")
	return best if not best.is_empty() else _find(actions, "end_turn")


func _best_play(actions: Array, state: Dictionary, kind: String) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = 0.0 if kind == "order" else -INF
	var sorted: Array = actions.filter(func(a: Dictionary): return a.type == kind)
	sorted.sort_custom(func(a: Dictionary, b: Dictionary): return _play_tie(a, state) < _play_tie(b, state))
	for action: Dictionary in sorted:
		var card: Dictionary = state.units[action.unit_id]
		var score: float = 4.0 * float(card.deploy_cost) if kind == "deploy" else -0.25 * float(card.deploy_cost)
		for ability in card.get("abilities", []):
			if ability.trigger != ("deploy" if kind == "deploy" else "play"): continue
			for effect in ability.effects:
				score += _effect_score(effect, card, action, state)
		if kind == "deploy" and card.get("keywords", {}).get("guard", false):
			var row: Array = state.sides[card.owner].support_ids.duplicate()
			row.insert(int(state.sides[card.owner].hq_index), "hq:" + str(card.owner))
			var index: int = int(action.insert_index)
			for neighbor in [index - 1, index]:
				if neighbor >= 0 and neighbor < row.size():
					score += 3.0 if str(row[neighbor]).begins_with("hq:") else 1.0
		if score > best_score:
			best_score = score
			best = action.duplicate(true)
	return best


func _play_tie(action: Dictionary, state: Dictionary) -> String:
	var owner: String = str(state.active_side)
	var hand_index: int = state.sides[owner].hand_ids.find(action.unit_id)
	var targets: Array = _board_order(state, "ai" if owner == "player" else "player")
	targets.append_array(_board_order(state, owner))
	targets.append("hq:" + owner)
	var target_index: int = targets.find(action.get("target_id", ""))
	return "%03d:%03d:%03d:%s" % [hand_index, 20 - int(action.get("insert_index", 0)), target_index + 1, str(action.get("target_id", ""))]


func _effect_score(effect: Dictionary, card: Dictionary, action: Dictionary, state: Dictionary) -> float:
	var score: float = 0.0
	var owner: String = str(card.owner)
	var targets: Array = Effects.targets(str(effect.get("target", "")), owner, str(action.get("target_id", "")), state)
	var amount: int = int(effect.get("amount", 0))
	for target in targets:
		var is_hq: bool = str(target).begins_with("hq:")
		var unit: Dictionary = state.units.get(target, {})
		var side: Dictionary = state.sides.get(str(target).trim_prefix("hq:"), {}) if is_hq else {}
		match str(effect.op):
			"damage":
				var hp: int = int(side.hq_hp) if is_hq else int(unit.get("hp", 0))
				var friendly: bool = str(target) == "hq:" + owner if is_hq else unit.get("owner") == owner
				var value: float = float(mini(amount, hp)) + (8.0 if amount >= hp and hp > 0 else 0.0)
				if is_hq and amount >= hp: value += 10000.0
				score += -value if friendly else value
			"heal":
				var missing: int = int(side.get("hq_max_hp", 20)) - int(side.hq_hp) if is_hq else int(unit.get("max_hp", 0)) - int(unit.get("hp", 0))
				score += float(mini(amount, missing))
			"draw":
				var participant: Dictionary = state.sides[owner]
				var count: int = mini(amount, int(participant.get("draw_count", 0)))
				var limit: int = int(state.get("limits", {}).get("hand_limit", 9))
				score += 2.0 * float(mini(count, maxi(0, limit - int(participant.get("hand_count", participant.hand_ids.size())) + 1)))
				var fatigue: int = int(participant.get("fatigue", 0))
				var damage: int = 0
				for _index in range(amount - count):
					fatigue = int(state.get("limits", {}).get("fatigue_initial", 1)) if fatigue == 0 else fatigue + int(state.get("limits", {}).get("fatigue_increment", 1))
					damage += fatigue
				score -= float(damage) * 2.0
				if damage >= int(participant.hq_hp): score -= 10000.0
			"modify_stats": score += float(effect.get("attack", 0)) * 1.5 + float(effect.get("health", 0))
			"suppress":
				if not unit.get("suppressed", false): score += 1.0 + float(unit.get("attack", 0))
	return score


func _board_order(state: Dictionary, side: String) -> Array:
	var ids: Array = []
	for id in state.frontline_ids:
		if state.units[id].owner == side:
			ids.append(id)
	ids.append_array(state.sides[side].support_ids)
	return ids


func _find(actions: Array, kind: String, source: String = "", target: String = "", insert_index: int = -1) -> Dictionary:
	for action in actions:
		if action.type != kind:
			continue
		if not source.is_empty() and action.get("unit_id") != source:
			continue
		if not target.is_empty() and action.get("target_id") != target:
			continue
		if insert_index >= 0 and action.get("insert_index") != insert_index:
			continue
		return action.duplicate(true)
	return {}
