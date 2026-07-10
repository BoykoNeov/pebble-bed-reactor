# tests/live_m4.gd
#
# MANUAL / real-time integration check for the M4 live loop. The fast, pure
# test_thermal.gd cannot exercise the SCENE — moving pebbles, position-based
# refueling, the equilibrium seed, and the feedback-OFF freeze all live in main.gd,
# and the fast test's idealized refuel does not reproduce the live "breathing". This
# drives the real scene headless in real time (~75 s) and asserts scene invariants:
#   godot --headless --script res://tests/live_m4.gd
#
# Guards two things the unit suite can't:
#  1. The core SETTLES to a bounded, running, self-regulating state before we poke it.
#  2. Toggling feedback OFF does NOT run away / deplete the core — the frozen-loop fix.
#     Without it, raw k>1 (no Doppler) drives power to A_MAX and burnup ∝ A/A_REF then
#     burns the whole core to spent in a step or two (silent state corruption).
extends SceneTree

var _main
var _t := 0.0
var _failures := 0
var _amp_before := 0.0
var _peak_before := 0.0
var _off_done := false
var _checked_off := false


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(delta: float) -> bool:
	_t += delta
	# t=45 s: the bed has filled, seeded, and is running. Snapshot state, cut feedback.
	if _t >= 45.0 and not _off_done:
		_check(_main._amplitude > Thermal.A_RUNNING, "core is running (settled) before F-off")
		_check(_main._peak_temp < 1800.0, "peak fuel temp bounded before F-off (%.0f K)" % _main._peak_temp)
		_amp_before = _main._amplitude
		_peak_before = _main._peak_temp
		_main._toggle_feedback()   # feedback OFF — dynamic loop must FREEZE
		_off_done = true
	# t=57 s: after 12 s of feedback OFF the dynamic loop must be BYTE-FROZEN — power
	# amplitude and fuel temperature untouched. WHY exact-equality, not a bound: at
	# GAIN=4 the runaway to A_MAX takes ~130 s, so a loose "A < A_MAX" would pass even
	# with the freeze broken; only an exact hold proves the loop actually stopped.
	# (Mechanical refueling keeps running — that is correct and independent of Doppler —
	# so total isotopics DO drift; the freeze is about the neutronic/thermal dynamics.)
	if _t >= 57.0 and not _checked_off:
		var amp: float = _main._amplitude
		var pk: float = _main._peak_temp
		print("  F-off 12 s: A %.4f -> %.4f   peakT %.0f -> %.0f K" % [_amp_before, amp, _peak_before, pk])
		_check(absf(amp - _amp_before) < 1.0e-6, "feedback-OFF FREEZES power amplitude (no runaway)")
		_check(absf(pk - _peak_before) < 1.0e-3, "feedback-OFF FREEZES fuel temperature")
		_main._toggle_feedback()   # back ON — resumes from the held state
		_checked_off = true
	if _t >= 75.0:
		_check(_main._amplitude > Thermal.A_RUNNING, "core resumes running after feedback back ON")
		if _failures == 0:
			print("LIVE M4 CHECKS PASSED")
		else:
			print("%d LIVE CHECK(S) FAILED" % _failures)
		quit(_failures)
	return false


func _check(ok: bool, label: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_failures += 1
