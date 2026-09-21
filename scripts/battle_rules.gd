class_name BattleRules
extends RefCounted
## Commands own all mutations. Zone ID lists are authoritative.
## support_ids contains only units; hq_index counts the units left of the HQ.

const RuleConfig = preload("res://scripts/config/rule_config.gd")
const SIDES: Array[String] = ["player", "ai"]

var _state: Dictionary = {}
var _config: Resource
var _random: RandomNumberGenerator = RandomNumberGenerator.new()
var _mulligan_random: Dictionary = {}


func setup(seed_value: int, rule_config: Resource, card_definitions: Dictionary, decks_by_side: Dictionary) -> Dictionary:
	if not _valid_setup(rule_config, card_definitions, decks_by_side):
		return {"accepted": false, "reason": "invalid_setup", "events": []}
	_config = rule_config.duplicate(true)
	_random.seed = seed_value
	_mulligan_random.clear()
	for side in SIDES:
		var generator: RandomNumberGenerator = RandomNumberGenerator.new()
		generator.seed = seed_value ^ (int(_config.player_mulligan_seed_salt) if side == "player" else int(_config.ai_mulligan_seed_salt))
		_mulligan_random[side] = generator
	var first_side: String = SIDES[_random.randi_range(0, 1)]
	_state = {
		"seed": seed_value, "turn": 0, "first_side": first_side, "active_side": first_side,
		"phase": "mulligan", "winner": "", "sides": {},
		"frontline_ids": [], "units": {},
		"limits": {
			"hand_limit": _config.hand_limit, "support_limit": _config.support_limit,
			"frontline_limit": _config.frontline_limit, "command_point_limit": _config.command_point_limit,
		},
	}
	for side in SIDES:
		_state.sides[side] = {
			"hq_hp": _config.hq_max_hp, "hq_max_hp": _config.hq_max_hp,
			"hq_index": 0, "fatigue": 0, "command_points": 0, "max_command_points": 0,
			"turns_started": 0, "mulligan_done": false,
			"hand_ids": [], "draw_ids": [], "discard_ids": [], "support_ids": [],
		}
		var deck: Array = decks_by_side[side].duplicate()
		# IDs do not reveal definitions or the order of hidden cards.
		_shuffle(deck)
		for index in range(deck.size()):
			var instance_id: String = "%s-%02d" % [side, index + 1]
			var unit: Dictionary = card_definitions[deck[index]].duplicate(true)
			unit.merge({
				"card_id": deck[index],
				"instance_id": instance_id, "owner": side, "hp": unit.max_hp,
				"moved_this_turn": false, "attacked_this_turn": false, "deployed_this_turn": false,
			}, true)
			_state.units[instance_id] = unit
			_state.sides[side].draw_ids.append(instance_id)
		_shuffle(_state.sides[side].draw_ids)
	var events: Array = [{"type": "battle_started", "seed": seed_value, "first_side": first_side}]
	for side in SIDES:
		for _index in range(int(_config.first_hand_count) if side == first_side else int(_config.second_hand_count)):
			_draw_card(side, events)
	return _accepted(events)


func _valid_setup(rule_config: Resource, card_definitions: Dictionary, decks_by_side: Dictionary) -> bool:
	# Validate everything before replacing either domain state or random generators.
	if not rule_config is RuleConfig:
		return false
	for field in ["hq_max_hp", "hand_limit", "support_limit", "frontline_limit", "command_point_growth", "command_point_limit", "fatigue_initial"]:
		if int(rule_config.get(field)) <= 0:
			return false
	for field in ["first_hand_count", "second_hand_count", "turn_draw_count", "fatigue_increment"]:
		if int(rule_config.get(field)) < 0:
			return false
	if rule_config.first_hand_count > rule_config.hand_limit or rule_config.second_hand_count > rule_config.hand_limit:
		return false
	for side in SIDES:
		if not decks_by_side.get(side) is Array:
			return false
		for card_id in decks_by_side[side]:
			if not card_id is String or not card_definitions.get(card_id) is Dictionary:
				return false
			var card: Dictionary = card_definitions[card_id]
			if card.get("unit_type") not in ["infantry", "tank", "artillery", "fighter", "bomber"]:
				return false
			for field in ["deploy_cost", "action_cost", "attack", "max_hp"]:
				if not card.get(field) is int or int(card[field]) < 0:
					return false
			if int(card.max_hp) == 0:
				return false
	return true


