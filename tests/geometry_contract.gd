extends SceneTree
## Resource and coordinate checks only; real mouse acceptance remains in ui_smoke.
const Geometry = preload("res://resources/art/battle_geometry.tres")
const Layout = preload("res://scripts/art_battle/battle_layout.gd")
const Card = preload("res://scripts/art/art_card.gd")
const DisplayProfile = preload("res://scripts/art/display_profile.gd")
const BattleMaterial = preload("res://resources/art/ancient_metal_profile.tres")
const SIZES: Array[Vector2] = [Vector2(1280, 720), Vector2(1366, 768), Vector2(1920, 1080), Vector2(2560, 1440), Vector2(3840, 2160), Vector2(1920, 1200), Vector2(3440, 1440), Vector2(1024, 640)]
var include_art: bool = OS.get_cmdline_user_args().has("--art")
var include_sizes: bool = OS.get_cmdline_user_args().has("--sizes")
var run_id: String = ""
var output_dir: String = ""
var assertions: int = 0
var failures: Array[String] = []
var trace: Array = []


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	for index in range(arguments.size() - 1):
		if arguments[index] == "--run-id": run_id = arguments[index + 1]
		elif arguments[index] == "--output-dir": output_dir = arguments[index + 1]
	call_deferred("_run")


func _run() -> void:
	if run_id.is_empty() or output_dir.is_empty():
		push_error("Geometry contract requires --run-id and --output-dir")
		quit(2)
		return
	var geometry: Resource = Geometry.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://docs/references/kards/geometry-baseline.json"))
	_check(not baseline.is_empty(), "Source measurement record loads")
	_profiles(geometry)
	_reference_bounds(geometry, baseline)
	for extent in (SIZES if include_sizes else [Vector2(1920, 1080)]):
		_safe_hands(geometry, extent)
		var layout: Dictionary = Layout.calculate(extent, 1.0, geometry)
		_check(layout.rects.settings == layout.rects.modal_close, "Settings and close share a rectangle at " + str(extent))
		_check(layout.rects.restart.size.is_equal_approx(layout.rects.end_turn.size) and layout.rects.main_menu.size.is_equal_approx(layout.rects.end_turn.size), "Settings actions match end-turn size at " + str(extent))
		for key in geometry.layout.viewport_rects:
			if geometry.layout.viewport_rects[key].get("allow_edge_crop", false): continue
			_check(Rect2(Vector2.ZERO, extent).encloses(layout.rects[key]), "Viewport hardware stays visible: %s at %s" % [key, extent])
		for count in [4, 5]:
			for index in range(count):
				var pose: Dictionary = Layout.mulligan_pose(layout, count, index)
				_check(Rect2(Vector2.ZERO, extent).encloses(Rect2(pose.position, pose.size)), "Mulligan %d/%d stays inside %s" % [count, index, extent])
	_check(is_equal_approx(float(geometry.layout.frontline_neutral_y), 287.226), "Neutral frontline geometry is explicit")
	_check(is_equal_approx(float(geometry.layout.frontline_player_y), 214.533), "Player frontline geometry is explicit")
	_check(is_equal_approx(float(geometry.layout.frontline_enemy_y), 360.51), "Enemy frontline design default is explicit")
	_write_result()
	quit(0 if failures.is_empty() else 1)


