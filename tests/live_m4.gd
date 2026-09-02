# tests/live_m4.gd
#
# MANUAL / real-time integration check for the M4 live loop. The fast, pure
# test_thermal.gd cannot exercise the SCENE — moving pebbles, position-based
# refueling, the equilibrium seed, and the feedback-OFF freeze all live in main.gd,
# and the fast test's idealized refuel does not reproduce the live "breathing". This
# drives the real scene headless in real time (~105 s) and asserts scene invariants:
#   godot --headless --script res://tests/live_m4.gd
#
# Guards three things the unit suite can't:
#  1. The core SETTLES to a bounded, running, self-regulating state before we poke it.
#  2. Toggling feedback OFF does NOT run away / deplete the core — the frozen-loop fix.
#     Without it, raw k>1 (no Doppler) drives power to A_MAX and burnup ∝ A/A_REF then
#     burns the whole core to spent in a step or two (silent state corruption).
#  3. (M5) SCRAM + loss-of-flow on the RUNNING scene collapses fission power while the
#     thermal/decay loop keeps integrating: decay heat persists and the fuel temperature
#     stays bounded — the walk-away-safe demo, exercised end-to-end through main.gd.
extends SceneTree

var _main
var _t := 0.0
var _failures := 0
var _amp_before := 0.0
var _peak_before := 0.0
var _off_done := false
var _checked_off := false
var _resume_checked := false
var _scram_done := false
var _checked_scram := false
var _amp_pre_scram := 0.0
var _peak_pre_scram := 0.0
var _peak_at_flow_restore := 0.0
var _checked_cooldown := false


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
	# t=75 s: after 18 s back ON the core has resumed running (Doppler regulating again).
	if _t >= 75.0 and _checked_off and not _resume_checked:
		_check(_main._amplitude > Thermal.A_RUNNING, "core resumes running after feedback back ON")
		_resume_checked = true
	# t=78 s: core is running again. SCRAM it and cut coolant flow — the M5 walk-away-safe
	# demo. Unlike feedback-OFF, the thermal/decay loop keeps running, so fission power must
	# COLLAPSE while decay heat persists and the temperature stays bounded.
	if _t >= 78.0 and not _scram_done:
		_check(_main._amplitude > Thermal.A_RUNNING, "core running before scram")
		_amp_pre_scram = _main._amplitude
		_peak_pre_scram = _main._peak_temp
		_main._toggle_scram()
		_main._set_flow(Thermal.FLOW_MIN)   # scram + loss of flow
		_scram_done = true
	# t=105 s: 27 s after the trip. Fission power collapsed, but decay heat is still being
	# produced and the fuel temperature never ran away.
	if _t >= 105.0 and not _checked_scram:
		var amp: float = _main._amplitude
		print("  scram 27 s: A %.2f -> %.4f   peakT %.0f -> %.0f K   decayP %.1f (%.0f%% of heat)"
			% [_amp_pre_scram, amp, _peak_pre_scram, _main._peak_temp, _main._decay_power, _main._decay_frac * 100.0])
		_check(amp < Thermal.A_RUNNING and amp < 0.05 * _amp_pre_scram, "scram collapses fission power")
		_check(_main._peak_temp < 2200.0, "fuel temperature BOUNDED after scram + loss-of-flow (walk-away safe)")
		# NOT "the core cools" here: with the flow cut, the decay heat has nowhere to go but
		# the small ambient leak, so the fuel is EXPECTED to warm before it settles — that is
		# the loss-of-flow story, and this gate used to contradict it (it failed on the
		# untouched scene: 734 → 987 K, driven by the decay-heat inventory seeded for A_REF
		# while the core actually runs far below it — docs/PLAN.md §3.4). Restore cooling
		# and gate the cooldown below.
		_peak_at_flow_restore = _main._peak_temp
		_main._set_flow(Thermal.FLOW_NOMINAL)
		_check(_main._decay_power > 0.0, "decay heat PERSISTS after fission stops")
		_checked_scram = true
	# t=125 s: with cooling back, decay heat alone cannot hold the temperature — the core
	# cools. (Fission is still off: the scram is latched.)
	if _t >= 125.0 and _checked_scram and not _checked_cooldown:
		print("  flow restored 20 s: peakT %.0f -> %.0f K   A %.4f" % [_peak_at_flow_restore, _main._peak_temp, _main._amplitude])
		_check(_main._peak_temp < _peak_at_flow_restore - 20.0, "core cools once cooling is restored (decay heat alone cannot hold it)")
		_check(_main._amplitude < Thermal.A_RUNNING, "fission stays off (scram latched)")
		_checked_cooldown = true
		if _failures == 0:
			print("LIVE M4/M5 CHECKS PASSED")
		else:
			print("%d LIVE CHECK(S) FAILED" % _failures)
		quit(_failures)
	return false


func _check(ok: bool, label: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_failures += 1
