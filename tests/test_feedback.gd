# tests/test_feedback.gd
#
# Headless calibration + correctness gate for the M2 Doppler feedback core. Runs
# pure (no scene, no physics) via:
#   godot --headless --script res://tests/test_feedback.gd
#
# WHY (mirrors test_neutronics.gd): the Doppler strength is a toy, pixel-native
# constant, so we cannot know a priori what temperature the nominal core settles
# at. This test both PROVES the feedback is right (sign, monotonicity, k pinned
# to 1 when regulating, passive shutdown when subcritical) and DRIVES the tuning
# (DOPPLER_C must land the nominal equilibrium at a plausible fuel temperature).
extends SceneTree

var _failures := 0


func _initialize() -> void:
	print("=== M2 Doppler feedback calibration ===")
	_test_doppler_sign_and_monotonic()
	_test_keff_falls_with_temperature()
	_test_nominal_regulates()
	_test_enrichment_raises_power_at_flat_reactivity()
	_test_feedback_insufficient()
	_test_subcritical_shuts_down()
	if _failures == 0:
		print("\nALL CHECKS PASSED")
	else:
		print("\n%d CHECK(S) FAILED" % _failures)
	quit(_failures)


## Symmetric packed core at `enrichment`, homogenized and ready to solve.
## (Same lattice as test_neutronics.gd so the two calibrations share a core.)
func _build_core(enrichment: float) -> Grid:
	var grid := Grid.for_silo()
	var pebbles := {}
	var positions := {}
	var id := 0
	var spacing := 18.0
	var half_cols := 8
	var y_top := Silo.OUTLET_Y - 370.0
	var y := y_top
	while y <= Silo.OUTLET_Y - spacing:
		for k in range(-half_cols, half_cols + 1):
			var x := Silo.CENTER_X + k * spacing
			if x <= Silo.LEFT + 8.0 or x >= Silo.RIGHT - 8.0:
				continue
			var peb := Pebble.new(id, 8.0)
			peb.u235 = enrichment
			peb.u238 = 1.0 - enrichment
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		y += spacing
	grid.homogenize(pebbles, positions)
	return grid


func _test_doppler_sign_and_monotonic() -> void:
	print("\n[doppler correlation]")
	# Zero at/below reference, strictly increasing above it — a NEGATIVE reactivity
	# feedback (more absorption as T rises).
	_check(Feedback.doppler_sigma_a(Feedback.T_REF) == 0.0, "doppler is zero at T_REF")
	_check(Feedback.doppler_sigma_a(Feedback.T_REF - 100.0) == 0.0, "doppler is zero below T_REF")
	var prev := -1.0
	var monotonic := true
	for t in [300.0, 500.0, 800.0, 1200.0]:
		var d := Feedback.doppler_sigma_a(t)
		if d <= prev:
			monotonic = false
		prev = d
	_check(monotonic, "doppler absorption strictly increases with temperature")


func _test_keff_falls_with_temperature() -> void:
	# The heart of the coefficient: heating the fuel (uniform temperature sweep)
	# must LOWER k-eff. Bypasses the search — drives temperature directly.
	print("\n[k-eff vs uniform fuel temperature]")
	var grid := _build_core(CrossSections.E_REF)
	var base_sa := grid.sigma_a1.duplicate()   # M5b: Doppler lands on the fast group
	var prev_k := INF
	var monotonic := true
	for t in [293.15, 500.0, 800.0, 1200.0]:
		for c in range(grid.cell_count()):
			grid.sigma_a1[c] = base_sa[c] + Feedback.doppler_sigma_a(t)
		var sol := Neutronics.solve(grid)
		print("  T=%.1f K  ->  k=%.4f" % [t, sol.k_eff])
		if sol.k_eff >= prev_k:
			monotonic = false
		prev_k = sol.k_eff
	_check(monotonic, "k-eff strictly decreases as fuel temperature rises (negative coefficient)")


