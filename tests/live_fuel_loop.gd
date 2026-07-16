# tests/live_fuel_loop.gd
#
# MANUAL / real-time integration check for the VISIBLE fuel cycle (FuelLoop).
#   godot --headless --script res://tests/live_fuel_loop.gd
#
# WHY this harness has to exist: the fuel-handling machine lives entirely in
# main.gd + game/, so the fast pure suites (which drive sim/ directly) cannot see
# it AT ALL — they would stay green even if this mechanic silently drained the bed.
# That matters because the one thing this feature must not do is perturb the
# physics: TARGET_POPULATION is a CALIBRATED quantity that the whole M4/M5
# operating point was tuned against.
#
# Guards the invariants that make a real (non-teleport) recirculation ride free:
#  1. The BED stays pinned at TARGET_POPULATION once filled — the staging queue
#     never starves. If LOOP_BUFFER were too small for the ride time, the bed would
#     silently run short (fewer pebbles → less fuel → k shifts, headline power reads
#     low) and NOTHING else in the test suite would notice.
#  2. Pebbles genuinely RIDE (the machine is populated in steady state) — i.e. the
#     teleport is actually gone, not just re-dressed.
#  3. Total inventory is conserved at TARGET_POPULATION + LOOP_BUFFER: riders are
#     neither leaked (stuck forever on the conveyor) nor duplicated.
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
	_max_riders = maxi(_max_riders, _main._loop.count())

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
	if _t > 32.0 and _frozen_id == -1 and _main._loop.count() > 0:
		var staged := {}
		for slot in _main._queue:
			staged[slot["id"]] = true
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
		print("  t=35 s: core=%d/%d  riding=%d  queued=%d  inventory=%d" % [
			_main._core_count(), _main.TARGET_POPULATION, _main._loop.count(),
			_main._queue.size(), _main._pebbles.size()])
		_check(_main._core_count() == _main.TARGET_POPULATION,
			"bed is FULL at its calibrated population (%d)" % _main._core_count())
		_check(_main._pebbles.size() == _main.TARGET_POPULATION + _main.LOOP_BUFFER,
			"inventory = target + buffer (%d)" % _main._pebbles.size())

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

	# t=70 s: a full cycle has run. The bed must NEVER have dipped below target.
	if _t >= 70.0 and not _checked_cycle:
		_checked_cycle = true
		print("  recirculated=%d  discharged=%d  made=%d  min core seen=%d" % [
			_main._total_recirculated, _main._total_extracted, _main._total_injected,
			_min_core_after_fill])
		_check(_main._total_recirculated > 0, "pebbles recirculate for another pass")
		_check(_min_core_after_fill == _main.TARGET_POPULATION,
			"bed NEVER ran short while pebbles rode (min core %d)" % _min_core_after_fill)
		_check(_main._pebbles.size() == _main.TARGET_POPULATION + _main.LOOP_BUFFER,
			"inventory conserved — no rider leaked or duplicated (%d)" % _main._pebbles.size())
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
