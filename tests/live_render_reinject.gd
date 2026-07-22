# tests/live_render_reinject.gd
#
# Captures real rendered frames of REINJECT's own riser (Phase 3b-iii) — a re-injected pebble
# climbing its own dedicated pipe beside the pool, and the ANSWER to the question this route's
# geometry was chosen against: does it sit legibly next to the M5d rod channel at x ~ 526, or
# does it visually clutter the reflector corridor the pool's shallow-tray design was built to
# keep clear for that channel?
#
#   godot --script res://tests/live_render_reinject.gd        # NOTE: no --headless
#
# Not a gate — asserts nothing, needs a GPU and a window. Same two traps as live_render_riser:
# capture on a LATER frame than any state change, and move fields via `_cycle_field` (which
# also refreshes the display) rather than writing `_current_field` directly.
extends SceneTree

const FIELD := 7    # burnup — a PER-PEBBLE field, see live_render_riser for why
const ACT_AT := 80.0
const SHOTS := 4
const SHOT_EVERY := 0.7   # the whole climb is ~2.5 s (tests/live_reinject_riser.gd measured it)
const GIVE_UP_AT := 140.0

var _main
var _t := 0.0
var _out := ""
var _acted := false
var _shots := 0
var _next_shot := 0.0
var _field_set := false
var _done_at := -1.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	DirAccess.make_dir_recursive_absolute("user://shots")
	_out = OS.get_user_data_dir() + "/shots/"
	print("[render reinject] writing to %s" % _out)
	print("  reinject riser bore x %.0f..%.0f — rod channel at x ~526"
		% [FuelLoop.REINJECT_X - FuelLoop.BORE_W * 0.5, FuelLoop.REINJECT_X + FuelLoop.BORE_W * 0.5])


func _process(delta: float) -> bool:
	_t += delta

	if not _acted:
		if _t < ACT_AT:
			return false
		_acted = true
		_act()
		return false

	# Move the field the way the player's V key does, and capture on a LATER frame than the
	# switch — `root.get_texture()` returns the last FINISHED frame.
	if _main._current_field != FIELD:
		_main._cycle_field()
		return false
	if not _field_set:
		_field_set = true
		return false

	if _shots < SHOTS and _t >= _next_shot:
		_next_shot = _t + SHOT_EVERY
		_shots += 1
		_capture("reinject_%d.png" % _shots)
		_dump()

	if _shots >= SHOTS and _done_at < 0.0:
		_done_at = _t
	if _done_at > 0.0 and _t > _done_at + 0.5:
		print("[render reinject complete] %s" % _out)
		quit(0)
	if _t > GIVE_UP_AT:
		print("[render reinject timed out] shots=%d" % _shots)
		quit(1)
	return false


## Same click-and-press path a player takes, mirroring tests/live_reinject.gd's `_act`.
func _act() -> void:
	var spent: Array = _main._spent
	if spent.is_empty():
		print("  (no settled pebble to re-inject at t=%.0f)" % _t)
		return
	_main._pick_at(_main._physics.get_position(spent[0].id))
	if _main._selected != spent[0]:
		print("  (click did not land on the pool pebble)")
		return
	print("  re-injecting #%d" % _main._selected.id)
	_main._reinject_selected()


func _dump() -> void:
	var riding := 0
	for id in _main._transit:
		if _main._transit[id] != FuelLoop.REINJECT:
			continue
		riding += 1
		var at: Vector2 = _main._physics.get_position(id)
		print("    #%-4d reinject (%6.1f, %6.1f)  v=%4.0f px/s"
			% [id, at.x, at.y, _main._physics.get_velocity(id).length()])
	print("  t=%.0f  reinject_pending %d   in transit %d   bed %d/%d"
		% [_t, _main._reinject_pending.size(), riding, _main._core_count(),
			_main._population_setpoint])


func _capture(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("  (no image — renderer gave nothing; are you running with --headless?)")
		return
	img.save_png(_out + name)
	print("  saved %s (%dx%d)" % [name, img.get_width(), img.get_height()])
