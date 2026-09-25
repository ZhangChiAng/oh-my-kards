extends "res://scripts/battle_controller.gd"
## Local battle assembly and explicit launch overrides.
const Rules = preload("res://scripts/battle_rules.gd")
const CardStore = preload("res://scripts/workshop/card_store.gd")
const ArtworkResolver = preload("res://scripts/art/card_artwork_resolver.gd")
const Policy = preload("res://scripts/ai_policy.gd")
const History = preload("res://scripts/art_battle/public_history.gd")
const Parameters = preload("res://resources/rules/approved_rules.tres")

var ai_policy = Policy.new()
var history = History.new()
var seed_override: int = -1
var run_id: String
var ai_step_delay: float = 0.3
var _ai_running: bool = false
var library_error: String = ""
var _library_error_panel: Control

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
	main_menu_requested.connect(func(): get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn"))
	action_resolved.connect(_record_action)
	_start_local_session()

func _start_local_session() -> void:
	var store := CardStore.new()
	store.configure_from_args(OS.get_cmdline_user_args())
	library_error = store.load_collection()
	if not library_error.is_empty():
		_show_library_error(library_error)
		return
	if is_instance_valid(_library_error_panel): _library_error_panel.queue_free()
	_view.visible = true
	var seed_value := seed_override
	if seed_value < 0: seed_value = randi()
	var session := Rules.new()
	var result: Dictionary = session.setup(seed_value, Parameters, store.definitions(),
		{"player": store.preset_deck(), "ai": store.preset_deck()})
	if not result.accepted:
		library_error = str(result.get("reason", "无法建立对局"))
		_show_library_error(library_error)
		return
	var session_profile: Resource = _view.profile.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	ArtworkResolver.configure_profile(session_profile, store.records, store.root_path.path_join("images"))
	_view.set_profile(session_profile)
	history.reset()
	history.record_events(result.events, {}, session.side_view("player"))
	var before: Dictionary = session.side_view("player")
	var opening: Dictionary = session.execute(ai_policy.choose_action(session.legal_actions("ai"), session.side_view("ai")), "ai")
	history.record_events(opening.events, before, session.side_view("player"))
	attach_session(session)
	_ai_running = false

func _show_library_error(message: String) -> void:
	# Block play without replacing unreadable data or silently using a fallback deck.
	battle_number += 1
	rules = null
	_ai_running = false
	_view.stop_presentation()
	_view.visible = false
	if is_instance_valid(_library_error_panel): _library_error_panel.queue_free()
	_library_error_panel = PanelContainer.new()
	_library_error_panel.name = "LibraryError"
	add_child(_library_error_panel)
	_library_error_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	_library_error_panel.add_child(center)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(520, 0)
	center.add_child(content)
	var label := Label.new()
	label.text = "无法开始对战\n\n" + message + "\n\n牌库文件已保留。修复后重新进入游戏。"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(520, 160)
	content.add_child(label)
	var back := Button.new()
	back.text = "返回主界面"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	content.add_child(back)

func _process(delta: float) -> void:
	super._process(delta)
	if rules == null or _ai_running or _interaction.state != "idle" or _is_modal_open(): return
	var state: Dictionary = rules.snapshot()
	if _ai_controls_state(state): _run_ai(battle_number)

func _ai_controls_state(state: Dictionary) -> bool:
	if state.phase == "waiting_choice": return state.get("pending_choice", {}).get("owner", "") == "ai"
	return state.phase == "active" and state.active_side == "ai"

func _run_ai(generation: int) -> void:
	_ai_running = true
	while is_inside_tree() and generation == battle_number and rules != null:
		await get_tree().create_timer(ai_step_delay).timeout
		if not is_inside_tree() or generation != battle_number or rules == null: return
		var state: Dictionary = rules.snapshot()
		if not _ai_controls_state(state): break
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
	state.library_error = library_error
	return state