func validation_reason(action: Dictionary, actor: String = "player") -> String:
	## Read-only command validation shared by previews and execution.
	return _validate(action, actor)


func execute(action: Dictionary, actor: String = "player") -> Dictionary:
	var reason: String = validation_reason(action, actor)
	if not reason.is_empty():
		return {"accepted": false, "reason": reason, "events": []}
	var events: Array = []
	var unit_id: String = str(action.get("unit_id", ""))
	match str(action.type):
		"mulligan":
			_resolve_mulligan(action.unit_ids, actor, events)
		"deploy":
			var side: Dictionary = _state.sides[actor]
			var deploy_index: int = int(action.get("insert_index", side.support_ids.size() + 1))
			var before_hq: bool = deploy_index <= int(side.hq_index)
			_spend(actor, int(_state.units[unit_id].deploy_cost), events)
			side.hand_ids.erase(unit_id)
			side.support_ids.insert(deploy_index if before_hq else deploy_index - 1, unit_id)
			if before_hq:
				side.hq_index += 1
			_state.units[unit_id].deployed_this_turn = true
			events.append({"type": "unit_deployed", "side": actor, "unit_id": unit_id, "insert_index": deploy_index})
		"move":
			var move_index: int = int(action.get("insert_index", _state.frontline_ids.size()))
			_spend(actor, int(_state.units[unit_id].action_cost), events)
			_remove_from_support(unit_id)
			_state.frontline_ids.insert(move_index, unit_id)
			_state.units[unit_id].moved_this_turn = true
			events.append({"type": "unit_moved", "side": actor, "unit_id": unit_id, "to": "frontline", "insert_index": move_index})
		"attack":
			_spend(actor, int(_state.units[unit_id].action_cost), events)
			_resolve_attack(unit_id, str(action.target_id), events)
		"end_turn":
			events.append({"type": "turn_ended", "side": actor, "turn": _state.turn})
			_state.active_side = _opponent(actor)
			_state.turn += 1
			_begin_turn(events)
	_check_winner(events)
	return _accepted(events)


