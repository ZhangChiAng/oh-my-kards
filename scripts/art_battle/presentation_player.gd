extends RefCounted
## One public-state animation path for all art profiles. Never calls battle rules.
## Host methods: presentation_create_card(key, state, pose),
## presentation_update_card(card, key, state), presentation_hide_card(key),
## presentation_restore(), presentation_set_frontline_y(value),
## presentation_set_status(public_state).
## Poses use hand:/unit:/hq:/back:ai:<index>, anonymous deck:<side> origins,
## and optional _frontline_y (design units) and _scale metadata.

const Run = preload("res://scripts/art_battle/presentation_run.gd")

var _active: RefCounted


func play(view: Control, action: Dictionary, events: Array, before: Dictionary,
		after: Dictionary, old_poses: Dictionary, new_poses: Dictionary, motion: Resource) -> RefCounted:
	if _active != null and not _active.done: _active.cancel()
	var run := Run.new()
	_active = run
	if not is_instance_valid(view) or not view.is_inside_tree():
		run.complete(true)
		return run
	var playback := Playback.new()
	playback.host = view
	playback.run = run
	playback.action = action.duplicate(true)
	playback.events = _public_events(events)
	playback.before = before.duplicate(true)
	playback.after = after.duplicate(true)
	playback.old_poses = old_poses.duplicate(true)
	playback.new_poses = new_poses.duplicate(true)
	playback.motion = motion
	view.add_child(playback)
	playback.start()
	return run


func cancel() -> void:
	if _active != null: _active.cancel()


static func _public_events(events: Array) -> Array:
	var result: Array = []
	for value in events:
		var event: Dictionary = value.duplicate(true)
		# Even a mistaken raw-event caller cannot retain hidden draw identities.
		if str(event.get("type", "")) in ["card_drawn", "hand_overflow"]:
			event.erase("unit_id")
		if str(event.get("type", "")) == "mulligan_completed": event.erase("unit_ids")
		result.append(event)
	return result


