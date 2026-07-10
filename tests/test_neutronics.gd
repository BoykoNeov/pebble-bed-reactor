# tests/test_neutronics.gd
#
# Headless calibration + correctness gate for the M1 neutronics core. Runs pure
# (no scene, no physics) via:  godot --headless --script res://tests/test_neutronics.gd
#
# WHY this exists before any Godot wiring (advisor): the cross-section constants
# are toy/pixel-native, so we cannot know a priori what k-eff they produce. This
# test both PROVES the solver is right (symmetric core → symmetric positive flux)
# and DRIVES the tuning (enrichment sweep must raise k-eff; a nominal core must
# land k-eff ~ 1). Without it, "solver bug" and "coefficients need tuning" blur
# together and cost a day.
extends SceneTree

var _failures := 0


func _initialize() -> void:
	print("=== M1 neutronics calibration ===")
	_test_symmetry_and_positivity()
	_test_enrichment_monotonic()
	_test_nominal_keff()
	print("\n=== M5b two-group targets ===")
	_test_spectrum_peaks()
	_test_moderation_peak()
	_test_mtc_sign_flip()
	if _failures == 0:
		print("\nALL CHECKS PASSED")
	else:
		print("\n%d CHECK(S) FAILED" % _failures)
	quit(_failures)


## Build a symmetric packed core (lattice of pebbles about the silo centerline)
## at the given enrichment, homogenize, and solve.
func _solve_core(enrichment: float, fuel_loading := 1.0) -> Dictionary:
	var grid := Grid.for_silo()
	var pebbles := {}
	var positions := {}
	var id := 0
	# Lattice spacing chosen for ~0.6 packing (pi r^2 / s^2 with r=8, s=18).
	var spacing := 18.0
	var half_cols := 8                      # symmetric about CENTER_X by construction
	var y_top := Silo.OUTLET_Y - 370.0      # ~bed height for a few-hundred pebble pile
	var y := y_top
	while y <= Silo.OUTLET_Y - spacing:
		for k in range(-half_cols, half_cols + 1):
			var x := Silo.CENTER_X + k * spacing
			if x <= Silo.LEFT + 8.0 or x >= Silo.RIGHT - 8.0:
				continue
			var peb := Pebble.new(id, 8.0)
			# Toy heavy-metal split so grid._enrichment_of() reads back `enrichment`.
			peb.u235 = enrichment
			peb.u238 = 1.0 - enrichment
			peb.fuel_loading = fuel_loading   # M5b: sets the cell moderation ratio
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		y += spacing
	grid.homogenize(pebbles, positions)
	var sol := Neutronics.solve(grid)
	return {"grid": grid, "sol": sol, "pebbles": id}


func _test_symmetry_and_positivity() -> void:
	var r := _solve_core(CrossSections.E_REF)
	var grid: Grid = r.grid
	var sol: Neutronics.Solution = r.sol
	print("\n[symmetry] pebbles=%d  cells=%dx%d  k=%.4f  converged=%s  iters=%d"
		% [r.pebbles, grid.nx, grid.ny, sol.k_eff, sol.converged, sol.iterations])

	# Positivity: flux must be strictly >= 0 everywhere (solver clamps; assert it).
	var min_flux := INF
	for v in sol.flux:
		min_flux = minf(min_flux, v)
	_check(min_flux >= 0.0, "flux non-negative (min=%.5f)" % min_flux)

	# Left-right symmetry: grid has an odd column count centered on CENTER_X, so
	# flux[i,j] should mirror flux[nx-1-i,j] for a symmetric core.
	var max_asym := 0.0
	for j in grid.ny:
		for i in grid.nx:
			var a := sol.flux[j * grid.nx + i]
			var b := sol.flux[j * grid.nx + (grid.nx - 1 - i)]
			max_asym = maxf(max_asym, absf(a - b))
	_check(max_asym < 1.0e-3, "flux left-right symmetric (max asym=%.6f)" % max_asym)

	# Sanity: the flux should peak inside the fuel, not out in the reflector band.
	_check(_peak_is_in_fuel(grid, sol), "flux peaks inside the fuel region")


