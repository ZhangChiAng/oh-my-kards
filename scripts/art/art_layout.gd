extends RefCounted
## Layout owns outer poses. Templates alone own card-internal geometry.

static func hand_pose(geometry: Resource, count: int, index: int) -> Dictionary:
	var card_size: Vector2 = geometry.template("full").size
	var settings: Dictionary = geometry.layout
	var half: float = float(count - 1) * 0.5
	var max_angle: float = minf(float(settings.max_hand_angle), half * float(settings.hand_step_angle))
	var angle: float = 0.0 if half == 0.0 else (float(index) - half) / half * max_angle
	var radians: float = deg_to_rad(angle)
	var radius: float = float(settings.hand_radius)
	var center := Vector2(float(settings.hand_center_x) + radius * sin(radians), float(settings.hand_pivot_y) - radius * cos(radians))
	return {"position": center - card_size * 0.5, "size": card_size, "rotation": radians, "scale": Vector2.ONE}
