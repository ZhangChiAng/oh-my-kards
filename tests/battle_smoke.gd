extends SceneTree
## Domain checks inject definitions and states; they never open the personal library.

const Rules = preload("res://scripts/battle_rules.gd")
const Policy = preload("res://scripts/ai_policy.gd")
const Catalog = preload("res://scripts/card_catalog.gd")
const Schema = preload("res://scripts/card_schema.gd")
const TEST_SEED: int = 20260917
const UNIT_TYPES: Array[String] = ["infantry", "tank", "artillery", "fighter", "bomber"]

var _run_id: String = ""
var _output_dir: String = ""
var _assertions: int = 0
var _failures: Array[String] = []
var _trace: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_read_arguments()
	_test_factory_definitions()
	_test_opening_and_views()
	_test_support_positions()
	_test_frontline_positions_and_departures()
	_test_turns_and_actions()
	_test_combat_matrix_and_cover()
	_test_overflow_fatigue_and_finish()
	_test_simple_ai()
	_test_keywords_and_orders()
	_test_modifiers_and_suppression()
	_test_aftermath_resolution()
	_test_choice_and_conditions()
	_test_effect_ai_and_privacy()
	_test_complete_battle()
	DirAccess.make_dir_recursive_absolute(_output_dir)
	_write_result()
	quit(0 if _failures.is_empty() else 1)


func _read_arguments() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for index in range(args.size()):
		if args[index] == "--run-id" and index + 1 < args.size():
			_run_id = args[index + 1]
		elif args[index].begins_with("--run-id="):
			_run_id = args[index].trim_prefix("--run-id=")
		elif args[index] == "--output-dir" and index + 1 < args.size():
			_output_dir = args[index + 1]
		elif args[index].begins_with("--output-dir="):
			_output_dir = args[index].trim_prefix("--output-dir=")
	if _run_id.is_empty():
		_run_id = "manual-rules-%d" % Time.get_ticks_usec()
	if _output_dir.is_empty():
		_output_dir = "res://artifacts/" + _run_id
	_output_dir = ProjectSettings.globalize_path(_output_dir)


func _fresh() -> Rules:
	var rules: Rules = Rules.new()
	rules.setup(TEST_SEED, preload("res://resources/rules/approved_rules.tres"), Catalog.CARDS, {"player": Catalog.preset_deck(), "ai": Catalog.preset_deck()})
	return rules


func _fixture(actor: String = "player") -> Rules:
	var rules: Rules = _fresh()
	rules._state = {"seed": TEST_SEED, "turn": 1, "first_side": "player", "active_side": actor,
		"phase": "active", "winner": "", "frontline_ids": [], "units": {}, "sides": {}}
	for side in ["player", "ai"]:
		rules._state.sides[side] = {"hq_hp": 20, "hq_index": 0, "fatigue": 0,
			"command_points": 12, "max_command_points": 12, "turns_started": 12, "mulligan_done": true,
			"hand_ids": [], "draw_ids": [], "discard_ids": [], "support_ids": []}
	return rules


func _put(rules: Rules, id: String, owner: String, zone: String, kind: String = "infantry",
		attack: int = 3, hp: int = 7, deploy_cost: int = 1, action_cost: int = 1) -> void:
	rules._state.units[id] = {"instance_id": id, "owner": owner, "card_id": "fixture-" + kind,
		"name": "Fixture " + kind, "unit_type": kind, "attack": attack, "max_hp": hp, "hp": hp,
		"deploy_cost": deploy_cost, "action_cost": action_cost,
		"moved_this_turn": false, "attacked_this_turn": false, "deployed_this_turn": false}
	if zone == "frontline":
		rules._state.frontline_ids.append(id)
	else:
		rules._state.sides[owner][zone + "_ids"].append(id)


func _check(condition: bool, label: String) -> void:
	_assertions += 1
	if not condition:
		_failures.append(label)
		printerr("RULES ASSERTION FAILED: " + label)


func _commit(rules: Rules, action: Dictionary, label: String, actor: String = "player") -> Dictionary:
	var before: Dictionary = rules.snapshot()
	var reason: String = rules.validation_reason(action, actor)
	_check(reason.is_empty() and rules.snapshot() == before, label + ": validation accepts without mutation")
	var result: Dictionary = rules.execute(action, actor)
	_check(result.accepted and result.reason == reason and not result.events.is_empty(), label + ": committed (" + str(result.reason) + ")")
	return rules.snapshot()


func _reject(rules: Rules, action: Dictionary, label: String, actor: String = "player") -> void:
	var before: Dictionary = rules.snapshot()
	var reason: String = rules.validation_reason(action, actor)
	_check(not reason.is_empty() and rules.snapshot() == before, label + ": validation rejects without mutation")
	var result: Dictionary = rules.execute(action, actor)
	_check(not result.accepted and result.reason == reason and result.events.is_empty() and rules.snapshot() == before,
		label + ": rejected without mutation")


func _record(rules: Rules, label: String) -> void:
	var state: Dictionary = rules.snapshot()
	_trace.append({"step": label, "state": state})
	_check(_consistent(state), label + ": identities, rows, HP and points remain valid")


func _consistent(state: Dictionary) -> bool:
	var seen: Array = []
	for side in ["player", "ai"]:
		var participant: Dictionary = state.sides[side]
		if participant.hq_hp < 0 or participant.hand_ids.size() > 9 or participant.support_ids.size() > 4:
			return false
		if participant.hq_index < 0 or participant.hq_index > participant.support_ids.size():
			return false
		if participant.command_points < 0 or participant.command_points > participant.max_command_points or participant.max_command_points > 12:
			return false
		for zone in ["hand", "draw", "discard", "support"]:
			var ids: Array = participant[zone + "_ids"]
			if participant[zone + "_count"] != ids.size():
				return false
			for id in ids:
				if seen.has(id) or not state.units.has(id) or state.units[id].owner != side or state.units[id].zone != zone:
					return false
				seen.append(id)
	if state.frontline_ids.size() > 5:
		return false
	var front_owner: String = ""
	for id in state.frontline_ids:
		if seen.has(id) or not state.units.has(id) or state.units[id].zone != "frontline":
			return false
		var owner: String = str(state.units[id].owner)
		if not front_owner.is_empty() and front_owner != owner:
			return false
		front_owner = owner
		seen.append(id)
	for id in state.units:
		var unit: Dictionary = state.units[id]
		if unit.instance_id != id:
			return false
		if unit.get("card_type", "unit") == "unit" and (unit.hp < 0 or unit.hp > unit.max_hp):
			return false
	return seen.size() == state.units.size()


func _choose(rules: Rules) -> Dictionary:
	var actor: String = str(rules.snapshot().active_side)
	return Policy.new().choose_action(rules.legal_actions(actor), rules.side_view(actor))


func _test_factory_definitions() -> void:
	_check(Catalog.CARDS.size() == 20 and Catalog.preset_deck().size() == 40, "catalogue: twenty definitions and forty-card fixture deck")
	var orders: int = 0
	for id in Catalog.CARDS:
		var definition: Dictionary = Schema.normalize_definition(Catalog.CARDS[id])
		_check(Schema.validate_definition(definition).is_empty(), "catalogue: valid definition " + id)
		_check(Catalog.preset_deck().count(id) == 2, "catalogue: two copies of " + id)
		if definition.card_type == "order": orders += 1
	_check(orders == 6, "catalogue: six orders and fourteen units")


