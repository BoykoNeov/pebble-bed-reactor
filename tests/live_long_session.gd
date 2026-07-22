# tests/live_long_session.gd
#
# LONG-SESSION live stability guard for the real scene.
#   godot --headless --script res://tests/live_long_session.gd
#
# WHY: every other live harness is short — live_m4 runs ~105 s, live_fuel_loop ~70 s, and
# the project notes' live health check was a single 60 s probe. But the live core is the
# same seeded, online-refueled core that the pure harness shows still BREATHING at 800 s+
# (its position-based refueling is batchy — an M3-level effect the M4a notes call "residual
# breathing"), so "fine at 60 s" is not evidence for "fine at 10 minutes". A player leaves
# this running far longer than any test does. This runs the real scene for 10 minutes and
# asserts the things that would rot slowly and silently:
#
#   * the bed stays near its calibrated setpoint (a slow leak in the fuel loop's staging
#     would drain it — the calibrated population is what the operating point is tuned
#     against),
#   * power and temperature stay BOUNDED and RUNNING (no runaway, no creeping collapse),
#   * the core does not drift monotonically — the second half's mean must not have walked
#     away from the first half's, which is what a slow depletion/refuel imbalance looks
#     like and what a short probe cannot see.
#
# It is a GUARD, not a calibration: the gates are deliberately loose (they bound runaway
# and collapse, not the breathing amplitude) because the breathing itself is known,
# documented, and accepted for the toy. Tightening them into a swing gate would be
# re-litigating a calibration the project has already settled.
extends SceneTree

const RUN_FOR := 600.0        # 10 minutes of real scene time
const SAMPLE_EVERY := 5.0     # sampling cadence (s)
const SETTLE_UNTIL := 60.0    # ignore the fill + seed + burn-in; that is live_m4's job

var _main
var _t := 0.0
var _next_sample := SETTLE_UNTIL
var _failures := 0
var _a := PackedFloat32Array()
var _peak := PackedFloat32Array()
var _kcold := PackedFloat32Array()
var _core := PackedInt32Array()
var _max_peak := 0.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live long session] real scene, %.0f s — does the core hold up over a player-length run?" % RUN_FOR)


func _process(delta: float) -> bool:
	_t += delta
	if _t > SETTLE_UNTIL:
		_max_peak = maxf(_max_peak, _main._peak_temp)
	if _t >= _next_sample and _t > SETTLE_UNTIL:
		_next_sample += SAMPLE_EVERY
		_a.append(_main._amplitude)
		_peak.append(_main._peak_temp)
		_kcold.append(_main._k_cold)
		_core.append(_main._core_count())
		if _a.size() % 12 == 0:   # a line each minute
			print("  t=%3.0f s  A=%6.2f  peakT=%4.0f K  k_cold=%.4f  core=%d  in_flight=%d"
				% [_t, _main._amplitude, _main._peak_temp, _main._k_cold,
					_main._core_count(), _main._inventory() - _main._population_setpoint])
	if _t < RUN_FOR:
		return false

	var half := _a.size() / 2
	var a1 := _mean(_a, 0, half)
	var a2 := _mean(_a, half, _a.size())
	var t1 := _mean(_peak, 0, half)
	var t2 := _mean(_peak, half, _peak.size())
	var k2 := _mean(_kcold, half, _kcold.size())
	var core_min := 1 << 30
	for c in _core:
		core_min = mini(core_min, c)
	print("\n  first half:  mean A=%6.2f  mean peakT=%4.0f K" % [a1, t1])
	print("  second half: mean A=%6.2f  mean peakT=%4.0f K  mean k_cold=%.4f" % [a2, t2, k2])
	print("  max peak fuel temp seen: %.0f K   min core seen: %d\n" % [_max_peak, core_min])

	# The bed must not quietly drain. RECOMMENDED_POPULATION (the default setpoint) is
	# calibrated; running short shifts k and reads the headline power low, and nothing else
	# in a long run would reveal it.
	#
	# Not exact-pin: under Phase 3c a real body has to physically travel back through the
	# inlet before it lands, so the bed legitimately dips by ~1 for the gap between an
	# extraction and its replacement — admission lag, sampled here over 600 s / ~every 5 s,
	# virtually guaranteed to catch at least one such dip. What this still forbids is a real
	# slow drain, which would show as a min far below one admission cycle's worth.
	_check(core_min >= _main._population_setpoint - 3,
		"bed stayed near its calibrated population for the whole run, not draining (min %d/%d)"
			% [core_min, _main._population_setpoint])
	# Still alive at the end — not shut down, not run away.
	_check(a2 > Thermal.A_RUNNING, "core is still RUNNING after %.0f s (mean A=%.2f)" % [RUN_FOR, a2])
	_check(k2 > 1.0, "k_cold still holds supercritical at the refueling equilibrium (%.4f)" % k2)
	_check(_max_peak < 2200.0, "peak fuel temperature stayed BOUNDED all run (max %.0f K)" % _max_peak)
	# No monotonic drift: the halves must agree. This is the slow-rot check a 60 s probe
	# cannot make. Loose on purpose — it bounds walk-away, not the known breathing.
	_check(a2 > 0.5 * a1 and a2 < 2.0 * a1,
		"power did not drift between halves (%.2f -> %.2f)" % [a1, a2])
	_check(absf(t2 - t1) < 250.0,
		"peak temperature did not drift between halves (%.0f -> %.0f K)" % [t1, t2])

	if _failures == 0:
		print("LIVE LONG-SESSION CHECKS PASSED")
	else:
		print("%d LIVE LONG-SESSION CHECK(S) FAILED" % _failures)
	quit(_failures)
	return true


func _mean(h, from_i: int, to_i: int) -> float:
	var s := 0.0
	var n := 0
	for j in range(from_i, to_i):
		s += h[j]; n += 1
	return s / maxi(n, 1)


func _check(ok: bool, label: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_failures += 1
