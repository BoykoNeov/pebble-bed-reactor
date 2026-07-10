# tests/live_xenon.gd
#
# MANUAL / real-time integration check for the M5c xenon pit on the LIVE scene. The
# pure test_xenon.gd proves the I-135/Xe-135 dynamics in isolation; this proves the
# pit actually emerges end-to-end through main.gd — real flux shape, the power-
# amplitude collapse after scram, homogenization, and the live reactivity-worth solve:
#   godot --headless --script res://tests/live_xenon.gd
#
# The story it exercises: let the core settle at its operating xenon load, then SCRAM.
# Fission power collapses, so Xe-135 burnout stops — but the I-135 already in the bed
# keeps decaying into Xe, so the xenon reactivity WORTH climbs above its operating
# value (the iodine pit), peaks, then drains as the Xe itself decays. A core held down
# by that transient xenon cannot restart until it clears — the "xenon dead time".
extends SceneTree

var _main
var _t := 0.0
var _failures := 0
var _worth_op := 0.0        # operating (pre-scram) xenon worth
var _worth_peak := 0.0      # max worth seen after the scram (the pit crest)
var _scram_done := false
var _checked := false
var _last_print := -1


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(delta: float) -> bool:
	_t += delta
	# t=45 s: bed filled, seeded, running at its operating xenon equilibrium. Snapshot the
	# operating worth, then SCRAM (fission off — the pit driver). No flow cut needed: the
	# pit is a xenon-chain effect, independent of cooling.
	if _t >= 45.0 and not _scram_done:
		_check(_main._amplitude > Thermal.A_RUNNING, "core running (settled) before scram")
		_check(_main._xenon_worth > 0.0, "core carries an operating xenon load (worth %.2f%%)" % (_main._xenon_worth * 100.0))
		_worth_op = _main._xenon_worth
		_worth_peak = _main._xenon_worth
		_main._toggle_scram()
		_scram_done = true
	# Track the pit crest through the post-scram window.
	if _scram_done and not _checked:
		if _main._xenon_worth > _worth_peak:
			_worth_peak = _main._xenon_worth
		# Print a coarse trace (one line per ~3 s) so the pit curve is visible in the log.
		var bucket := int(_t) / 3
		if bucket != _last_print:
			_last_print = bucket
			print("  t=%3ds  xenon worth=%.3f%%  k_cold=%.4f  mean Xe=%.1f  A=%.3f"
				% [int(_t), _main._xenon_worth * 100.0, _main._k_cold, _main._mean_xenon * 1e5, _main._amplitude])
	# t=95 s: ~50 s (≈10 campaign units) after the trip — well past the pit crest, into the
	# drain. The crest must have exceeded the operating worth (the pit rose), and the worth
	# must now be falling back off that crest (the pit drains).
	if _t >= 95.0 and _scram_done and not _checked:
		print("  operating worth=%.3f%%   pit peak=%.3f%%   final=%.3f%%"
			% [_worth_op * 100.0, _worth_peak * 100.0, _main._xenon_worth * 100.0])
		_check(_worth_peak > _worth_op * 1.05, "xenon worth RISES >5%% above operating after scram (the pit)")
		_check(_main._xenon_worth < _worth_peak, "xenon worth falls back off the pit crest (draining)")
		_checked = true
		if _failures == 0:
			print("LIVE M5c XENON PIT CHECKS PASSED")
		else:
			print("%d LIVE CHECK(S) FAILED" % _failures)
		quit(_failures)
	return false


func _check(ok: bool, label: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_failures += 1
