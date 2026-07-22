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
# `_feed_inlet_top` runs every physics frame but only admits into a lane that is currently
# clear — real plant traffic this test does not control. A few real frames is more than
# enough once the backlog is cleared out of THIS pebble's way (see section 3 below).
const MINT_WAIT_GIVEUP := 5.0

var _main
var _t := 0.0
var _failures := 0
var _phase := 0            # 0 = settle and run checks 1/2/3a, 1 = wait for the body, 2 = done
var _minted := -1
var _minted_big := 0.0
var _default_r := 0.0
var _saved_mint_pending: Array = []
var _mint_wait_start := 0.0


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

	if _phase == 1:
		return _wait_for_minted_body()

	if _t < SETTLE_AT:
		return false

	# --- 1. The default template reproduces today's core exactly ---
	_default_r = _main.RADIUS_DEFAULT
	_ok(is_equal_approx(_default_r, _main.PEBBLE_RADIUS),
		"the default design radius IS the nominal (%.2f)" % _default_r)
	_ok(is_equal_approx(_main._pebble_radius, _default_r),
		"the sim opens at the default design radius")

	var off := 0
	for id in _main._pebbles:
		var peb: Pebble = _main._pebbles[id]
		if not is_equal_approx(peb.radius, _default_r):
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
	#
	# Phase 3c retired `_queue`/`_spawn_from_queue` — a minted pebble now stages bodiless
	# in `_mint_pending` and gets a body from `_feed_inlet_top`, called every physics frame
	# but gated on a LANE being clear (real plant traffic this test does not control). So
	# rather than force it synchronously and risk reading "no body" from a lane that was
	# merely busy, not broken, this clears the backlog out of THIS pebble's way and lets
	# the real loop admit it over a few real frames — see `_wait_for_minted_body`.
	var big: float = _main.RADIUS_MAX
	_main._pebble_radius = big
	var before_ids := {}
	for id in _main._pebbles:
		before_ids[id] = true
	_main._mint_pebble()
	_minted = -1
	for id in _main._pebbles:
		if not before_ids.has(id):
			_minted = id
			break
	_ok(_minted != -1, "a pebble was minted at the edited design")
	_main._pebble_radius = _default_r   # restore immediately, before anything else can mint

	if _minted == -1:
		_phase = 2
		return _finish_checks()

	var mp: Pebble = _main._pebbles[_minted]
	_minted_big = big
	_ok(is_equal_approx(mp.radius, big),
		"the minted pebble carries the EDITED radius (%.2f), not the nominal" % mp.radius)

	# THE CHECK WITH TEETH. Everything above runs on a core where every pebble is already
	# 8.0, so sim-radius and body-radius are trivially equal and the whole "two worlds
	# agree" sweep passes whether or not the desync exists — verified: it went green with
	# the bug deliberately restored. Only a NON-default pebble can tell the two apart. So
	# push this oversized pebble through the real admission path and read the body it
	# produces: if `_feed_inlet_top` ever passed a constant instead of `peb.radius`, the
	# body comes back 8.0 while its pebble says (say) 11.0, and the bed packs one way
	# while the flux solve sees another.
	_saved_mint_pending = _main._mint_pending.duplicate()
	_main._mint_pending.clear()
	_main._mint_pending.push_back(_minted)
	_mint_wait_start = _t
	_phase = 1
	return false


## Poll for the real game loop (`_feed_inlet_top`, called every physics frame) to admit the
## edited pebble into a clear lane. Not a synchronous force — a lane being briefly busy with
## real traffic is not a failure, so this gives it real frames rather than reading "no body"
## off a single blocked instant.
func _wait_for_minted_body() -> bool:
	var nb = _main._physics._bodies.get(_minted)
	if nb == null and _t - _mint_wait_start < MINT_WAIT_GIVEUP:
		return false
	_main._mint_pending.append_array(_saved_mint_pending)
	_ok(nb != null, "the edited pebble reached the inlet pipe as a body (%.1fs)"
		% (_t - _mint_wait_start))
	if nb != null:
		_ok(is_equal_approx(nb.radius, _minted_big),
			"the body was built at the pebble's OWN radius (%.2f, want %.2f) — the edit survives injection"
				% [nb.radius, _minted_big])
		_ok(is_equal_approx(nb._shape.radius, _minted_big),
			"...and it COLLIDES at that radius (%.2f) — physics and neutronics agree"
				% nb._shape.radius)
	_phase = 2
	return _finish_checks()


func _finish_checks() -> bool:
	# --- 4. The bounds are real and derived, not decorative ---
	#
	# RADIUS_MAX is tied to the transport bore rather than picked, so a pebble can never
	# be designed wider than the pipe it must ride inside. Asserting the RELATIONSHIP,
	# not the number: retuning the pipe should move the lever, and this check should
	# follow rather than need editing.
	_ok(_main.RADIUS_MAX * 2.0 <= FuelLoop.BORE_W + 0.001,
		"a max-size pebble fits the transport bore (2*%.2f <= %.1f)"
			% [_main.RADIUS_MAX, FuelLoop.BORE_W])
	_ok(_main.RADIUS_MIN < _default_r and _default_r < _main.RADIUS_MAX,
		"the default sits INSIDE the lever's range (%.1f < %.1f < %.1f)"
			% [_main.RADIUS_MIN, _default_r, _main.RADIUS_MAX])

	# A max-size pebble must still fit the VESSEL it is spawned into — the other hard
	# limit. Silo.spawn_x takes a margin, so a pebble born at the wall would be pushed
	# out by the solver. Checks the widest design against the narrowest part it enters.
	var span: float = Silo.RIGHT - Silo.LEFT
	_ok(_main.RADIUS_MAX * 2.0 < span,
		"a max-size pebble fits the vessel bore (2*%.2f < %.0f)" % [_main.RADIUS_MAX, span])

	print("ALL CHECKS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
	return true
	return true