func _test_opening_and_views() -> void:
	var rules: Rules = _fresh()
	var opening: Dictionary = rules.snapshot()
	_check(opening.phase == "mulligan" and opening.turn == 0 and opening.units.size() == 80, "opening: separate HQs and forty cards each")
	_check(_fresh().snapshot() == opening, "opening: same seed reproduces state")
	var compositions: Dictionary = {}
	for side in ["player", "ai"]:
		var participant: Dictionary = opening.sides[side]
		var count: int = 4 if side == opening.first_side else 5
		_check(participant.hq_hp == 20 and participant.hq_index == 0 and participant.hand_count == count and participant.draw_count == 40 - count,
			"opening: HQ and initial hand " + side)
		var composition: Dictionary = {}
		for unit in opening.units.values():
			if unit.owner == side:
				composition[unit.card_id] = int(composition.get(unit.card_id, 0)) + 1
		compositions[side] = composition
	_check(compositions.player == compositions.ai and compositions.player.size() == 20,
		"opening: equal fixed twenty-definition presets")
	var hand: Array = opening.sides.player.hand_ids
	_reject(rules, {"type": "deploy", "unit_id": hand[0]}, "opening: play waits for mulligan")
	_reject(rules, {"type": "mulligan", "unit_ids": [hand[0], hand[0]]}, "opening: duplicate replacement")
	var selected: Array = hand.slice(0, 2)
	var pending: Dictionary = _commit(rules, {"type": "mulligan", "unit_ids": selected}, "opening: replace two")
	_check(pending.phase == "mulligan" and pending.sides.player.hand_count == hand.size(), "opening: waits for second confirmation")
	for id in selected:
		_check(not pending.sides.player.hand_ids.has(id) and pending.sides.player.draw_ids.has(id), "opening: replacement cannot redraw same instance")
	_reject(rules, {"type": "mulligan", "unit_ids": []}, "opening: one confirmation only")
	var active: Dictionary = _commit(rules, {"type": "mulligan", "unit_ids": []}, "opening: start", "ai")
	_check(active.phase == "active" and active.turn == 1 and active.sides[active.first_side].command_points == 1,
		"opening: both confirmations begin first turn")
	_check(active.sides[active.first_side].hand_count == 4, "opening: first turn skips draw")
	var view: Dictionary = rules.side_view("ai")
	_check(not view.has("seed") and not view.sides.player.has("hand_ids") and not view.sides.ai.has("draw_ids"), "view: hidden order and seed absent")
	for id in active.sides.player.hand_ids + active.sides.player.draw_ids + active.sides.ai.draw_ids:
		_check(not view.units.has(id), "view: unknown card omitted")
	var isolated: Dictionary = rules.snapshot()
	isolated.sides.player.hand_ids.clear()
	isolated.sides.player.hq_index = 99
	_check(rules.snapshot() == active, "view: snapshot mutations cannot change rules")
	_record(rules, "opening-and-views")


func _test_support_positions() -> void:
	var orders: Array = [["new", "left", "right"], ["left", "new", "right"], ["left", "new", "right"], ["left", "right", "new"]]
	for actor in ["player", "ai"]:
		for gap in range(4):
			var rules: Rules = _fixture(actor)
			_put(rules, "left", actor, "support")
			_put(rules, "right", actor, "support")
			_put(rules, "new", actor, "hand")
			rules._state.sides[actor].hq_index = 1
			var action: Dictionary = {"type": "deploy", "unit_id": "new", "insert_index": gap}
			_check(rules.legal_actions(actor).has(action), "support: every visible gap advertised")
			var state: Dictionary = _commit(rules, action, "support: insert gap %d/%s" % [gap, actor], actor)
			_check(state.sides[actor].support_ids == orders[gap] and state.sides[actor].hq_index == (2 if gap < 2 else 1),
				"support: precise order around HQ")
			_record(rules, "support/%s/%d" % [actor, gap])
	for gap in [0, 1]:
		var rules: Rules = _fixture()
		_put(rules, "new", "player", "hand")
		var state: Dictionary = _commit(rules, {"type": "deploy", "unit_id": "new", "insert_index": gap}, "support: empty row HQ side")
		_check(state.sides.player.hq_index == 1 - gap and state.sides.player.support_ids == ["new"], "support: first card either side of HQ")
	var rules: Rules = _fixture()
	_put(rules, "new", "player", "hand")
	for index in [-1, 2, 0.5, "0"]:
		_reject(rules, {"type": "deploy", "unit_id": "new", "insert_index": index}, "support: invalid gap")
	var state: Dictionary = _commit(rules, {"type": "deploy", "unit_id": "new"}, "support: default rightmost")
	_check(state.sides.player.hq_index == 0, "support: omitted index places right of HQ")
	for index in range(3):
		_put(rules, "rear%d" % index, "player", "support")
	_put(rules, "extra", "player", "hand")
	_reject(rules, {"type": "deploy", "unit_id": "extra", "insert_index": 0}, "support: four units plus HQ is full")
	_reject(rules, {"type": "deploy", "unit_id": "new", "insert_index": 0}, "support: no same-row rearrangement")
	_reject(rules, {"type": "move", "unit_id": "hq:player"}, "support: HQ cannot move")
	_record(rules, "support/capacity-and-rejections")


func _test_frontline_positions_and_departures() -> void:
	var orders: Array = [["left", "front-a", "front-b"], ["front-a", "left", "front-b"], ["front-a", "front-b", "left"]]
	for gap in range(3):
		var rules: Rules = _fixture()
		_put(rules, "left", "player", "support")
		_put(rules, "right", "player", "support")
		rules._state.sides.player.hq_index = 1
		_put(rules, "front-a", "player", "frontline")
		_put(rules, "front-b", "player", "frontline")
		var action: Dictionary = {"type": "move", "unit_id": "left", "insert_index": gap}
		_check(rules.legal_actions("player").has(action), "frontline: each gap advertised")
		var state: Dictionary = _commit(rules, action, "frontline: insert")
		_check(state.frontline_ids == orders[gap] and state.sides.player.hq_index == 0 and state.sides.player.support_ids == ["right"],
			"frontline: exact order and left departure updates HQ")
		_reject(rules, {"type": "move", "unit_id": "front-a", "insert_index": 0}, "frontline: no same-row movement")
		_record(rules, "frontline/gap-%d" % gap)
	var rules: Rules = _fixture()
	_put(rules, "left", "player", "support")
	_put(rules, "right", "player", "support")
	rules._state.sides.player.hq_index = 1
	for index in [-1, 1, 0.5, "0"]:
		_reject(rules, {"type": "move", "unit_id": "right", "insert_index": index}, "frontline: invalid gap")
	var state: Dictionary = _commit(rules, {"type": "move", "unit_id": "right"}, "frontline: default and right departure")
	_check(state.frontline_ids == ["right"] and state.sides.player.hq_index == 1, "frontline: right departure preserves HQ split")
	for index in range(4):
		_put(rules, "full%d" % index, "player", "frontline")
	_reject(rules, {"type": "move", "unit_id": "left"}, "frontline: five-unit cap")
	for victim in ["left", "right"]:
		rules = _fixture()
		_put(rules, "gun", "player", "support", "artillery", 10)
		_put(rules, "left", "ai", "support")
		_put(rules, "right", "ai", "support")
		rules._state.sides.ai.hq_index = 1
		state = _commit(rules, {"type": "attack", "unit_id": "gun", "target_id": victim}, "HQ: death on either side")
		_check(state.sides.ai.hq_index == (0 if victim == "left" else 1) and state.sides.ai.discard_ids == [victim], "HQ: death preserves surviving order")
		_record(rules, "support/death-" + victim)