func _test_enrichment_monotonic() -> void:
	print("\n[enrichment sweep]")
	var prev_k := -INF
	var monotonic := true
	for e in [0.05, 0.07, 0.085, 0.11, 0.15]:
		var r := _solve_core(e)
		var k: float = r.sol.k_eff
		print("  e=%.3f  ->  k=%.4f" % [e, k])
		if k <= prev_k:
			monotonic = false
		prev_k = k
	_check(monotonic, "k-eff strictly increases with enrichment")


func _test_nominal_keff() -> void:
	var r := _solve_core(CrossSections.E_REF)
	var k: float = r.sol.k_eff
	print("\n[nominal] e=%.3f  k-eff=%.4f (target ~1.0)" % [CrossSections.E_REF, k])
	# Loose band: we only need it in the right ballpark for a critical-ish toy.
	_check(k > 0.85 and k < 1.20, "nominal k-eff in [0.85, 1.20]")


## Two-group SPECTRUM target: the fast flux (neutrons born in fission) must peak
## in the FUEL, while the thermal flux must peak out in the graphite REFLECTOR —
## fast neutrons leak into the reflector, slow down there (its strong down-scatter)
## and pile up because the reflector barely absorbs thermal neutrons. This is the
## reflector thermal peak that one-group can only fake; it is a defining reason to
## carry two groups at all (CLAUDE.md: "flux peaking near the reflector").
func _test_spectrum_peaks() -> void:
	var r := _solve_core(CrossSections.E_REF)
	var grid: Grid = r.grid
	var sol: Neutronics.Solution = r.sol
	var fast_c := _argmax(sol.flux_fast)
	var therm_c := _argmax(sol.flux_thermal)
	print("\n[spectrum] fast peak in %s   thermal peak in %s"
		% [_mat_name(grid.material[fast_c]), _mat_name(grid.material[therm_c])])
	_check(grid.material[fast_c] == CrossSections.FUEL, "fast flux peaks in the fuel")
	_check(grid.material[therm_c] == CrossSections.REFLECTOR, "thermal flux peaks in the reflector")


## Two-group MODERATION target (advisor): k_inf as a function of moderation M must
## PEAK, not saturate — under-moderated below the peak (dk/dM > 0), over-moderated
## above it (dk/dM < 0). That peak is the ONLY thing that lets the moderator-
## temperature coefficient flip sign (M5b feedback). Computed leakage-free straight
## from the cross-sections (k_inf = (νΣf1 + νΣf2·Σr/Σa2)/(Σa1+Σr)) so it isolates
## the parameterization from the solver. Nominal M = 1 must sit on the UNDER-
## moderated side, so the default core is stable and the player must dial moderation
## UP (fuel loading DOWN) to reach instability.
func _test_moderation_peak() -> void:
	print("\n[moderation sweep]  k_inf(M), pack=0.60, e=E_REF")
	var pack := 0.60
	var e := CrossSections.E_REF
	var ms := [0.5, 0.75, 1.0, 1.2, 1.5, 2.0, 3.0, 4.0]
	var ks := []
	for m in ms:
		var sa1 := CrossSections.sigma_a1_fuel(pack)
		var sa2 := CrossSections.sigma_a2_fuel(pack, 0.0, m)
		var sr := CrossSections.sigma_r_fuel(pack, m)
		var f1 := CrossSections.nu_sigma_f1(pack, e, 0.0)
		var f2 := CrossSections.nu_sigma_f2(pack, e, 0.0)
		var kinf: float = (f1 + f2 * sr / sa2) / (sa1 + sr)
		ks.append(kinf)
		print("  M=%.2f  ->  k_inf=%.4f" % [m, kinf])
	# Peaked (interior maximum): the max is neither the first nor the last sample.
	var peak_i := 0
	for i in range(ks.size()):
		if ks[i] > ks[peak_i]:
			peak_i = i
	_check(peak_i > 0 and peak_i < ks.size() - 1,
		"k_inf(M) peaks at an interior M (index %d of %d)" % [peak_i, ks.size()])
	# Nominal M = 1 (index 2) must be on the UNDER-moderated (rising) side of the peak.
	_check(peak_i >= 2 and ks[2] < ks[peak_i],
		"nominal M=1 is under-moderated (below the peak)")
	# And the over-moderated fall must be a REAL drop, not a rounding wiggle — the
	# instability needs a coefficient the player can feel.
	_check(ks[ks.size() - 1] < ks[peak_i] - 0.05,
		"k_inf falls appreciably on the over-moderated side (%.3f < %.3f)"
			% [ks[ks.size() - 1], ks[peak_i]])


