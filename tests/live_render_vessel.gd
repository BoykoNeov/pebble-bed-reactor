# tests/live_render_vessel.gd
#
# Captures rendered frames of the vessel shell and the fuel-handling PIPEWORK.
#
#   godot --script res://tests/live_render_vessel.gd        # NOTE: no --headless
#
# WHY (same reason as live_render_capture.gd, which this is modelled on): the shell and the
# pipes are pure `_draw`, and `--headless` uses a DUMMY renderer that executes _draw and
# produces no pixels. The whole suite can be green while the wall is inside out or the pipe
# reads as a stripe. tests/test_silo.gd proves the shell's GEOMETRY is sound headlessly —
# that it is uniformly WALL_T thick and strictly outward — but "is it legible" is not a
# property a number can settle. This is the go-look-at-it tool.
#
# Both traps from live_render_capture.gd apply and are respected below: capture a frame
# LATER than the change, and change fields via _cycle_field (not _current_field).
#
# Not a gate — it asserts nothing and needs a GPU and a window.
extends SceneTree

# Let the bed fill and settle so the shell is framed by a real packed core, and the fuel
# loop has pebbles actually riding the pipes (which is the thing being judged).
const START_AT := 40.0
const GIVE_UP_AT := 220.0
# Rods half in, for the shot that checks the thicker wall did not swallow the rod channels.
const ROD_INSERTION := 0.5

var _main
var _t := 0.0
var _out := ""
var _shot_wide := false
var _shot_rods := false
var _shot_riders := 0
var _done_at := -1.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	DirAccess.make_dir_recursive_absolute("user://shots")
	_out = OS.get_user_data_dir() + "/shots/"
	print("[vessel capture] writing to %s" % _out)


func _process(delta: float) -> bool:
	_t += delta
	if _t < START_AT:
		return false

	# 1. The default view: thick shell around a packed bed, pipes carrying the fuel loop.
	if not _shot_wide:
		_shot_wide = true
		_capture("vessel_shell.png")
		_report_geometry()
		return false

	# 2. Rods half inserted — the shell must not have covered the channels they ride in.
	#    Drive them through the player's own lever so this is the real path, not a poke.
	if not _shot_rods:
		_shot_rods = true
		_main._set_rods(ROD_INSERTION)
		return false
	if _shot_rods and _shot_riders == 0:
		_capture("vessel_rods.png")
		print("  rods at %.0f%% — channels at x = %s, wall outer faces at x = %.0f / %.0f"
			% [_main._rod_insertion * 100.0, str(_rod_x()), Silo.LEFT - Silo.WALL_T,
				Silo.RIGHT + Silo.WALL_T])
		_shot_riders = 1
		return false

	# 3. Catch pebbles actually INSIDE the pipe — the point of the whole slice. Phase 3c made
	#    every leg a real body (no more presentation-only riders), so "on a straight run" is
	#    now a real zone check rather than a fraction along a stored path — pick a transiting
	#    body actually inside one of the pipe zones, not right at either end. Several shots,
	#    because traffic is spread around the loop.
	if _shot_riders < 4:
		for id in _main._transit:
			var at: Vector2 = _main._physics.get_position(id)
			var leg: int = _main._transit[id]
			var mid_pipe: bool = FuelLoop.in_duct(at) or FuelLoop.in_riser(at) \
				or FuelLoop.in_recirc_merge(at) or FuelLoop.in_reinject_riser(at) \
				or FuelLoop.in_reinject_merge(at)
			if mid_pipe:
				_shot_riders += 1
				_capture("vessel_pipe_rider_%d.png" % _shot_riders)
				print("  body #%d leg=%d at (%.0f, %.0f)" % [id, leg, at.x, at.y])
				break

	if _shot_wide and _shot_rods and _shot_riders >= 4 and _done_at < 0.0:
		_done_at = _t
	if _done_at > 0.0 and _t > _done_at + 0.5:
		print("[vessel capture complete] %s" % _out)
		quit(0)
	if _t > GIVE_UP_AT:
		print("[vessel capture timed out] wide=%s rods=%s riders=%d"
			% [str(_shot_wide), str(_shot_rods), _shot_riders])
		quit(1)
	return false


func _rod_x() -> Array:
	var xs := []
	for i in ControlRods.rod_columns(_main._grid):
		xs.append(_main._grid.ox + (float(i) + 0.5) * _main._grid.h)
	return xs


## The numbers behind the picture — so a wrong-looking frame can be told apart from a
## wrong-looking *scene*.
func _report_geometry() -> void:
	print("  bed %d/%d in core, %d in transit; shell %0.f px thick, bed x = %.0f..%.0f"
		% [_main._core_count(), _main._population_setpoint, _main._transit.size(), Silo.WALL_T,
			Silo.LEFT, Silo.RIGHT])
	print("  pipe bore %.0f px carrying pebbles of r=%.0f (clearance %.0f px each side)"
		% [FuelLoop.BORE_W, FuelLoop.PEBBLE_R, FuelLoop.BORE_CLEARANCE])


func _capture(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("  (no image — renderer gave nothing; are you running with --headless?)")
		return
	img.save_png(_out + name)
	print("  saved %s (%dx%d)" % [name, img.get_width(), img.get_height()])
