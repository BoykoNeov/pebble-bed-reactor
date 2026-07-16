# tests/live_rods.gd
#
# MANUAL / real-time integration check for the M5d control rods on the REAL scene:
#   godot --headless --script res://tests/live_rods.gd
#
# WHY a live harness when test_control_rods.gd already passes: that suite proves the
# rod PHYSICS on a synthetic lattice (worth, the S-curve, the headline rescue). It says
# nothing about the WIRING — whether the rods reach the live solve at all. Everything
# between ControlRods.apply_rods and the player lives in main.gd: the apply site
# relative to the base snapshot, the worth measurement, the key handler, the redraw.
# A rod that is never applied would leave every pure test green.
#
# WHAT IT GUARDS:
#  1. Withdrawn is the default and costs nothing: worth is exactly 0.
#  2. Inserting rods drops the LIVE k_cold by the amount the worth readout claims —
#     i.e. the number on the HUD is the reactivity actually removed from the solve,
#     not a decoration computed on a different grid.
#  3. Full insertion shuts the RUNNING scene down, through the whole chain
#     (rods -> sigma_a2 -> k -> point kinetics -> power -> temperature).
#  4. Withdrawing RESTARTS it. Rods are a reversible lever, unlike the latched scram;
#     if insertion were somehow one-way the sim would still look right in a screenshot.
#
# MEASURING IN A BREATHING CORE (the trap this project has hit before): the live core
# does not sit still — it breathes on a ~100 s period, with the power amplitude swinging
# roughly 9 to 48 (see live_long_session.gd). So "A went down after I inserted rods"
# proves NOTHING on its own; the breathing does that by itself. Two defenses used here:
#   * The k_cold check is immediate and deterministic — rods are an absorption change,
#     so one solve cadence separates cause from effect, far faster than the core evolves.
#   * The power checks use FULL insertion (worth ~0.38 Dk), which is an order of
#     magnitude beyond anything the breathing can do, and assert a COLLAPSE past
#     A_RUNNING rather than a mere decrease.
extends SceneTree

var _main
var _t := 0.0
var _failures := 0

const SETTLE_AT := 45.0     # bed filled, seeded, turning (same point live_m4 uses)
const HALF := 0.5           # a mid-stroke insertion: real worth, core still identifiable

