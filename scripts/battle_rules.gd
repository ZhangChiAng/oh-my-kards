class_name BattleRules
extends RefCounted
## Commands own mutations. An ability completes before the next FIFO job.
const RuleConfig = preload("res://scripts/config/rule_config.gd")
const Schema = preload("res://scripts/card_schema.gd")
const Effects = preload("res://scripts/battle_effects.gd")
const SIDES: Array[String] = ["player", "ai"]

var _state: Dictionary = {}
var _config: Resource
var _random: RandomNumberGenerator = RandomNumberGenerator.new()
var _mulligan_random: Dictionary = {}
var _resolution: Dictionary = {}
var _batch_serial: int = 0
var _choice_serial: int = 0


func setup(seed_value: int, rule_config: Resource, definitions: Dictionary, decks: Dictionary, allow_fixture_choices: bool = false) -> Dictionary:
	if not _valid_setup(rule_config, definitions, decks, allow_fixture_choices):
		return {"accepted": false, "reason": "invalid_setup", "events": []}
	_config = rule_config.duplicate(true)
	_random.seed = seed_value
	_mulligan_random.clear()
	_resolution.clear()
	_batch_serial = 0
	_choice_serial = 0
	for side in SIDES:
		var generator: RandomNumberGenerator = RandomNumberGenerator.new()
		generator.seed = seed_value ^ (int(_config.player_mulligan_seed_salt) if side == "player" else int(_config.ai_mulligan_seed_salt))
		_mulligan_random[side] = generator
	var first_side: String = SIDES[_random.randi_range(0, 1)]
	_state = {
		"seed": seed_value, "turn": 0, "first_side": first_side, "active_side": first_side,
		"phase": "mulligan", "winner": "", "sides": {}, "pending_choice": {},
		"frontline_ids": [], "units": {}, "next_entered_sequence": 0,
		"limits": {"hand_limit": _config.hand_limit, "support_limit": _config.support_limit,
			"frontline_limit": _config.frontline_limit, "command_point_limit": _config.command_point_limit,
			"fatigue_initial": _config.fatigue_initial, "fatigue_increment": _config.fatigue_increment},
	}
	for side in SIDES:
		_state.sides[side] = {
			"hq_hp": _config.hq_max_hp, "hq_max_hp": _config.hq_max_hp, "hq_index": 0,
			"fatigue": 0, "command_points": 0, "max_command_points": 0,
			"turns_started": 0, "mulligan_done": false,
			"hand_ids": [], "draw_ids": [], "discard_ids": [], "support_ids": [],
		}
		var deck: Array = decks[side].duplicate()
		_shuffle(deck)
		for index in range(deck.size()):
			var id: String = "%s-%02d" % [side, index + 1]
			var card: Dictionary = Schema.normalize_definition(definitions[deck[index]])
			card.merge({"card_id": deck[index], "instance_id": id, "owner": side, "publicly_revealed": false}, true)
			if _is_unit(card):
				card.hp = card.max_hp
				_ensure_runtime_values(card)
			_state.units[id] = card
			_state.sides[side].draw_ids.append(id)
		_shuffle(_state.sides[side].draw_ids)
	var events: Array = [{"type": "battle_started", "seed": seed_value, "first_side": first_side}]
	for side in SIDES:
		for _index in range(int(_config.first_hand_count) if side == first_side else int(_config.second_hand_count)):
			_draw_card(side, events)
			if _state.phase == "finished": break
	return _accepted(events)


func _valid_setup(config: Resource, definitions: Dictionary, decks: Dictionary, fixtures: bool) -> bool:
	if not config is RuleConfig: return false
	for field in ["hq_max_hp", "hand_limit", "support_limit", "frontline_limit", "command_point_growth", "command_point_limit", "fatigue_initial"]:
		if int(config.get(field)) <= 0: return false
	for field in ["first_hand_count", "second_hand_count", "turn_draw_count", "fatigue_increment"]:
		if int(config.get(field)) < 0: return false
	if config.first_hand_count > config.hand_limit or config.second_hand_count > config.hand_limit: return false
	for card_id in definitions:
		if not card_id is String or not definitions[card_id] is Dictionary: return false
		if not Schema.validate_definition(Schema.normalize_definition(definitions[card_id]), fixtures).is_empty(): return false
	for side in SIDES:
		if not decks.get(side) is Array: return false
		for card_id in decks[side]:
			if not card_id is String or not definitions.has(card_id): return false
	return true


func validation_reason(action: Dictionary, actor: String = "player") -> String:
	return _validate(action, actor)