func _test_turns_and_actions() -> void:
	var rules: Rules = _fresh()
	_commit(rules, {"type": "mulligan", "unit_ids": []}, "turn: player keeps")
	_commit(rules, {"type": "mulligan", "unit_ids": []}, "turn: AI keeps", "ai")
	var first: String = str(rules.snapshot().first_side)
	var second: String = "ai" if first == "player" else "player"
	var state: Dictionary = _commit(rules, {"type": "end_turn"}, "turn: second starts", first)
	_check(state.sides[second].command_points == 1 and state.sides[second].hand_count == 6, "turn: second side begins at one and draws")
	state = _commit(rules, {"type": "end_turn"}, "turn: first returns", second)
	_check(state.sides[first].command_points == 2 and state.sides[first].hand_count == 5, "turn: own budget grows, old hand stays")
	for kind in UNIT_TYPES:
		rules = _fixture()
		_put(rules, "unit", "player", "support", kind, 3, 7, 2, 2)
		state = _commit(rules, {"type": "move", "unit_id": "unit"}, "action: all types advance " + kind)
		_check(state.sides.player.command_points == 10, "action: move pays operating cost")
		if kind == "tank":
			state = _commit(rules, {"type": "attack", "unit_id": "unit", "target_id": "hq:ai"}, "action: tank attacks after move")
			_check(state.sides.player.command_points == 8, "action: tank pays twice")
		else:
			_reject(rules, {"type": "attack", "unit_id": "unit", "target_id": "hq:ai"}, "action: non-tank shared action")
	rules = _fixture()
	_put(rules, "tank", "player", "support", "tank", 4, 7)
	_put(rules, "blocker", "ai", "frontline", "infantry", 2, 3)
	_reject(rules, {"type": "move", "unit_id": "tank"}, "action: enemy owns frontline")
	_commit(rules, {"type": "attack", "unit_id": "tank", "target_id": "blocker"}, "action: tank attacks first")
	_commit(rules, {"type": "move", "unit_id": "tank"}, "action: then takes cleared front")
	_reject(rules, {"type": "attack", "unit_id": "tank", "target_id": "hq:ai"}, "action: only one attack")
	_commit(rules, {"type": "end_turn"}, "action: enemy turn")
	state = _commit(rules, {"type": "end_turn"}, "action: own refresh", "ai")
	_check(state.units.tank.ready and state.units.tank.hp == 5 and state.sides.player.command_points == 12, "action: refresh and cap without healing")
	rules = _fixture()
	rules._state.sides.player.command_points = 2
	_put(rules, "expensive", "player", "hand", "infantry", 3, 7, 3)
	_put(rules, "exact", "player", "hand", "infantry", 3, 7, 2)
	_reject(rules, {"type": "deploy", "unit_id": "expensive"}, "budget: unaffordable deployment")
	state = _commit(rules, {"type": "deploy", "unit_id": "exact"}, "budget: exact cost")
	_check(state.sides.player.command_points == 0 and not state.units.exact.ready, "budget: exact payment and deployment waiting")
	_reject(rules, {"type": "move", "unit_id": "exact"}, "action: newly deployed waits")
	_record(rules, "turns-and-actions")


func _test_combat_matrix_and_cover() -> void:
	var retaliation: Array = [[2, 2, 2, 2, 0], [2, 2, 2, 2, 0], [0, 0, 0, 0, 0], [2, 2, 2, 2, 0], [0, 0, 0, 2, 0]]
	for attacker in range(5):
		for defender in range(5):
			var rules: Rules = _fixture()
			_put(rules, "source", "player", "support", UNIT_TYPES[attacker], 3, 9)
			_put(rules, "target", "ai", "frontline", UNIT_TYPES[defender], 2, 9)
			rules._state.units.target.deployed_this_turn = true
			var state: Dictionary = _commit(rules, {"type": "attack", "unit_id": "source", "target_id": "target"}, "combat: %s/%s" % [UNIT_TYPES[attacker], UNIT_TYPES[defender]])
			_check(state.units.source.hp == 9 - retaliation[attacker][defender] and state.units.target.hp == 6,
				"combat: simultaneous damage and retaliation matrix")
			_check(not state.units.target.attacked_this_turn and state.sides.ai.command_points == 12, "combat: fresh defender retaliates without action or payment")
	for kind in UNIT_TYPES:
		var rules: Rules = _fixture()
		_put(rules, "source", "player", "support", kind)
		var action: Dictionary = {"type": "attack", "unit_id": "source", "target_id": "hq:ai"}
		_check(rules.legal_actions("player").has(action) == (kind in ["artillery", "fighter", "bomber"]), "range: rear HQ access " + kind)
		if kind in ["infantry", "tank"]:
			_check(rules.validation_reason(action) == "target_out_of_range", "range: query explains unreachable HQ " + kind)
			_reject(rules, action, "range: rear HQ rejected " + kind)
	var rules: Rules = _fixture()
	_put(rules, "bomber", "player", "support", "bomber")
	_put(rules, "gun", "player", "support", "artillery", 10)
	_put(rules, "fighter", "ai", "support", "fighter")
	_put(rules, "rear", "ai", "support")
	_put(rules, "front", "ai", "frontline")
	rules._state.sides.ai.hq_index = 1
	for target in ["rear", "hq:ai"]:
		_reject(rules, {"type": "attack", "unit_id": "bomber", "target_id": target}, "cover: protects same row and HQ")
	for target in ["fighter", "front"]:
		_check(rules.legal_actions("player").has({"type": "attack", "unit_id": "bomber", "target_id": target}), "cover: fighter itself and other row remain targets")
	_commit(rules, {"type": "attack", "unit_id": "gun", "target_id": "fighter"}, "cover: artillery removes cover")
	var state: Dictionary = _commit(rules, {"type": "attack", "unit_id": "bomber", "target_id": "hq:ai"}, "cover: HQ now reachable")
	_check(state.sides.ai.hq_hp == 17 and state.units.bomber.hp == 7, "HQ: damage without retaliation")
	rules = _fixture()
	_put(rules, "source", "player", "support", "infantry", 7, 3)
	_put(rules, "reserve", "player", "support")
	rules._state.sides.player.hq_index = 1
	_put(rules, "target", "ai", "frontline", "infantry", 6, 4)
	state = _commit(rules, {"type": "attack", "unit_id": "source", "target_id": "target"}, "combat: simultaneous deaths")
	_check(state.frontline_ids.is_empty() and state.sides.player.discard_ids == ["source"] and state.sides.ai.discard_ids == ["target"] and state.sides.player.hq_index == 0,
		"combat: both deaths release rows and update HQ position")
	_record(rules, "combat-and-cover")


