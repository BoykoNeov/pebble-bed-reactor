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
	if _failures == 0:
		print("\nALL CHECKS PASSED")
	else:
		print("\n%d CHECK(S) FAILED" % _failures)
	quit(_failures)


## Build a symmetric packed core (lattice of pebbles about the silo centerline)
## at the given enrichment, homogenize, and solve.
func _solve_core(enrichment: float) -> Dictionary:
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
