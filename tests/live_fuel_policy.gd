# tests/live_fuel_policy.gd
#
# Integration check for the LIVE fuel-cycle policy — the player's recirculate-vs-discharge
# criteria (main._discharge_burnup / _max_passes, driven by G/H and O/P).
#   godot --headless --script res://tests/live_fuel_policy.gd
#
# WHY a live harness: the policy knob lives in main.gd, so every pure test_* suite is
# structurally blind to it — they drive sim/ directly and never instantiate main. A green
# pure suite says nothing at all about this feature, in either direction.
#
# The three failures this guards, in ascending order of how quietly they'd pass:
#
# FAILURE 1 — the knob is decorative. It moves, the HUD shows it, and the sorter keeps
# using the old constant. The reactor looks fine; the player's lever just does nothing.
#
# FAILURE 2 — the PANEL LIES. This is the sharp one, and it is the reason main._is_spent
# exists as a single shared predicate rather than two copies of one rule. If the sorter
# reads the live knob and the inspector reads Depletion.DISCHARGE_BURNUP, then at any
# non-default policy the panel reports "45.0 / 90 MWd/kgHM" with no (spent) tag about a
# pebble the sorter is in the act of discharging. Nothing crashes; the panel is simply
# wrong about the one thing it exists to say. This is the same two-worlds-disagree bug
# commit 7b0be70 fixed for radius (a pebble neutronically large and physically small),
# wearing a different costume — so it is tested the same way: by driving the two worlds
# apart and demanding they still agree.
#
# FAILURE 3 — the policy LEAKS into calibration. DISCHARGE_BURNUP has several readers and
# only the fate-deciding ones want the live value. The other two are calibrated references
# that must not follow the knob: the burnup colormap's range (CLAUDE.md demands STABLE
# normalization — a scale that moves when the player taps a key makes transients
# incomparable, which is exactly what the rule forbids) and _seed_burned (a one-time
# startup calibration; an operating lever must not rewrite the core's history). A leak
# there is invisible on screen and would quietly redefine the constant that several
# existing calibrations are expressed in terms of.
extends SceneTree

# The bed is seeded to a burnup SPREAD (0 → ~90) and discharges are flowing by ~70 s
# (live_fuel_loop). Margin on top, matching the other live harnesses.
const SETTLE_AT := 80.0
# How long to watch the wave. Baseline discharge runs ~1 per 16 s, so this window sees
# roughly 1 discharge at the default policy — the wave has to beat that by a mile for the
# check to mean anything.
const WATCH := 20.0

var _main
var _t := 0.0
var _failures := 0
var _phase := 0
var _extracted_at_drop := 0
var _recirc_at_drop := 0
var _backlog_before := 0
var _backlog_after := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live fuel policy] the player's discharge criteria must GOVERN the sorter — and the panel must not lie about them")


func _ok(pass_: bool, msg: String) -> void:
	print("  %s  %s" % ["PASS" if pass_ else "FAIL", msg])
	if not pass_:
		_failures += 1


## Bed pebbles the current policy calls spent — the sorter's backlog.
func _backlog() -> int:
	var n := 0
	for id in _main._pebbles:
		if not _main._out_of_core.has(id) and _main._is_spent(_main._pebbles[id]):
			n += 1
	return n