func _test_overflow_fatigue_and_finish() -> void:
	var rules: Rules = _fixture("ai")
	var opening_config: Resource = preload("res://resources/rules/approved_rules.tres").duplicate(true)
	opening_config.hq_max_hp = 1
	opening_config.first_hand_count = 1
	opening_config.second_hand_count = 1
	var opening_result: Dictionary = rules.setup(TEST_SEED, opening_config, {}, {"player": [], "ai": []})
	var opening_state: Dictionary = rules.snapshot()
	_check(opening_result.accepted and opening_state.phase == "finished" and opening_state.winner == "ai", "opening fatigue: first draw ends battle")
	_check(opening_state.sides.player.hq_hp == 0 and opening_state.sides.player.fatigue == 1
		and opening_state.sides.ai.hq_hp == 1 and opening_state.sides.ai.fatigue == 0, "opening fatigue: terminal result cancels other side's opening draw")
	_check(_events_of(opening_result.events, "fatigue_damage").size() == 1
		and _events_of(opening_result.events, "battle_finished").size() == 1
		and opening_result.events.back().type == "battle_finished", "opening fatigue: one fatigue batch and one final event")
	rules = _fixture("ai")
	for index in range(9):
		_put(rules, "hand%d" % index, "player", "hand")
	_put(rules, "new", "player", "draw")
	var state: Dictionary = _commit(rules, {"type": "end_turn"}, "draw: overflow", "ai")
	_check(state.sides.player.hand_count == 9 and state.sides.player.discard_ids == ["new"] and state.sides.player.fatigue == 0, "draw: ninth retained, incoming tenth discarded")
	rules = _fixture()
	for index in range(6):
		var actor: String = str(rules.snapshot().active_side)
		state = _commit(rules, {"type": "end_turn"}, "fatigue: empty draw", actor)
	_check(state.sides.player.hq_hp == 14 and state.sides.ai.hq_hp == 14, "fatigue: one, two, three damage per side")
	rules._state.sides.ai.hq_hp = 1
	state = _commit(rules, {"type": "end_turn"}, "fatigue: terminal draw")
	_check(state.phase == "finished" and state.winner == "player", "fatigue: ends before input")
	_reject(rules, {"type": "end_turn"}, "finish: no more turns")
	rules = _fixture()
	_put(rules, "source", "player", "frontline", "infantry", 21)
	state = _commit(rules, {"type": "attack", "unit_id": "source", "target_id": "hq:ai"}, "finish: lethal HQ")
	_check(state.phase == "finished" and state.winner == "player" and state.sides.ai.hq_hp == 0, "finish: winner and clamped HQ")
	_check(rules.legal_actions("player").is_empty() and rules.legal_actions("ai").is_empty(), "finish: no legal choices")
	_reject(rules, {"type": "attack", "unit_id": "source", "target_id": "hq:ai"}, "finish: combat input frozen")
	_record(rules, "draw-and-finish")


func _test_simple_ai() -> void:
	var rules: Rules = _fresh()
	var policy: Policy = Policy.new()
	for side in ["player", "ai"]:
		_check(policy.choose_action(rules.legal_actions(side), rules.side_view(side)) == {"type": "mulligan", "unit_ids": []}, "AI: always keeps opening hand")
	rules = _fixture("ai")
	_put(rules, "z-front", "ai", "frontline", "infantry", 1)
	_put(rules, "a-front", "ai", "frontline", "infantry", 8)
	_put(rules, "rear", "ai", "support", "artillery", 9)
	_put(rules, "hand", "ai", "hand")
	rules._state.sides.player.hq_hp = 5
	_check(_choose(rules) == {"type": "attack", "unit_id": "z-front", "target_id": "hq:player"}, "AI: HQ first, front left first, no lethal optimization")
	rules = _fixture("ai")
	_put(rules, "z-tank", "ai", "support", "tank")
	_put(rules, "a-bomber", "ai", "support", "bomber")
	_put(rules, "cover", "player", "support", "fighter")
	var action: Dictionary = _choose(rules)
	_check(action == {"type": "move", "unit_id": "z-tank", "insert_index": 0}, "AI: advance before attacking units")
	_commit(rules, action, "AI: tank advances", "ai")
	action = _choose(rules)
	_check(action == {"type": "attack", "unit_id": "z-tank", "target_id": "hq:player"}, "AI: rechecks HQ priority after every step")
	_commit(rules, action, "AI: tank attacks HQ", "ai")
	_check(_choose(rules) == {"type": "move", "unit_id": "a-bomber", "insert_index": 1}, "AI: ranged units also advance into occupied friendly front, at right")
	rules = _fixture("ai")
	_put(rules, "z-source", "ai", "support", "bomber")
	_put(rules, "a-source", "ai", "support", "bomber")
	_put(rules, "z-front", "player", "frontline", "fighter", 3, 3)
	_put(rules, "a-front", "player", "frontline", "fighter", 3, 3)
	_put(rules, "rear", "player", "support", "fighter", 3, 9)
	rules._state.units.rear.hp = 2
	_check(_choose(rules) == {"type": "attack", "unit_id": "z-source", "target_id": "rear"}, "AI: lowest current HP before row and source order")
	rules._state.units.rear.hp = 3
	action = _choose(rules)
	_check(action == {"type": "attack", "unit_id": "z-source", "target_id": "z-front"}, "AI: tied target front-left, then source left, independent of IDs")
	var shuffled: Array = rules.legal_actions("ai")
	shuffled.reverse()
	_check(policy.choose_action(shuffled, rules.side_view("ai")) == action, "AI: choices independent of action enumeration order")
	rules = _fixture("ai")
	rules._state.sides.ai.command_points = 6
	_put(rules, "cheap", "ai", "hand", "infantry", 3, 7, 1)
	_put(rules, "z-costly", "ai", "hand", "infantry", 3, 7, 5)
	_put(rules, "a-costly", "ai", "hand", "infantry", 3, 7, 5)
	_put(rules, "unaffordable", "ai", "hand", "infantry", 3, 7, 8)
	action = _choose(rules)
	_check(action == {"type": "deploy", "unit_id": "z-costly", "insert_index": 1}, "AI: highest affordable cost, hand-left ties, right of HQ")
	_commit(rules, action, "AI: costly deployment", "ai")
	action = _choose(rules)
	_check(action == {"type": "deploy", "unit_id": "cheap", "insert_index": 2}, "AI: keeps deploying affordable cards")
	_commit(rules, action, "AI: cheap deployment", "ai")
	_check(_choose(rules) == {"type": "end_turn"}, "AI: ends when no useful legal action remains")
	_record(rules, "simple-ai")


