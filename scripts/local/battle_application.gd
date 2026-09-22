extends "res://scripts/battle_controller.gd"
## Local battle assembly and explicit launch overrides.
const Rules = preload("res://scripts/battle_rules.gd")
const Catalog = preload("res://scripts/card_catalog.gd")
const Policy = preload("res://scripts/ai_policy.gd")
const History = preload("res://scripts/art_battle/public_history.gd")
const Parameters = preload("res://resources/rules/approved_rules.tres")

var ai_policy = Policy.new()
var history = History.new()
var seed_override: int = -1
var run_id: String
var ai_step_delay: float = 0.3
var _ai_running: bool = false

func _ready() -> void:
	super._ready()
	add_to_group("mcp_watch")
	run_id = "local-%d" % Time.get_ticks_usec()
	var args := OS.get_cmdline_user_args()
	_view.geometry_debug = args.has("--geometry-debug")
	for index in range(args.size() - 1):
		if args[index] == "--seed": seed_override = int(args[index + 1])
		elif args[index] == "--run-id": run_id = args[index + 1]
		elif args[index] == "--profile": _view.set_profile(load(args[index + 1]))
	restart_requested.connect(_start_local_session)
	action_resolved.connect(_record_action)
	_start_local_session()

func _start_local_session() -> void:
	var seed_value := seed_override
	if seed_value < 0: seed_value = randi()
	var session := Rules.new()
	var result: Dictionary = session.setup(seed_value, Parameters, Catalog.CARDS,
		{"player": Catalog.preset_deck(), "ai": Catalog.preset_deck()})
	if not result.accepted: return
	history.reset()
	history.record_events(result.events, {}, session.side_view("player"))
	var before: Dictionary = session.side_view("player")
	var opening: Dictionary = session.execute(ai_policy.choose_action(session.legal_actions("ai"), session.side_view("ai")), "ai")
	history.record_events(opening.events, before, session.side_view("player"))
	attach_session(session)
	_ai_running = false

func _process(delta: float) -> void:
	super._process(delta)
	if rules == null or _ai_running or _interaction.state != "idle" or _is_modal_open(): return
	var state: Dictionary = rules.snapshot()
	if state.phase == "active" and state.active_side == "ai": _run_ai(battle_number)

func _run_ai(generation: int) -> void:
	_ai_running = true
	while is_inside_tree() and generation == battle_number and rules != null:
		await get_tree().create_timer(ai_step_delay).timeout
		if not is_inside_tree() or generation != battle_number or rules == null: return
		var state: Dictionary = rules.snapshot()
		if state.phase != "active" or state.active_side != "ai": break
		if _interaction.state != "idle" or _is_modal_open(): continue
		var action: Dictionary = ai_policy.choose_action(rules.legal_actions("ai"), rules.side_view("ai"))
		await submit_action(action, "ai")
	if generation == battle_number: _ai_running = false

func _record_action(action: Dictionary, actor: String, result: Dictionary, before: Dictionary, after: Dictionary) -> void:
	if result.accepted: history.record_events(result.events, before, after)
	print(JSON.stringify({"event": "battle_action", "run_id": run_id, "seed": rules.snapshot().seed, "battle_number": battle_number, "actor": actor, "action": action, "accepted": result.accepted, "reason": result.reason}))

func _mcp_state() -> Dictionary:
	var state: Dictionary = snapshot()
	state.run_id = run_id
	state.history = history.snapshot()
	return state
