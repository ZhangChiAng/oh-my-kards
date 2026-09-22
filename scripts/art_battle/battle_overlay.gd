extends Control
## View-owned affordances. No target selection and no battle mutations.
var profile: Resource
var active: bool = false
var arrow: bool = false
var legal: bool = false
var start := Vector2.ZERO
var cursor := Vector2.ZERO
var presentation_scale: float = 1.0


func _draw() -> void:
	if not active or profile == null:
		return
	var accent: Color = profile.visual_theme.color("amber" if legal else "danger")
	var unit: float = presentation_scale
	var style: Dictionary = profile.visual_theme.surface.strokes
	if arrow and cursor.distance_to(start) > 1.0:
		var direction: Vector2 = (cursor - start).normalized()
		var tip: Vector2 = cursor - direction * float(style.arrow_tip_gap) * unit
		var normal: Vector2 = direction.orthogonal()
		draw_line(start, tip, profile.visual_theme.color("shadow"), float(style.arrow_shadow_width) * unit, bool(style.antialiased))
		draw_line(start, tip, accent, float(style.arrow_width) * unit, bool(style.antialiased))
		draw_colored_polygon(PackedVector2Array([tip + direction * float(style.arrow_tip_length) * unit, tip - direction * float(style.arrow_head_length) * unit + normal * float(style.arrow_head_half_width) * unit, tip - direction * float(style.arrow_head_length) * unit - normal * float(style.arrow_head_half_width) * unit]), accent)