func _test_complete_battle() -> void:
	var rules: Rules = _fresh()
	var policy: Policy = Policy.new()
	for side in ["player", "ai"]:
		var opening: Dictionary = policy.choose_action(rules.legal_actions(side), rules.side_view(side))
		_commit(rules, opening, "battle: opening", side)
	var steps: int = 0
	var seen_types: Dictionary = {}
	for index in range(1200):
		var before: Dictionary = rules.snapshot()
		if before.phase == "finished":
			break
		var actor: String = str(before.active_side)
		var legal: Array = rules.legal_actions(actor)
		var action: Dictionary = policy.choose_action(legal, rules.side_view(actor))
		seen_types[str(action.get("type", ""))] = true
		var failures_before: int = _failures.size()
		_check(legal.has(action) and rules.snapshot() == before, "battle: policy only selects legal actions and never mutates state")
		var after: Dictionary = _commit(rules, action, "battle: %03d/%s/%s" % [index, actor, action.type], actor)
		_check(_consistent(after), "battle: identities, rows, HP and points remain valid")
		_trace.append({"step": index, "turn": before.turn, "actor": actor, "action": action})
		if _failures.size() > failures_before: _trace.append({"step": "failure", "before": before, "after": after})
		steps += 1
	var final: Dictionary = rules.snapshot()
	_check(final.phase == "finished" and steps > 10 and final.units.size() == 80, "battle: a complete forty-card game reaches a result")
	_check(seen_types.has("order") and seen_types.has("deploy") and seen_types.has("attack") and seen_types.has("move"), "battle: AI exercises orders and every battlefield action")
	_record(rules, "battle/finished")


func _write_result() -> void:
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(_output_dir)
	_check(directory_error == OK, "result directory is writable")
	var result_path: String = _output_dir.path_join("rules-result.json")
	var output: FileAccess = FileAccess.open(result_path, FileAccess.WRITE)
	if output == null:
		_check(false, "cannot write result: " + result_path)
		return
	var result: Dictionary = {"run_id": _run_id, "seed": TEST_SEED,
		"status": "passed" if _failures.is_empty() else "failed", "assertions": _assertions,
		"failures": _failures, "trace": _trace, "godot_version": Engine.get_version_info()}
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print("RULES_RESULT " + JSON.stringify({"run_id": _run_id, "status": result.status, "assertions": _assertions, "failures": _failures.size(), "path": result_path}))


func _defined(rules: Rules, id: String, owner: String, zone: String, definition: Dictionary, sequence: int = 0) -> void:
	var card: Dictionary = Schema.normalize_definition(definition)
	_check(Schema.validate_definition(card, true).is_empty(), "fixture definition validates: " + id)
	card.merge({"instance_id": id, "card_id": "test-" + id, "owner": owner,
		"moved_this_turn": false, "attacked_this_turn": false, "deployed_this_turn": false}, true)
	if card.card_type == "unit": card.hp = card.max_hp
	if sequence > 0: card.entered_sequence = sequence
	rules._state.units[id] = card
	if zone == "frontline": rules._state.frontline_ids.append(id)
	else: rules._state.sides[owner][zone + "_ids"].append(id)


func _unit_definition(effects: Array = [], trigger: String = "aftermath", hp: int = 1) -> Dictionary:
	var card: Dictionary = {"name": "测试单位", "unit_type": "infantry", "deploy_cost": 1, "action_cost": 1, "attack": 1, "max_hp": hp}
	if not effects.is_empty(): card.abilities = [{"trigger": trigger, "effects": effects}]
	return card


func _order(rules: Rules, id: String, effects: Array, owner: String = "player", cost: int = 1) -> void:
	_defined(rules, id, owner, "hand", {"card_type": "order", "name": "测试指令", "deploy_cost": cost,
		"abilities": [{"trigger": "play", "effects": effects}]})


func _events_of(events: Array, kind: String) -> Array:
	return events.filter(func(event: Dictionary): return event.type == kind)


func _test_keywords_and_orders() -> void:
	for kind in UNIT_TYPES:
		var rules: Rules = _fixture()
		_put(rules, "raid", "player", "hand", kind, 3, 7, 2, 2)
		rules._state.units.raid.keywords = {"raid": true}
		_commit(rules, {"type": "deploy", "unit_id": "raid"}, "raid: deploy " + kind)
		var state: Dictionary = _commit(rules, {"type": "move", "unit_id": "raid"}, "raid: immediate move " + kind)
		_check(state.sides.player.command_points == 8, "raid: deployment and movement both paid")
		if kind == "tank":
			state = _commit(rules, {"type": "attack", "unit_id": "raid", "target_id": "hq:ai"}, "raid: tank attacks after moving")
			_check(state.sides.player.command_points == 6, "raid: tank pays separately for attack")
		else:
			_reject(rules, {"type": "attack", "unit_id": "raid", "target_id": "hq:ai"}, "raid: does not grant extra actions")
	var rules: Rules = _fixture()
	_put(rules, "attacker", "player", "frontline", "tank", 3, 9)
	_put(rules, "left", "ai", "support")
	_put(rules, "middle", "ai", "support")
	_put(rules, "right", "ai", "support")
	rules._state.units.left.keywords = {"guard": true}
	rules._state.units.right.keywords = {"guard": true}
	rules._state.sides.ai.hq_index = 1
	_reject(rules, {"type": "attack", "unit_id": "attacker", "target_id": "hq:ai"}, "guard: HQ is an adjacent slot")
	_reject(rules, {"type": "attack", "unit_id": "attacker", "target_id": "middle"}, "guard: adjacent unit protected")
	_check(rules.validation_reason({"type": "attack", "unit_id": "attacker", "target_id": "left"}).is_empty(), "guard: guards never guard each other")
	_put(rules, "gun", "player", "support", "artillery", 1, 9)
	_put(rules, "plane", "player", "support", "bomber", 1, 9)
	for source in ["gun", "plane"]:
		_check(rules.validation_reason({"type": "attack", "unit_id": source, "target_id": "middle"}).is_empty(), "guard: artillery and bomber bypass")
	_put(rules, "fighter", "ai", "support", "fighter")
	_reject(rules, {"type": "attack", "unit_id": "plane", "target_id": "middle"}, "guard: fighter restriction still applies to bomber")
	rules = _fixture()
	_put(rules, "armored_attacker", "player", "support", "infantry", 3, 8)
	_put(rules, "armored_defender", "ai", "frontline", "infantry", 3, 8)
	rules._state.units.armored_attacker.keywords = {"armor": 2}
	rules._state.units.armored_defender.keywords = {"armor": 1, "guard": true}
	var state: Dictionary = _commit(rules, {"type": "attack", "unit_id": "armored_attacker", "target_id": "armored_defender"}, "armor: attack and counter")
	_check(state.units.armored_attacker.hp == 7 and state.units.armored_defender.hp == 6, "armor: both directions use defender armor")
	_order(rules, "damage", [{"op": "damage", "target": "chosen_enemy_unit", "amount": 2}])
	state = _commit(rules, {"type": "order", "unit_id": "damage", "target_id": "armored_defender"}, "armor: effect bypasses armor and guard")
	_check(state.units.armored_defender.hp == 4 and state.sides.player.discard_ids == ["damage"], "order: full effect damage and discard")
	rules = _fixture()
	_defined(rules, "deploy_target", "player", "hand", _unit_definition([{"op": "damage", "target": "chosen_enemy_unit", "amount": 2}], "deploy"))
	_commit(rules, {"type": "deploy", "unit_id": "deploy_target"}, "deploy: no legal target still plays")
	_order(rules, "requires_target", [{"op": "damage", "target": "chosen_enemy_unit", "amount": 2}])
	_reject(rules, {"type": "order", "unit_id": "requires_target"}, "order: no legal target cannot play")
	for index in range(3): _put(rules, "full-%d" % index, "player", "support")
	_put(rules, "enemy", "ai", "frontline")
	state = _commit(rules, {"type": "order", "unit_id": "requires_target", "target_id": "enemy"}, "order: usable with full support row")
	_check(state.sides.player.support_count == 4 and state.units.enemy.hp == 5, "order: consumes no unit slot")
	_record(rules, "keywords-and-orders")