func execute(action: Dictionary, actor: String = "player") -> Dictionary:
	var reason: String = validation_reason(action, actor)
	if not reason.is_empty(): return {"accepted": false, "reason": reason, "events": []}
	var events: Array = []
	_ensure_entered_sequences()
	if action.type == "choose":
		_resolution.current.target_id = str(action.target_id)
		_lock_chosen_targets(_resolution.current)
		_state.pending_choice = {}
		_state.phase = "active"
		events.append({"type": "choice_resolved", "choice_id": action.choice_id, "target_id": action.target_id, "side": actor})
		_drain_resolution(events)
		return _accepted(events)
	_resolution = {"queue": [], "current": {}, "after_end_turn": ""}
	var id: String = str(action.get("unit_id", ""))
	match str(action.type):
		"mulligan":
			_resolve_mulligan(action.unit_ids, actor, events)
		"deploy":
			var side: Dictionary = _state.sides[actor]
			var index: int = int(action.get("insert_index", side.support_ids.size() + 1))
			var before_hq: bool = index <= int(side.hq_index)
			_spend(actor, int(_state.units[id].deploy_cost), events)
			side.hand_ids.erase(id)
			side.support_ids.insert(index if before_hq else index - 1, id)
			if before_hq: side.hq_index += 1
			_ensure_runtime_values(_state.units[id])
			_state.next_entered_sequence = int(_state.get("next_entered_sequence", 0)) + 1
			_state.units[id].entered_sequence = _state.next_entered_sequence
			_state.units[id].deployed_this_turn = true
			_state.units[id].publicly_revealed = true
			events.append({"type": "unit_deployed", "side": actor, "unit_id": id, "insert_index": index})
			_enqueue_abilities(_state.units[id], "deploy", 1, str(action.get("target_id", "")))
		"order":
			_spend(actor, int(_state.units[id].deploy_cost), events)
			_state.sides[actor].hand_ids.erase(id)
			_state.sides[actor].discard_ids.append(id)
			_state.units[id].publicly_revealed = true
			events.append({"type": "order_played", "side": actor, "unit_id": id})
			_enqueue_abilities(_state.units[id], "play", 1, str(action.get("target_id", "")))
		"move":
			var index: int = int(action.get("insert_index", _state.frontline_ids.size()))
			_spend(actor, int(_state.units[id].action_cost), events)
			_remove_from_support(id)
			_state.frontline_ids.insert(index, id)
			_state.units[id].moved_this_turn = true
			events.append({"type": "unit_moved", "side": actor, "unit_id": id, "to": "frontline", "insert_index": index})
		"attack":
			_spend(actor, int(_state.units[id].action_cost), events)
			_resolve_attack(id, str(action.target_id), events)
		"end_turn":
			events.append({"type": "turn_ended", "side": actor, "turn": _state.turn})
			_expire_turn_state(actor, events)
			if _state.phase != "finished": _resolution.after_end_turn = actor
	_drain_resolution(events)
	return _accepted(events)


