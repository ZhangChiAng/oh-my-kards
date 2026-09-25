extends Control
## Coordinates commands and input. Rules own the game; BattleView owns presentation.

signal restart_requested
signal main_menu_requested
signal action_resolved(action: Dictionary, actor: String, result: Dictionary, before: Dictionary, after: Dictionary)

const DefaultInteraction = preload("res://resources/interaction/basic_interaction.tres")
@export var interaction_config: Resource = DefaultInteraction

var rules: RefCounted
var battle_number: int = 0
var _view: Control
var _view_state: Dictionary = {}
var _legal_actions: Array = []
var _interaction: Dictionary = _idle_interaction()
var _cursor := Vector2.ZERO
var _press_position := Vector2.ZERO
var _source_pose: Dictionary = {}
var _interaction_turn: int = 0
var _interaction_battle: int = 0
var _animation_serial: int = 0
var _mulligan_selected: Array[String] = []
var _mulligan_pressed: String = ""
var _relayout_queued: bool = false
var _pending_deploy_pose: Dictionary = {}


static func _idle_interaction() -> Dictionary:
	return {"state": "idle", "source_id": "", "source_zone": "", "hover_target_key": "", "legal_target_keys": [], "presentation_busy": false}


func _ready() -> void:
	_view = $BattleView
	_view.end_turn_requested.connect(func(): _player_command({"type": "end_turn"}))
	_view.restart_requested.connect(request_restart)
	_view.main_menu_requested.connect(request_main_menu)
	_view.mulligan_confirm_requested.connect(_confirm_mulligan)
	_view.modal_changed.connect(_on_modal_changed)
	_view.presentation_invalidated.connect(_on_presentation_invalidated)
	get_window().size_changed.connect(_on_window_resized)
	_refresh_ui()


