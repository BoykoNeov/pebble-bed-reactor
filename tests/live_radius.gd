# tests/live_radius.gd
#
# Gate for the design SIZE lever's plumbing.
#   godot --headless --script res://tests/live_radius.gd
#
# Two things to prove, and the first is by far the more important:
#
# 1. CALIBRATION NEUTRALITY. The size lever threads peb.radius through five sites that
#    previously read a hardcoded constant. At the DEFAULT design that substitution must
#    be a no-op — every pebble r=8.0, every body r=8.0, k unchanged. The whole M4/M5
#    operating point was tuned against this core; if the default template drifts, every
#    calibration downstream silently drifts with it and the pure suites (which drive
#    sim/ directly and never build a scene) would stay green while the GAME moved.
#
# 2. THE TWO-WORLDS DESYNC. peb.radius is what grid.gd homogenizes (PI*r^2 → packing);
#    the radius handed to spawn_pebble is what collides and what is drawn. They are set
#    in different places and nothing structurally ties them together, so they can
#    disagree — a pebble neutronically large and physically small, with NOTHING on
#    screen to show it. That is the failure this file exists for: it is invisible, it
#    corrupts the flux solve, and no pure suite can see it because it lives in main.gd.
extends SceneTree

const SETTLE_AT := 30.0

var _main
var _t := 0.0
var _failures := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live radius] default design must be a no-op; the two worlds must agree on size")


func _ok(pass_: bool, msg: String) -> void:
	print("  %s  %s" % ["PASS" if pass_ else "FAIL", msg])
	if not pass_:
		_failures += 1


func _process(delta: float) -> bool:
	_t += delta
	if _t < SETTLE_AT:
		return false

	# --- 1. The default template reproduces today's core exactly ---
	var default_r: float = _main.RADIUS_DEFAULT
	_ok(is_equal_approx(default_r, _main.PEBBLE_RADIUS),
		"the default design radius IS the nominal (%.2f)" % default_r)
	_ok(is_equal_approx(_main._pebble_radius, default_r),
		"the sim opens at the default design radius")

	var off := 0
	for id in _main._pebbles:
		var peb: Pebble = _main._pebbles[id]
		if not is_equal_approx(peb.radius, default_r):
			off += 1
	_ok(off == 0, "every pebble in a default core is nominal-sized (%d off)" % off)

	# --- 2. The two worlds agree: sim radius == collision/draw radius ---
	#
	# Reads the BODY, not the spawn call, because the body is the physical truth: it is
	# what collides, what packs the bed, and what the player sees. Comparing the two
	# independently-set numbers is the only way to catch the desync — asserting either
	# one alone against 8.0 would pass happily while they disagreed with each other.
	var checked := 0
	var desynced := 0
	for id in _main._physics._bodies:
		var peb: Pebble = _main._pebbles.get(id)
		if peb == null:
			continue
		var body = _main._physics._bodies[id]
		checked += 1
		if not is_equal_approx(body.radius, peb.radius):
			desynced += 1
	_ok(checked > 100, "there were bodies to check (%d)" % checked)
	_ok(desynced == 0,
		"every body's radius equals its pebble's radius — the two worlds agree (%d desynced)"
			% desynced)

	# The collision SHAPE too, not just the body's bookkeeping field: configure() sets
	# both, and a change that updated one without the other would desync the physics
	# from the drawing while this test still read "radius" and passed.
	var shape_off := 0
	for id in _main._physics._bodies:
		var body = _main._physics._bodies[id]
		if not is_equal_approx(body._shape.radius, body.radius):
			shape_off += 1
	_ok(shape_off == 0, "every collision shape matches its body's radius (%d off)" % shape_off)

	# --- 3. An edited pebble's size actually REACHES the bed ---
	#
	# The point of the lever. Mint at a non-default radius and follow it all the way to a
	# body: this is the path that was broken before — Pebble.new took the design size but
	# spawn_pebble passed the CONSTANT, so an edited pebble arrived in the bed at 8.0 and
	# the edit vanished with nothing to show for it.
	var big: float = _main.RADIUS_MAX
	_main._pebble_radius = big
	var before_ids := {}
	for id in _main._pebbles:
		before_ids[id] = true
	_main._mint_pebble()
	var minted := -1
	for id in _main._pebbles:
		if not before_ids.has(id):
			minted = id
			break
	_ok(minted != -1, "a pebble was minted at the edited design")
	if minted != -1:
		var mp: Pebble = _main._pebbles[minted]
		_ok(is_equal_approx(mp.radius, big),
			"the minted pebble carries the EDITED radius (%.2f), not the nominal" % mp.radius)

		# THE CHECK WITH TEETH. Everything above runs on a core where every pebble is
		# already 8.0, so sim-radius and body-radius are trivially equal and the whole
		# "two worlds agree" sweep passes whether or not the desync exists — verified: it
		# went green with the bug deliberately restored. Only a NON-default pebble can
		# tell the two apart. So push this oversized pebble through the real spawn path
		# and read the body it produced: if _spawn_from_queue passes the constant, the
		# body comes back 8.0 while its pebble says 11.0, and the bed packs one way while
		# the flux solve sees another.
		var saved: Array = _main._queue.duplicate()
		_main._queue.clear()
		_main._queue.push_back({"id": minted, "x": Silo.spawn_x(_main._rng, big + 2.0)})
		_main._spawn_from_queue()
		var nb = _main._physics._bodies.get(minted)
		_ok(nb != null, "the edited pebble reached the bed as a body")
		if nb != null:
			_ok(is_equal_approx(nb.radius, big),
				"the body was built at the pebble's OWN radius (%.2f, want %.2f) — the edit survives injection"
					% [nb.radius, big])
			_ok(is_equal_approx(nb._shape.radius, big),
				"...and it COLLIDES at that radius (%.2f) — physics and neutronics agree"
					% nb._shape.radius)
		_main._queue = saved
	_main._pebble_radius = default_r   # restore, so the checks below read a clean core

	# --- 4. The bounds are real and derived, not decorative ---
	#
	# RADIUS_MAX is tied to the transport bore rather than picked, so a pebble can never
	# be designed wider than the pipe it must ride inside. Asserting the RELATIONSHIP,
	# not the number: retuning the pipe should move the lever, and this check should
	# follow rather than need editing.
	_ok(_main.RADIUS_MAX * 2.0 <= FuelLoop.BORE_W + 0.001,
		"a max-size pebble fits the transport bore (2*%.2f <= %.1f)"
			% [_main.RADIUS_MAX, FuelLoop.BORE_W])
	_ok(_main.RADIUS_MIN < default_r and default_r < _main.RADIUS_MAX,
		"the default sits INSIDE the lever's range (%.1f < %.1f < %.1f)"
			% [_main.RADIUS_MIN, default_r, _main.RADIUS_MAX])

	# A max-size pebble must still fit the VESSEL it is spawned into — the other hard
	# limit. Silo.spawn_x takes a margin, so a pebble born at the wall would be pushed
	# out by the solver. Checks the widest design against the narrowest part it enters.
	var span: float = Silo.RIGHT - Silo.LEFT
	_ok(_main.RADIUS_MAX * 2.0 < span,
		"a max-size pebble fits the vessel bore (2*%.2f < %.0f)" % [_main.RADIUS_MAX, span])

	print("ALL CHECKS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
	return true