func _test_nominal_regulates() -> void:
	# The self-regulation target: a cold-supercritical nominal core must find a
	# critical equilibrium — k pinned to ~1 at a PLAUSIBLE fuel temperature.
	print("\n[nominal self-regulation]")
	var grid := _build_core(CrossSections.E_REF)
	var eq := Feedback.solve_equilibrium(grid)
	var peak_t := Feedback.T_REF + eq.peak_dt
	print("  k_cold=%.4f  ->  regulated k=%.4f  peak fuel T=%.0f K (dT %.0f)  iters=%d"
		% [eq.k_cold, eq.k_eff, peak_t, eq.peak_dt, eq.iterations])
	_check(eq.regulated, "nominal core regulates (is cold-supercritical)")
	_check(absf(eq.k_eff - 1.0) < Feedback.K_TOL, "regulated k pinned to ~1.0")
	_check(eq.iterations < Feedback.MAX_ITERS, "search converged before hitting iteration cap")
	# Plausibility: hot fuel, not molten and not merely warm. HTR-PM fuel runs
	# ~600-1000 C; a toy equilibrium anywhere in a few-hundred-to-~1500 K band is fine.
	_check(peak_t > 450.0 and peak_t < 1500.0, "equilibrium fuel temperature is physically plausible")
	# Flux must stay well-behaved under feedback (advisor): positive and symmetric.
	var min_flux := INF
	for v in eq.flux:
		min_flux = minf(min_flux, v)
	_check(min_flux >= 0.0, "flux non-negative under feedback (min=%.5f)" % min_flux)
	var max_asym := 0.0
	for j in grid.ny:
		for i in grid.nx:
			var a := eq.flux[j * grid.nx + i]
			var b := eq.flux[j * grid.nx + (grid.nx - 1 - i)]
			max_asym = maxf(max_asym, absf(a - b))
	_check(max_asym < 1.0e-3, "flux left-right symmetric under feedback (max asym=%.6f)" % max_asym)


func _test_enrichment_raises_power_at_flat_reactivity() -> void:
	# The headline behavior: more reactive fuel does NOT run away — it self-limits
	# at HIGHER power (hotter) while k stays pinned at ~1. Roughly flat reactivity,
	# rising power — the online-refueling / self-regulation story.
	#
	# Steps are SMALL and near nominal on purpose: enrichment is a steep reactivity
	# lever (dk/de is large), and Doppler is a WEAK fine feedback. A few tenths of a
	# percent enrichment already moves cold k by ~1%, which Doppler burns off at a
	# plausible temperature. Large enrichment jumps overwhelm Doppler — that is the
	# feedback_insufficient regime covered by _test_feedback_insufficient().
	print("\n[enrichment -> power, reactivity flat]")
	var prev_dt := -1.0
	var rising := true
	var all_pinned := true
	for e in [0.085, 0.086, 0.087]:
		var grid := _build_core(e)
		var eq := Feedback.solve_equilibrium(grid)
		print("  e=%.3f  k_cold=%.4f  reg k=%.4f  peak dT=%.0f  power=%.0f"
			% [e, eq.k_cold, eq.k_eff, eq.peak_dt, eq.power])
		if not eq.regulated or eq.feedback_insufficient or absf(eq.k_eff - 1.0) >= Feedback.K_TOL:
			all_pinned = false
		if eq.peak_dt <= prev_dt:
			rising = false
		prev_dt = eq.peak_dt
	_check(all_pinned, "k stays pinned at ~1.0 across a small enrichment range")
	_check(rising, "equilibrium power (peak dT) rises with enrichment")


func _test_feedback_insufficient() -> void:
	# A large enrichment jump puts far more excess reactivity in the core than
	# Doppler can burn at any plausible temperature. The search must run out of
	# temperature headroom and FLAG it (feedback_insufficient) rather than falsely
	# claiming a critical equilibrium — the "you need control rods" teaching signal.
	print("\n[feedback insufficient — excess reactivity beyond Doppler]")
	var grid := _build_core(0.12)   # cold k well above 1 (M1 sweep: ~1.4)
	var eq := Feedback.solve_equilibrium(grid)
	print("  e=0.120  k_cold=%.4f  reg k=%.4f  peak dT=%.0f  insufficient=%s"
		% [eq.k_cold, eq.k_eff, eq.peak_dt, eq.feedback_insufficient])
	_check(eq.regulated, "core is cold-supercritical (feedback engaged)")
	_check(eq.feedback_insufficient, "flags feedback insufficient when Doppler cannot pin k=1")
	_check(eq.k_eff > 1.0, "reports the residual supercriticality honestly")


func _test_subcritical_shuts_down() -> void:
	# A cold-subcritical core has no critical power: feedback can only lower k, so
	# it must regulate to ZERO power (passive shutdown), not report a bogus level.
	print("\n[subcritical passive shutdown]")
	var grid := _build_core(0.05)   # e=0.05 is cold-subcritical (M1 sweep: k~0.59)
	var eq := Feedback.solve_equilibrium(grid)
	print("  e=0.050  k_cold=%.4f  regulated=%s  power=%.1f" % [eq.k_cold, eq.regulated, eq.power])
	_check(not eq.regulated, "subcritical core does not regulate")
	_check(eq.power == 0.0 and eq.peak_dt == 0.0, "subcritical core settles at zero power (shutdown)")


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1