## The M5b HEADLINE (CLAUDE.md validation target): the moderator-temperature
## coefficient FLIPS SIGN across the k_inf(M) peak. Driven by PEBBLE (graphite)
## temperature (Feedback.moderator_m_eff → Thermal.apply_field_moderator rescaling
## Σr/Σa2), the reactivity response to heating the graphite is NEGATIVE for an
## under-moderated core (self-stabilizing) but POSITIVE for an over-moderated one (the
## accidental runaway). Proven STATICALLY here — isolated from the coupled thermal
## dynamics (advisor) — by warm-solving the SAME core at a cold vs a hot uniform pebble
## temperature with Doppler OFF. Holds at ANY positive MTC_C: this pins the SIGN; the magnitude that
## makes the live core visibly destabilize is tuned separately against the sim.
func _test_mtc_sign_flip() -> void:
	print("\n[moderator-temperature coefficient: emergent sign across the peak]")
	var t_hot := 900.0
	# Under-moderated design: fuel_loading 1.0 → M = 1.0, below the k_inf peak (~1.2).
	var ku_cold := _mtc_k(1.0, Feedback.T_REF)
	var ku_hot := _mtc_k(1.0, t_hot)
	print("  under-moderated (M=1.00): k(cold)=%.5f  k(hot)=%.5f  dk=%+.5f"
		% [ku_cold, ku_hot, ku_hot - ku_cold])
	_check(ku_hot < ku_cold - 1.0e-4,
		"under-moderated core: hotter graphite LOWERS k (negative MTC → stable)")
	# Over-moderated design: fuel_loading 0.6 → M ≈ 1.67, above the peak.
	var ko_cold := _mtc_k(0.6, Feedback.T_REF)
	var ko_hot := _mtc_k(0.6, t_hot)
	print("  over-moderated  (M=1.67): k(cold)=%.5f  k(hot)=%.5f  dk=%+.5f"
		% [ko_cold, ko_hot, ko_hot - ko_cold])
	_check(ko_hot > ko_cold + 1.0e-4,
		"over-moderated core: hotter graphite RAISES k (positive MTC → unstable)")


## Warm k_eff of a core at design moderation `fuel_loading` with a uniform PEBBLE
## (graphite) temperature `t_peb` driving the MTC, Doppler OFF (fuel absorption left
## cold) so ONLY the moderator coefficient moves k. At t_peb = T_REF the MTC is a
## no-op, giving the design-M reference k; a hotter t_peb lowers M_eff and shifts k by
## an amount whose SIGN is set by which side of the k_inf(M) peak the design M sits on.
func _mtc_k(fuel_loading: float, t_peb: float) -> float:
	var r := _solve_core(CrossSections.E_REF, fuel_loading)
	var grid: Grid = r.grid
	grid.temperature.fill(t_peb)
	Thermal.apply_field_moderator(grid)
	return Neutronics.solve(grid).k_eff


func _argmax(field: PackedFloat32Array) -> int:
	var best := -INF
	var best_c := 0
	for c in range(field.size()):
		if field[c] > best:
			best = field[c]
			best_c = c
	return best_c


func _mat_name(m: int) -> String:
	match m:
		CrossSections.FUEL: return "FUEL"
		CrossSections.REFLECTOR: return "REFLECTOR"
		_: return "VOID"


func _peak_is_in_fuel(grid: Grid, sol: Neutronics.Solution) -> bool:
	var peak := -INF
	var peak_c := -1
	for c in range(grid.cell_count()):
		if sol.flux[c] > peak:
			peak = sol.flux[c]
			peak_c = c
	return peak_c >= 0 and grid.material[peak_c] == CrossSections.FUEL


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1