func legal_actions(actor: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _state.is_empty() or not SIDES.has(actor) or _state.phase == "finished":
		return result
	if _state.phase == "mulligan":
		if _state.sides[actor].mulligan_done:
			return result
		var hand: Array = _state.sides[actor].hand_ids
		for mask in range(1 << hand.size()):
			var replacements: Array = []
			for index in range(hand.size()):
				if mask & (1 << index):
					replacements.append(hand[index])
			result.append({"type": "mulligan", "unit_ids": replacements})
		return result
	if _state.active_side != actor:
		return result
	var ids: Array = _state.units.keys()
	ids.sort()
	var targets: Array = ids.duplicate()
	targets.append("hq:" + _opponent(actor))
	for unit_id in ids:
		if _state.units[unit_id].owner != actor:
			continue
		for kind in ["deploy", "move"]:
			var candidate: Dictionary = {"type": kind, "unit_id": unit_id}
			if _validate(candidate, actor).is_empty():
				var last_index: int = _state.sides[actor].support_ids.size() + 1 if kind == "deploy" else _state.frontline_ids.size()
				for index in range(last_index + 1):
					result.append({"type": kind, "unit_id": unit_id, "insert_index": index})
		for target_id in targets:
			var candidate: Dictionary = {"type": "attack", "unit_id": unit_id, "target_id": target_id}
			if _validate(candidate, actor).is_empty():
				result.append(candidate)
	result.append({"type": "end_turn"})
	return result


func snapshot() -> Dictionary:
	var result: Dictionary = _state.duplicate(true)
	if result.is_empty():
		return result
	for side in SIDES:
		for zone in ["hand", "draw", "discard", "support"]:
			result.sides[side][zone + "_count"] = result.sides[side][zone + "_ids"].size()
	for unit_id in result.units:
		result.units[unit_id]["zone"] = _zone_of(str(unit_id))
		result.units[unit_id]["ready"] = _is_ready(str(unit_id))
	return result


func side_view(viewer: String) -> Dictionary:
	## Gameplay views omit unknown cards; the MCP diagnostic snapshot is complete.
	var result: Dictionary = snapshot()
	if not SIDES.has(viewer) or result.is_empty():
		return {}
	for side in SIDES:
		var hidden: Array = result.sides[side].draw_ids.duplicate()
		result.sides[side].erase("draw_ids")
		if side != viewer:
			hidden.append_array(result.sides[side].hand_ids)
			result.sides[side].erase("hand_ids")
		for unit_id in hidden:
			result.units.erase(unit_id)
	result.erase("seed")
	return result


func _validate(action: Dictionary, actor: String) -> String:
	if _state.is_empty() or _state.phase == "finished":
		return "battle_finished"
	if not SIDES.has(actor):
		return "not_your_turn"
	var kind: String = str(action.get("type", ""))
	if _state.phase == "mulligan":
		if kind != "mulligan":
			return "mulligan_required"
		if _state.sides[actor].mulligan_done:
			return "mulligan_already_done"
		if not action.get("unit_ids") is Array:
			return "invalid_mulligan"
		var seen: Array = []
		for value in action.unit_ids:
			if not value is String or seen.has(value) or not _state.sides[actor].hand_ids.has(value):
				return "invalid_mulligan"
			seen.append(value)
		return ""
	if _state.active_side != actor:
		return "not_your_turn"
	if kind == "end_turn":
		return ""
	if kind not in ["deploy", "move", "attack"]:
		return "unknown_action"
	var unit_id: String = str(action.get("unit_id", ""))
	if not _state.units.has(unit_id):
		return "unknown_unit"
	var unit: Dictionary = _state.units[unit_id]
	if unit.owner != actor:
		return "not_your_unit"
	var zone: String = _zone_of(unit_id)
	if kind == "deploy":
		if zone != "hand":
			return "unit_not_in_hand"
		if _state.sides[actor].support_ids.size() >= int(_config.support_limit):
			return "support_full"
		if not _valid_insert_index(action, _state.sides[actor].support_ids.size() + 1):
			return "invalid_insert_index"
		return "insufficient_command_points" if int(_state.sides[actor].command_points) < int(unit.deploy_cost) else ""
	if zone not in ["support", "frontline"]:
		return "unit_not_on_battlefield"
	if unit.deployed_this_turn:
		return "unit_not_ready"
	if kind == "move":
		if zone != "support":
			return "cannot_retreat"
		if unit.moved_this_turn or (unit.unit_type != "tank" and unit.attacked_this_turn):
			return "unit_not_ready"
		if not _state.frontline_ids.is_empty() and _state.units[_state.frontline_ids[0]].owner != actor:
			return "enemy_controls_frontline"
		if _state.frontline_ids.size() >= int(_config.frontline_limit):
			return "frontline_full"
		if not _valid_insert_index(action, _state.frontline_ids.size()):
			return "invalid_insert_index"
	else:
		if unit.attacked_this_turn or (unit.unit_type != "tank" and unit.moved_this_turn):
			return "unit_not_ready"
		var target_reason: String = _validate_target(unit_id, str(action.get("target_id", "")), zone)
		if not target_reason.is_empty():
			return target_reason
	if int(_state.sides[actor].command_points) < int(unit.action_cost):
		return "insufficient_command_points"
	return ""


func _valid_insert_index(action: Dictionary, last_index: int) -> bool:
	if not action.has("insert_index"):
		return true
	var index: Variant = action.insert_index
	return index is int and index >= 0 and index <= last_index


func _remove_from_support(unit_id: String) -> void:
	var side: Dictionary = _state.sides[_state.units[unit_id].owner]
	var index: int = side.support_ids.find(unit_id)
	if index < 0:
		return
	if index < int(side.hq_index):
		side.hq_index -= 1
	side.support_ids.remove_at(index)


func _validate_target(attacker_id: String, target_id: String, attacker_zone: String) -> String:
	var attacker: Dictionary = _state.units[attacker_id]
	var enemy: String = _opponent(str(attacker.owner))
	var target_zone: String = "support"
	var target_type: String = "hq"
	if target_id != "hq:" + enemy:
		if not _state.units.has(target_id):
			return "invalid_target"
		if _state.units[target_id].owner == attacker.owner:
			return "friendly_target"
		target_zone = _zone_of(target_id)
		if target_zone not in ["support", "frontline"]:
			return "target_out_of_range"
		target_type = str(_state.units[target_id].unit_type)
	if attacker.unit_type in ["infantry", "tank"]:
		if not ((attacker_zone == "support" and target_zone == "frontline") or (attacker_zone == "frontline" and target_zone == "support")):
			return "target_out_of_range"
	if attacker.unit_type == "bomber" and target_type != "fighter":
		var row: Array = _state.frontline_ids if target_zone == "frontline" else _state.sides[enemy].support_ids
		for unit_id in row:
			if _state.units[unit_id].owner == enemy and _state.units[unit_id].unit_type == "fighter":
				return "fighter_cover"
	return ""


func _is_ready(unit_id: String) -> bool:
	var unit: Dictionary = _state.units[unit_id]
	var zone: String = _zone_of(unit_id)
	if zone not in ["support", "frontline"] or unit.deployed_this_turn:
		return false
	if unit.unit_type == "tank":
		return not unit.attacked_this_turn or (zone == "support" and not unit.moved_this_turn)
	return not unit.moved_this_turn and not unit.attacked_this_turn


func _resolve_mulligan(unit_ids: Array, actor: String, events: Array) -> void:
	var replacements: Array = unit_ids.duplicate()
	# Canonical ordering makes identical selections independent of click order.
	replacements.sort()
	for unit_id in replacements:
		_state.sides[actor].hand_ids.erase(unit_id)
	for _unit_id in replacements:
		_draw_card(actor, events)
	_state.sides[actor].draw_ids.append_array(replacements)
	if not replacements.is_empty():
		_shuffle(_state.sides[actor].draw_ids, _mulligan_random[actor])
	_state.sides[actor].mulligan_done = true
	events.append({"type": "mulligan_completed", "side": actor, "replaced_count": replacements.size()})
	if _state.sides.player.mulligan_done and _state.sides.ai.mulligan_done:
		_state.phase = "active"
		_state.turn = 1
		_begin_turn(events)


func _resolve_attack(attacker_id: String, target_id: String, events: Array) -> void:
	var attacker: Dictionary = _state.units[attacker_id]
	attacker.attacked_this_turn = true
	if target_id.begins_with("hq:"):
		var side: String = target_id.trim_prefix("hq:")
		_state.sides[side].hq_hp = maxi(0, int(_state.sides[side].hq_hp) - int(attacker.attack))
		events.append({"type": "hq_attacked", "attacker_id": attacker_id, "target_id": target_id,
			"damage": attacker.attack, "remaining_hp": _state.sides[side].hq_hp})
		return
	var defender: Dictionary = _state.units[target_id]
	# Read both attack values before damage, including a dying defender's.
	var outgoing: int = int(attacker.attack)
	var retaliation: int = retaliation_damage(attacker, defender)
	attacker.hp = maxi(0, int(attacker.hp) - retaliation)
	defender.hp = maxi(0, int(defender.hp) - outgoing)
	events.append({"type": "units_battled", "attacker_id": attacker_id, "target_id": target_id,
		"damage_to_target": outgoing, "damage_to_attacker": retaliation,
		"attacker_hp": attacker.hp, "target_hp": defender.hp})
	var casualties: Array = [attacker_id, target_id]
	casualties.sort()
	for unit_id in casualties:
		var unit: Dictionary = _state.units[unit_id]
		if unit.hp <= 0:
			_remove_from_support(unit_id)
			_state.frontline_ids.erase(unit_id)
			_state.sides[unit.owner].discard_ids.append(unit_id)
			events.append({"type": "unit_destroyed", "unit_id": unit_id, "side": unit.owner})


static func retaliation_damage(attacker: Dictionary, defender: Dictionary) -> int:
	if attacker.unit_type == "artillery" or defender.unit_type == "bomber":
		return 0
	if attacker.unit_type == "bomber" and defender.unit_type != "fighter":
		return 0
	return int(defender.attack)


func _begin_turn(events: Array) -> void:
	var side: String = _state.active_side
	var side_state: Dictionary = _state.sides[side]
	side_state.turns_started += 1
	side_state.max_command_points = mini(int(_config.command_point_limit), int(side_state.max_command_points) + int(_config.command_point_growth))
	side_state.command_points = side_state.max_command_points
	for unit_id in _state.units:
		if _state.units[unit_id].owner == side:
			_state.units[unit_id].deployed_this_turn = false
			_state.units[unit_id].moved_this_turn = false
			_state.units[unit_id].attacked_this_turn = false
	events.append({"type": "turn_started", "side": side, "turn": _state.turn,
		"command_points": side_state.command_points, "max_command_points": side_state.max_command_points})
	if not (side == _state.first_side and int(side_state.turns_started) == 1):
		for _index in range(int(_config.turn_draw_count)):
			_draw_card(side, events)
			if _state.phase == "finished":
				break


func _spend(side: String, amount: int, events: Array) -> void:
	_state.sides[side].command_points -= amount
	events.append({"type": "command_points_spent", "side": side, "amount": amount,
		"remaining": _state.sides[side].command_points})


func _draw_card(side: String, events: Array) -> void:
	if _state.sides[side].draw_ids.is_empty():
		_state.sides[side].fatigue = int(_config.fatigue_initial) if int(_state.sides[side].fatigue) == 0 else int(_state.sides[side].fatigue) + int(_config.fatigue_increment)
		var damage: int = int(_state.sides[side].fatigue)
		_state.sides[side].hq_hp = maxi(0, int(_state.sides[side].hq_hp) - damage)
		events.append({"type": "fatigue_damage", "side": side, "damage": damage,
			"remaining_hp": _state.sides[side].hq_hp})
		_check_winner(events)
		return
	var unit_id: String = str(_state.sides[side].draw_ids.pop_front())
	_receive_card(side, unit_id, events)


func _receive_card(side: String, unit_id: String, events: Array) -> void:
	if _state.sides[side].hand_ids.size() >= int(_config.hand_limit):
		_state.sides[side].discard_ids.append(unit_id)
		events.append({"type": "hand_overflow", "side": side, "unit_id": unit_id})
	else:
		_state.sides[side].hand_ids.append(unit_id)
		events.append({"type": "card_drawn", "side": side, "unit_id": unit_id})


func _check_winner(events: Array) -> void:
	if _state.phase == "finished":
		return
	for side in SIDES:
		if _state.sides[side].hq_hp <= 0:
			_state.phase = "finished"
			_state.winner = _opponent(side)
			events.append({"type": "battle_finished", "winner": _state.winner})
			return


func _zone_of(unit_id: String) -> String:
	if _state.frontline_ids.has(unit_id):
		return "frontline"
	for side in SIDES:
		for zone in ["hand", "draw", "discard", "support"]:
			if _state.sides[side][zone + "_ids"].has(unit_id):
				return zone
	return ""


func _opponent(side: String) -> String:
	return "ai" if side == "player" else "player"


func _shuffle(values: Array, random_source: RandomNumberGenerator = null) -> void:
	var generator: RandomNumberGenerator = _random if random_source == null else random_source
	for index in range(values.size() - 1, 0, -1):
		var other: int = generator.randi_range(0, index)
		var previous: Variant = values[index]
		values[index] = values[other]
		values[other] = previous


func _accepted(events: Array) -> Dictionary:
	return {"accepted": true, "reason": "", "events": events.duplicate(true)}