func _test_modifiers_and_suppression() -> void:
	var rules: Rules = _fixture()
	_put(rules, "friend", "player", "support", "infantry", 2, 5)
	rules._state.units.friend.hp = 2
	_order(rules, "buff", [{"op": "modify_stats", "target": "chosen_friendly_unit", "attack": 1, "health": 2}])
	var state: Dictionary = _commit(rules, {"type": "order", "unit_id": "buff", "target_id": "friend"}, "modifiers: buff injured unit")
	_check(state.units.friend.base_attack == 2 and state.units.friend.base_max_hp == 5 and state.units.friend.damage_taken == 3, "modifiers: base stats and wounds stay separate")
	_check(state.units.friend.attack == 3 and state.units.friend.max_hp == 7 and state.units.friend.hp == 4, "modifiers: max and current health increase equally")
	_order(rules, "heal", [{"op": "heal", "target": "chosen_friendly", "amount": 9}])
	state = _commit(rules, {"type": "order", "unit_id": "heal", "target_id": "friend"}, "modifiers: heal to modified maximum")
	_check(state.units.friend.hp == 7 and state.units.friend.damage_taken == 0 and state.units.friend.modifiers.size() == 1, "healing: does not replace stat modifiers")
	_order(rules, "temporary", [{"op": "modify_stats", "target": "chosen_friendly_unit", "attack": 2, "health": 2, "duration": "until_next_owner_turn_end"}])
	_commit(rules, {"type": "order", "unit_id": "temporary", "target_id": "friend"}, "modifiers: temporary extension")
	_commit(rules, {"type": "end_turn"}, "modifiers: current turn ends")
	_commit(rules, {"type": "end_turn"}, "modifiers: next owner turn starts", "ai")
	state = _commit(rules, {"type": "end_turn"}, "modifiers: next owner turn ends")
	_check(state.units.friend.attack == 3 and state.units.friend.max_hp == 7 and state.units.friend.modifiers.size() == 1, "modifiers: expiry recalculates from unchanged base")
	rules = _fixture()
	_put(rules, "dependent", "player", "support", "infantry", 1, 1)
	var provider: Dictionary = _unit_definition([{"op": "modify_stats", "target": "friendly_units", "attack": 0, "health": 2, "duration": "while_source_on_battlefield"}], "deploy")
	provider.auras = [{"kind": "aftermath_twice"}]
	_defined(rules, "provider", "player", "hand", provider)
	rules._state.units.dependent.abilities = [{"trigger": "aftermath", "effects": [{"op": "heal", "target": "owner_hq", "amount": 1}]}]
	rules._state.sides.player.hq_hp = 10
	_commit(rules, {"type": "deploy", "unit_id": "provider"}, "source modifier: provider enters")
	_order(rules, "wound", [{"op": "damage", "target": "chosen_friendly_unit", "amount": 2}])
	_commit(rules, {"type": "order", "unit_id": "wound", "target_id": "dependent"}, "source modifier: dependent survives on extra health")
	_order(rules, "remove", [{"op": "damage", "target": "chosen_friendly_unit", "amount": 3}])
	var result: Dictionary = rules.execute({"type": "order", "unit_id": "remove", "target_id": "provider"})
	_check(result.accepted and rules.snapshot().sides.player.support_ids.is_empty(), "source modifier: lost provider causes a second death cohort")
	_check(rules.snapshot().sides.player.hq_hp == 11, "source modifier: later death does not use previously dead doubling aura")
	_check(_events_of(result.events, "unit_destroyed").size() == 2, "source modifier: recursive stabilization removes each unit once")
	var dependent_deaths: Array = _events_of(result.events, "unit_destroyed")
	_check(dependent_deaths[0].batch_id != dependent_deaths[1].batch_id, "source modifier: derivative death is recorded as a separate cohort")
	rules = _fixture()
	_put(rules, "bomber", "player", "support", "bomber", 1, 8)
	_put(rules, "fighter", "ai", "support", "fighter", 3, 8)
	_put(rules, "covered", "ai", "support")
	_order(rules, "pin", [{"op": "suppress", "target": "chosen_enemy_unit"}])
	_commit(rules, {"type": "order", "unit_id": "pin", "target_id": "fighter"}, "suppression: applied")
	_reject(rules, {"type": "attack", "unit_id": "bomber", "target_id": "covered"}, "suppression: fighter passive remains")
	state = _commit(rules, {"type": "attack", "unit_id": "bomber", "target_id": "fighter"}, "suppression: defender still retaliates")
	_check(state.units.bomber.hp == 5, "suppression: retaliation does not require readiness")
	_commit(rules, {"type": "end_turn"}, "suppression: owner's next turn begins")
	_reject(rules, {"type": "attack", "unit_id": "fighter", "target_id": "hq:player"}, "suppression: cannot attack on its next turn", "ai")
	_reject(rules, {"type": "move", "unit_id": "fighter"}, "suppression: cannot move on its next turn", "ai")
	state = _commit(rules, {"type": "end_turn"}, "suppression: expires at next owner turn end", "ai")
	_check(not state.units.fighter.suppressed, "suppression: independent expiry survives ordinary ready refresh")
	rules = _fixture()
	_put(rules, "active", "player", "support", "infantry", 2, 7)
	_defined(rules, "pin_after", "ai", "frontline", _unit_definition([{"op": "suppress", "target": "enemy_units"}]))
	_commit(rules, {"type": "attack", "unit_id": "active", "target_id": "pin_after"}, "suppression: applied during target owner's turn")
	state = _commit(rules, {"type": "end_turn"}, "suppression: same owner's current turn ends")
	_check(state.units.active.suppressed, "suppression: current remainder is not the next complete turn")
	_commit(rules, {"type": "end_turn"}, "suppression: returns to owner", "ai")
	state = _commit(rules, {"type": "end_turn"}, "suppression: following owner turn ends")
	_check(not state.units.active.suppressed, "suppression: correct expiry after being applied in own turn")


