# tests/live_render_capture.gd
#
# Captures real rendered frames of the running scene to PNG, for the things only an eyeball
# can judge.
#
#   godot --script res://tests/live_render_capture.gd        # NOTE: no --headless
#
# WHY THIS EXISTS: every other harness here runs `--headless`, which uses a DUMMY renderer.
# That exercises `_draw` without crashing and proves nothing about pixels — so a field can be
# registered, solved, homogenized, unit-tested green, and still be unreadable on screen. That
# is not hypothetical: the coolant-temperature heatmap shipped with a fixed 293-900 K range
# that squashed the bed's entire downstream rise into the bottom ~17% of the colormap, so the
# one thing the field exists to show rendered as flat black. Every suite was green. It took a
# rendered frame to see it.
#
# Not a gate — it asserts nothing and needs a GPU and a window, so it cannot run in CI. It is
# the tool for "go look at it" when a visual claim needs evidence.
#
# TWO TRAPS, both learned the hard way, both preserved in the code below:
#  * `root.get_texture()` returns the frame the GPU last FINISHED. Capturing in the same
#    _process that changes something yields the PREVIOUS state's image.
#  * Setting `_current_field` does NOT repaint. `_cycle_field` also calls
#    `_refresh_field_display`, which is what pushes the field into the heatmap and colorbar.
#    Bypassing it renders the OLD heatmap under a HUD label naming the NEW field.
extends SceneTree

# Which field to capture — index into main._fields. 5 = coolant temperature.
const FIELD := 5
# Let the bed fill, seed, and start turning first.
const START_AT := 38.0
const GIVE_UP_AT := 150.0

var _main
var _t := 0.0
var _out := ""
var _shot_field := false
var _shot_bin := 0
var _done_at := -1.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	# user:// so this works on any machine, rather than hardcoding one person's scratch dir.
	DirAccess.make_dir_recursive_absolute("user://shots")
	_out = OS.get_user_data_dir() + "/shots/"
	print("[render capture] writing to %s" % _out)


func _process(delta: float) -> bool:
	_t += delta
	if _t < START_AT:
		return false

	# Switch fields the way the player's V key does (see trap 2 in the header).
	if _main._current_field != FIELD:
		_main._cycle_field()
		return false
	# Capture on a LATER frame than the switch (trap 1).
	if not _shot_field:
		_shot_field = true
		var d = _main._fields[FIELD]["desc"]
		_capture("field_%d.png" % FIELD)
		print("  field '%s' scale %.0f-%.0f %s (inlet %.0f K, bed outlet %.0f K)"
			% [d.name, d.vmin, d.vmax, d.units, _main._inlet_temp, _main._coolant_out])
		return false

	# Wait for a REAL discharge and catch it heading into the spent bin. Discharges are rare
	# (~5 per 70 s), so this waits for one rather than staging a fake.
	if _shot_bin < 3:
		for r in _main._loop._riders:
			if r["kind"] == FuelLoop.DISCHARGE and r["d"] / r["len"] > 0.6:
				_shot_bin += 1
				_capture("spent_bin_%d.png" % _shot_bin)
				print("  DISCHARGE rider #%d at %.0f%% along its leg to the bin"
					% [r["id"], 100.0 * r["d"] / r["len"]])
				break

	if _shot_field and _shot_bin >= 3 and _done_at < 0.0:
		_done_at = _t
	if _done_at > 0.0 and _t > _done_at + 0.5:
		print("[render capture complete] %s" % _out)
		quit(0)
	if _t > GIVE_UP_AT:
		print("[render capture timed out] field=%s  bin shots=%d" % [str(_shot_field), _shot_bin])
		quit(1)
	return false


func _capture(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("  (no image — renderer gave nothing; are you running with --headless?)")
		return
	img.save_png(_out + name)
	print("  saved %s (%dx%d)" % [name, img.get_width(), img.get_height()])
