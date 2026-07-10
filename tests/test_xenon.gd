# tests/test_xenon.gd
#
# Headless calibration + correctness gate for the M5c xenon transient. Runs pure
# (no scene, no physics) via:
#   godot --headless --script res://tests/test_xenon.gd
#
# WHY (mirrors test_depletion.gd): the xenon micro-rates are toy, campaign-time-
# native constants, so their ABSOLUTE values are meaningless — what carries meaning
# is a set of ORDERINGS and shapes that make xenon behave like xenon:
#   1. buildup: I-135 and Xe-135 rise from zero to a positive equilibrium under flux,
#      and that equilibrium RISES with flux (more fission → more poison), saturating.
#   2. the equilibrium matches Depletion.seed_xenon (so the initial-bed seed is right).
#   3. THE HEADLINE — the post-shutdown pit: cut the flux and Xe-135 RISES above its
#      operating level (trapped I-135 keeps decaying in while burnout stops), peaks,
#      then decays away. This is the iodine pit / xenon dead time.
#   4. negative reactivity: a core carrying equilibrium xenon is less reactive than
#      the same core with the xenon removed.
#   5. the operating point still survives: the equilibrium-mix core stays critical at
#      the operating enrichment WITH xenon folded in (re-tuned from the pre-M5c point).
extends SceneTree

var _failures := 0

# Representative peak-normalized bed flux a mid-core pebble sees at the operating
# point (same 0.5 the depletion notes use). The pit is driven from this level.
const PHI_OP := 0.5


func _initialize() -> void:
	print("=== M5c xenon calibration ===")
	_test_buildup_to_equilibrium()
	_test_equilibrium_matches_seed()
	_test_lambda_ordering()
	_test_post_shutdown_pit()
	_test_xenon_lowers_keff()
	_test_operating_point_survives()
	if _failures == 0:
		print("\nALL CHECKS PASSED")
	else:
		print("\n%d CHECK(S) FAILED" % _failures)
	quit(_failures)


## A single fresh pebble at a given enrichment (heavy-metal split as main stamps it).
func _fresh_pebble(enrichment := 0.11) -> Pebble:
	var peb := Pebble.new(0, 8.0)
	peb.u235 = enrichment
	peb.u238 = 1.0 - enrichment
	return peb


## Drive a pebble at constant flux for a span of campaign time in small steps, so the
## xenon backward-Euler resolves its transient. Returns nothing (mutates peb).
func _run(peb: Pebble, flux: float, span: float, steps := 400) -> void:
	var dt := span / steps
	for _i in steps:
		Depletion.step(peb, flux, dt)


func _test_buildup_to_equilibrium() -> void:
	print("\n[buildup to equilibrium]")
	var peb := _fresh_pebble()
	# Sample the rise partway and near-equilibrium.
	_run(peb, PHI_OP, 4.0, 80)
	var xe_early := peb.xe135
	var i_early := peb.i135
	_run(peb, PHI_OP, 60.0, 1200)   # long enough to settle (tau_Xe ~ 1/0.12 ~ 8)
	var xe_eq := peb.xe135
	# xenon inventories are tiny toy numbers (~1e-5); print ×1e5 so they're legible.
	print("  I-135 early=%.3f   Xe-135 early=%.3f  eq=%.3f  (×1e-5)" % [i_early * 1e5, xe_early * 1e5, xe_eq * 1e5])
	_check(i_early > 0.0, "I-135 builds up from zero under flux")
	_check(xe_early > 0.0, "Xe-135 builds up from zero under flux")
	_check(xe_eq > xe_early, "Xe-135 keeps rising toward equilibrium")

	# Higher flux → higher equilibrium xenon (production ∝ flux; removal saturates). Use
	# seed_xenon on IDENTICAL fresh fissile at two fluxes so the comparison is the pure
	# equilibrium relation — a long burn-in would confound it with U-235 depletion (the
	# hotter pebble burns down its fission source, lowering F over the run).
	var lo_eq := _fresh_pebble()
	var hi_eq := _fresh_pebble()
	Depletion.seed_xenon(lo_eq, 0.5)
	Depletion.seed_xenon(hi_eq, 1.0)
	print("  Xe eq @phi=0.5: %.3f   @phi=1.0: %.3f  (×1e-5)" % [lo_eq.xe135 * 1e5, hi_eq.xe135 * 1e5])
	_check(hi_eq.xe135 > lo_eq.xe135, "higher flux settles at higher equilibrium xenon")


