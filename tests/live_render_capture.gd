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
const GIVE_UP_AT := 200.0
# A raised inlet, to prove the coolant window actually tracks the lever. The whole point of
# the lever-relative range is that it stays legible when the player raises the inlet — the
# case a fixed ceiling handles worst — so capturing only the default inlet would verify the
# easy half of the claim.
const RAISED_INLET := 500.0
const RAISE_AT := 46.0   # after the default-inlet shot, with time to re-solve the field

var _main
var _t := 0.0
var _out := ""
var _shot_field := false
var _shot_raised := false
var _raised := false
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
		_capture("field_%d.png" % FIELD)
		_report_scale()
		return false

	# Now raise the inlet (the K key's lever) and capture again: the coolant window should
	# have slid up with it, keeping the same gradient legible instead of clamping.
	if not _raised and _t >= RAISE_AT:
		_raised = true
		_main._set_inlet(RAISED_INLET)
		print("  inlet lever raised to %.0f K" % _main._inlet_temp)
		return false
	if _raised and not _shot_raised and _t >= RAISE_AT + 6.0:
		_shot_raised = true
		_capture("field_%d_inlet_raised.png" % FIELD)
		_report_scale()
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

	if _shot_field and _shot_raised and _shot_bin >= 3 and _done_at < 0.0:
		_done_at = _t
	if _done_at > 0.0 and _t > _done_at + 0.5:
		print("[render capture complete] %s" % _out)
		quit(0)
	if _t > GIVE_UP_AT:
		print("[render capture timed out] field=%s  bin shots=%d" % [str(_shot_field), _shot_bin])
		quit(1)
	return false


## The numbers behind the picture: if the field's display range does not sit on the span the
## HUD reports, the heatmap is a flat rectangle however correct the physics behind it is.
func _report_scale() -> void:
	var d = _main._fields[FIELD]["desc"]
	print("  field '%s' scale %.0f-%.0f %s   inlet %.0f K, bed outlet %.0f K (rise %.0f K = %.0f%% of scale)"
		% [d.name, d.vmin, d.vmax, d.units, _main._inlet_temp, _main._coolant_out,
			_main._coolant_out - _main._inlet_temp,
			100.0 * (_main._coolant_out - _main._inlet_temp) / maxf(d.vmax - d.vmin, 1.0)])


func _capture(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("  (no image — renderer gave nothing; are you running with --headless?)")
		return
	img.save_png(_out + name)
	print("  saved %s (%dx%d)" % [name, img.get_width(), img.get_height()])
