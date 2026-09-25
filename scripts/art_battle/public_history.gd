extends RefCounted
## Anonymous public event projection; independent of controls and artwork resources.

var _history_entries: Array[Dictionary] = []


func reset() -> void:
	_history_entries.clear()


func snapshot() -> Dictionary:
	return {"open": false, "entries": _history_entries.duplicate(true)}

func record_events(events: Array, before: Dictionary, after: Dictionary) -> void:
	# Events may contain hidden IDs. Only this public projection is retained.
	var turn: int = int(before.get("turn", after.get("turn", 0)))
	var replacements: bool = false
	var casualties: Array[String] = []
	var effect_chain: bool = false
	for event in events:
		if event.type in ["ability_triggered", "effect_damage", "healed", "stats_modified", "status_applied", "order_played"]: effect_chain = true
		if event.type == "mulligan_completed": replacements = true
		elif event.type == "unit_destroyed": casualties.append(_public_name(str(event.unit_id), before, after))
	var draws: Dictionary = {"player": 0, "ai": 0}
	for event in events:
		var type: String = str(event.type)
		var side: String = str(event.get("side", ""))
		if type == "card_drawn":
			if not replacements: draws[side] += 1
			continue
		_flush_draws(draws, turn)
		match type:
			"battle_started":
				_append_history(type, 0, "", "战斗开始 · " + ("你先手" if event.first_side == "player" else "对手先手"))
			"turn_started":
				turn = int(event.turn)
				_append_history(type, turn, side, "第 %d 回合 · %s" % [turn, _side_name(side)])
			"mulligan_completed":
				var count: int = int(event.replaced_count)
				_append_history(type, turn, side, "%s更换了 %d 张起手牌" % [_side_name(side), count] if count > 0 else _side_name(side) + "保留了起手牌")
			"unit_deployed", "unit_moved":
				var unit: Dictionary = _public_unit(str(event.unit_id), before, after)
				var verb: String = "部署" if type == "unit_deployed" else "推进"
				_append_history(type, turn, side, "%s%s了%s" % [_side_name(side), verb, str(unit.get("name", "单位"))], str(unit.get("unit_type", "")))
			"units_battled":
				var attacker: Dictionary = _public_unit(str(event.attacker_id), before, after)
				var defender: String = _public_name(str(event.target_id), before, after)
				var summary: String = "%s → %s\n造成 %d / 反击 %d" % [str(attacker.get("name", "单位")), defender, int(event.damage_to_target), int(event.damage_to_attacker)]
				if not casualties.is_empty() and not effect_chain: summary += "\n阵亡：" + "、".join(casualties)
				_append_history("attack", turn, str(attacker.get("owner", "")), summary, str(attacker.get("unit_type", "")))
			"hq_attacked":
				var attacker: Dictionary = _public_unit(str(event.attacker_id), before, after)
				_append_history("attack", turn, str(attacker.get("owner", "")), "%s → %s总部\n造成 %d · 总部剩余 %d" % [str(attacker.get("name", "单位")), "己方" if event.target_id == "hq:player" else "敌方", int(event.damage), int(event.remaining_hp)], str(attacker.get("unit_type", "")))
			"fatigue_damage":
				_append_history(type, turn, side, "%s空抽，受到 %d 点伤害" % [_side_name(side), int(event.damage)])
			"hand_overflow":
				_append_history(type, turn, side, _side_name(side) + "手牌已满，新抽的 1 张牌进入弃牌堆")
			"order_played":
				_append_history(type, turn, side, "%s使用了%s" % [_side_name(side), _public_name(str(event.unit_id), before, after)])
			"ability_triggered":
				var label: String = {"deploy": "部署", "aftermath": "余波", "play": "指令效果"}.get(str(event.trigger), "效果")
				_append_history(type, turn, side, "%s触发%s" % [_public_name(str(event.source_id), before, after), label])
			"effect_damage":
				_append_history(type, turn, side, "%s受到 %d 点效果伤害" % [_public_name(str(event.target_id), before, after), int(event.damage)])
			"healed":
				_append_history(type, turn, side, "%s恢复 %d 点生命" % [_public_name(str(event.target_id), before, after), int(event.amount)])
			"stats_modified":
				_append_history(type, turn, side, "%s攻血变为 %d／%d" % [_public_name(str(event.unit_id), before, after), int(event.attack), int(event.hp)])
			"status_applied", "status_expired":
				_append_history(type, turn, side, _public_name(str(event.unit_id), before, after) + ("被压制" if type == "status_applied" else "解除压制"))
			"unit_destroyed":
				if effect_chain: _append_history(type, turn, side, _public_name(str(event.unit_id), before, after) + "被消灭")
			"battle_finished":
				_append_history(type, turn, str(event.winner), "战斗平局" if event.winner == "draw" else ("战斗胜利" if event.winner == "player" else "战斗失败"))
	_flush_draws(draws, turn)


func _flush_draws(draws: Dictionary, turn: int) -> void:
	for side in ["player", "ai"]:
		if int(draws[side]) > 0:
			_append_history("card_drawn", turn, side, "%s抽了 %d 张牌" % [_side_name(side), int(draws[side])])
			draws[side] = 0


func _public_unit(id: String, before: Dictionary, after: Dictionary) -> Dictionary:
	return after.get("units", {}).get(id, before.get("units", {}).get(id, {}))


func _public_name(id: String, before: Dictionary, after: Dictionary) -> String:
	if id.begins_with("hq:"): return "己方总部" if id == "hq:player" else "敌方总部"
	return str(_public_unit(id, before, after).get("name", "单位"))


func _side_name(side: String) -> String:
	return "你" if side == "player" else "对手"


func _append_history(type: String, turn: int, side: String, value: String, art_key: String = "") -> void:
	var entry: Dictionary = {"type": type, "turn": turn, "side": side, "text": value}
	if not art_key.is_empty(): entry["art_key"] = art_key
	_history_entries.append(entry)
