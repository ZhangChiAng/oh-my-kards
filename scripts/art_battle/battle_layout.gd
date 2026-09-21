extends RefCounted
## One transform maps the authored stage into logical viewport coordinates.
## Card poses, hit regions and insertion previews all use the same geometry.

const SharedLayout = preload("res://scripts/art/art_layout.gd")


static func calculate(viewport_size: Vector2, screen_scale: float, geometry: Resource) -> Dictionary:
	var extent := Vector2(maxf(viewport_size.x, 1.0), maxf(viewport_size.y, 1.0))
	var design_size: Vector2 = geometry.layout.stage_size
	var factor: float = minf(extent.x / design_size.x, extent.y / design_size.y)
	var stage := Rect2((extent - design_size * factor) * 0.5, design_size * factor)
	var settings: Dictionary = geometry.layout
	var layout: Dictionary = {
		"viewport_size": extent, "viewport_rect": Rect2(Vector2.ZERO, extent),
		"stage_rect": stage, "design_size": design_size, "art_scale": factor,
		"screen_scale": maxf(screen_scale, 0.1), "geometry": geometry,
		"body_font": ceili(maxf(float(settings.battle_font_sizes.body) * factor, float(settings.minimum_body_screen_size) / maxf(screen_scale, 0.1))),
		"field_size": geometry.template("field").size * factor,
		"full_size": geometry.template("full").size * factor,
		"back_size": geometry.template("back").size * factor,
		"row_left": stage.position.x + float(settings.battle_row_left) * factor,
		"row_right": stage.position.x + float(settings.battle_row_right) * factor,
		"row_center": stage.get_center().x,
		"row_step": float(settings.row_step) * factor,
		"enemy_y": stage.position.y + float(settings.enemy_y) * factor,
		"front_y": stage.position.y + float(settings.front_y) * factor,
		"player_y": stage.position.y + float(settings.player_y) * factor,
		"rects": {},
	}
	for key in settings.battle_rects:
		layout.rects[key] = rect(layout, settings.battle_rects[key])
	# Edge hardware follows the viewport instead of the narrower authored stage.
	# Its reference pixels remain geometry data, independent of the chosen skin.
	var reference: Vector2 = settings.viewport_reference_size
	var reference_scale: float = float(layout.art_scale) * design_size.y / reference.y
	var vertical_origin: float = (extent.y - reference.y * reference_scale) * 0.5
	for key in settings.viewport_rects:
		var entry: Dictionary = settings.viewport_rects[key]
		var source: Rect2 = entry.rect
		var origin := Vector2(source.position.x * reference_scale, vertical_origin + source.position.y * reference_scale)
		if entry.anchor == "right": origin.x = extent.x - (reference.x - source.position.x) * reference_scale
		elif entry.anchor == "center": origin.x = extent.x * 0.5 + (source.position.x - reference.x * 0.5) * reference_scale
		var dimensions: Vector2 = source.size * reference_scale
		if not entry.get("allow_edge_crop", false):
			dimensions = dimensions.min(extent)
			origin = origin.clamp(Vector2.ZERO, extent - dimensions)
		layout.rects[key] = Rect2(origin, dimensions)
	return layout


static func to_view(layout: Dictionary, point: Vector2) -> Vector2:
	return layout.stage_rect.position + point * float(layout.art_scale)


static func to_design(layout: Dictionary, point: Vector2) -> Vector2:
	return (point - layout.stage_rect.position) / float(layout.art_scale)


static func rect(layout: Dictionary, design_rect: Rect2) -> Rect2:
	return Rect2(to_view(layout, design_rect.position), design_rect.size * float(layout.art_scale))


static func hand_pose(layout: Dictionary, count: int, index: int) -> Dictionary:
	var pose: Dictionary = SharedLayout.hand_pose(layout.geometry, count, index)
	pose.position = to_view(layout, pose.position)
	pose.size *= float(layout.art_scale)
	return pose