func _profiles(geometry: Resource) -> void:
	var before: Dictionary = geometry.spec()
	var full: Resource = geometry.template("full")
	var field: Resource = geometry.template("field")
	_check(field.size == Vector2(90, 123), "Field card preserves its outer proportions")
	_check(is_equal_approx(field.slots.banner.position.y, 3.0) and is_equal_approx(field.size.y - field.artwork_rect.end.y, 3.0), "Field content has equal three-unit top and bottom margins")
	_check(is_equal_approx(field.artwork_rect.position.x, 3.0) and is_equal_approx(field.size.x - field.artwork_rect.end.x, 3.0), "Field artwork preserves three-unit side margins")
	for key in ["attack_box", "health_box"]:
		_check(is_equal_approx(field.slots[key].end.y, 120.0), "Field stat box aligns with artwork bottom: " + key)
	for pair in [["attack_box", "attack"], ["health_box", "health"], ["type_icon_box", "type_icon"]]:
		_check(field.slots[pair[1]] == field.slots[pair[0]].grow(-1.0), "Field stat and icon content retain their frame inset: " + str(pair[1]))
	var mark: Rect2 = full.slots.mulligan_mark
	_check(is_equal_approx(mark.get_center().x, full.size.x * 0.5), "Mulligan mark is horizontally centered")
	_check(is_equal_approx(mark.position.y - full.slots.header.end.y, full.slots.attack_box.position.y - mark.end.y), "Mulligan mark has equal clearance from header bottom and stat boxes")
	var source: Resource = BattleMaterial.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	var source_before: Dictionary = source.visual_theme.surface.palette.duplicate(true)
	if include_art:
		var skin: Resource = source.visual_theme.control_skin
		_check(skin != null and skin.styles.mulligan_mark is StyleBoxTexture, "Material supplies replaceable stamp")
		_check(skin.styles.end_turn_face != skin.styles.end_turn_face_disabled, "Enabled and disabled button materials are independent")
		var original: Color = BattleMaterial.visual_theme.control_skin.styles.end_turn_face.modulate_color
		skin.styles.end_turn_face.modulate_color = Color.RED
		_check(BattleMaterial.visual_theme.control_skin.styles.end_turn_face.modulate_color == original and geometry.spec() == before, "Control skin copies cannot mutate shared theme or geometry")
	_check(source.visual_theme.card_texture != null and source.visual_theme.card_texture.get_size().x > 0, "Default card paper loads independently of tabletop")
	var displays: Array = [source]
	if include_art: displays.append(DisplayProfile.resolve(source, true))
	for profile: Resource in displays:
		var forbidden: bool = false
		for property in profile.get_property_list():
			if str(property.name) in ["layout", "templates", "geometry", "animation"]: forbidden = true
		for property in profile.visual_theme.get_property_list():
			if str(property.name) in ["layout", "templates", "geometry", "animation"]: forbidden = true
		_check(not forbidden, "Profile owns appearance only: " + str(profile.profile_id))
		for mode in ["full", "field", "hq", "back"]:
			var card := Card.new()
			card.configure({}, mode, profile, geometry.template(mode))
			_check(card.template_spec() == before.templates[mode] and card.size == geometry.template(mode).size, "Explicit geometry is identical: %s/%s" % [profile.profile_id, mode])
			card.free()
		profile.visual_theme.surface.palette["text"] = Color(0.5, 0.3, 0.1)
		_check(geometry.spec() == before, "Skin mutation leaves geometry untouched: " + str(profile.profile_id))
		if profile != source:
			_check(profile.artworks == null and profile.visual_theme.background_texture == null and profile.visual_theme.card_texture == null and profile.visual_theme.control_skin == null and profile.visual_theme.renderer.get_script().resource_path == "res://scripts/art/surface_renderer.gd", "Wireframe has no image dependencies and uses its own renderer")
	_check(source.visual_theme.background_texture != null and BattleMaterial.visual_theme.surface.palette == source_before, "Diagnostic resolution and copies preserve shared source materials")
	var shared_material: Resource = BattleMaterial
	var original_text: Color = shared_material.visual_theme.surface.palette.text
	shared_material.visual_theme.surface.palette.text = Color.RED
	var diagnostic: Resource = DisplayProfile.resolve(BattleMaterial, true)
	_check(diagnostic.visual_theme.color("text") == Color.WHITE, "Shared material edits cannot recolor fixed diagnostic style")
	shared_material.visual_theme.surface.palette.text = original_text
	var independent: Resource = geometry.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	independent.template("full").size.x += 1.0
	_check(geometry.spec() == before and independent.spec() != before, "Geometry isolation copies external card templates")