func _test_aftermath_resolution() -> void:
	var rules: Rules = _fixture()
	rules._state.sides.player.hq_hp = 10
	rules._state.sides.ai.hq_hp = 10
	var heal: Array = [{"op": "heal", "target": "owner_hq", "amount": 1}]
	_defined(rules, "victim", "player", "support", _unit_definition(heal), 2)
	_defined(rules, "enemy_first", "ai", "support", _unit_definition(heal), 1)
	for index in range(2):
		var aura: Dictionary = _unit_definition()
		aura.auras = [{"kind": "aftermath_twice"}]
		_defined(rules, "aura-%d" % index, "player", "support", aura, 3 + index)
	_order(rules, "wave", [{"op": "damage", "target": "all_units", "amount": 1}])
	var result: Dictionary = rules.execute({"type": "order", "unit_id": "wave"})
	_check(result.accepted, "aftermath: atomic all-unit damage accepted")
	var deaths: Array = _events_of(result.events, "unit_destroyed")
	var triggers: Array = _events_of(result.events, "ability_triggered").filter(func(e: Dictionary): return e.trigger == "aftermath")
	_check(deaths.map(func(e: Dictionary): return e.unit_id) == ["enemy_first", "victim", "aura-0", "aura-1"], "deaths: global entry order across both owners")
	_check(deaths.all(func(e: Dictionary): return e.batch_id == deaths[0].batch_id), "deaths: AOE is one damage and death batch")
	_check(triggers.map(func(e: Dictionary): return e.source_id) == ["enemy_first", "victim", "victim"], "aftermath: same-death aura doubles and multiple auras cap at two")
	_check(rules.snapshot().sides.player.hq_hp == 12 and rules.snapshot().sides.ai.hq_hp == 11, "aftermath: captured counts remain fixed after aura removal")
	_check(result.events.find(deaths.back()) < result.events.find(triggers.front()), "deaths: whole cohort removed before any aftermath")
	rules = _fixture()
	var choose: Array = [{"op": "choose", "target": "chosen_enemy_unit"}]
	_defined(rules, "left", "player", "support", _unit_definition(choose), 1)
	_defined(rules, "right", "player", "support", _unit_definition(choose), 2)
	rules._state.sides.player.hq_index = 1
	_put(rules, "choice_target", "ai", "support")
	_order(rules, "positions", [{"op": "damage", "target": "friendly_units", "amount": 1}])
	result = rules.execute({"type": "order", "unit_id": "positions"})
	_check(result.accepted and rules.snapshot().phase == "waiting_choice" and rules.snapshot().sides.player.hq_index == 0,
		"death position: both support units leave before first aftermath pauses")
	var left_source: Dictionary = rules._resolution.current.source
	var right_source: Dictionary = rules._resolution.queue.front().source
	_check(left_source.death_zone == "support" and left_source.death_index == 0 and left_source.death_unit_index == 0
		and left_source.death_hq_index == 1, "death position: left snapshot retains original HQ slot")
	_check(right_source.death_zone == "support" and right_source.death_index == 2 and right_source.death_unit_index == 1
		and right_source.death_hq_index == 1, "death position: right snapshot includes HQ and survives same-batch removals")
	rules = _fixture()
	rules._state.sides.player.hq_hp = 10
	rules._state.sides.ai.hq_hp = 10
	_defined(rules, "A", "player", "support", _unit_definition([
		{"op": "damage", "target": "enemy_units", "amount": 2}, {"op": "heal", "target": "owner_hq", "amount": 1}]), 1)
	_defined(rules, "B", "player", "support", _unit_definition([{"op": "heal", "target": "owner_hq", "amount": 3}]), 2)
	_defined(rules, "C", "ai", "support", _unit_definition([{"op": "heal", "target": "owner_hq", "amount": 2}], "aftermath", 2), 3)
	_order(rules, "start", [{"op": "damage", "target": "friendly_units", "amount": 1}])
	result = rules.execute({"type": "order", "unit_id": "start"})
	triggers = _events_of(result.events, "ability_triggered").filter(func(e: Dictionary): return e.trigger == "aftermath")
	_check(triggers.map(func(e: Dictionary): return e.source_id) == ["A", "B", "C"], "FIFO: A completes, then queued B, then newly killed C")
	var heals: Array = _events_of(result.events, "healed")
	_check(heals.map(func(e: Dictionary): return e.amount) == [1, 3, 2], "FIFO: A's second effect completes before B or C")
	rules = _fixture()
	rules._state.sides.player.hq_hp = 10
	var aura: Dictionary = _unit_definition()
	aura.auras = [{"kind": "aftermath_twice"}]
	_defined(rules, "aura", "player", "support", aura, 1)
	_defined(rules, "twice", "player", "support", _unit_definition([
		{"op": "heal", "target": "owner_hq", "amount": 1}, {"op": "draw", "target": "owner", "amount": 1}]), 2)
	for index in range(2): _put(rules, "draw-%d" % index, "player", "draw")
	_order(rules, "kill", [{"op": "damage", "target": "chosen_friendly_unit", "amount": 1}])
	result = rules.execute({"type": "order", "unit_id": "kill", "target_id": "twice"})
	var steps: Array = result.events.filter(func(e: Dictionary): return e.type in ["healed", "card_drawn"])
	_check(steps.map(func(e: Dictionary): return e.type) == ["healed", "card_drawn", "healed", "card_drawn"], "doubling: two complete abilities, not each effect repeated")
	rules = _fixture()
	_order(rules, "mutual", [{"op": "damage", "target": "all_hqs", "amount": 20}, {"op": "heal", "target": "owner_hq", "amount": 99}])
	result = rules.execute({"type": "order", "unit_id": "mutual"})
	var final: Dictionary = rules.snapshot()
	_check(final.phase == "finished" and final.winner == "draw" and final.sides.player.hq_hp == 0 and final.sides.ai.hq_hp == 0, "terminal: both HQs reach zero in one batch")
	_check(_events_of(result.events, "healed").is_empty() and _events_of(result.events, "battle_finished").size() == 1, "terminal: no later heal and one result event")
	rules = _fixture()
	rules._state.sides.player.hq_hp = 10
	_defined(rules, "lethal_A", "player", "support", _unit_definition([
		{"op": "damage", "target": "enemy_hq", "amount": 20}, {"op": "heal", "target": "owner_hq", "amount": 2}]), 1)
	_defined(rules, "cancelled_B", "player", "support", _unit_definition(heal), 2)
	_order(rules, "terminal_chain", [{"op": "damage", "target": "friendly_units", "amount": 1}])
	result = rules.execute({"type": "order", "unit_id": "terminal_chain"})
	_check(rules.snapshot().winner == "player" and rules.snapshot().sides.player.hq_hp == 10, "terminal: cancels current remainder and later abilities")
	_check(_events_of(result.events, "ability_triggered").size() == 2, "terminal: queued B never starts")