static func mulligan_pose(layout: Dictionary, count: int, index: int) -> Dictionary:
	var card_size: Vector2 = layout.full_size * float(layout.geometry.layout.mulligan_scale)
	var area: Rect2 = layout.rects.mulligan_cards
	var gap: float = float(layout.geometry.layout.mulligan_card_gap) * float(layout.art_scale)
	var step: float = minf(card_size.x + gap, (area.size.x - card_size.x) / maxf(count - 1, 1))
	var total_width: float = card_size.x + maxf(count - 1, 0) * step
	return _pose(Vector2(area.get_center().x - total_width * 0.5 + index * step, area.get_center().y - card_size.y * 0.5), card_size)


static func row_pose(layout: Dictionary, row: String, kind: String, index: int, count: int) -> Dictionary:
	var card_size: Vector2 = layout.geometry.template(kind).size * float(layout.art_scale)
	var row_width: float = float(layout.row_right) - float(layout.row_left)
	var step: float = minf(float(layout.row_step), (row_width - card_size.x) / maxf(count - 1, 1))
	var width: float = card_size.x + maxf(count - 1, 0) * step
	return _pose(Vector2(float(layout.row_center) - width * 0.5 + index * step, row_y(layout, row)), card_size)


static func row_y(layout: Dictionary, row: String) -> float:
	if row == "enemy": return float(layout.enemy_y)
	if row == "frontline": return float(layout.front_y)
	return float(layout.player_y)


static func gap_geometry(layout: Dictionary, row: String, index: int, count: int) -> Dictionary:
	var card_size: Vector2 = layout.field_size
	var left: float = float(layout.row_left)
	var right: float = float(layout.row_right)
	if index > 0:
		left = float(row_pose(layout, row, "field", index - 1, count).position.x) + card_size.x * 0.5
	if index < count:
		right = float(row_pose(layout, row, "field", index, count).position.x) + card_size.x * 0.5
	var marker_x: float = (left + right) * 0.5
	var pad: float = float(layout.geometry.layout.gap_padding) * float(layout.art_scale)
	if count > 0:
		if index == 0: marker_x = right - card_size.x * 0.5 - pad
		elif index == count: marker_x = left + card_size.x * 0.5 + pad
	var y: float = row_y(layout, row)
	return {"rect": Rect2(left, y - pad, right - left, card_size.y + pad * 2.0), "hit_point": Vector2(marker_x, y + card_size.y * 0.5)}


static func hover_pose(layout: Dictionary, base: Dictionary) -> Dictionary:
	var result: Dictionary = base.duplicate(true)
	var edge: float = float(layout.geometry.layout.popup_margin) * float(layout.art_scale)
	var bounds: Rect2 = layout.viewport_rect.grow(-edge)
	result.position = Vector2(base.position.x, to_view(layout, Vector2(0, float(layout.geometry.layout.hover_y))).y).clamp(bounds.position, bounds.end - result.size)
	result.rotation = 0.0
	result.scale = Vector2.ONE
	return result


static func enemy_back_pose(layout: Dictionary, index: int, count: int) -> Dictionary:
	var settings: Dictionary = layout.geometry.layout
	var card_size: Vector2 = layout.geometry.template("back").size
	var half: float = maxf(float(count - 1) * 0.5, 0.0)
	var offset: float = float(index) - half
	var step: float = minf(float(settings.enemy_hand_step), (float(settings.enemy_hand_width) - card_size.x) / maxf(count - 1, 1))
	var relative: float = offset / maxf(half, 1.0)
	var center: Vector2 = Vector2(layout.design_size.x * 0.5 + offset * step, float(settings.enemy_hand_center_y) - absf(relative) * float(settings.enemy_hand_rise))
	var pose: Dictionary = _pose(to_view(layout, center - card_size * 0.5), card_size * float(layout.art_scale))
	pose.rotation = deg_to_rad(-relative * float(settings.enemy_hand_max_angle))
	return pose