func legal_actions(actor: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _state.is_empty() or not SIDES.has(actor) or _state.phase == "finished": return result
	if _state.phase == "waiting_choice":
		var pending: Dictionary = _state.pending_choice
		if pending.owner == actor:
			for target in pending.target_ids:
				result.append({"type": "choose", "choice_id": pending.choice_id, "target_id": target})
		return result
	if _state.phase == "mulligan":
		if _state.sides[actor].mulligan_done: return result
		var hand: Array = _state.sides[actor].hand_ids
		for mask in range(1 << hand.size()):
			var replacements: Array = []
			for index in range(hand.size()):
				if mask & (1 << index): replacements.append(hand[index])
			result.append({"type": "mulligan", "unit_ids": replacements})
		return result
	if _state.active_side != actor: return result
	for id in _state.sides[actor].hand_ids:
		var card: Dictionary = _state.units[id]
		var kind: String = "deploy" if _is_unit(card) else "order"
		var targets: Array = _initial_targets(card)
		if targets.is_empty() and (_initial_selectors(card).is_empty() or kind == "deploy"): targets.append("")
		var positions: int = _state.sides[actor].support_ids.size() + 2 if kind == "deploy" else 1
		for target in targets:
			for index in range(positions):
				var candidate: Dictionary = {"type": kind, "unit_id": id}
				if kind == "deploy": candidate.insert_index = index
				if not str(target).is_empty(): candidate.target_id = target
				if _validate(candidate, actor).is_empty(): result.append(candidate)
	var targets: Array = Effects.board_ids(_state, _opponent(actor))
	targets.append("hq:" + _opponent(actor))
	for id in Effects.board_ids(_state, actor):
		for index in range(_state.frontline_ids.size() + 1):
			var move: Dictionary = {"type": "move", "unit_id": id, "insert_index": index}
			if _validate(move, actor).is_empty(): result.append(move)
		for target in targets:
			var attack: Dictionary = {"type": "attack", "unit_id": id, "target_id": target}
			if _validate(attack, actor).is_empty(): result.append(attack)
	result.append({"type": "end_turn"})
	return result


func snapshot() -> Dictionary:
	var result: Dictionary = _state.duplicate(true)
	if result.is_empty(): return result
	result.pending_choice = result.get("pending_choice", {})
	for side in SIDES:
		for zone in ["hand", "draw", "discard", "support"]:
			result.sides[side][zone + "_count"] = result.sides[side][zone + "_ids"].size()
	for id in result.units:
		result.units[id]["zone"] = _zone_of(str(id))
		result.units[id]["ready"] = _is_ready(str(id))
		result.units[id]["suppressed"] = _is_suppressed(result.units[id])
	return result


func side_view(viewer: String) -> Dictionary:
	var result: Dictionary = snapshot()
	if not SIDES.has(viewer) or result.is_empty(): return {}
	for side in SIDES:
		var hidden: Array = result.sides[side].draw_ids.duplicate()
		result.sides[side].erase("draw_ids")
		if side != viewer:
			hidden.append_array(result.sides[side].hand_ids)
			result.sides[side].erase("hand_ids")
			var public_discard: Array = []
			for id in result.sides[side].discard_ids:
				if result.units[id].get("publicly_revealed", false): public_discard.append(id)
				else: hidden.append(id)
			result.sides[side].discard_ids = public_discard
		for id in hidden: result.units.erase(id)
	result.erase("seed")
	return result


func _validate(action: Dictionary, actor: String) -> String:
	if _state.is_empty() or _state.phase == "finished": return "battle_finished"
	if not SIDES.has(actor): return "not_your_turn"
	var kind: String = str(action.get("type", ""))
	if _state.phase == "waiting_choice":
		var pending: Dictionary = _state.pending_choice
		if kind != "choose": return "choice_required"
		if pending.owner != actor: return "not_your_choice"
		if str(action.get("choice_id", "")) != str(pending.choice_id): return "stale_choice"
		return "" if pending.target_ids.has(str(action.get("target_id", ""))) else "invalid_target"
	if _state.phase == "mulligan":
		if kind != "mulligan": return "mulligan_required"
		if _state.sides[actor].mulligan_done: return "mulligan_already_done"
		if not action.get("unit_ids") is Array: return "invalid_mulligan"
		var seen: Array = []
		for value in action.unit_ids:
			if not value is String or seen.has(value) or not _state.sides[actor].hand_ids.has(value): return "invalid_mulligan"
			seen.append(value)
		return ""
	if _state.active_side != actor: return "not_your_turn"
	if kind == "end_turn": return ""
	if kind not in ["deploy", "order", "move", "attack"]: return "unknown_action"
	var id: String = str(action.get("unit_id", ""))
	if not _state.units.has(id): return "unknown_unit"
	var card: Dictionary = _state.units[id]
	if card.owner != actor: return "not_your_unit"
	var zone: String = _zone_of(id)
	if kind in ["deploy", "order"]:
		if zone != "hand": return "unit_not_in_hand"
		if (kind == "deploy") != _is_unit(card): return "wrong_card_type"
		if kind == "deploy":
			if _state.sides[actor].support_ids.size() >= int(_config.support_limit): return "support_full"
			if not _valid_insert_index(action, _state.sides[actor].support_ids.size() + 1): return "invalid_insert_index"
		var selectors: Array = _initial_selectors(card)
		var targets: Array = _initial_targets(card)
		var target: String = str(action.get("target_id", ""))
		if not selectors.is_empty():
			if not targets.has(target) and not (kind == "deploy" and targets.is_empty() and target.is_empty()):
				return "target_required" if target.is_empty() else "invalid_target"
		elif not target.is_empty(): return "invalid_target"
		return "insufficient_command_points" if int(_state.sides[actor].command_points) < int(card.deploy_cost) else ""
	if not _is_unit(card) or zone not in ["support", "frontline"]: return "unit_not_on_battlefield"
	if _is_suppressed(card): return "unit_suppressed"
	if card.get("deployed_this_turn", false) and not card.get("keywords", {}).get("raid", false): return "unit_not_ready"
	if kind == "move":
		if zone != "support": return "cannot_retreat"
		if card.get("moved_this_turn", false) or (card.unit_type != "tank" and card.get("attacked_this_turn", false)): return "unit_not_ready"
		if not _state.frontline_ids.is_empty() and _state.units[_state.frontline_ids[0]].owner != actor: return "enemy_controls_frontline"
		if _state.frontline_ids.size() >= int(_config.frontline_limit): return "frontline_full"
		if not _valid_insert_index(action, _state.frontline_ids.size()): return "invalid_insert_index"
	else:
		if card.get("attacked_this_turn", false) or (card.unit_type != "tank" and card.get("moved_this_turn", false)): return "unit_not_ready"
		var target_reason: String = _validate_target(id, str(action.get("target_id", "")), zone)
		if not target_reason.is_empty(): return target_reason
	return "insufficient_command_points" if int(_state.sides[actor].command_points) < int(card.action_cost) else ""


func _initial_selectors(card: Dictionary) -> Array:
	var result: Array = []
	var trigger: String = "deploy" if _is_unit(card) else "play"
	for ability in card.get("abilities", []):
		if str(ability.trigger) != trigger: continue
		for effect in ability.effects:
			if str(effect.op) == "choose": break
			var selector: String = str(effect.get("target", ""))
			if selector.begins_with("chosen_") and not result.has(selector): result.append(selector)
	return result


func _initial_targets(card: Dictionary) -> Array:
	var selectors: Array = _initial_selectors(card)
	if selectors.is_empty(): return []
	var result: Array = Effects.candidates(str(selectors[0]), str(card.owner), _state)
	for index in range(1, selectors.size()):
		var accepted: Array = Effects.candidates(str(selectors[index]), str(card.owner), _state)
		result = result.filter(func(id: Variant): return accepted.has(id))
	return result


func _valid_insert_index(action: Dictionary, last_index: int) -> bool:
	if not action.has("insert_index"): return true
	return action.insert_index is int and action.insert_index >= 0 and action.insert_index <= last_index


func _remove_from_support(id: String) -> void:
	var side: Dictionary = _state.sides[_state.units[id].owner]
	var index: int = side.support_ids.find(id)
	if index < 0: return
	if index < int(side.hq_index): side.hq_index -= 1
	side.support_ids.remove_at(index)


func _validate_target(attacker_id: String, target_id: String, attacker_zone: String) -> String:
	var attacker: Dictionary = _state.units[attacker_id]
	var enemy: String = _opponent(str(attacker.owner))
	var target_zone: String = "support"
	var target_type: String = "hq"
	if target_id != "hq:" + enemy:
		if not _state.units.has(target_id): return "invalid_target"
		if _state.units[target_id].owner == attacker.owner: return "friendly_target"
		target_zone = _zone_of(target_id)
		if target_zone not in ["support", "frontline"]: return "target_out_of_range"
		target_type = str(_state.units[target_id].unit_type)
	if attacker.unit_type in ["infantry", "tank"]:
		if not ((attacker_zone == "support" and target_zone == "frontline") or (attacker_zone == "frontline" and target_zone == "support")): return "target_out_of_range"
	if attacker.unit_type == "bomber" and target_type != "fighter":
		for id in Effects.row_ids(_state, enemy, target_zone):
			if _state.units[id].unit_type == "fighter": return "fighter_cover"
	if attacker.unit_type not in ["artillery", "bomber"] and _guarded(target_id, enemy, target_zone): return "guarded_target"
	return ""


func _guarded(target_id: String, owner: String, zone: String) -> bool:
	if _state.units.get(target_id, {}).get("keywords", {}).get("guard", false): return false
	var row: Array = Effects.row_ids(_state, owner, zone)
	if zone == "support": row.insert(int(_state.sides[owner].hq_index), "hq:" + owner)
	var index: int = row.find(target_id)
	for neighbor in [index - 1, index + 1]:
		if index >= 0 and neighbor >= 0 and neighbor < row.size():
			if _state.units.get(row[neighbor], {}).get("keywords", {}).get("guard", false): return true
	return false


func _is_ready(id: String) -> bool:
	var card: Dictionary = _state.units[id]
	var zone: String = _zone_of(id)
	if not _is_unit(card) or zone not in ["support", "frontline"] or _is_suppressed(card): return false
	if card.get("deployed_this_turn", false) and not card.get("keywords", {}).get("raid", false): return false
	if card.unit_type == "tank":
		return not card.get("attacked_this_turn", false) or (zone == "support" and not card.get("moved_this_turn", false))
	return not card.get("moved_this_turn", false) and not card.get("attacked_this_turn", false)


func _resolve_mulligan(unit_ids: Array, actor: String, events: Array) -> void:
	var replacements: Array = unit_ids.duplicate()
	replacements.sort()
	for id in replacements: _state.sides[actor].hand_ids.erase(id)
	for _id in replacements:
		_draw_card(actor, events)
		if _state.phase == "finished": return
	_state.sides[actor].draw_ids.append_array(replacements)
	if not replacements.is_empty(): _shuffle(_state.sides[actor].draw_ids, _mulligan_random[actor])
	_state.sides[actor].mulligan_done = true
	events.append({"type": "mulligan_completed", "side": actor, "replaced_count": replacements.size()})
	if _state.sides.player.mulligan_done and _state.sides.ai.mulligan_done:
		_state.phase = "active"
		_state.turn = 1
		_begin_turn(events)


func _resolve_attack(attacker_id: String, target_id: String, events: Array) -> void:
	var attacker: Dictionary = _state.units[attacker_id]
	attacker.attacked_this_turn = true
	var packets: Array = [{"target_id": target_id, "amount": int(attacker.attack)}]
	if not target_id.begins_with("hq:"):
		packets.append({"target_id": attacker_id, "amount": retaliation_damage(attacker, _state.units[target_id])})
	_damage_batch(packets, attacker_id, "combat", events, {"attacker_id": attacker_id, "target_id": target_id})


static func retaliation_damage(attacker: Dictionary, defender: Dictionary) -> int:
	if attacker.unit_type == "artillery" or defender.unit_type == "bomber": return 0
	if attacker.unit_type == "bomber" and defender.unit_type != "fighter": return 0
	return int(defender.attack)


func _damage_batch(packets: Array, source_id: String, kind: String, events: Array, combat: Dictionary = {}) -> void:
	var batch: int = _next_batch()
	var applied: Dictionary = {}
	for packet in packets:
		var target: String = str(packet.target_id)
		var amount: int = maxi(0, int(packet.amount))
		if target.begins_with("hq:"):
			var side: String = target.trim_prefix("hq:")
			if not SIDES.has(side): continue
			_state.sides[side].hq_hp = maxi(0, int(_state.sides[side].hq_hp) - amount)
			applied[target] = amount
		elif _zone_of(target) in ["support", "frontline"]:
			var unit: Dictionary = _state.units[target]
			_ensure_runtime_values(unit)
			if kind == "combat": amount = Effects.combat_damage(amount, unit)
			unit.damage_taken += amount
			_recalculate(unit)
			applied[target] = amount
	if not combat.is_empty():
		var attacker_id: String = str(combat.attacker_id)
		var target_id: String = str(combat.target_id)
		if target_id.begins_with("hq:"):
			events.append({"type": "hq_attacked", "attacker_id": attacker_id, "target_id": target_id,
				"damage": applied.get(target_id, 0), "remaining_hp": _target_hp(target_id), "batch_id": batch})
		else:
			events.append({"type": "units_battled", "attacker_id": attacker_id, "target_id": target_id,
				"damage_to_target": applied.get(target_id, 0), "damage_to_attacker": applied.get(attacker_id, 0),
				"attacker_hp": _target_hp(attacker_id), "target_hp": _target_hp(target_id), "batch_id": batch})
	else:
		for target in applied:
			events.append({"type": "effect_damage", "source_id": source_id, "target_id": target,
				"damage": applied[target], "remaining_hp": _target_hp(str(target)), "damage_kind": kind, "batch_id": batch})
	_stabilize(events, batch)


func _stabilize(events: Array, batch: int) -> void:
	if _state.phase == "finished": return
	var captured_deaths: Array = []
	while true:
		_remove_source_modifiers(events, batch)
		var deaths: Array = []
		# Read auras before removing this cohort, including providers at zero HP.
		var copies: Dictionary = {}
		for owner in SIDES: copies[owner] = 2 if _has_aftermath_aura(owner) else 1
		for owner in SIDES:
			for id in Effects.board_ids(_state, owner):
				var unit: Dictionary = _state.units[id]
				if int(unit.hp) <= 0:
					var captured: Dictionary = unit.duplicate(true)
					captured.death_zone = _zone_of(str(id))
					captured.death_unit_index = Effects.row_ids(_state, owner, captured.death_zone).find(id)
					captured.death_hq_index = int(_state.sides[owner].hq_index) if captured.death_zone == "support" else -1
					# Preserve the actual row slot, including the HQ between support units.
					captured.death_index = _state.frontline_ids.find(id)
					if captured.death_zone == "support":
						captured.death_index = captured.death_unit_index + (1 if int(captured.death_unit_index) >= int(captured.death_hq_index) else 0)
					deaths.append({"source": captured, "copies": copies[owner]})
		if deaths.is_empty(): break
		deaths.sort_custom(func(a: Dictionary, b: Dictionary):
			return int(a.source.get("entered_sequence", 0)) < int(b.source.get("entered_sequence", 0)))
		for death in deaths:
			var unit: Dictionary = death.source
			_remove_from_support(str(unit.instance_id))
			_state.frontline_ids.erase(unit.instance_id)
			_state.sides[unit.owner].discard_ids.append(unit.instance_id)
			_state.units[unit.instance_id].publicly_revealed = true
			events.append({"type": "unit_destroyed", "unit_id": unit.instance_id, "side": unit.owner, "batch_id": batch})
		captured_deaths.append_array(deaths)
		# Loss of a source-bound modifier may create a new death cohort.
		batch = _next_batch()
	_check_winner(events)
	if _state.phase == "finished": return
	for death in captured_deaths:
		_enqueue_abilities(death.source, "aftermath", int(death.copies))


func _has_aftermath_aura(owner: String) -> bool:
	for id in Effects.board_ids(_state, owner):
		for aura in _state.units[id].get("auras", []):
			if str(aura.get("kind", "")) == "aftermath_twice": return true
	return false


func _enqueue_abilities(source: Dictionary, trigger: String, copies: int, target_id: String = "") -> void:
	if _resolution.is_empty(): _resolution = {"queue": [], "current": {}, "after_end_turn": ""}
	for ability in source.get("abilities", []):
		if str(ability.trigger) != trigger: continue
		if not ability_condition_matches(ability, {"owner": source.owner, "source": source}): continue
		for index in range(copies):
			_resolution.queue.append({"source_id": source.instance_id, "owner": source.owner,
				"source": source.duplicate(true), "trigger": trigger, "ability_id": ability.get("id", ""),
				"effects": ability.effects.duplicate(true), "step": 0, "target_id": target_id,
				"started": false, "locked_targets": {}, "copy_index": index + 1, "copies": copies})


func ability_condition_matches(ability: Dictionary, context: Dictionary) -> bool:
	var condition: Dictionary = ability.get("condition", {})
	if condition.is_empty(): return true
	var owner: String = str(context.owner)
	match str(condition.get("kind", "")):
		"source_owner_active": return owner == str(_state.active_side)
		"owner_hq_damaged": return int(_state.sides[owner].hq_hp) < int(_state.sides[owner].get("hq_max_hp", _config.hq_max_hp))
	return false


func _drain_resolution(events: Array) -> void:
	while _state.phase == "active":
		if _resolution.current.is_empty():
			if _resolution.queue.is_empty():
				var ending: String = str(_resolution.after_end_turn)
				if not ending.is_empty():
					_resolution.after_end_turn = ""
					_state.active_side = _opponent(ending)
					_state.turn += 1
					_begin_turn(events)
					continue
				break
			_resolution.current = _resolution.queue.pop_front()
		var job: Dictionary = _resolution.current
		if not job.started:
			job.started = true
			_lock_ability_targets(job)
			events.append({"type": "ability_triggered", "source_id": job.source_id, "trigger": job.trigger,
				"ability_id": job.ability_id, "side": job.owner, "copy_index": job.copy_index, "copies": job.copies})
		while int(job.step) < job.effects.size() and _state.phase == "active":
			var effect: Dictionary = job.effects[int(job.step)]
			job.step += 1
			if str(effect.op) == "choose":
				_request_choice(effect, job, events)
			else:
				_apply_effect(effect, job, events)
		if _state.phase != "active": return
		_resolution.current = {}


func _request_choice(effect: Dictionary, job: Dictionary, events: Array) -> void:
	var targets: Array = Effects.candidates(str(effect.target), str(job.owner), _state)
	job.target_id = ""
	if targets.is_empty(): return
	_choice_serial += 1
	_state.pending_choice = {"choice_id": "choice-%d" % _choice_serial, "owner": job.owner,
		"source_id": job.source_id, "target_ids": targets}
	_state.phase = "waiting_choice"
	var event: Dictionary = _state.pending_choice.duplicate(true)
	event.type = "choice_requested"
	events.append(event)


func _lock_ability_targets(job: Dictionary) -> void:
	var deferred_choice: bool = false
	for index in range(job.effects.size()):
		var effect: Dictionary = job.effects[index]
		if effect.op == "choose":
			deferred_choice = true
			continue
		var selector: String = str(effect.get("target", ""))
		if deferred_choice and selector.begins_with("chosen_"): continue
		job.locked_targets[str(index)] = Effects.targets(selector, str(job.owner), str(job.target_id), _state)


func _lock_chosen_targets(job: Dictionary) -> void:
	for index in range(int(job.step), job.effects.size()):
		var effect: Dictionary = job.effects[index]
		if effect.op == "choose": break
		var selector: String = str(effect.get("target", ""))
		if selector.begins_with("chosen_"):
			job.locked_targets[str(index)] = Effects.targets(selector, str(job.owner), str(job.target_id), _state)


func _apply_effect(effect: Dictionary, job: Dictionary, events: Array) -> void:
	var targets: Array = job.locked_targets.get(str(int(job.step) - 1), []).duplicate()
	# Auto targets stay locked for the entire ability. Lost targets simply disappear.
	var still_valid: Array = Effects.targets(str(effect.get("target", "")), str(job.owner), str(job.target_id), _state)
	targets = targets.filter(func(id: Variant): return still_valid.has(id))
	var amount: int = int(effect.get("amount", 0))
	if effect.op == "damage":
		var packets: Array = []
		for target in targets: packets.append({"target_id": target, "amount": amount})
		_damage_batch(packets, str(job.source_id), "effect", events)
		return
	var batch: int = _next_batch()
	match str(effect.op):
		"draw":
			for target in targets:
				if not SIDES.has(target): continue
				for _index in range(amount):
					_draw_card(str(target), events)
					if _state.phase == "finished": return
		"heal":
			for target in targets:
				var before: int = _target_hp(str(target))
				if str(target).begins_with("hq:"):
					var side: Dictionary = _state.sides[str(target).trim_prefix("hq:")]
					side.hq_hp = mini(int(side.get("hq_max_hp", _config.hq_max_hp)), int(side.hq_hp) + amount)
				elif _zone_of(str(target)) in ["support", "frontline"]:
					var unit: Dictionary = _state.units[target]
					_ensure_runtime_values(unit)
					unit.damage_taken = maxi(0, int(unit.damage_taken) - amount)
					_recalculate(unit)
				else: continue
				events.append({"type": "healed", "source_id": job.source_id, "target_id": target,
					"amount": _target_hp(str(target)) - before, "remaining_hp": _target_hp(str(target)), "batch_id": batch})
		"modify_stats":
			for target in targets:
				if _zone_of(str(target)) not in ["support", "frontline"]: continue
				var unit: Dictionary = _state.units[target]
				_ensure_runtime_values(unit)
				var modifier: Dictionary = {"source_id": job.source_id, "operation": "add",
					"attack": int(effect.get("attack", 0)), "health": int(effect.get("health", 0)),
					"duration": effect.get("duration", "permanent")}
				if modifier.duration == "until_next_owner_turn_end":
					modifier.expires_owner_turn = int(_state.sides[unit.owner].turns_started) + 1
				unit.modifiers.append(modifier)
				_recalculate(unit)
				events.append({"type": "stats_modified", "source_id": job.source_id, "unit_id": target,
					"attack": unit.attack, "hp": unit.hp, "max_hp": unit.max_hp, "batch_id": batch})
		"suppress":
			for target in targets:
				if _zone_of(str(target)) not in ["support", "frontline"]: continue
				var unit: Dictionary = _state.units[target]
				_ensure_runtime_values(unit)
				var expires: int = int(_state.sides[unit.owner].turns_started) + 1
				expires = maxi(expires, int(unit.statuses.get("suppressed", {}).get("expires_owner_turn", 0)))
				unit.statuses.suppressed = {"expires_owner_turn": expires}
				events.append({"type": "status_applied", "source_id": job.source_id, "unit_id": target,
					"status": "suppressed", "expires_owner_turn": expires, "batch_id": batch})
	_stabilize(events, batch)


func _ensure_runtime_values(unit: Dictionary) -> void:
	if not unit.has("base_attack"): unit.base_attack = int(unit.attack)
	if not unit.has("base_max_hp"): unit.base_max_hp = int(unit.max_hp)
	if not unit.has("damage_taken"): unit.damage_taken = maxi(0, int(unit.max_hp) - int(unit.get("hp", unit.max_hp)))
	if not unit.has("modifiers"): unit.modifiers = []
	if not unit.has("statuses"): unit.statuses = {}
	for field in ["moved_this_turn", "attacked_this_turn", "deployed_this_turn"]:
		if not unit.has(field): unit[field] = false


func _ensure_entered_sequences() -> void:
	var last: int = int(_state.get("next_entered_sequence", 0))
	for owner in SIDES:
		for id in Effects.board_ids(_state, owner):
			last = maxi(last, int(_state.units[id].get("entered_sequence", 0)))
	for owner in SIDES:
		for id in Effects.board_ids(_state, owner):
			if int(_state.units[id].get("entered_sequence", 0)) <= 0:
				last += 1
				_state.units[id].entered_sequence = last
	_state.next_entered_sequence = last


func _remove_source_modifiers(events: Array, batch: int) -> void:
	for owner in SIDES:
		for id in Effects.board_ids(_state, owner):
			var unit: Dictionary = _state.units[id]
			var retained: Array = []
			var modifiers: Array = unit.get("modifiers", [])
			for modifier in modifiers:
				if modifier.get("duration", "permanent") != "while_source_on_battlefield" or _zone_of(str(modifier.get("source_id", ""))) in ["support", "frontline"]:
					retained.append(modifier)
			if retained.size() != modifiers.size():
				_ensure_runtime_values(unit)
				unit.modifiers = retained
				_recalculate(unit)
				events.append({"type": "stats_modified", "unit_id": id, "attack": unit.attack,
					"hp": unit.hp, "max_hp": unit.max_hp, "batch_id": batch})


func _recalculate(unit: Dictionary) -> void:
	var attack: int = int(unit.base_attack)
	var health: int = int(unit.base_max_hp)
	for modifier in unit.modifiers:
		attack += int(modifier.get("attack", 0))
		health += int(modifier.get("health", 0))
	unit.attack = maxi(0, attack)
	unit.max_hp = maxi(0, health)
	unit.hp = maxi(0, int(unit.max_hp) - int(unit.damage_taken))


func _is_suppressed(unit: Dictionary) -> bool:
	return unit.get("statuses", {}).has("suppressed")


func _expire_turn_state(owner: String, events: Array) -> void:
	var batch: int = _next_batch()
	var count: int = int(_state.sides[owner].turns_started)
	for id in Effects.board_ids(_state, owner):
		var unit: Dictionary = _state.units[id]
		_ensure_runtime_values(unit)
		if unit.statuses.has("suppressed") and int(unit.statuses.suppressed.expires_owner_turn) <= count:
			unit.statuses.erase("suppressed")
			events.append({"type": "status_expired", "unit_id": id, "status": "suppressed", "batch_id": batch})
		var retained: Array = []
		for modifier in unit.modifiers:
			if not modifier.has("expires_owner_turn") or int(modifier.expires_owner_turn) > count:
				retained.append(modifier)
		if retained.size() != unit.modifiers.size():
			unit.modifiers = retained
			_recalculate(unit)
			events.append({"type": "stats_modified", "unit_id": id, "attack": unit.attack,
				"hp": unit.hp, "max_hp": unit.max_hp, "batch_id": batch})
	_stabilize(events, batch)


func _begin_turn(events: Array) -> void:
	var side: String = str(_state.active_side)
	var value: Dictionary = _state.sides[side]
	value.turns_started += 1
	value.max_command_points = mini(int(_config.command_point_limit), int(value.max_command_points) + int(_config.command_point_growth))
	value.command_points = value.max_command_points
	for unit in _state.units.values():
		if unit.owner == side and _is_unit(unit):
			unit.deployed_this_turn = false
			unit.moved_this_turn = false
			unit.attacked_this_turn = false
	events.append({"type": "turn_started", "side": side, "turn": _state.turn,
		"command_points": value.command_points, "max_command_points": value.max_command_points})
	if not (side == _state.first_side and int(value.turns_started) == 1):
		for _index in range(int(_config.turn_draw_count)):
			_draw_card(side, events)
			if _state.phase == "finished": break


func _spend(side: String, amount: int, events: Array) -> void:
	_state.sides[side].command_points -= amount
	events.append({"type": "command_points_spent", "side": side, "amount": amount, "remaining": _state.sides[side].command_points})


func _draw_card(side: String, events: Array) -> void:
	if _state.phase == "finished": return
	if _state.sides[side].draw_ids.is_empty():
		_state.sides[side].fatigue = int(_config.fatigue_initial) if int(_state.sides[side].fatigue) == 0 else int(_state.sides[side].fatigue) + int(_config.fatigue_increment)
		var damage: int = int(_state.sides[side].fatigue)
		_state.sides[side].hq_hp = maxi(0, int(_state.sides[side].hq_hp) - damage)
		var batch: int = _next_batch()
		events.append({"type": "fatigue_damage", "side": side, "damage": damage,
			"remaining_hp": _state.sides[side].hq_hp, "batch_id": batch})
		_stabilize(events, batch)
		return
	_receive_card(side, str(_state.sides[side].draw_ids.pop_front()), events)


func _receive_card(side: String, id: String, events: Array) -> void:
	if _state.sides[side].hand_ids.size() >= int(_config.hand_limit):
		_state.sides[side].discard_ids.append(id)
		events.append({"type": "hand_overflow", "side": side, "unit_id": id})
	else:
		_state.sides[side].hand_ids.append(id)
		events.append({"type": "card_drawn", "side": side, "unit_id": id})


func _check_winner(events: Array) -> void:
	if _state.phase == "finished": return
	var defeated: Array = []
	for side in SIDES:
		if int(_state.sides[side].hq_hp) <= 0: defeated.append(side)
	if defeated.is_empty(): return
	_state.phase = "finished"
	_state.winner = "draw" if defeated.size() == 2 else _opponent(str(defeated[0]))
	_state.pending_choice = {}
	if not _resolution.is_empty():
		_resolution.queue.clear()
		_resolution.current = {}
		_resolution.after_end_turn = ""
	events.append({"type": "battle_finished", "winner": _state.winner})


func _target_hp(id: String) -> int:
	if id.begins_with("hq:"): return int(_state.sides[id.trim_prefix("hq:")].hq_hp)
	return int(_state.units.get(id, {}).get("hp", 0))


func _zone_of(id: String) -> String:
	if _state.frontline_ids.has(id): return "frontline"
	for side in SIDES:
		for zone in ["hand", "draw", "discard", "support"]:
			if _state.sides[side][zone + "_ids"].has(id): return zone
	return ""


static func _is_unit(card: Dictionary) -> bool:
	return str(card.get("card_type", "unit")) == "unit"


func _opponent(side: String) -> String:
	return "ai" if side == "player" else "player"


func _next_batch() -> int:
	_batch_serial += 1
	return _batch_serial


func _shuffle(values: Array, random_source: RandomNumberGenerator = null) -> void:
	var generator: RandomNumberGenerator = _random if random_source == null else random_source
	for index in range(values.size() - 1, 0, -1):
		var other: int = generator.randi_range(0, index)
		var previous: Variant = values[index]
		values[index] = values[other]
		values[other] = previous


func _accepted(events: Array) -> Dictionary:
	return {"accepted": true, "reason": "", "events": events.duplicate(true), "awaiting_choice": _state.phase == "waiting_choice"}