class Playback extends Control:
	const FixedLabel = preload("res://scripts/art_battle/fixed_label.gd")
	var host: Control
	var run: RefCounted
	var action: Dictionary
	var events: Array
	var before: Dictionary
	var after: Dictionary
	var old_poses: Dictionary
	var new_poses: Dictionary
	var motion: Resource
	var _entries: Dictionary = {}
	var _stages: Array[Dictionary] = []
	var _index: int = 0
	var _stage_time: float = 0.0
	var _elapsed: float = 0.0
	var _duration: float = 0.0
	var _finishing: bool = false
	var _attack_from: String = ""
	var _attack_to: String = ""
	var _lunge := Vector2.ZERO
	var _line_progress: float = 0.0
	var _hit_state: Dictionary = {}
	var _casualties: Array[String] = []
	var _damage: Array[Dictionary] = []
	var _labels: Array[Control] = []
	var _turn_label: Control
	var _scale: float = 1.0


	func start() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		z_index = int(host.geometry.layout.layers.animation)
		size = host.size
		_scale = float(new_poses.get("_scale", old_poses.get("_scale", 1.0)))
		run.bind_cancel(_cancel)
		_prepare_hit()
		_prepare_cards()
		host.presentation_set_status(before)
		_prepare_stages()
		for value in _stages: _duration += float(value.duration)
		if _stages.is_empty():
			_finish(false)
			return
		_enter_stage()
		_apply_stage(0.0)
		set_process(true)


	func _prepare_cards() -> void:
		var destinations: Dictionary = {}
		var unit_id: String = str(action.get("unit_id", ""))
		var deploy_key: String = "unit:" + unit_id if action.get("type", "") == "deploy" else ""
		var deploy_back: String = ""
		if not deploy_key.is_empty() and not old_poses.has("hand:" + unit_id):
			for key in old_poses:
				if str(key).begins_with("back:ai:") and not new_poses.has(key): deploy_back = str(key)
		for raw_key in old_poses:
			var key: String = str(raw_key)
			if not _card_key(key): continue
			var destination: String = key
			if not deploy_key.is_empty() and (key == "hand:" + unit_id or key == deploy_back): destination = deploy_key
			var from: Dictionary = old_poses[key]
			var to: Dictionary = new_poses.get(destination, from)
			var card: Control = host.presentation_create_card(key, before, from)
			if card == null: continue
			_entries[destination] = {"node": card, "from": from, "to": to, "original_key": key,
				"added": false, "removed": not new_poses.has(destination), "flipped": key == destination}
			destinations[destination] = true
			host.presentation_hide_card(key)
		for raw_key in new_poses:
			var key: String = str(raw_key)
			if not _card_key(key): continue
			host.presentation_hide_card(key)
			if destinations.has(key): continue
			var to: Dictionary = new_poses[key]
			var side: String = "ai" if key.begins_with("back:ai:") else "player"
			var from: Dictionary = old_poses.get("deck:" + side, to).duplicate(true)
			if key.begins_with("hq:"): from = to.duplicate(true)
			if key == deploy_key: from = old_poses.get(deploy_back, from).duplicate(true)
			var card: Control = host.presentation_create_card(key, after, from)
			if card == null: continue
			_entries[key] = {"node": card, "from": from, "to": to, "original_key": key,
				"added": true, "removed": false, "flipped": true}
			card.hide()
		if not _attack_from.is_empty() and _entries.has(_attack_from) and _entries.has(_attack_to):
			var source: Dictionary = _entries[_attack_from].from
			var target: Dictionary = _entries[_attack_to].from
			_lunge = (_center(target) - _center(source)).normalized() * float(motion.attack_lunge_distance) * _scale
		_set_frontline(0.0)


	func _prepare_hit() -> void:
		_hit_state = (before if action.get("type", "") == "attack" else after).duplicate(true)
		for event in events:
			match str(event.get("type", "")):
				"units_battled":
					_attack_from = "unit:" + str(event.attacker_id)
					_attack_to = "unit:" + str(event.target_id)
					_set_hp(str(event.attacker_id), int(event.attacker_hp))
					_set_hp(str(event.target_id), int(event.target_hp))
					_damage.append({"key": _attack_from, "amount": int(event.damage_to_attacker)})
					_damage.append({"key": _attack_to, "amount": int(event.damage_to_target)})
				"hq_attacked":
					_attack_from = "unit:" + str(event.attacker_id)
					_attack_to = str(event.target_id)
					_set_hp(_attack_to, int(event.remaining_hp))
					_damage.append({"key": _attack_to, "amount": int(event.damage)})
				"unit_destroyed": _casualties.append("unit:" + str(event.unit_id))
				"fatigue_damage":
					var key: String = "hq:" + str(event.side)
					_set_hp(key, int(event.remaining_hp))
					_damage.append({"key": key, "amount": int(event.damage)})


	func _set_hp(id: String, hp: int) -> void:
		if id.begins_with("hq:"):
			var side: String = id.trim_prefix("hq:")
			if _hit_state.get("sides", {}).has(side): _hit_state.sides[side].hq_hp = hp
		elif _hit_state.get("units", {}).has(id): _hit_state.units[id].hp = hp


	func _prepare_stages() -> void:
		if action.get("type", "") == "attack":
			_add_stage("attack_windup", motion.attack_windup_seconds)
			_add_stage("attack_line", motion.attack_line_seconds)
			_add_stage("attack_hit", motion.attack_hit_seconds)
			_add_stage("attack_recover", motion.attack_recover_seconds)
			return
		for event in events:
			if event.get("type", "") == "turn_ended":
				_add_stage("turn_end", motion.turn_end_seconds, host.text.caption("turn_ended") % _side_name(str(event.side)))
		for event in events:
			if event.get("type", "") == "turn_started":
				_add_stage("turn_start", motion.turn_start_seconds, host.text.caption("turn_started") % _side_name(str(event.side)))
		var has_draw: bool = false
		for event in events:
			if event.get("type", "") == "card_drawn": has_draw = true
		if action.get("type", "") in ["deploy", "move", "mulligan"] or has_draw:
			_add_stage("travel", motion.travel_seconds)
		if not _damage.is_empty():
			_add_stage("attack_hit", motion.attack_hit_seconds)
			_add_stage("attack_recover", motion.attack_recover_seconds)


	func _add_stage(value: String, seconds: float, caption: String = "") -> void:
		_stages.append({"name": value, "duration": maxf(0.001, seconds), "caption": caption})


	func _enter_stage() -> void:
		var stage_name: String = _stages[_index].name
		if stage_name == "turn_start": host.presentation_set_status(_before_hit_state())
		if stage_name in ["turn_start", "turn_end"]:
			if _turn_label == null:
				var placement: Dictionary = host.geometry.layout.animation
				_turn_label = _label("", Vector2(0.0, size.y * float(placement.turn_y_ratio)), Vector2(size.x, float(placement.turn_height) * _scale), int(placement.turn_font))
			_turn_label.text = _stages[_index].caption
			_turn_label.show()
		elif _turn_label != null: _turn_label.hide()
		if stage_name == "attack_hit":
			host.presentation_set_status(_hit_state)
			for key in _entries:
				var item: Dictionary = _entries[key]
				if not item.added: _update_card(item, str(key), _hit_state)
			for item in _damage:
				var amount: int = int(item.amount)
				if amount <= 0 or not _entries.has(item.key): continue
				var card: Control = _entries[item.key].node
				var point: Vector2 = card.position + Vector2(0.0, card.size.y * float(host.geometry.layout.animation.damage_y_ratio))
				_labels.append(_label(host.text.caption("damage") % amount, point, Vector2(card.size.x, float(host.geometry.layout.animation.damage_height) * _scale), int(host.geometry.layout.animation.damage_font), true))
		if stage_name in ["travel", "attack_recover"]:
			var display_state: Dictionary = _before_hit_state() if stage_name == "travel" else after
			host.presentation_set_status(display_state)
			for key in _entries:
				var item: Dictionary = _entries[key]
				if not item.removed and item.flipped: _update_card(item, str(key), display_state)
				if item.added: item.node.show()


	func _before_hit_state() -> Dictionary:
		if _damage.is_empty(): return after
		var result: Dictionary = after.duplicate(true)
		for item in _damage:
			var key: String = item.key
			if key.begins_with("hq:"):
				var side: String = key.trim_prefix("hq:")
				result.sides[side].hq_hp = before.sides[side].hq_hp
			else:
				var id: String = key.trim_prefix("unit:")
				if result.units.has(id) and before.units.has(id): result.units[id].hp = before.units[id].hp
		return result


	func _process(delta: float) -> void:
		if _finishing or run.done: return
		var remaining: float = delta
		while remaining > 0.0 and not _finishing:
			var duration: float = float(_stages[_index].duration)
			var step: float = minf(remaining, duration - _stage_time)
			_stage_time += step
			_elapsed += step
			remaining -= step
			_apply_stage(_stage_time / duration)
			if _stage_time + 0.00001 < duration: break
			_index += 1
			_stage_time = 0.0
			if _index >= _stages.size():
				_finish(false)
				return
			_enter_stage()
			_apply_stage(0.0)


	func _apply_stage(fraction: float) -> void:
		var stage_name: String = _stages[_index].name
		var t: float = clampf(fraction, 0.0, 1.0)
		var eased: float = motion.sample_curve(t)
		run.update_stage(stage_name, t, _elapsed, _duration)
		match stage_name:
			"travel":
				for key in _entries:
					var item: Dictionary = _entries[key]
					if not item.flipped and t >= float(motion.deploy_flip_fraction):
						_update_card(item, str(key), after)
						item.flipped = true
					_apply_pose(item.node, _mix_pose(item.from, item.to, eased))
					if item.removed: item.node.modulate.a = 1.0 - t
				_set_frontline(eased)
			"attack_windup":
				if _entries.has(_attack_from): _entries[_attack_from].node.position = _entries[_attack_from].from.position + _lunge * eased
			"attack_line": _line_progress = t
			"attack_recover":
				for key in _entries:
					var item: Dictionary = _entries[key]
					var from: Dictionary = item.from.duplicate(true)
					if key == _attack_from: from.position += _lunge
					_apply_pose(item.node, _mix_pose(from, item.to, eased))
					if item.removed: item.node.modulate.a = 1.0 - t
				for label in _labels: label.modulate.a = 1.0 - t
				_line_progress = 0.0
				_set_frontline(eased)
		queue_redraw()


	func _update_card(item: Dictionary, key: String, state: Dictionary) -> void:
		var node: Control = item.node
		var pose: Dictionary = {"position": node.position, "size": node.size, "rotation": node.rotation, "scale": node.scale, "pivot": node.pivot_offset}
		var previous_display: Dictionary = node.display_data.duplicate(true)
		host.presentation_update_card(node, key, state)
		if str(_stages[_index].name) == "attack_hit" and state == _hit_state:
			for field in ["ready", "type_name"]:
				if previous_display.has(field): node.display_data[field] = previous_display[field]
			node.queue_redraw()
		_apply_pose(node, pose)


	func _set_frontline(t: float) -> void:
		if not old_poses.has("_frontline_y") or not new_poses.has("_frontline_y"): return
		host.presentation_set_frontline_y(lerpf(float(old_poses._frontline_y), float(new_poses._frontline_y), t))


	func _draw() -> void:
		if _finishing or _stages.is_empty() or _index >= _stages.size(): return
		if _line_progress > 0.0 and _entries.has(_attack_from) and _entries.has(_attack_to):
			var source: Control = _entries[_attack_from].node
			var target: Control = _entries[_attack_to].node
			var from: Vector2 = source.position + source.size * 0.5
			var to: Vector2 = target.position + target.size * 0.5
			draw_line(from, from.lerp(to, _line_progress), host.profile.visual_theme.color("line"), maxf(1.0, float(host.profile.visual_theme.wireframe.attack_line_width) * _scale), bool(host.profile.visual_theme.wireframe.antialiased))
		if str(_stages[_index].name) in ["attack_hit", "attack_recover"]:
			for key in _casualties:
				if not _entries.has(key): continue
				var card: Control = _entries[key].node
				var inset: Vector2 = card.size * float(host.geometry.layout.animation.casualty_inset_ratio)
				var color := Color(host.profile.visual_theme.color("line"), card.modulate.a)
				draw_line(card.position + inset, card.position + card.size - inset, color, maxf(1.0, float(host.profile.visual_theme.wireframe.casualty_line_width) * _scale), bool(host.profile.visual_theme.wireframe.antialiased))
				draw_line(card.position + Vector2(card.size.x - inset.x, inset.y), card.position + Vector2(inset.x, card.size.y - inset.y), color, maxf(1.0, float(host.profile.visual_theme.wireframe.casualty_line_width) * _scale), bool(host.profile.visual_theme.wireframe.antialiased))


	func _label(value: String, point: Vector2, extent: Vector2, font_size: int, numeric: bool = false) -> Control:
		var label := FixedLabel.new()
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.text = value
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.position = point
		label.size = extent
		label.add_theme_font_override("font", host.profile.visual_theme.number_font if numeric else host.profile.visual_theme.font)
		label.add_theme_font_size_override("font_size", maxi(int(host.geometry.layout.animation.minimum_font), roundi(float(font_size) * _scale)))
		label.add_theme_color_override("font_color", host.profile.visual_theme.color("text"))
		label.add_theme_color_override("font_outline_color", host.profile.visual_theme.color("shadow"))
		label.add_theme_constant_override("outline_size", maxi(1, roundi(float(host.profile.visual_theme.wireframe.label_outline_width) * _scale)))
		add_child(label)
		return label


	func _cancel() -> void:
		_finish(true)


	func _finish(was_cancelled: bool) -> void:
		if _finishing: return
		_finishing = true
		set_process(false)
		for item in _entries.values():
			var card: Control = item.node
			if is_instance_valid(card):
				card.hide()
				card.queue_free()
		_entries.clear()
		if is_instance_valid(host):
			host.presentation_restore()
			host.presentation_set_status(after)
		run.complete(was_cancelled)
		queue_free()


	func _exit_tree() -> void:
		if run != null and not run.done: _finish(true)


	static func _card_key(key: String) -> bool:
		return key.begins_with("hand:") or key.begins_with("unit:") or key.begins_with("hq:") or key.begins_with("back:ai:")


	static func _center(pose: Dictionary) -> Vector2:
		return pose.position + pose.size * 0.5


	static func _apply_pose(card: Control, pose: Dictionary) -> void:
		card.position = pose.position
		card.size = pose.size
		card.rotation = float(pose.get("rotation", 0.0))
		card.scale = pose.get("scale", Vector2.ONE)
		card.pivot_offset = pose.get("pivot", card.size * 0.5)


	static func _mix_pose(from: Dictionary, to: Dictionary, t: float) -> Dictionary:
		return {"position": Vector2(from.position).lerp(to.position, t), "size": Vector2(from.size).lerp(to.size, t),
			"rotation": lerp_angle(float(from.get("rotation", 0.0)), float(to.get("rotation", 0.0)), t),
			"scale": Vector2(from.get("scale", Vector2.ONE)).lerp(to.get("scale", Vector2.ONE), t)}


	func _side_name(side: String) -> String:
		return host.text.caption("side_player" if side == "player" else "side_enemy")
