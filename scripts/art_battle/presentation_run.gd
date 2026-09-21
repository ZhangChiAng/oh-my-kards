extends RefCounted
## A presentation always resolves exactly once, including when its view disappears.

signal finished(cancelled: bool)

var done: bool:
	get: return _done
var cancelled: bool:
	get: return _cancelled
var stage: String:
	get: return _stage
var progress: float:
	get: return _progress

var _done: bool = false
var _cancelled: bool = false
var _stage: String = "pending"
var _progress: float = 0.0
var _elapsed: float = 0.0
var _duration: float = 0.0
var _cancel_callback: Callable


func cancel() -> void:
	if _done: return
	if _cancel_callback.is_valid(): _cancel_callback.call()
	# Fallback still resolves if the animation owner was already freed.
	if not _done: complete(true)


func bind_cancel(callback: Callable) -> void:
	_cancel_callback = callback


func update_stage(value: String, fraction: float, elapsed: float, duration: float) -> void:
	if _done: return
	_stage = value
	_progress = clampf(fraction, 0.0, 1.0)
	_elapsed = elapsed
	_duration = duration


func complete(was_cancelled: bool = false) -> void:
	if _done: return
	_done = true
	_cancelled = was_cancelled
	_stage = "cancelled" if was_cancelled else "complete"
	_progress = 1.0
	_cancel_callback = Callable()
	finished.emit(was_cancelled)


func snapshot() -> Dictionary:
	return {"done": _done, "cancelled": _cancelled, "stage": _stage,
		"progress": _progress, "elapsed": _elapsed, "duration": _duration}