func _test_equilibrium_matches_seed() -> void:
	# The seed used to open the live bed must equal what the loop converges to, or the
	# core would drift off its seeded xenon load at startup (a spurious transient).
	print("\n[equilibrium matches seed_xenon]")
	var peb := _fresh_pebble()
	_run(peb, PHI_OP, 120.0, 2400)   # deep settle
	var seed := _fresh_pebble()
	# Seed uses the CURRENT isotopics (U-235 has burned a little over 120 units), so
	# match the settled pebble's fissile vector before seeding for a fair comparison.
	seed.u235 = peb.u235
	seed.u238 = peb.u238
	seed.pu239 = peb.pu239
	Depletion.seed_xenon(seed, PHI_OP)
	var rel := absf(peb.xe135 - seed.xe135) / peb.xe135
	print("  settled Xe=%.3f   seed Xe=%.3f  (×1e-5)  rel.err=%.3f" % [peb.xe135 * 1e5, seed.xe135 * 1e5, rel])
	_check(rel < 0.05, "seed_xenon matches the settled equilibrium within 5%%")


func _test_lambda_ordering() -> void:
	# Structural precondition for a pit: iodine must decay FASTER than xenon, so a
	# trapped I inventory dumps into Xe faster than Xe can clear.
	print("\n[decay-constant ordering]")
	_check(Depletion.LAMBDA_I > Depletion.LAMBDA_XE,
		"lambda_I (%.2f) > lambda_Xe (%.2f)" % [Depletion.LAMBDA_I, Depletion.LAMBDA_XE])
	# And burnout must be a real fraction of removal at operating flux, or cutting flux
	# wouldn't change Xe removal enough to open a pit.
	var burnout := Depletion.SIGMA_XE * PHI_OP
	_check(burnout >= Depletion.LAMBDA_XE,
		"burnout sigma_Xe*phi (%.3f) >= lambda_Xe (%.3f) at operating flux" % [burnout, Depletion.LAMBDA_XE])


func _test_post_shutdown_pit() -> void:
	# THE HEADLINE. Build to equilibrium at operating flux, then CUT the flux to zero
	# and evolve on TIME only. Xe-135 must RISE above its operating equilibrium (the
	# pit), reach a peak, then decay away — the classic xenon dead time.
	print("\n[post-shutdown xenon pit]")
	var peb := _fresh_pebble()
	_run(peb, PHI_OP, 80.0, 1600)
	var xe_op := peb.xe135
	# Freeze the fissile vector so a fair comparison isn't confounded by burnup: the
	# pit is a xenon-chain effect, so we probe it in isolation by shutting flux OFF.
	var peak := xe_op
	var peak_t := 0.0
	var dt := 0.05
	var t := 0.0
	var final_xe := xe_op
	# Evolve 60 campaign-time units at ZERO flux (shutdown). Track the peak.
	for _i in 1200:
		Depletion.step(peb, 0.0, dt)
		t += dt
		if peb.xe135 > peak:
			peak = peb.xe135
			peak_t = t
		final_xe = peb.xe135
	var swing := (peak - xe_op) / xe_op
	print("  Xe operating=%.3f   pit peak=%.3f at t=%.1f   final=%.3f  (×1e-5)" % [xe_op * 1e5, peak * 1e5, peak_t, final_xe * 1e5])
	print("  peak swing above operating = %.1f%%" % (swing * 100.0))
	_check(peak > xe_op * 1.05, "Xe-135 rises >5%% above operating after shutdown (the pit)")
	_check(peak_t > 0.0, "the pit peaks AFTER shutdown, not at it")
	_check(final_xe < peak, "Xe-135 decays back down past the pit peak")
	_check(final_xe < xe_op, "Xe-135 eventually clears below the operating level")


func _test_xenon_lowers_keff() -> void:
	# Xenon is a parasitic absorber: a core carrying equilibrium xenon must be less
	# reactive than the identical core with the xenon zeroed out.
	print("\n[xenon lowers k-eff]")
	var k_with := _solve_mixed(0.113, true)
	var k_without := _solve_mixed(0.113, false)
	print("  k(with xenon)=%.4f   k(no xenon)=%.4f   worth Δk=%.4f" % [k_with, k_without, k_without - k_with])
	_check(k_without > k_with, "equilibrium xenon suppresses k-eff")
	_check((k_without - k_with) > 0.001, "xenon worth is a resolvable margin (Δk > 0.1%%)")
	_check((k_without - k_with) < 0.010, "equilibrium xenon worth stays inside the operating margin (Δk < 1%%)")