func _reference_bounds(geometry: Resource, baseline: Dictionary) -> void:
	var layout: Dictionary = Layout.calculate(Vector2(1920, 1080), 1.0, geometry)
	for sample in baseline.viewport_hud_samples:
		var source: Array = sample.source_rect_px
		var expected := Rect2(Vector2(source[0], source[1]) * 3.0, Vector2(source[2], source[3]) * 3.0)
		if sample.key == "settings":
			expected.position += Vector2(-18, -9)
			expected.size *= 1.5
		var error: float = _edge_error(layout.rects[sample.key], expected)
		_check(error <= 6.0, "Measured HUD boundary within 6 px: " + str(sample.key))
		trace.append({"kind": "viewport-hud", "key": sample.key, "maximum_edge_error": error})
	for sample in baseline.deck_face_samples:
		var target: Rect2 = layout.rects[sample.key]
		var angle: float = deg_to_rad(float(geometry.layout.battle_deck_angles[sample.side]))
		var transform: Transform2D = _pose_transform({"position": target.position, "size": target.size, "rotation": angle})
		var local: Array[Vector2] = [Vector2.ZERO, Vector2(target.size.x, 0), target.size, Vector2(0, target.size.y)]
		var error: float = 0.0
		for index in range(4):
			var actual: Vector2 = transform * local[index]
			var source: Array = sample.source_corners_px[index]
			var expected := Vector2(source[0], source[1]) * 3.0
			error = maxf(error, maxf(absf(actual.x - expected.x), absf(actual.y - expected.y)))
		_check(error <= 6.0, "Measured deck face corners within 6 px: " + str(sample.key))
		trace.append({"kind": "deck-face", "key": sample.key, "maximum_coordinate_error": error})
	for sample in baseline.row_and_frontline_samples:
		var actual: float = float(geometry.layout[sample.key]) * float(layout.art_scale)
		var expected: float = float(sample.source_value_px) * 3.0
		_check(absf(actual - expected) <= float(sample.tolerance_1920_px), "Measured row/frontline within 6 px: " + str(sample.key))
		trace.append({"kind": "layout", "key": sample.key, "actual_1920": actual, "source_expanded_1920": expected, "absolute_error": absf(actual - expected)})
	for sample in baseline.card_region_samples:
		var definition: Resource = geometry.template(str(sample.mode))
		var factor: float = float(layout.art_scale) * (float(geometry.layout.mulligan_scale) if sample.mode == "full" else 1.0)
		var source: Array = sample.source_rect_or_size_px
		var actual: Rect2
		var expected: Rect2
		if sample.key == "size":
			actual = Rect2(Vector2.ZERO, definition.size * factor)
			expected = Rect2(Vector2.ZERO, Vector2(source[0], source[1]) * 3.0)
		else:
			var target: Rect2 = definition.get(sample.key) if sample.key in ["inner_rect", "artwork_rect"] else definition.slots[sample.key]
			actual = Rect2(target.position * factor, target.size * factor)
			expected = Rect2(Vector2(source[0], source[1]) * 3.0, Vector2(source[2], source[3]) * 3.0)
			# Keep the original source measurements; apply the approved equal-margin adjustment.
			if sample.mode == "field":
				if sample.key == "artwork_rect": expected.size.y += 3.0 * factor
				elif sample.key in ["attack_box", "health_box", "type_icon_box"]: expected.position.y += 4.0 * factor
		var error: float = _edge_error(actual, expected)
		_check(error <= float(sample.tolerance_1920_px), "Measured card region within 6 px: %s/%s" % [sample.mode, sample.key])
		trace.append({"kind": "card-region", "mode": sample.mode, "key": sample.key, "maximum_edge_error": error})
	for sample in baseline.mulligan_five.cards:
		var pose: Dictionary = Layout.mulligan_pose(layout, 5, int(sample.index))
		var source: Array = sample.source_rect_px
		var expected := Rect2(Vector2(source[0], source[1]) * 3.0, Vector2(source[2], source[3]) * 3.0)
		var error: float = _edge_error(Rect2(pose.position, pose.size), expected)
		_check(error <= float(sample.tolerance_1920_px), "Five-card mulligan measured boundary within 6 px: " + str(sample.index))
		trace.append({"kind": "mulligan", "index": sample.index, "maximum_edge_error": error})


