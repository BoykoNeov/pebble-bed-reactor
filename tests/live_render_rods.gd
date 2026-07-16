# tests/live_render_rods.gd
#
# Captures real rendered frames of the M5d control rods at several insertions:
#
#   godot --script res://tests/live_render_rods.gd        # NOTE: no --headless
#
# WHY (see live_render_capture.gd's header for the full argument): `--headless` uses a
# DUMMY renderer, so every suite here can be green while something on screen is invisible
# or wrong. The rods are a NEW piece of drawing — a channel, an inserted length, a tip
# marker, positioned from grid coordinates — and none of that is exercised by a test that
# never rasterizes. The coolant heatmap shipped flat black with a green suite; this is the
# same class of risk, so it gets the same treatment: go look at it.
#
# Not a gate — asserts nothing, needs a GPU and a window.
#
# The two traps from live_render_capture.gd apply here too:
#  * root.get_texture() returns the LAST FINISHED frame, so capture on a later frame than
#    the change you want to see.
#  * Driving state directly does not repaint by itself; _set_rods calls queue_redraw, which
#    is exactly the wiring this capture is checking, so it is used rather than bypassed.
extends SceneTree

# Insertions to photograph: withdrawn (channels only), mid-stroke, tip in the flux peak
# (where the S-curve is steepest), and fully in.
const SHOTS := [0.0, 0.25, 0.65, 1.0]
const START_AT := 38.0     # let the bed fill, seed and start turning
const SETTLE := 2.0        # per-shot: let the solve + redraw catch up before capturing
const GIVE_UP_AT := 140.0

var _main
var _t := 0.0
var _out := ""
var _i := 0
var _set_at := -1.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	DirAccess.make_dir_recursive_absolute("user://shots")
	_out = OS.get_user_data_dir() + "/shots/"
	print("[rod render capture] writing to %s" % _out)


func _process(delta: float) -> bool:
	_t += delta
	if _t < START_AT:
		return false
	if _i >= SHOTS.size():
		print("[rod render capture complete] %s" % _out)
		quit(0)
		return true
	if _t > GIVE_UP_AT:
		print("[rod render capture timed out] got %d/%d" % [_i, SHOTS.size()])
		quit(1)
		return true

	var target: float = SHOTS[_i]
	# Drive the lever the way the player's N/M keys do, then wait — both for the next flux
	# solve (so k/worth in the HUD match the picture) and for the redraw to land.
	if _set_at < 0.0:
		_main._set_rods(target)
		_set_at = _t
		return false
	if _t - _set_at < SETTLE:
		return false

	_capture("rods_%02d.png" % int(round(target * 100.0)))
	print("  rods %.0f%% in -> k_cold %.4f   worth %.4f Dk   A %.2f   peakT %.0f K"
		% [_main._rod_insertion * 100.0, _main._k_cold, _main._rod_worth,
		   _main._amplitude, _main._peak_temp])
	_i += 1
	_set_at = -1.0
	return false


func _capture(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("  (no image — renderer gave nothing; are you running with --headless?)")
		return
	img.save_png(_out + name)
	print("  saved %s (%dx%d)" % [name, img.get_width(), img.get_height()])