func _test_choice_and_conditions() -> void:
	var rules: Rules = _fixture()
	_put(rules, "friend", "player", "support", "infantry", 1, 5)
	rules._state.units.friend.hp = 2
	_put(rules, "enemy", "ai", "frontline", "infantry", 1, 7)
	_put(rules, "drawn", "player", "draw")
	var effects: Array = [
		{"op": "draw", "target": "owner", "amount": 1},
		{"op": "choose", "target": "chosen_enemy_unit"},
		{"op": "damage", "target": "chosen_enemy_unit", "amount": 2},
		{"op": "heal", "target": "friendly_units", "amount": 1},
	]
	_order(rules, "choice", effects)
	var definition: Dictionary = {"card_type": "order", "name": "测试选择", "deploy_cost": 1, "abilities": [{"trigger": "play", "effects": effects}]}
	_check(not Schema.validate_definition(definition).is_empty() and Schema.validate_definition(definition, true).is_empty(), "choice: unsupported product ability is limited to fixture mode")
	var config: Resource = preload("res://resources/rules/approved_rules.tres").duplicate(true)
	config.first_hand_count = 0
	config.second_hand_count = 0
	var injected: Rules = Rules.new()
	_check(injected.setup(TEST_SEED, config, {"choice": definition}, {"player": ["choice"], "ai": ["choice"]}, true).accepted, "choice: fixture definition passes the real setup entry")
	var result: Dictionary = rules.execute({"type": "order", "unit_id": "choice"})
	var paused: Dictionary = rules.snapshot()
	_check(result.accepted and paused.phase == "waiting_choice" and paused.sides.player.command_points == 11 and paused.sides.player.hand_ids == ["drawn"], "choice: accepted action suspends after paid draw")
	var choice_id: String = str(paused.pending_choice.choice_id)
	_check(rules.legal_actions("ai").is_empty() and rules.legal_actions("player").size() == 1, "choice: only the choosing owner receives actions")
	_reject(rules, {"type": "end_turn"}, "choice: cannot end turn while resolving")
	_reject(rules, {"type": "choose", "choice_id": choice_id, "target_id": "enemy"}, "choice: wrong owner", "ai")
	_reject(rules, {"type": "choose", "choice_id": "old", "target_id": "enemy"}, "choice: stale identity")
	_reject(rules, {"type": "choose", "choice_id": choice_id, "target_id": "friend"}, "choice: invalid selection")
	# A fixture adds a later unit to expose whether automatic targets were locked at start.
	_put(rules, "later_friend", "player", "support", "infantry", 1, 5)
	rules._state.units.later_friend.hp = 2
	result = rules.execute({"type": "choose", "choice_id": choice_id, "target_id": "enemy"})
	var resumed: Dictionary = rules.snapshot()
	_check(result.accepted and resumed.phase == "active" and resumed.pending_choice.is_empty(), "choice: valid answer resumes saved cursor")
	_check(resumed.units.enemy.hp == 5 and resumed.units.friend.hp == 3 and resumed.units.later_friend.hp == 2, "choice: chosen target resolves and automatic targets stay locked for whole ability")
	_check(resumed.sides.player.command_points == 11 and _events_of(result.events, "command_points_spent").is_empty() and _events_of(result.events, "card_drawn").is_empty() and _events_of(result.events, "ability_triggered").is_empty(), "choice: resume repeats no cost, earlier effect or trigger")
	_reject(rules, {"type": "choose", "choice_id": choice_id, "target_id": "enemy"}, "choice: consumed cursor cannot resume twice")
	rules = _fixture()
	_put(rules, "attacker", "player", "support", "infantry", 2, 7)
	var conditional: Dictionary = _unit_definition([{"op": "heal", "target": "owner_hq", "amount": 1}])
	conditional.abilities[0].condition = {"kind": "source_owner_active"}
	_defined(rules, "conditional", "ai", "frontline", conditional)
	rules._state.sides.ai.hq_hp = 10
	result = rules.execute({"type": "attack", "unit_id": "attacker", "target_id": "conditional"})
	_check(result.accepted and rules.snapshot().sides.ai.hq_hp == 10 and _events_of(result.events, "ability_triggered").is_empty(), "condition: inactive source owner prevents trigger capture")
	_check(rules.ability_condition_matches({"condition": {"kind": "owner_hq_damaged"}}, {"owner": "ai"}), "condition: public HQ damage predicate")
	_check(not rules.ability_condition_matches({"condition": {"kind": "owner_hq_damaged"}}, {"owner": "player"}), "condition: full HQ predicate is false")
	rules = _fixture()
	_put(rules, "active_source", "player", "support", "infantry", 2, 7)
	_defined(rules, "enemy_choice", "ai", "frontline", _unit_definition([
		{"op": "choose", "target": "chosen_enemy_unit"}, {"op": "damage", "target": "chosen_enemy_unit", "amount": 1}]))
	result = rules.execute({"type": "attack", "unit_id": "active_source", "target_id": "enemy_choice"})
	_check(result.accepted and rules.snapshot().phase == "waiting_choice" and rules.snapshot().pending_choice.owner == "ai", "choice: inactive owner can choose during opponent's turn")
	var answer: Dictionary = Policy.new().choose_action(rules.legal_actions("ai"), rules.side_view("ai"))
	result = rules.execute(answer, "ai")
	_check(result.accepted and rules.snapshot().phase == "active" and rules.snapshot().active_side == "player" and rules.snapshot().units.active_source.hp == 5, "choice: inactive owner resumes original actor after one counter and one effect")


func _test_effect_ai_and_privacy() -> void:
	for card_id in ["order_damage", "order_row_damage", "order_draw", "order_heal", "order_buff", "order_suppress"]:
		var rules: Rules = _fixture("ai")
		_put(rules, "friend", "ai", "support", "infantry", 1, 7)
		rules._state.units.friend.hp = 2
		rules._state.units.friend.deployed_this_turn = true
		_put(rules, "enemy", "player", "frontline", "infantry", 3, 2)
		for index in range(2): _put(rules, "draw-%d" % index, "ai", "draw")
		_defined(rules, "order", "ai", "hand", Catalog.card(card_id))
		var action: Dictionary = _choose(rules)
		_check(action.get("type") == "order" and action.get("unit_id") == "order", "AI: useful " + card_id)
		_commit(rules, action, "AI: executes " + card_id, "ai")
	var rules: Rules = _fixture("ai")
	rules._state.sides.ai.hq_hp = 1
	_put(rules, "last_card", "ai", "draw")
	_defined(rules, "dangerous_draw", "ai", "hand", Catalog.card("order_draw"))
	_check(_choose(rules).get("type") == "end_turn", "AI: avoids lethal fatigue from multi-draw with one card left")
	rules = _fixture("ai")
	_put(rules, "zero_attack", "ai", "support", "artillery", 0, 5)
	_check(_choose(rules).get("type") != "attack", "AI: avoids paying to deal zero damage to HQ")
	rules = _fixture()
	for index in range(8): _put(rules, "hidden-%d" % index, "ai", "hand")
	_order(rules, "public_order", [{"op": "heal", "target": "owner_hq", "amount": 1}], "ai")
	_defined(rules, "secret_overflow", "ai", "draw", _unit_definition([{"op": "damage", "target": "enemy_hq", "amount": 10}]))
	var result: Dictionary = rules.execute({"type": "end_turn"})
	var view: Dictionary = rules.side_view("player")
	_check(result.accepted and view.sides.ai.discard_count == 1 and view.sides.ai.discard_ids.is_empty() and not view.units.has("secret_overflow"), "privacy: enemy overflow keeps only anonymous discard count")
	_check(view.sides.player.hq_hp == 20 and _events_of(result.events, "ability_triggered").is_empty(), "overflow: discard is not battlefield death")
	result = rules.execute({"type": "order", "unit_id": "public_order"}, "ai")
	view = rules.side_view("player")
	_check(result.accepted and view.units.has("public_order") and view.sides.ai.discard_ids == ["public_order"], "privacy: played enemy order remains public in discard")
	_check(not view.units.has("secret_overflow"), "privacy: later actions never reveal an overflowed card")