func _safe_hands(geometry: Resource, extent: Vector2) -> void:
	var layout: Dictionary = Layout.calculate(extent, 1.0, geometry)
	var poses: Array[Dictionary] = []
	for index in range(9): poses.append(Layout.hand_pose(layout, 9, index))
	var bounds: Rect2 = layout.viewport_rect.grow(-8.0 * float(layout.art_scale))
	var points: Array = []
	for index in range(9):
		var pose: Dictionary = poses[index]
		var found: bool = false
		var transform: Transform2D = _pose_transform(pose)
		var hover: Dictionary = Layout.hover_pose(layout, pose)
		var inverse_hover: Transform2D = _pose_transform(hover).affine_inverse()
		for yi in range(2, 48):
			if found: break
			for xi in range(2, 48):
				var candidate: Vector2 = transform * (pose.size * Vector2(xi / 50.0, yi / 50.0))
				if not bounds.has_point(candidate): continue
				if not Rect2(Vector2.ZERO, hover.size).has_point(inverse_hover * candidate): continue
				var covered: bool = false
				for other in range(index + 1, 9):
					if Rect2(Vector2.ZERO, poses[other].size).has_point(_pose_transform(poses[other]).affine_inverse() * candidate):
						covered = true
						break
				if not covered:
					points.append({"index": index, "x": candidate.x, "y": candidate.y})
					found = true
					break
		_check(found, "Nine-card fan has a visible rotation-aware safe point %d at %s" % [index, extent])
	_check(poses == _hand_poses(layout), "Computing hover preserves the nine base slots at " + str(extent))
	trace.append({"kind": "safe-hand-points", "viewport": [extent.x, extent.y], "points": points, "note": "Mathematical bounds only; real Input checks are in UI acceptance."})


func _hand_poses(layout: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(9): result.append(Layout.hand_pose(layout, 9, index))
	return result


func _pose_transform(pose: Dictionary) -> Transform2D:
	var transform := Transform2D(float(pose.rotation), Vector2.ZERO)
	var pivot: Vector2 = pose.size * 0.5
	transform.origin = pose.position + pivot - transform * pivot
	return transform


func _edge_error(actual: Rect2, expected: Rect2) -> float:
	return maxf(maxf(absf(actual.position.x - expected.position.x), absf(actual.position.y - expected.position.y)), maxf(absf(actual.end.x - expected.end.x), absf(actual.end.y - expected.end.y)))


func _check(ok: bool, caption: String) -> void:
	assertions += 1
	if not ok:
		failures.append(caption)
		push_error(caption)


func _write_result() -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(output_dir)
	_check(error == OK, "Geometry result directory is writable")
	var path: String = output_dir.path_join("geometry-result.json")
	var output: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		_check(false, "Cannot write geometry result")
		return
	var result: Dictionary = {"run_id": run_id, "status": "passed" if failures.is_empty() else "failed", "assertions": assertions, "failures": failures, "trace": trace, "godot_version": Engine.get_version_info(), "scope": {"art": include_art, "sizes": include_sizes}}
	output.store_string(JSON.stringify(result, "\t"))
	output.close()
	print("GEOMETRY_RESULT " + JSON.stringify({"run_id": run_id, "status": result.status, "assertions": assertions, "failures": failures.size(), "path": path}))
