# tests/live_render_riser.gd
#
# Captures real rendered frames of the RECIRCULATION leg (Phase 3b-ii) — pebbles climbing the
# riser as real bodies inside a real pipe.
#
#   godot --script res://tests/live_render_riser.gd        # NOTE: no --headless
#
# WHY: every gate for this slice runs `--headless`, which uses a DUMMY renderer — it exercises
# `_draw` without producing pixels. So the whole plant can be green (bed pinned, nothing stuck,
# nothing lost) while the pebbles climb a pipe that is drawn somewhere else entirely, or phase
# through its walls, or vanish at the hand-off onto the chute. The physics faces come from
# `FuelLoop.plant_walls` and the drawn bore from `_pipe_runs`, and the ONLY thing keeping those
# two in agreement is that both derive from the same constants. That is an argument, not
# evidence. This is the evidence.
#
# Not a gate — it asserts nothing and needs a GPU and a window. It is the "go look at it" tool.
#
# The two traps from live_render_capture apply here too and are respected below:
#  * `root.get_texture()` returns the frame the GPU last FINISHED, so never capture in the same
#    _process that changed something.
#  * `_current_field` must be moved with `_cycle_field`, which also refreshes the display.
extends SceneTree

# Burnup — a PER-PEBBLE field, chosen deliberately over a grid one: it colors the bodies
# themselves, so a climbing pebble is legible against the pipe AND carries its own state up the
# riser. That is the Lagrangian claim this leg exists to make good on — you can follow one
# pebble out of the bed, up the machine and back in.
#
# The INDEX into main._fields, and it must be counted from that list rather than guessed: 3 is
# "Moderation M", a GRID field, which would have painted a heatmap and left every pebble in
# graphite grey — the exact shot this harness exists to avoid taking.
const FIELD := 7
const START_AT := 40.0     # the bed fills by ~30 s; give the sorter time to be recirculating
const GIVE_UP_AT := 180.0
const SHOTS := 4
const SHOT_EVERY := 1.4    # a ~3 s climb, so this walks the pebbles up the pipe between frames

var _main
var _t := 0.0
var _out := ""
var _shots := 0
var _next_shot := 0.0
var _field_set := false
var _done_at := -1.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	DirAccess.make_dir_recursive_absolute("user://shots")
	_out = OS.get_user_data_dir() + "/shots/"
	print("[render riser] writing to %s" % _out)
	print("  riser bore x %.0f..%.0f, climbing from the duct at y %.0f to the chute at y %.0f"
		% [FuelLoop.RISER_X - FuelLoop.BORE_W * 0.5, FuelLoop.RISER_X + FuelLoop.BORE_W * 0.5,
			FuelLoop.HUB_Y, FuelLoop.CHUTE_Y])


func _process(delta: float) -> bool:
	_t += delta
	if _t < START_AT:
		return false

	# Move the field the way the player's V key does (trap 2), and capture on a LATER frame
	# than the switch (trap 1).
	if _main._current_field != FIELD:
		_main._cycle_field()
		return false
	if not _field_set:
		_field_set = true
		return false

	if _shots < SHOTS and _t >= _next_shot:
		_next_shot = _t + SHOT_EVERY
		_shots += 1
		_capture("riser_%d.png" % _shots)
		_dump_leg()

	if _shots >= SHOTS and _done_at < 0.0:
		_done_at = _t
	if _done_at > 0.0 and _t > _done_at + 0.5:
		print("[render riser complete] %s" % _out)
		quit(0)
	if _t > GIVE_UP_AT:
		print("[render riser timed out] shots=%d" % _shots)
		quit(1)
	return false


## The numbers behind the picture. A frame showing pebbles in a pipe is only worth something if
## those pebbles are the ones the sim thinks are climbing — so print where every transiting
## body is, which leg it is on, and how fast it is going, and let the two be compared.
func _dump_leg() -> void:
	var climbing := 0
	var ducting := 0
	for id in _main._transit:
		var at: Vector2 = _main._physics.get_position(id)
		var leg: int = _main._transit[id]
		var tag := "recirc" if leg == FuelLoop.RECIRC else "discharge"
		if leg == FuelLoop.RECIRC and at.y < FuelLoop.HUB_Y - FuelLoop.BORE_W:
			climbing += 1
		elif FuelLoop.in_duct(at):
			ducting += 1
		print("    #%-4d %-9s (%6.1f, %6.1f)  v=%4.0f px/s"
			% [id, tag, at.x, at.y, _main._physics.get_velocity(id).length()])
	print("  t=%.0f  climbing the riser %d   in the duct %d   riding the chute %d   bed %d/%d"
		% [_t, climbing, ducting, _main._loop.count(), _main._core_count(),
			_main.TARGET_POPULATION])


func _capture(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("  (no image — renderer gave nothing; are you running with --headless?)")
		return
	img.save_png(_out + name)
	print("  saved %s (%dx%d)" % [name, img.get_width(), img.get_height()])
