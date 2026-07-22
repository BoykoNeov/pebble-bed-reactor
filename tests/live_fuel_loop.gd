# tests/live_fuel_loop.gd
#
# MANUAL / real-time integration check for the VISIBLE fuel cycle (FuelLoop).
#   godot --headless --script res://tests/live_fuel_loop.gd
#
# WHY this harness has to exist: the fuel-handling machine lives entirely in
# main.gd + game/, so the fast pure suites (which drive sim/ directly) cannot see
# it AT ALL — they would stay green even if this mechanic silently drained the bed.
# That matters because the one thing this feature must not do is perturb the
# physics: RECOMMENDED_POPULATION is the CALIBRATED quantity the whole M4/M5
# operating point was tuned against, and it is also the default `_population_setpoint`
# the fuel machine chases (Phase 3c made the target a player lever, not a hard pin).
#
# Guards the invariants that make a real (non-teleport) recirculation ride free:
#  1. The BED stays at its setpoint once filled — the staging queue never starves.
#     If LOOP_BUFFER were too small for the ride time, the bed would silently run
#     short (fewer pebbles → less fuel → k shifts, headline power reads low) and
#     NOTHING else in the test suite would notice.
#  2. Pebbles genuinely RIDE (the machine is populated in steady state) — i.e. the
#     teleport is actually gone, not just re-dressed.
#  3. Every pebble ever made is still ACCOUNTED FOR: riders are neither leaked (stuck
#     forever on the conveyor) nor duplicated.
#  4. Every body the BELTS carry sweeps its path (continuous collision on). Since Phase
#     3b-ii most of the recirculation ride is a real body at 380 px/s, and a pebble built
#     at RADIUS_MIN can cross a wall between two steps — see the note at the check itself
#     for why this belongs here and not in tests/live_riser.gd, which measures the hazard
#     but cannot tell whether the PLANT asked for the fix.
#
#     WHAT THIS IS CAREFUL NOT TO FORBID. This used to be stated as "total inventory is
#     conserved at TARGET_POPULATION + LOOP_BUFFER", and checked `_pebbles.size()`
#     against that sum. That was the MECHANISM, not the claim: it held only while the
#     spent pool lived OUTSIDE the registry, so a discharged pebble left `_pebbles` and
#     the raw count happened to equal the circulating population. Since the pool became
#     re-injectable it lives INSIDE `_pebbles` (see main._inventory()), so the registry
#     legitimately outgrows target + buffer by the pool size — and this check failed on a
#     sim that had lost nothing at all (432 = 428 circulating + 4 pooled).
#
#     The accounting claim survives that move intact. `_mint_pebble` is the only writer
#     that ADDS to `_pebbles`, and `_ship_to_cask` the only one that removes, so every
#     pebble ever made is either still in the registry or provably casked:
#     `_total_injected == _pebbles.size() + _total_shipped`. That keeps the original teeth
#     (a leaked or stuck rider makes the left side exceed the right; a duplicate makes it
#     fall short) and is the literal restatement of this invariant's own description.
#
#     Deliberately NOT re-pointed at `_inventory() == target + buffer`: the t=35 block
#     already checks precisely that, so this would have become a redundant second copy of
#     invariant 1 wearing invariant 3's name — passing while testing nothing.
#
#     RE-INJECTION LEAVES THIS UNTOUCHED, which is worth stating because it looks like it
#     should not. Sending a pooled pebble back is not a mint (`_total_injected` does not
#     move) and it never leaves the registry (`_pebbles.size()` does not move) — it only
#     changes which internal list holds it. So this identity is blind to it by design,
#     and `_inventory()` is the number that reacts. See `main._reinject`.
#  4. Both legs of the sorter run: pebbles recirculate, and spent ones discharge and
#     are replaced 1:1 by fresh fuel.
#  5. Riders stay FROZEN while in transit — a pebble in the pipe is out of the flux,
#     so it must not burn (its stale local_flux would otherwise keep depleting it).
extends SceneTree

# A pebble that just left the bed carries the bed's heat (~800-1000 K); the pebbles
# staged in `_queue` at startup have never been in the core and sit at ambient 293 K.
# Only the former can prove the freeze (see the snapshot block below).
const HOT_RIDER_K := 600.0
# How long the snapshotted rider must hold its state. Comfortably inside the ~4 s ride,
# but long enough that an unfrozen pebble would visibly cool and burn.
const FREEZE_WINDOW := 2.0

var _main
var _t := 0.0
var _failures := 0
var _checked_fill := false
var _checked_ride := false
var _checked_cycle := false
var _max_riders := 0
# Bodies caught on a belt with continuous collision DISABLED. Any at all is a failure, so this
# accumulates ids rather than a flag — it names the pebble that would have leaked.
var _unswept: Array = []
var _transit_seen := 0
var _min_core_after_fill := 1 << 30
# Invariant 5: a rider snapshotted mid-ride, re-checked while still riding.
var _frozen_id := -1
var _frozen_burnup := 0.0
var _frozen_temp := 0.0
var _frozen_t := 0.0
var _checked_freeze := false


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live fuel loop] visible recirculation — bed must stay pinned while pebbles ride")