var _k_before := 0.0
var _amp_before := 0.0
var _stage := 0
var _amp_rodded := 0.0
var _peak_rodded := 0.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(delta: float) -> bool:
	_t += delta

	# --- t=45: settled and running, rods withdrawn (the shipped default) ---
	if _stage == 0 and _t >= SETTLE_AT:
		_check(_main._amplitude > Thermal.A_RUNNING, "core is running before the rods move")
		_check(_main._rod_insertion == 0.0, "rods default to fully WITHDRAWN")
		_check(_main._rod_worth == 0.0, "withdrawn rods have exactly zero worth (and cost no solve)")
		_k_before = _main._k_cold
		_amp_before = _main._amplitude
		_main._set_rods(HALF)
		print("  rods -> %.0f%% in (k_cold was %.4f, A was %.1f)" % [HALF * 100.0, _k_before, _amp_before])
		_stage = 1
		return false

	# --- t=48: the rods must have actually reached the solve ---
	# The claim: k_cold fell, and it fell BY the worth the HUD is reporting. That
	# equivalence is the real check — it can only hold if the same absorption the worth
	# solve differenced is the absorption the live solve used.
	# Read back after ~1 s (5 solve cadences — several times more than the one needed),
	# deliberately SHORT: the live k_cold genuinely drifts as the core burns, breathes and
	# refuels, so the longer this gap the more of that drift pollutes the comparison.
	if _stage == 1 and _t >= SETTLE_AT + 1.0:
		var k_now: float = _main._k_cold
		var worth: float = _main._rod_worth
		var drop := _k_before - k_now
		print("  rods %.0f%% in: k_cold %.4f -> %.4f (drop %.4f)   reported worth %.4f"
			% [_main._rod_insertion * 100.0, _k_before, k_now, drop, worth])
		_check(worth > 0.0, "inserted rods report positive worth (%.4f)" % worth)
		_check(k_now < _k_before, "inserting rods LOWERS the live k_cold")
		# The tolerance covers the core's OWN evolution between the two readings (burnup,
		# xenon, refuelling all move k_cold by ~0.01 on their own over a few seconds — see
		# live_long_session), NOT slack in the rod maths. It is still a sharp check: broken
		# wiring gives drop = 0, and a worth computed on a stale or different grid gives a
		# number nowhere near the drop.
		_check(absf(drop - worth) < 0.015,
			"the k_cold drop MATCHES the reported worth (%.4f vs %.4f) — same absorption, one grid"
			% [drop, worth])
		_main._set_rods(ControlRods.INSERT_MAX)
		print("  rods -> 100%% in (full insertion)")
		_stage = 2
		return false

	# --- full insertion must shut the running scene down ---
	# 20 s is ample: fully rodded, k ~ 0.69, so the kinetics e-fold is ~0.8 s and the
	# amplitude is pinned at its A_MIN source floor within ~10 s.
	if _stage == 2 and _t >= SETTLE_AT + 21.0:
		_amp_rodded = _main._amplitude
		_peak_rodded = _main._peak_temp
		print("  fully rodded 20 s: A %.1f -> %.4f   peakT -> %.0f K   k_cold %.4f   worth %.4f"
			% [_amp_before, _amp_rodded, _peak_rodded, _main._k_cold, _main._rod_worth])
		_check(_main._k_cold < 1.0, "fully rodded live core is subcritical (%.4f)" % _main._k_cold)
		_check(_amp_rodded < Thermal.A_RUNNING,
			"full insertion SHUTS DOWN the running scene (A %.4f < %.2f)" % [_amp_rodded, Thermal.A_RUNNING])
		_check(_amp_rodded < 0.05 * _amp_before, "and it is a collapse, not the breathing (%.1f -> %.4f)"
			% [_amp_before, _amp_rodded])
		_main._set_rods(ControlRods.INSERT_MIN)
		print("  rods -> 0%% (withdrawn)")
		_stage = 3
		return false

	# --- withdrawing must bring it back ---
	# Rods are reversible: unlike scram this is not a latch. The window is LONG on purpose.
	# A deep rod shutdown pins the amplitude at the A_MIN = 1e-4 source floor, so restart is
	# a climb of ln(A_RUNNING/A_MIN) ~ 6.2 e-folds; at the withdrawn k_cold ~ 1.026 and
	# KINETICS_GAIN = 4 an e-fold is ~10 s, so the core needs ~60 s MINIMUM to get back to a
	# running level and cannot be hurried. (A first pass allowed 45 s and read the failure as
	# "does not restart" when the core was in fact climbing steadily — 0.0001 -> 0.0030, a
	# factor of 30. That is a slow restart from source level, which is what a real reactor
	# does after a deep shutdown, not a broken lever.)
	if _stage == 3 and _t >= SETTLE_AT + 130.0:
		print("  withdrawn 109 s: A %.4f -> %.1f   peakT %.0f -> %.0f K   k_cold %.4f   worth %.4f"
			% [_amp_rodded, _main._amplitude, _peak_rodded, _main._peak_temp, _main._k_cold, _main._rod_worth])
		_check(_main._rod_worth == 0.0, "withdrawn rods return to exactly zero worth")
		_check(_main._k_cold > 1.0, "withdrawing restores cold supercriticality (%.4f)" % _main._k_cold)
		_check(_main._amplitude > Thermal.A_RUNNING,
			"the core RESTARTS after withdrawal (A %.4f) — the lever is reversible" % _main._amplitude)
		_check(_main._amplitude > 10.0 * _amp_rodded, "and it is a real restart, not a flicker")
		_stage = 4
		if _failures == 0:
			print("LIVE ROD CHECKS PASSED")
		else:
			print("%d LIVE CHECK(S) FAILED" % _failures)
		quit(_failures)
	return false


func _check(ok: bool, label: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_failures += 1