func _test_operating_point_survives() -> void:
	# The M3/M4 operating point must survive M5c: the equilibrium-mix core still sits
	# supercritical-with-margin at the (re-tuned) operating enrichment WITH xenon in.
	print("\n[operating mix still critical with xenon]")
	for e in [0.110, 0.113, 0.116, 0.120]:
		var eq := Feedback.solve_equilibrium(_mixed_grid(e, true))
		print("  e=%.3f  k(mix,xenon)=%.4f  regulated peak T=%.0f K%s"
			% [e, eq.k_cold, Feedback.T_REF + eq.peak_dt,
			   "  (over-temp)" if (Feedback.T_REF + eq.peak_dt) >= OVER_TEMP_K else ""])
	var op := operating_enrichment()
	var op_eq := Feedback.solve_equilibrium(_mixed_grid(op, true))
	var op_peak := Feedback.T_REF + op_eq.peak_dt
	_check(op <= 0.20, "operating point stays LEU (%.1f%%)" % (op * 100.0))
	_check(op_eq.k_cold > 1.008, "operating mix supercritical with margin, xenon in (k=%.4f)" % op_eq.k_cold)
	_check(op_eq.regulated and not op_eq.feedback_insufficient and op_peak < OVER_TEMP_K,
		"operating mix self-regulates below over-temp with xenon (peak %.0f K)" % op_peak)


const OVER_TEMP_K := 1800.0

## The re-tuned lattice operating enrichment WITH xenon folded in. Pre-M5c this was
## 0.110 (test_depletion); equilibrium xenon costs a little reactivity, so the lattice
## point moves up a hair — the same lattice-vs-live compensation the codebase already
## documents for every layer. main.gd's ENRICH_DEFAULT tracks this (plus its own
## live-bed offset).
func operating_enrichment() -> float:
	return 0.113


## Solve k for the equilibrium-spread mixed core, optionally zeroing xenon to isolate
## its worth (the with/without contrast of _test_xenon_lowers_keff).
func _solve_mixed(enrichment: float, with_xenon: bool) -> float:
	return Neutronics.solve(_mixed_grid(enrichment, with_xenon)).k_eff


## Homogenized grid for the equilibrium-spread mixed core (fresh at top → spent at
## bottom), each pebble carrying its settled equilibrium xenon. `with_xenon=false`
## zeroes the xenon after settling to measure the xenon reactivity worth in isolation.
func _mixed_grid(enrichment: float, with_xenon: bool) -> Grid:
	var grid := Grid.for_silo()
	var pebbles := {}
	var positions := {}
	var id := 0
	var spacing := 18.0
	var half_cols := 8
	var y_top := Silo.OUTLET_Y - 370.0
	var rows := int((Silo.OUTLET_Y - spacing - y_top) / spacing) + 1
	var row := 0
	var y := y_top
	while y <= Silo.OUTLET_Y - spacing:
		var frac: float = float(row) / maxf(1.0, float(rows - 1))
		var target := frac * Depletion.DISCHARGE_BURNUP
		for k in range(-half_cols, half_cols + 1):
			var x := Silo.CENTER_X + k * spacing
			if x <= Silo.LEFT + 8.0 or x >= Silo.RIGHT - 8.0:
				continue
			var peb := _fresh_pebble(enrichment)
			peb.id = id
			# Deplete to the burnup target (builds burnup/poison AND equilibrium xenon,
			# since Depletion.step now evolves the xenon chain at flux 1.0).
			if target > 0.0:
				var dt := target / 200.0
				for _s in 200:
					Depletion.step(peb, 1.0, dt)
			else:
				# Fresh top pebbles: seed their equilibrium xenon at operating flux so
				# the mix carries a realistic xenon load top-to-bottom.
				Depletion.seed_xenon(peb, PHI_OP)
			if not with_xenon:
				peb.xe135 = 0.0
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		row += 1
		y += spacing
	grid.homogenize(pebbles, positions)
	return grid


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1