func _process(_delta: float) -> void:
	if _interaction.state in ["pressed", "dragging", "choosing_deploy"]:
		var state: Dictionary = rules.snapshot()
		if battle_number != _interaction_battle or state.turn != _interaction_turn or state.phase != "active" or state.active_side != "player":
			_cancel_drag(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and is_instance_valid(_view):
		_view._hide_detail()
		_mulligan_pressed = ""
		_cancel_drag(false)


func _on_window_resized() -> void:
	_mulligan_pressed = ""
	_cancel_drag(false)
	if is_instance_valid(_view): _view.update_hover(Vector2(-100, -100))
	if not _relayout_queued:
		_relayout_queued = true
		_finish_relayout.call_deferred()


func _finish_relayout() -> void:
	_relayout_queued = false
	if not is_instance_valid(_view): return
	# Presentation is disposable; domain state and AI scheduling do not depend on layout.
	_view.stop_presentation()
	_view.relayout()


func _input(event: InputEvent) -> void:
	if not is_instance_valid(_view) or rules == null or _view_state.is_empty(): return
	# _input precedes GUI dispatch: a modal must gate gameplay here, while native
	# Button nodes still receive mouse events through normal GUI dispatch.
	if _is_modal_open():
		if event is InputEventKey:
			if event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
				_view.close_modal()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		if event.echo: return
		if event.pressed and event.keycode == KEY_ESCAPE:
			_mulligan_pressed = ""
			_cancel_drag(true)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("end_turn"):
			if _interaction.state == "idle": _player_command({"type": "end_turn"})
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		_cursor = event.position
		if not _mulligan_pressed.is_empty() and _drag_distance() > interaction_config.drag_threshold: _mulligan_pressed = ""
		if _interaction.state == "pressed" and _drag_distance() > interaction_config.drag_threshold:
			_interaction.state = "dragging"
			_refresh_ui()
		if _interaction.state in ["dragging", "choosing_deploy", "choosing_choice"]:
			_update_drag()
			get_viewport().set_input_as_handled()
		elif _interaction.state == "idle": _view.update_hover(_cursor)
		return
	if not event is InputEventMouseButton: return
	_cursor = event.position
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_mulligan_pressed = ""
		_cancel_drag(true)
		get_viewport().set_input_as_handled()
		return
	if event.button_index != MOUSE_BUTTON_LEFT: return
	if event.pressed: _view._hide_detail()
	# Native controls retain normal GUI input.
	if event.pressed and _view.is_ui_point(_cursor):
		_mulligan_pressed = ""
		_cancel_drag(false)
		return
	if _view_state.get("phase", "") == "mulligan":
		_handle_mulligan_input(event)
		return
	if _interaction.state in ["choosing_deploy", "choosing_choice"]:
		if not event.pressed: _finish_target_choice()
		get_viewport().set_input_as_handled()
		return
	if event.pressed:
		if _interaction.state != "idle" or not _player_turn(): return
		var key: String = _view.pick_source(_cursor)
		if key.is_empty(): return
		var id: String = key.get_slice(":", 1)
		if not _source_is_legal(id): return
		_source_pose = _view.source_pose(key)
		_interaction = {"state": "pressed", "source_id": id, "source_zone": "hand" if key.begins_with("hand:") else str(_view_state.units[id].zone), "hover_target_key": "", "legal_target_keys": _targets_for(id), "presentation_busy": false}
		_press_position = _cursor
		_interaction_turn = int(_view_state.turn)
		_interaction_battle = battle_number
		_refresh_ui()
		get_viewport().set_input_as_handled()
	elif _interaction.state == "pressed":
		_clear_interaction()
		_refresh_ui()
		get_viewport().set_input_as_handled()
	elif _interaction.state == "dragging":
		_finish_drag()
		get_viewport().set_input_as_handled()


func _is_modal_open() -> bool:
	return _view.is_modal_open()


func _on_modal_changed(open: bool) -> void:
	if open:
		_mulligan_pressed = ""
		_cancel_drag(false)
		_view.update_hover(Vector2(-100, -100))
	_refresh_ui()


func _drag_distance() -> float:
	return _view.drag_distance(_press_position, _cursor)


func _on_presentation_invalidated() -> void:
	_mulligan_pressed = ""
	_cancel_drag(false)
	_view.update_hover(Vector2(-100, -100))


func attach_session(session: RefCounted) -> void:
	## External assembly supplies an initialized rules session and owns content/seed.
	battle_number += 1
	_stop_presentation()
	_clear_interaction()
	_mulligan_selected.clear()
	_mulligan_pressed = ""
	rules = session
	if is_instance_valid(_view): _view.reset_presentation()
	_refresh_ui()


func request_main_menu() -> void:
	attach_session(null)
	main_menu_requested.emit()


func request_restart() -> void:
	## Invalidate pending callbacks before the external owner starts a new session.
	attach_session(null)
	restart_requested.emit()


func _handle_mulligan_input(event: InputEventMouseButton) -> void:
	if _view_state.sides.player.mulligan_done: return
	if _view.is_ui_point(_cursor):
		_mulligan_pressed = ""
		return
	var key: String = _view.pick_source(_cursor)
	if event.pressed:
		_mulligan_pressed = key if key.begins_with("hand:") else ""
		_press_position = _cursor
	elif not _mulligan_pressed.is_empty():
		if key == _mulligan_pressed:
			var id: String = key.get_slice(":", 1)
			if _mulligan_selected.has(id): _mulligan_selected.erase(id)
			else: _mulligan_selected.append(id)
		_mulligan_pressed = ""
		_refresh_ui()
	get_viewport().set_input_as_handled()


func _confirm_mulligan() -> void:
	if _is_modal_open() or _interaction.state != "idle": return
	if _view_state.get("phase", "") != "mulligan" or _view_state.sides.player.mulligan_done: return
	var action: Dictionary = {"type": "mulligan", "unit_ids": _mulligan_selected.duplicate()}
	_mulligan_selected.clear()
	_mulligan_pressed = ""
	await _execute_visual(action, "player")


func _player_turn() -> bool:
	return not _view_state.is_empty() and _view_state.phase == "active" and _view_state.active_side == "player"


func _source_is_legal(id: String) -> bool:
	for action in _legal_actions:
		if str(action.get("unit_id", "")) == id: return true
	return false


func _targets_for(id: String) -> Array:
	var result: Array = []
	if _interaction.state == "choosing_deploy":
		for candidate in _interaction.get("candidate_actions", []):
			var target_key: String = _effect_target_key(str(candidate.get("target_id", "")))
			if not result.has(target_key): result.append(target_key)
		return result
	for action in rules.legal_actions("player"):
		if str(action.get("type", "")) == "choose":
			result.append(_effect_target_key(str(action.target_id)))
			continue
		if str(action.get("unit_id", "")) != id: continue
		var key: String = _action_target_key(action)
		if not result.has(key): result.append(key)
	return result


func _action_target_key(action: Dictionary) -> String:
	match str(action.type):
		"deploy": return "support:player:%d" % int(action.insert_index)
		"move": return "frontline:%d" % int(action.insert_index)
		"attack":
			var target: String = str(action.target_id)
			return target if target.begins_with("hq:") else "unit:" + target
		"order": return _effect_target_key(str(action.get("target_id", ""))) if action.has("target_id") else "cast:player"
		"choose": return _effect_target_key(str(action.target_id))
	return ""


func _effect_target_key(id: String) -> String:
	return id if id.begins_with("hq:") or id.begins_with("row:") else "unit:" + id


func _update_drag() -> void:
	_interaction.legal_target_keys = _targets_for(str(_interaction.source_id))
	_interaction.hover_target_key = _view.pick_drop(_cursor)
	_view.show_drag(_interaction, _cursor, _source_pose)


func _finish_drag() -> void:
	_update_drag()
	var action: Dictionary = {}
	var target_choices: Array = []
	if _interaction_battle == battle_number and _interaction_turn == int(rules.snapshot().turn):
		for candidate in rules.legal_actions("player"):
			if str(candidate.get("unit_id", "")) == str(_interaction.source_id) and _action_target_key(candidate) == str(_interaction.hover_target_key):
				action = candidate
				if candidate.type == "deploy" and candidate.has("target_id"): target_choices.append(candidate)
	if not target_choices.is_empty():
		_pending_deploy_pose = _view.drag_pose()
		_interaction.state = "choosing_deploy"
		_interaction.candidate_actions = target_choices
		_interaction.hover_target_key = ""
		_interaction.legal_target_keys = _targets_for(str(_interaction.source_id))
		_refresh_ui()
		_update_drag()
		return
	if action.is_empty(): _cancel_drag(true)
	else:
		var released: Dictionary = _view.drag_pose()
		_clear_interaction()
		_player_command(action, released)


func _finish_target_choice() -> void:
	_update_drag()
	var selected: Dictionary = {}
	var candidates: Array = _interaction.get("candidate_actions", []) if _interaction.state == "choosing_deploy" else rules.legal_actions("player")
	for candidate in candidates:
		if candidate.has("target_id") and _effect_target_key(str(candidate.target_id)) == str(_interaction.hover_target_key):
			selected = candidate
			break
	if selected.is_empty(): return
	var released: Dictionary = _pending_deploy_pose.duplicate(true)
	_clear_interaction()
	if selected.type == "choose": await _execute_visual(selected, "player")
	else: _player_command(selected, released)


func _cancel_drag(animate: bool) -> void:
	if _interaction.state == "choosing_choice": return
	if not _interaction.state in ["pressed", "dragging", "choosing_deploy"]: return
	var id: String = str(_interaction.source_id)
	var was_dragging: bool = _interaction.state == "dragging"
	var drag_pose: Dictionary = _view.drag_pose()
	_clear_interaction()
	if animate and was_dragging and _view_state.units.has(id):
		_interaction.state = "animating"
		_interaction.presentation_busy = true
		var generation: int = battle_number
		_animation_serial += 1
		var serial: int = _animation_serial
		_refresh_ui()
		var task: RefCounted = _view.animate_cancel(id, drag_pose)
		if not task.done: await task.finished
		if not is_inside_tree() or generation != battle_number or serial != _animation_serial: return
		_stop_presentation()
		_clear_interaction()
	_refresh_ui()


func _clear_interaction() -> void:
	_interaction = _idle_interaction()
	_pending_deploy_pose.clear()
	if is_instance_valid(_view): _view.clear_drag()


func _stop_presentation() -> void:
	_animation_serial += 1
	if is_instance_valid(_view): _view.stop_presentation()


func _player_command(action: Dictionary, released: Dictionary = {}) -> void:
	if _is_modal_open() or _interaction.state != "idle" or not _player_turn(): return
	await _execute_visual(action, "player", released)


func submit_action(action: Dictionary, actor: String) -> void:
	## An external opponent driver can use the same serialized presentation path.
	if not is_inside_tree() or not is_instance_valid(_view): return
	if rules == null or _interaction.state != "idle" or _is_modal_open(): return
	await _execute_visual(action, actor)


func _execute_visual(action: Dictionary, actor: String, released: Dictionary = {}) -> void:
	var session: RefCounted = rules
	var generation: int = battle_number
	var before: Dictionary = rules.side_view("player")
	var old_poses: Dictionary = released.get("all_poses", _view.capture_poses())
	if action.get("type", "") in ["deploy", "move"] and not released.is_empty() and not released.get("attack", true):
		var source_key: String = ("hand:" if action.type == "deploy" else "unit:") + str(action.unit_id)
		var released_pose: Dictionary = old_poses.get(source_key, {}).duplicate(true)
		released_pose.merge(released.pose, true)
		old_poses[source_key] = released_pose
	var result: Dictionary = rules.execute(action, actor)
	_clear_interaction()
	_interaction.state = "animating"
	_interaction.presentation_busy = true
	_animation_serial += 1
	var serial: int = _animation_serial
	var public_result: Dictionary = result.duplicate(true)
	public_result.events = _public_events(result.events)
	action_resolved.emit(action.duplicate(true), actor, public_result, before.duplicate(true), rules.side_view("player"))
	if session != rules or generation != battle_number or serial != _animation_serial: return
	if not result.accepted:
		_clear_interaction()
		_refresh_ui()
		return
	_refresh_ui()
	var task: RefCounted = _view.animate_action(action, _public_events(result.events), before, old_poses)
	if not task.done: await task.finished
	if not is_inside_tree() or generation != battle_number or serial != _animation_serial: return
	_stop_presentation()
	_clear_interaction()
	_refresh_ui()


func _public_events(events: Array) -> Array:
	var result: Array = []
	for value in events:
		var event: Dictionary = value.duplicate(true)
		if event.get("type", "") in ["card_drawn", "hand_overflow"]: event.erase("unit_id")
		if event.get("type", "") == "mulligan_completed": event.erase("unit_ids")
		result.append(event)
	return result


func _refresh_ui() -> void:
	if rules == null:
		_view_state = {}
		_legal_actions = []
		return
	if not is_instance_valid(_view): return
	_view_state = rules.side_view("player")
	_legal_actions = rules.legal_actions("player")
	if _interaction.state in ["pressed", "dragging", "choosing_deploy"] and (not _view_state.units.has(_interaction.source_id) or _view_state.turn != _interaction_turn or _view_state.phase != "active"):
		_clear_interaction()
	if _view_state.phase == "waiting_choice" and _interaction.state == "idle" and _view_state.get("pending_choice", {}).get("owner", "") == "player":
		var source_id: String = str(_view_state.pending_choice.get("source_id", ""))
		_interaction = {"state": "choosing_choice", "source_id": source_id, "source_zone": "effect", "hover_target_key": "", "legal_target_keys": [], "presentation_busy": false}
		_interaction.legal_target_keys = _targets_for(source_id)
		_source_pose = _view.source_pose("unit:" + source_id)
		if _source_pose.is_empty(): _source_pose = {"position": _view.size * 0.5, "size": Vector2.ZERO}
	_view.render(_view_state, _legal_actions, _interaction, _mulligan_selected)


func snapshot() -> Dictionary:
	var state: Dictionary = rules.snapshot() if rules != null else {}
	state["battle_number"] = battle_number
	state["interaction"] = _interaction.duplicate(true)
	state.interaction["mulligan_selected_ids"] = _mulligan_selected.duplicate()
	state["legal_actions"] = rules.legal_actions("player") if rules != null else []
	state["ui_controls"] = _view.snapshot_controls()
	state["presentation"] = _view.presentation_snapshot()
	return state
