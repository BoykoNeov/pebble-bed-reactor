# tests/live_scram.gd
#
# MANUAL / real-time integration check for the UNIFIED SCRAM on the REAL scene:
#   godot --headless --script res://tests/live_scram.gd
#
# WHY this exists on top of live_rods.gd. Scram is no longer a lumped kinetics
# constant — it IS a full insertion of the control rods (Thermal.SCRAM_WORTH is gone).
# live_rods.gd already proves the mechanism the trip now rides on: that driving the
# bank to 100% shuts the running scene down through the whole chain. So this harness
# deliberately does NOT re-prove the physics of a deep rod shutdown. It proves the
# three things the unification ADDED, all of which live only in main._toggle_scram and
# would leave every other suite green if broken:
#
#  1. The trip actually DRIVES THE RODS. `_scrammed` is now a mode flag, not a
#     reactivity: if the toggle failed to move _rod_insertion, k would never fall and
#     the core would keep running behind a HUD that says SCRAMMED.
#  2. Manual rod keys are INERT while scrammed. The trip and the player now share one
#     mechanism, so without the gate a jog on N would walk a tripped bank back out and
#     silently defeat the scram.
#  3. Reset restores the PRE-SCRAM insertion, not zero. This is the subtle one and the
#     reason a trim is set up below: a player holding a hot core at partial insertion
#     who trips and resets must get their rods BACK. Withdrawing to zero would re-expose
#     exactly the excess reactivity those rods were holding, making the un-scram itself
#     the cause of an over-temp — a bug that only shows on a core that was trimmed, which
#     is why testing the trip from the default withdrawn state would miss it entirely.
#
# TRIM CHOICE (10%): small enough that the nominal core is still RUNNING when we trip it
# (there must be a real running start to collapse), because this core only carries ~2%
# excess and much past ~20% insertion is already shut down — see control_rods.gd's
# known-trade-off note. It is also unmistakably distinct from both 0 and 1, so a restore
# to the wrong one of those cannot pass by coincidence.
extends SceneTree

var _main
var _t := 0.0
var _failures := 0

const SETTLE_AT := 45.0     # bed filled, seeded, turning (same point live_rods/live_m4 use)
const TRIM := 0.10          # the player's pre-scram rod position (see TRIM CHOICE above)

var _k_before := 0.0
var _amp_before := 0.0
var _stage := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(delta: float) -> bool:
	_t += delta

	# --- t=45: settled and running; set the player's trim ---
	if _stage == 0 and _t >= SETTLE_AT:
		_check(_main._amplitude > Thermal.A_RUNNING, "core is running before the trip")
		_check(not _main._scrammed, "scram is not latched at startup")
		_check(_main._rod_insertion == 0.0, "rods default to fully WITHDRAWN")
		_main._set_rods(TRIM)
		_check(_main._rod_insertion == TRIM, "player can trim the rods to %.0f%% before the trip" % (TRIM * 100.0))
		print("  trimmed rods -> %.0f%% (the position a reset must give back)" % (TRIM * 100.0))
		_stage = 1
		return false

	# --- t=47: TRIP. The trip must move the bank, and must reach the solve at once ---
	# _toggle_scram re-solves immediately (unlike a manual jog, which waits for the solve
	# cadence), so k_cold is checked on the very next frame rather than after a settle: a
	# trip that only landed on the next scheduled solve would be a real UX regression.
	if _stage == 1 and _t >= SETTLE_AT + 2.0:
		_k_before = _main._k_cold
		_amp_before = _main._amplitude
		_check(_main._amplitude > Thermal.A_RUNNING, "core still running at the trim (A %.1f)" % _amp_before)
		_main._toggle_scram()
		print("  SCRAM tripped (k_cold was %.4f, A was %.1f)" % [_k_before, _amp_before])
		_check(_main._scrammed, "the trip latches _scrammed")
		_check(_main._rod_insertion == ControlRods.INSERT_MAX,
			"the trip DRIVES THE RODS fully in (%.2f) — the whole mechanism" % _main._rod_insertion)
		_check(_main._k_cold < _k_before, "the trip reaches the solve IMMEDIATELY: k_cold %.4f -> %.4f"
			% [_k_before, _main._k_cold])
		_check(_main._k_cold < 1.0, "a scrammed core is honestly subcritical in the solve (%.4f)" % _main._k_cold)

		# The gate: manual rod motion must not defeat a live trip. Try to yank them out.
		_main._set_rods(ControlRods.INSERT_MIN)
		_check(_main._rod_insertion == ControlRods.INSERT_MAX,
			"manual rod keys are INERT while scrammed — a jog cannot walk the bank back out")
		_stage = 2
		return false

	# --- 20 s later: the trip must actually collapse the power, end to end ---
	# Fully rodded k ~ 0.62 gives a ~0.7 s kinetics e-fold, so 20 s pins the amplitude at
	# its A_MIN source floor many times over. Asserting a COLLAPSE past A_RUNNING (not a
	# mere decrease) is what separates the trip from the core's ~100 s breathing.
	if _stage == 2 and _t >= SETTLE_AT + 23.0:
		var amp_scrammed: float = _main._amplitude
		print("  scrammed 20 s: A %.1f -> %.4f   peakT -> %.0f K   k_cold %.4f   rod worth %.4f"
			% [_amp_before, amp_scrammed, _main._peak_temp, _main._k_cold, _main._rod_worth])
		_check(amp_scrammed < Thermal.A_RUNNING,
			"the trip SHUTS THE SCENE DOWN (A %.4f < %.2f)" % [amp_scrammed, Thermal.A_RUNNING])
		_check(amp_scrammed < 0.05 * _amp_before,
			"and it is a collapse, not the breathing (%.1f -> %.4f)" % [_amp_before, amp_scrammed])
		_check(_main._rod_worth > 0.2,
			"the trip's worth is EMERGENT from the solve, and large (%.4f Dk)" % _main._rod_worth)

		# --- RESET: the rods must come back to the TRIM, not to zero ---
		_main._toggle_scram()
		print("  scram reset -> rods %.0f%% (pre-scram trim was %.0f%%)"
			% [_main._rod_insertion * 100.0, TRIM * 100.0])
		_check(not _main._scrammed, "reset clears the latch")
		_check(is_equal_approx(_main._rod_insertion, TRIM),
			"reset RESTORES the pre-scram trim (%.2f), it does not withdraw to zero" % _main._rod_insertion)
		_main._set_rods(TRIM + ControlRods.INSERT_STEP)
		_check(_main._rod_insertion > TRIM,
			"and the rod keys are LIVE again once reset (the gate lifts with the latch)")
		_stage = 3
		if _failures == 0:
			print("LIVE SCRAM CHECKS PASSED")
		else:
			print("%d LIVE CHECK(S) FAILED" % _failures)
		quit(_failures)
	return false


func _check(ok: bool, label: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_failures += 1
