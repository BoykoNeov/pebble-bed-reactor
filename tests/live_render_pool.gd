# tests/live_render_pool.gd
#
# Captures rendered frames of the SPENT-FUEL POOL.
#
#   godot --script res://tests/live_render_pool.gd        # NOTE: no --headless
#
# WHY: the pool is pure `_draw`, and --headless uses a DUMMY renderer that executes
# _draw and produces no pixels. tests/live_spent_pool.gd proves the pool's BEHAVIOUR
# (it accumulates, it stays out of the flux, it keeps the newest arrivals) — but
# "does it read as a pool of pebbles, and does it collide with the pipework or the
# rod channel" is not a property any number settles. This is the go-look-at-it tool.
#
# Two shots, because the interesting states are far apart in time: discharge runs at
# roughly one pebble per 16 s, so a real session shows a nearly-empty tray for the
# first several minutes and a full one only after ~6. The second shot force-fills the
# pool to judge the layout at capacity without waiting — clearly labelled, because
# that frame shows SYNTHESIZED contents, not a real campaign's outflow.
extends SceneTree

const START_AT := 90.0     # discharges are flowing by ~70 s (see live_fuel_loop.gd)
const GIVE_UP_AT := 260.0
const DROP_EVERY := 1.1    # a pebble must land and settle before the next one lands on it
const SETTLE := 3.0

var _main
var _t := 0.0
var _out := ""
var _shot_real := false
var _shot_full := false
var _filling := false
var _dropped := 0
var _next_drop := 0.0
var _done_at := -1.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	DirAccess.make_dir_recursive_absolute("user://shots")
	_out = OS.get_user_data_dir() + "/shots/"
	print("[pool capture] writing to %s" % _out)


func _process(delta: float) -> bool:
	_t += delta
	if _t < START_AT:
		return false

	# Colour the pebbles by burnup — the field that makes a spent pool worth looking at.
	# Driven through _cycle_field, not by poking _current_field (the documented trap).
	if not _shot_real:
		_shot_real = true
		while _main._fields[_main._current_field]["desc"].world != FieldDescriptor.PEBBLE:
			_main._cycle_field()
		return false   # capture a LATER frame — the other documented trap

	if _shot_real and not _shot_full:
		_shot_full = true
		_capture("pool_real.png")
		print("  real outflow: %d settled, field=%s"
			% [_main._spent.size(), _main._fields[_main._current_field]["desc"].name])
		# Now fill it to capacity to judge the pile when full, ONE PEBBLE PER TICK.
		#
		# Not a loop any more: a pooled pebble is a real body, and pushing the whole tray
		# in a single frame spawns every one of them inside the others at the pipe mouth,
		# where the solver blows the pile apart. The shot would show a scatter the game
		# cannot produce — which is the exact failure mode this script exists to avoid.
		# Fed one at a time they fall down the pipe and settle, as they do in a real run.
		_filling = true
		return false

	if _filling:
		if _t < _next_drop:
			return false
		_next_drop = _t + DROP_EVERY
		if _dropped < FuelLoop.pool_capacity():
			# Spread EVERY per-pebble field, not just burnup: the shot is judged under
			# whichever field is selected, and a dummy that only sets burnup renders as a
			# black socket under Pebble temperature — which looks like a bug in the pool
			# rather than a bug in this script. (It did, the first time.)
			var f := float(_dropped) / float(FuelLoop.pool_capacity())
			var dummy := Pebble.new(900000 + _dropped, _main.PEBBLE_RADIUS)
			dummy.burnup = Depletion.DISCHARGE_BURNUP * f
			dummy.temperature = 400.0 + 1000.0 * f
			dummy.xe135 = 6.0e-5 * f
			# (decay_e is the reservoir ARRAY, not a scalar — left at its default.)
			# Registered like a real pebble: `_pool_push` gives it a body and declares it
			# out of core, and an unregistered id in `_out_of_core` walks `_core_count()`
			# down by one per dummy. It also has to be in `_pebbles` for the per-pebble
			# field walk to tint it — an unregistered dummy renders graphite grey and the
			# shot judges the pool's colors on pebbles the field never colored.
			_main._pebbles[dummy.id] = dummy
			# Through the real push site, not straight onto `_spent`: it enforces the cap,
			# so this lands on EXACTLY a full tray (the real arrivals cask out ahead of the
			# dummies) instead of overfilling it and piling pebbles over the rim — which
			# would make the shot judge a layout the game cannot produce.
			_main._pool_push(dummy)
			_dropped += 1
			return false
		# Let the last few stop rolling before the shutter opens.
		if _t < _next_drop + SETTLE:
			return false
		_filling = false
		_main._refresh_pool()
		return false

	if _done_at < 0.0:
		_done_at = _t
		_capture("pool_full.png")
		print("  SYNTHETIC full pool: %d settled (cap %d)"
			% [_main._spent.size(), FuelLoop.pool_capacity()])
		print("  pool tray x = %.0f..%.0f, y = %.0f..%.0f"
			% [FuelLoop.POOL_LEFT, FuelLoop.POOL_LEFT + FuelLoop.POOL_W,
				FuelLoop.POOL_FLOOR - FuelLoop.POOL_H, FuelLoop.POOL_FLOOR])
		return false

	if _t > _done_at + 0.5:
		print("[pool capture complete] %s" % _out)
		quit(0)
	if _t > GIVE_UP_AT:
		print("[pool capture timed out]")
		quit(1)
	return false


func _capture(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("  (no image — are you running with --headless?)")
		return
	img.save_png(_out + name)
	print("  saved %s (%dx%d)" % [name, img.get_width(), img.get_height()])
