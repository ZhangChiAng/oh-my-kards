extends Resource
## Animation timing is independent of geometry and artwork.

@export_range(0.0, 2.0, 0.01) var detail_delay_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var insertion_seconds: float = 0.0
@export var motion_id: String = ""
@export_enum("linear", "quadratic_out", "cubic_out") var travel_curve: String = "linear"
@export_range(0.0, 2.0, 0.01) var hover_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var cancel_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var travel_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var turn_end_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var turn_start_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var attack_windup_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var attack_line_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var attack_hit_seconds: float = 0.0
@export_range(0.0, 2.0, 0.01) var attack_recover_seconds: float = 0.0
@export_range(0.0, 60.0, 1.0) var attack_lunge_distance: float = 0.0

@export_range(0.0, 1.0, 0.01) var deploy_flip_fraction: float = 0.0


func spec() -> Dictionary:
	return {
		"motion_id": motion_id,
		"detail_delay_seconds": detail_delay_seconds, "insertion_seconds": insertion_seconds,
		"hover_seconds": hover_seconds, "cancel_seconds": cancel_seconds,
		"travel_seconds": travel_seconds, "deploy_flip_fraction": deploy_flip_fraction,
		"turn_end_seconds": turn_end_seconds, "turn_start_seconds": turn_start_seconds,
		"attack_windup_seconds": attack_windup_seconds, "attack_line_seconds": attack_line_seconds,
		"attack_hit_seconds": attack_hit_seconds, "attack_recover_seconds": attack_recover_seconds,
		"attack_lunge_distance": attack_lunge_distance,
		"travel_curve": travel_curve,
	}


func sample_curve(fraction: float) -> float:
	var t: float = clampf(fraction, 0.0, 1.0)
	match travel_curve:
		"linear": return t
		"cubic_out": return 1.0 - pow(1.0 - t, 3.0)
	return 1.0 - (1.0 - t) * (1.0 - t)


## Pair with Tween.EASE_OUT. The sampled and native-tween paths share this choice.
func tween_transition() -> Tween.TransitionType:
	match travel_curve:
		"linear": return Tween.TRANS_LINEAR
		"cubic_out": return Tween.TRANS_CUBIC
	return Tween.TRANS_QUAD