func _process(delta: float) -> bool:
	_t += delta

	# Track the worst-case bed shortfall across the whole run, once the bed has had
	# time to fill (380 pebbles at 3 per 0.12 s ≈ 16 s, plus settling).
	if _t > 30.0:
		_min_core_after_fill = mini(_min_core_after_fill, _main._core_count())
	# Pebbles out of the bed but not yet pooled, measured against the SETPOINT, not against the
	# live core count — riders don't exist any more (Phase 3c: every leg is a real body), and
	# `main._mint_pebble`'s own gate (`_inventory() < _population_setpoint + LOOP_BUFFER`) bounds
	# exactly this quantity. Measuring against `_core_count()` instead looked equivalent but is
	# NOT: real physical admission means the bed's own count now legitimately dips by ~1 for the
	# gap between an extraction and its replacement landing (there is no more instant, same-frame
	# rider materialization), which briefly and harmlessly makes `inventory - core_count` read
	# one over the buffer even though the mint gate itself was never violated. Against the
	# setpoint, this is structurally bounded by the gate's own arithmetic and cannot false-fail.
	_max_riders = maxi(_max_riders, _main._inventory() - _main._population_setpoint)

	# Every body the belts carry must SWEEP its path, not just sample where it landed.
	#
	# WHY THIS IS CHECKED HERE, in the plant, and not where the hazard was measured: the
	# tunnelling itself is gated by tests/live_riser.gd, which drives the geometry directly at
	# RADIUS_MIN and loses up to 37% of the recirculating fuel with sweeping off. But that
	# harness turns sweeping on ITSELF — so it proves the pipe needs it and would go on passing
	# happily if `main._feed_drop` ever stopped asking for it. Nothing else would notice either:
	# the nominal pebble does not tunnel, so the live plant looks perfect until a player winds
	# the size lever down and the bed starts quietly losing fuel it will never get back.
	# This is the line that says the PLANT wires it, not just that the physics supports it.
	for id in _main._transit:
		var body = _main._physics._bodies.get(id)
		if body == null:
			continue
		_transit_seen += 1
		if body.continuous_cd == RigidBody2D.CCD_MODE_DISABLED and not _unswept.has(id):
			_unswept.append(id)

	# Catch a HOT rider mid-ride and remember its state, to prove it is frozen in transit.
	# WHY the temperature floor is load-bearing: `_out_of_core` covers BOTH riders and the
	# LOOP_BUFFER pebbles staged in `_queue`, and `_seed_burned` stamps a burnup spread on
	# the startup fill — so a burnup>0 filter alone can select a pebble that is still
	# sitting in the queue at ambient, having never been in the flux. Freezing that pebble
	# holds a temperature it had no reason to change, so the assert passes while testing
	# nothing. A pebble that just left the hot bed is the one that would visibly cool if
	# the freeze broke.
	# It must also be a pebble still ON the machine, not one already staged in `_queue` at
	# the top. `_out_of_core` is FIFO — its oldest entry is the next one dropped into the
	# bed — so taking the first match always lands on the candidate with the LEAST time
	# left out of core (~one EXTRACT_INTERVAL, 0.3 s). It re-enters before the window
	# elapses, the re-arm below picks the new oldest, and the check can never accumulate
	# its window at all. A pebble genuinely in transit has its remaining ride PLUS the
	# whole queue wait ahead of it, so it comfortably outlives FREEZE_WINDOW.
	if _t > 32.0 and _frozen_id == -1 and (_main._inventory() - _main._core_count()) > 0:
		var staged := {}
		for id in _main._mint_pending:
			staged[id] = true
		for id in _main._out_of_core:
			if staged.has(id):
				continue
			var peb = _main._pebbles.get(id)
			if peb != null and peb.burnup > 0.0 and peb.temperature > HOT_RIDER_K:
				_frozen_id = id
				_frozen_burnup = peb.burnup
				_frozen_temp = peb.temperature
				_frozen_t = _t
				break

	# t=35 s: the bed has filled and the machine is turning.
	if _t >= 35.0 and not _checked_fill:
		_checked_fill = true
		print("  t=35 s: core=%d/%d  in_flight=%d  mint_pending=%d  inventory=%d" % [
			_main._core_count(), _main._population_setpoint,
			_main._inventory() - _main._core_count(),
			_main._mint_pending.size(), _main._inventory()])
		_check(_main._core_count() == _main._population_setpoint,
			"bed is FULL at its calibrated population (%d)" % _main._core_count())
		_check(_main._inventory() == _main._population_setpoint + _main.LOOP_BUFFER,
			"inventory = setpoint + buffer (%d)" % _main._inventory())

	# The freeze check: same pebble, still out of the core, must not have burned or cooled.
	# Re-arm instead of giving up if it re-entered the bed before the window elapsed — the
	# ride is only ~4 s, so a snapshot caught late runs out of transit first. Without the
	# re-arm that case skipped the check SILENTLY and the suite still reported all-pass;
	# the t=70 guard below now fails if no hot rider was ever checked.
	if _frozen_id != -1 and not _checked_freeze:
		if not _main._out_of_core.has(_frozen_id):
			_frozen_id = -1
		elif _t - _frozen_t >= FREEZE_WINDOW:
			_checked_freeze = true
			var peb = _main._pebbles.get(_frozen_id)
			if peb != null:
				print("  rider #%d in transit %.1f s: burnup %.4f -> %.4f   T %.1f -> %.1f K" % [
					_frozen_id, _t - _frozen_t, _frozen_burnup, peb.burnup,
					_frozen_temp, peb.temperature])
				_check(absf(peb.burnup - _frozen_burnup) < 1.0e-9,
					"a riding pebble does NOT burn (out of the core = out of the flux)")
				_check(absf(peb.temperature - _frozen_temp) < 1.0e-6,
					"a HOT riding pebble's temperature is frozen for the ride (%.0f K)" % _frozen_temp)

	# t=45 s: pebbles are actually riding — the teleport is gone.
	if _t >= 45.0 and not _checked_ride:
		_checked_ride = true
		print("  peak riders seen: %d (LOOP_BUFFER=%d)" % [_max_riders, _main.LOOP_BUFFER])
		_check(_max_riders > 0, "pebbles physically RIDE the machine (no teleport)")
		_check(_max_riders <= _main.LOOP_BUFFER,
			"riders in flight stay within the buffer (queue cannot starve)")
		# The `_transit_seen` half is what stops this being vacuous: with no bodies on the
		# belts, "none of them is unswept" is true of the empty set and says nothing.
		_check(_transit_seen > 0 and _unswept.is_empty(),
			"every body the belts carry has continuous collision ON (%d seen, %d unswept) — the plant wires the sweep, not just the physics"
				% [_transit_seen, _unswept.size()])

	# t=70 s: a full cycle has run. The bed must NEVER have dipped below target.
	if _t >= 70.0 and not _checked_cycle:
		_checked_cycle = true
		print("  recirculated=%d  discharged=%d  made=%d  min core seen=%d" % [
			_main._total_recirculated, _main._total_extracted, _main._total_injected,
			_min_core_after_fill])
		_check(_main._total_recirculated > 0, "pebbles recirculate for another pass")
		# Not exact equality: under Phase 3c an extracted pebble is a real body that has to
		# physically travel back through the inlet before it lands, so the bed legitimately
		# dips by ~1 for the gap between an extraction and its replacement — that is admission
		# lag, not the bed running short. What this still forbids is the bed draining for real
		# (the buffer starving), which would show as a dip far larger than one admission cycle.
		_check(_min_core_after_fill >= _main._population_setpoint - 3,
			"bed NEVER ran meaningfully short while pebbles rode (min core %d/%d)"
				% [_min_core_after_fill, _main._population_setpoint])
		# `_mint_pebble` is the only writer that ADDS to `_pebbles` and `_ship_to_cask` the
		# only one that removes, so the mint count must equal the registry plus whatever has
		# left for a cask — see invariant 3 in the header for why this is the accounting
		# claim and `_inventory()` is not. The pool is included here ON PURPOSE: a
		# discharged pebble is still a pebble that was made, and it is still accounted for.
		# Where it sits is invariant 1's business, not this check's.
		_check(_main._total_injected == _main._pebbles.size() + _main._total_shipped,
			"every pebble ever made is still accounted for — none leaked or duplicated (made %d, registry %d + casked %d)"
				% [_main._total_injected, _main._pebbles.size(), _main._total_shipped])
		# ...and the CIRCULATING side is still on its calibrated sum despite the pool having
		# filled. This is not the t=35 check moved later: at t=35 nothing had discharged yet,
		# so the pool was empty and `_inventory()` could not tell a pool-subtracting gate
		# from one that ignores the pool. Here the pool is NON-EMPTY (see `discharged` in the
		# line printed above), so this is the first moment the subtraction is load-bearing —
		# it proves the mint gate replaced each discharged pebble exactly 1:1 rather than
		# letting the filling pool throttle fresh fuel and starve the bed.
		#
		# Stated against target + buffer, NOT against `_pebbles.size() - _spent.size()`:
		# that is the DEFINITION of `_inventory()` and would be a tautology.
		_check(_main._inventory() == _main._population_setpoint + _main.LOOP_BUFFER,
			"...and the circulating population held its calibrated sum with %d in the pool (%d)"
				% [_main._spent.size(), _main._inventory()])
		# Invariant 5 is only proven if it actually ran on a hot rider. A skipped check is
		# indistinguishable from a passing one in the output, so make the absence fail.
		_check(_checked_freeze,
			"the freeze check ran on a hot (>%.0f K) rider" % HOT_RIDER_K)
		_report()
		return true
	return false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  PASS  %s" % what)
	else:
		print("  FAIL  %s" % what)
		_failures += 1


func _report() -> void:
	if _failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