func _process(delta: float) -> bool:
	_t += delta

	if _phase == 0:
		if _t < SETTLE_AT:
			return false
		_phase_settled()
		_phase = 1
		return false

	if _phase == 1:
		if _t < SETTLE_AT + WATCH:
			return false
		_phase_wave()
		print("ALL CHECKS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures)
		quit(1 if _failures > 0 else 0)
		return true

	return false


## t = SETTLE_AT: the core is at its running equilibrium and the policy is untouched.
## Everything here is asserted at the DEFAULT setting, then the knob is dropped.
func _phase_settled() -> void:
	# 1. NEUTRAL AT THE DEFAULT — the calibration claim, and the reason every pre-existing
	#    calibration survives this feature untouched (the M5d pattern). Asserted by
	#    IDENTITY against the constants, not against a re-typed 90.0/15: if someone retunes
	#    Depletion.DISCHARGE_BURNUP, the default must follow it rather than silently become
	#    an override that shifts the cycle.
	_ok(_main._discharge_burnup == Depletion.DISCHARGE_BURNUP,
		"the discharge knob defaults to the calibrated constant (%.1f)" % _main._discharge_burnup)
	_ok(_main._max_passes == Depletion.MAX_PASSES,
		"the passes knob defaults to the calibrated constant (%d)" % _main._max_passes)

	# 2. The bed really does hold a burnup SPREAD. Asserted first because every check below
	#    is vacuous without it: if every pebble were fresh, lowering the threshold would
	#    reclassify nothing and the wave check would pass or fail for reasons unrelated to
	#    the policy. This is the seeded online-refueling equilibrium (main._seed_burned).
	var lo := INF
	var hi := -INF
	for id in _main._pebbles:
		if _main._out_of_core.has(id):
			continue
		var b: float = _main._pebbles[id].burnup
		lo = minf(lo, b)
		hi = maxf(hi, b)
	_ok(hi - lo > 40.0,
		"the bed holds a real burnup spread (%.1f → %.1f) — the knob has something to bite on"
			% [lo, hi])

	# 3. THE PANEL MUST NOT LIE. Drive the policy to a value that splits the bed's spread,
	#    then find a pebble the OLD code would have gotten wrong: burnup above the new
	#    threshold but below the constant, i.e. spent under the live policy and NOT spent
	#    under Depletion.DISCHARGE_BURNUP. That pebble is precisely the liar case — a panel
	#    reading the constant calls it healthy while the sorter discharges it.
	_main._set_discharge_burnup(30.0)
	_ok(_main._discharge_burnup == 30.0, "the discharge knob moves (%.1f)" % _main._discharge_burnup)
	var liar: Pebble = null
	for id in _main._pebbles:
		if _main._out_of_core.has(id):
			continue
		var p: Pebble = _main._pebbles[id]
		if p.burnup > 35.0 and p.burnup < Depletion.DISCHARGE_BURNUP - 5.0:
			liar = p
			break
	if liar == null:
		_ok(false, "found a pebble spent under the live policy but not the constant (none in the bed)")
	else:
		# The two worlds, made to disagree on purpose. Under the default they agree and this
		# proves nothing — that is why the knob is moved FIRST.
		_ok(_main._is_spent(liar),
			"a pebble at %.1f burnup IS spent under the live 30.0 policy" % liar.burnup)
		_ok(liar.burnup < Depletion.DISCHARGE_BURNUP,
			"...and would NOT be spent under the constant (%.1f < %.1f) — the panel can lie here"
				% [liar.burnup, Depletion.DISCHARGE_BURNUP])
		_main._selected = liar
		_main._update_inspector()
		var txt: String = _main._inspector.text
		_ok(txt.contains("(spent)"),
			"the panel tags it (spent) — it agrees with the sorter about this pebble's fate")
		_ok(txt.contains("/ 30 MWd/kgHM"),
			"the panel measures it against the LIVE threshold (30), not the constant")
		_ok(not txt.contains("/ 90 MWd/kgHM"),
			"the panel does NOT quote the stale constant (90) at the player")
		# The passes row must track its knob the same way.
		_main._set_max_passes(7)
		_main._update_inspector()
		_ok(_main._inspector.text.contains("/ 7"),
			"the passes row tracks the live pass limit (7), not the constant")
		_main._set_max_passes(Depletion.MAX_PASSES)
		_main._selected = null

	# 4. THE POLICY MUST NOT LEAK INTO CALIBRATION.
	#
	#    4a. The colormap's range is a fixed SCALE, not a policy readout. It must still span
	#        0..DISCHARGE_BURNUP with the knob at 30 — CLAUDE.md's stable-normalization rule.
	#        The visible consequence is deliberate and is NOT a bug to reconcile later: a
	#        pebble can read ~44% of the colorbar and still be tagged (spent). Colour is
	#        absolute burnup; the tag is the policy verdict. Two honest axes.
	_ok(_main._burnup_desc.vmax == Depletion.DISCHARGE_BURNUP,
		"the burnup colormap keeps its CALIBRATED range (0..%.0f) at a 30.0 policy — stable normalization"
			% _main._burnup_desc.vmax)

	#    4b. _seed_burned is a one-time startup calibration and must read the constant, not
	#        the knob. Sampled rather than reasoned about: with the knob at 30, a seeder that
	#        wrongly followed it could never produce a burnup above 30. Drawing 100 uniform
	#        samples from 0..90, the odds of the max landing below 50 by chance are
	#        (50/90)^100 ≈ 1e-26 — so this discriminates the two implementations decisively
	#        without depending on the RNG seed.
	var seed_hi := 0.0
	for i in 100:
		var probe := Pebble.new(700000 + i, _main.PEBBLE_RADIUS)
		_main._stamp_enrichment(probe, _main._enrichment)
		_main._seed_burned(probe)
		seed_hi = maxf(seed_hi, probe.burnup)
	_ok(seed_hi > 50.0,
		"startup seeding still spans the CALIBRATED 0..%.0f range (max %.1f) — the knob did not rewrite history"
			% [Depletion.DISCHARGE_BURNUP, seed_hi])

	# 5. Clamping — the knob may not be driven outside its band.
	_main._set_discharge_burnup(9999.0)
	_ok(_main._discharge_burnup == _main.DISCHARGE_MAX,
		"the discharge knob clamps at its ceiling (%.1f)" % _main._discharge_burnup)
	_main._set_discharge_burnup(-50.0)
	_ok(_main._discharge_burnup == _main.DISCHARGE_MIN,
		"the discharge knob clamps at its floor (%.1f)" % _main._discharge_burnup)
	_main._set_max_passes(0)
	_ok(_main._max_passes == _main.PASSES_MIN,
		"the pass backstop clamps at its floor (%d) — never zero" % _main._max_passes)
	_main._set_max_passes(Depletion.MAX_PASSES)

	# 6. THE WAVE. The knob is now at its floor (from the clamp check above), so nearly the
	#    whole seeded spread is reclassified as spent in one keystroke. Snapshot the cycle
	#    counters and the backlog, then let it run.
	_backlog_before = _backlog()
	_extracted_at_drop = _main._total_extracted
	_recirc_at_drop = _main._total_recirculated
	_ok(_backlog_before > 20,
		"dropping the threshold to %.0f reclassifies a slug of the bed as spent (%d pebbles)"
			% [_main._discharge_burnup, _backlog_before])


## t = SETTLE_AT + WATCH: the sorter has been running under the floored policy. The wave
## must have actually happened — this is the check that the knob GOVERNS rather than decorates.
func _phase_wave() -> void:
	var discharged: int = _main._total_extracted - _extracted_at_drop
	var recirculated: int = _main._total_recirculated - _recirc_at_drop
	_backlog_after = _backlog()

	# At the default policy this window sees ~1 discharge (~1 per 16 s). Under the floored
	# policy every pebble reaching the outlet is spent, so the sorter discharges instead of
	# recirculating, metered at one per EXTRACT_INTERVAL. An order of magnitude is the whole
	# signal; the exact rate is throughput-limited by the machine and is not the claim.
	_ok(discharged >= 10,
		"the sorter DISCHARGES the newly-spent backlog (%d in %.0f s; ~1 at the default policy)"
			% [discharged, WATCH])
	# THE DECISION ITSELF MUST FLIP — the sharpest form of "the knob governs the sorter",
	# because it is the SAME measurement taken under two policies in one run. A sorter that
	# merely discharged more while still recirculating just as freely would mean it was
	# cycling faster, not deciding differently. So compare the share of decisions that came
	# out "recirculate":
	#   * At the DEFAULT policy (the settling window) the cycle is multi-pass by design —
	#     a pebble takes ~6-15 passes to reach discharge burnup, so the sorter sends the
	#     large majority of what it touches back around.
	#   * At the FLOORED policy that share must collapse.
	#
	# It does NOT collapse to zero, and expecting zero was this test's own first mistake —
	# worth recording, because the leftover is the cycle working rather than a leak. The
	# wave discharges spent fuel and mints FRESH replacements at burnup 0; a few of those
	# reach the outlet within the window, and at ~0 burnup they are genuinely below even the
	# floored threshold, so recirculating them is the correct call. The bed is never wholly
	# spent precisely BECAUSE the wave is refilling it with fresh fuel.
	var base_total: int = _recirc_at_drop + _extracted_at_drop
	var wave_total: int = recirculated + discharged
	var base_share: float = float(_recirc_at_drop) / float(maxi(base_total, 1))
	var wave_share: float = float(recirculated) / float(maxi(wave_total, 1))
	_ok(base_total > 0 and base_share > 0.5,
		"at the DEFAULT policy the sorter mostly RECIRCULATES (%.0f%% of %d decisions) — multi-pass fuelling"
			% [base_share * 100.0, base_total])
	_ok(wave_share < 0.15,
		"...and at the floored policy that flips to mostly DISCHARGE (%.0f%% recirculated of %d) — the knob decides, not the clock"
			% [wave_share * 100.0, wave_total])
	# Every discharged pebble is accounted for: the wave must not drop fuel on the floor.
	#
	# The pool is CAPPED at the tray, and this wave discharges far more than a tray holds,
	# so `_spent.size() == _total_extracted` (what this asserted before the cap) is now
	# false for an entirely correct reason — the surplus went to a cask, which is where a
	# full pool is supposed to send it. Add the shipped term rather than weaken the claim:
	# every discharged pebble is either still in the tray or provably casked, and any that
	# went missing shows up here as a shortfall exactly as it would have before.
	_ok(_main._spent.size() + _main._total_shipped == _main._total_extracted,
		"every pebble the wave discharged is accounted for — held or casked (%d + %d == %d)"
			% [_main._spent.size(), _main._total_shipped, _main._total_extracted])
	# ...and the cap really is holding. Without this the check above would still pass if
	# the tray grew without bound (shipped would just stay 0), which is the state the cap
	# exists to prevent — and the one that made the pool's older half unreachable.
	_ok(_main._spent.size() <= FuelLoop.pool_capacity(),
		"the pool never outgrows its tray (%d <= %d)"
			% [_main._spent.size(), FuelLoop.pool_capacity()])
	_ok(_main._total_shipped > 0,
		"...and this wave really did overflow it, so the cask path is exercised (%d shipped)"
			% _main._total_shipped)
	# The bed stays pinned at its calibrated population THROUGH the wave — fresh fuel
	# replaces the discharged 1:1. A wave that drained the bed would walk k off calibration
	# for reasons that have nothing to do with the policy (the LOOP_BUFFER hazard).
	_ok(_main._core_count() == _main.TARGET_POPULATION,
		"the bed stays pinned at its calibrated population through the wave (%d / %d)"
			% [_main._core_count(), _main.TARGET_POPULATION])

	# Restoring the policy must restore the cycle: the backlog is a property of the RULE,
	# not damage done to the fuel. Nothing was burned by moving the knob — put it back and
	# the reclassified pebbles are simply healthy again.
	_main._set_discharge_burnup(Depletion.DISCHARGE_BURNUP)
	_ok(_backlog() < _backlog_before,
		"restoring the policy un-reclassifies the survivors (backlog %d → %d) — the knob reads fuel, it does not burn it"
			% [_backlog_before, _backlog()])