static func detail_geometry(layout: Dictionary, anchor: Rect2, panel_size: Vector2, show_card: bool, avoid_rects: Array[Rect2] = []) -> Dictionary:
	if not show_card:
		return {"card": _pose(anchor.position, anchor.size), "rules": popup_rect(layout, panel_size, anchor, avoid_rects), "source": anchor}
	var settings: Dictionary = layout.geometry.layout
	var card_size: Vector2 = layout.full_size * float(settings.detail_scale)
	var gap: float = float(settings.popup_gap) * float(layout.art_scale)
	var group_size := Vector2(card_size.x + gap + panel_size.x, maxf(card_size.y, panel_size.y))
	var group: Rect2 = popup_rect(layout, group_size, anchor, avoid_rects)
	var card_on_right: bool = group.get_center().x < anchor.get_center().x
	var card_position: Vector2 = group.position + (Vector2(panel_size.x + gap, 0) if card_on_right else Vector2.ZERO)
	var rules_position: Vector2 = group.position + (Vector2.ZERO if card_on_right else Vector2(card_size.x + gap, 0))
	return {"card": _pose(card_position, card_size), "rules": Rect2(rules_position, panel_size), "source": anchor, "group": group}


## Shared placement for hover cards and rule text. The anchor is
## never sacrificed to save space: when crowded, other overlaps are preferred.
static func popup_rect(layout: Dictionary, popup_size: Vector2, anchor: Rect2, avoid_rects: Array[Rect2] = [], preferred_positions: Array[Vector2] = []) -> Rect2:
	var factor: float = float(layout.art_scale)
	var gap: float = float(layout.geometry.layout.popup_gap) * factor
	var bounds: Rect2 = layout.viewport_rect.grow(-float(layout.geometry.layout.popup_margin) * factor)
	var maximum: Vector2 = (bounds.end - popup_size).max(bounds.position)
	var candidates: Array[Vector2] = preferred_positions.duplicate()
	var obstacles: Array[Rect2] = [anchor]
	obstacles.append_array(avoid_rects)
	for obstacle in obstacles:
		candidates.append(Vector2(obstacle.end.x + gap, obstacle.position.y))
		candidates.append(Vector2(obstacle.position.x - popup_size.x - gap, obstacle.position.y))
		candidates.append(Vector2(obstacle.end.x + gap, obstacle.end.y - popup_size.y))
		candidates.append(Vector2(obstacle.position.x - popup_size.x - gap, obstacle.end.y - popup_size.y))
		candidates.append(Vector2(obstacle.get_center().x - popup_size.x * 0.5, obstacle.position.y - popup_size.y - gap))
		candidates.append(Vector2(obstacle.get_center().x - popup_size.x * 0.5, obstacle.end.y + gap))
	for corner in [bounds.position, Vector2(maximum.x, bounds.position.y), maximum, Vector2(bounds.position.x, maximum.y)]:
		candidates.append(corner)
	var best := Rect2(bounds.position, popup_size)
	var smallest_overlap: float = INF
	for candidate in candidates:
		var placed := Rect2(candidate.clamp(bounds.position, maximum), popup_size)
		var overlap_area: float = 0.0
		for index in range(obstacles.size()):
			var obstacle: Rect2 = obstacles[index]
			var overlap: Rect2 = placed.intersection(obstacle.grow(gap * 0.5))
			if overlap.has_area(): overlap_area += overlap.size.x * overlap.size.y * (1000000.0 if index == 0 else 1.0)
		if overlap_area <= 0.0: return placed
		if overlap_area < smallest_overlap:
			smallest_overlap = overlap_area
			best = placed
	return best


static func _pose(position: Vector2, size: Vector2) -> Dictionary:
	return {"position": position, "size": size, "rotation": 0.0, "scale": Vector2.ONE}
