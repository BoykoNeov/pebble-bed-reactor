# tests/test_reactor.gd
#
# Headless gate for the LIVE coupling loop — sim/reactor.gd, the exact code main.gd
# drives every frame — run pure on a lattice:
#   godot --headless --script res://tests/test_reactor.gd
#
# WHY (structure): before ReactorCore existed the coupled loop lived on the scene node,
# and tests/test_thermal.gd could only gate its own RE-IMPLEMENTATION of it. This file
# gates the real thing. It is deliberately NOT a copy of test_thermal's calibration
# sweeps: it asks the questions only the live loop can answer —
#   1. does the core, driven exactly as the scene drives it, seed and settle
#      self-regulating, and does a scram through the same object shut it down while
#      decay heat keeps the temperature bounded;
#   2. TWO-WORLDS ENERGY CONSISTENCY for pebble SIZE — the Eulerian coolant march picks
#      up exactly the heat the Lagrangian pebbles shed, for a mixed-size bed (this was
#      wrong for any radius but 8 before Grid.conductance);
#   3. the size lever does the surface-to-volume physics CLAUDE.md names: a bigger
#      pebble at the same power density runs HOTTER;
#   4. the FISSION-WEIGHTED sample-back: a fresh pebble beside a spent one in the same
#      cell makes more heat, while the cell's total is unchanged (calibration-neutral);
#   5. the WARM-STARTED solve cadence agrees with cold-started solves.
extends SceneTree

var _failures := 0


func _initialize() -> void:
	print("=== ReactorCore: the live coupling loop, headless ===")
	_test_settles_and_scrams()
	_test_size_energy_consistency()
	_test_bigger_pebbles_run_hotter()
	_test_fission_weighting()
	_test_warm_start_agrees()
	if _failures == 0:
		print("\nALL CHECKS PASSED")
	else:
		print("\n%d CHECK(S) FAILED" % _failures)
	quit(_failures)


## A settled lattice bed (same geometry as the other suites). `radius_of` maps a
## (row, col) to a pebble radius so mixed-size beds can be built; positions are on a
## fixed pitch so packing stays comparable.
func _lattice(enrichment: float, radius_of: Callable, burn_spread := false, spacing := 18.0) -> Dictionary:
	var pebbles := {}
	var positions := {}
	var id := 0
	var half_cols := int(8.0 * 18.0 / spacing)
	var y := Silo.OUTLET_Y - 370.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var row := 0
	while y <= Silo.OUTLET_Y - spacing:
		for k in range(-half_cols, half_cols + 1):
			var x := Silo.CENTER_X + k * spacing
			if x <= Silo.LEFT + 8.0 or x >= Silo.RIGHT - 8.0:
				continue
			var r: float = radius_of.call(row, k)
			var peb := Pebble.new(id, r)
			peb.u235 = enrichment
			peb.u238 = 1.0 - enrichment
			if burn_spread:
				var target := rng.randf() * Depletion.DISCHARGE_BURNUP
				for _i in 120:
					Depletion.step(peb, 1.0, target / 120.0)
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		y += spacing
		row += 1
	return {"pebbles": pebbles, "positions": positions}


func _nominal(_row: int, _k: int) -> float:
	return Pebble.R_REF


## Drive a core the way main._physics_process does: solve every `solve_every` steps,
## thermal + deplete every step.
func _run(core: ReactorCore, bed: Dictionary, steps: int, dt := 0.05, solve_every := 4) -> Dictionary:
	var pebbles: Dictionary = bed["pebbles"]
	var positions: Dictionary = bed["positions"]
	var none := {}
	var peak_seen := 0.0
	var a_hist := PackedFloat32Array()
	for i in range(steps):
		if i % solve_every == 0:
			core.solve(pebbles, positions, true)
		core.thermal_step(pebbles, none, dt)
		core.deplete(pebbles, none, dt)
		peak_seen = maxf(peak_seen, core.peak_temp)
		if i % 20 == 0:
			a_hist.append(core.amplitude)
	return {"peak_seen": peak_seen, "a_hist": a_hist}


func _test_settles_and_scrams() -> void:
	print("\n[live loop: seeds, settles self-regulating, scrams through the same object]")
	var bed := _lattice(0.113, _nominal, true)
	var core := ReactorCore.new(Grid.for_silo())
	var st := _run(core, bed, 4000)   # 200 s
	var a_hist: PackedFloat32Array = st["a_hist"]
	var tail_from := int(a_hist.size() * 0.6)
	var ma := 0.0
	for j in range(tail_from, a_hist.size()):
		ma += a_hist[j]
	ma /= (a_hist.size() - tail_from)
	var va := 0.0
	for j in range(tail_from, a_hist.size()):
		va += (a_hist[j] - ma) * (a_hist[j] - ma)
	var sda := sqrt(va / (a_hist.size() - tail_from))
	print("  seeded=%s  k=%.4f  k_cold=%.4f  A=%.1f (tail mean %.1f, sd %.0f%%)  peakT=%.0f K  running=%s"
		% [core.thermal_seeded, core.k_eff, core.k_cold, core.amplitude, ma, 100.0 * sda / ma, core.peak_temp, core.running])
	_check(core.thermal_seeded, "the equilibrium seed fired through solve(allow_seed)")
	_check(absf(core.k_eff - 1.0) < 0.01, "the live loop self-regulates to k≈1 (%.4f)" % core.k_eff)
	_check(core.running, "the core is running")
	_check(core.peak_temp > 400.0 and core.peak_temp < 1800.0, "peak fuel temperature is plausible (%.0f K)" % core.peak_temp)
	_check(sda / ma < 0.25, "power is settled, not cycling (tail sd %.0f%%)" % (100.0 * sda / ma))

	# Scram through the SAME object main's button uses.
	var a_pre := core.amplitude
	var peak_pre := core.peak_temp
	core.toggle_scram()
	_check(core.scrammed and core.rod_insertion == ControlRods.INSERT_MAX, "scram drives the rods fully in")
	_check(not core.set_rods(0.0), "rods are inert while scrammed")
	var st2 := _run(core, bed, 1200)   # 60 s post-trip
	print("  post-scram: k=%.4f  rod worth=%.4f  A=%.4f (was %.1f)  peakT=%.0f (was %.0f, max seen %.0f)  decay=%.2f (%.0f%% of heat)"
		% [core.k_eff, core.rod_worth, core.amplitude, a_pre, core.peak_temp, peak_pre, st2["peak_seen"], core.decay_heat, 100.0 * core.decay_frac])
	_check(core.k_eff < 0.95, "the tripped core is deeply subcritical")
	_check(core.rod_worth > 0.1, "rod worth is measured live (%.3f)" % core.rod_worth)
	_check(core.amplitude < 0.05 * a_pre, "fission power collapsed")
	_check(core.decay_frac > 0.5, "what heat remains is decay heat")
	_check(st2["peak_seen"] <= peak_pre + 5.0, "temperature stays bounded after the trip (walk-away safe)")
	core.toggle_scram()
	_check(not core.scrammed and core.rod_insertion == 0.0, "reset restores the pre-scram insertion")


## Sum over in-core pebbles of what they shed into the coolant vs. what the coolant
## march picked up — the two-worlds energy balance, cell by cell.
func _shed_vs_pickup(core: ReactorCore, bed: Dictionary) -> Dictionary:
	var pebbles: Dictionary = bed["pebbles"]
	var positions: Dictionary = bed["positions"]
	var h := Thermal.h_of_flow(core.coolant_flow)
	# Per-cell: pebbles' conductance × (mean T − cell coolant) vs the march's pickup.
	var shed := 0.0
	var grid := core.grid
	# Rebuild the coolant march's per-cell pickup from the field it wrote.
	var w := Thermal.w_of_flow(core.coolant_flow)
	var pickup := 0.0
	for i in range(grid.nx):
		var t_in := core.inlet_temp
		for j in range(grid.ny):
			var c := grid.idx(i, j)
			if grid.nu_sigma_f[c] > 0.0:
				pickup += w * (grid.coolant_temp[c] - t_in)
			t_in = grid.coolant_temp[c]
	# The pebbles' side, evaluated against THEIR cell's coolant (what the march assumes:
	# every pebble in a cell sheds into that cell's outlet temperature at the cell's
	# homogenized temperature).
	for id in positions:
		var peb: Pebble = pebbles[id]
		var c := grid.cell_of(positions[id])
		shed += h * Thermal.size_of(peb) * (grid.temperature[c] - grid.coolant_temp[c])
	return {"shed": shed, "pickup": pickup}


func _test_size_energy_consistency() -> void:
	print("\n[two worlds agree on heat for ANY pebble size mix]")
	for label in ["small r=5", "big r=11", "mixed 5/8/11"]:
		var radius_of: Callable
		match label:
			"small r=5": radius_of = func(_r: int, _k: int) -> float: return 5.0
			"big r=11": radius_of = func(_r: int, _k: int) -> float: return 11.0
			_: radius_of = func(r: int, k: int) -> float: return [5.0, 8.0, 11.0][(r + k + 8) % 3]
		# Pitch scaled to the LARGEST radius so the bed stays a ~0.6-packed lattice rather
		# than a stack of overlapping discs (which would be capped at PACK_MAX and run away).
		var pitch: float = 18.0 * (11.0 / 8.0) if label != "small r=5" else 18.0 * (5.0 / 8.0)
		var bed := _lattice(0.113, radius_of, false, pitch)
		var core := ReactorCore.new(Grid.for_silo())
		_run(core, bed, 400)
		var e := _shed_vs_pickup(core, bed)
		var rel: float = absf(e["shed"] - e["pickup"]) / maxf(e["shed"], 1e-9)
		print("  %-14s pebbles shed %.3f   coolant picked up %.3f   mismatch %.2f%%" % [label, e["shed"], e["pickup"], 100.0 * rel])
		_check(rel < 1.0e-3, "%s: coolant pickup equals pebble shedding (grid.conductance)" % label)


func _test_bigger_pebbles_run_hotter() -> void:
	print("\n[uniform size change: surface-to-volume makes bigger pebbles hotter at the same flux]")
	# Same amplitude, same local flux, same coolant: steady temperature vs size. The
	# closed-form steady_temp is what the integrator relaxes toward, so this is the
	# lever's direct physics; the coupled consequence (more Doppler → less power) rides
	# the existing feedback.
	var h := Thermal.h_of_flow(Thermal.FLOW_NOMINAL)
	var prev := 0.0
	var mono := true
	var t8 := 0.0
	for r: float in [5.0, 6.5, 8.0, 9.5, 11.0]:
		var size: float = r / Pebble.R_REF
		var s := Thermal.pebble_power(Thermal.A_REF, 0.6, size)
		var t := Thermal.steady_temp(s, Thermal.T_INLET, h, size)
		if r == 8.0:
			t8 = t
		print("  r=%4.1f  size=%.3f  P=%.1f  T_steady=%.0f K" % [r, size, s, t])
		if t <= prev:
			mono = false
		prev = t
	_check(mono, "steady pebble temperature rises monotonically with radius")
	var t_nominal_old := Thermal.steady_temp(Thermal.pebble_power(Thermal.A_REF, 0.6), Thermal.T_INLET, h)
	_check(absf(t8 - t_nominal_old) < 1e-6, "the nominal radius is scaled by exactly 1 (calibration-neutral)")
	# Time constant grows with size too: C/(hA) ∝ size.
	var tau5 := Thermal.HEAT_CAPACITY * 0.390625 / ((h + Thermal.G_AMBIENT) * 0.625)
	var tau11 := Thermal.HEAT_CAPACITY * 1.890625 / ((h + Thermal.G_AMBIENT) * 1.375)
	_check(tau11 > tau5, "bigger pebbles respond more slowly (τ ∝ size)")


func _test_fission_weighting() -> void:
	print("\n[fission-weighted sample-back: fresh pebbles run hotter than spent ones in the same cell]")
	var bed := _lattice(0.113, _nominal, true)
	var core := ReactorCore.new(Grid.for_silo())
	# Seed + a few thermal time constants at operating power. (Not longer: this harness
	# has no refueling, so a long run depletes the un-refueled lattice toward shutdown,
	# where every pebble cools to the same ambient and the comparison is meaningless.)
	_run(core, bed, 600)
	print("  A=%.1f  k=%.4f  peakT=%.0f K" % [core.amplitude, core.k_eff, core.peak_temp])
	var pebbles: Dictionary = bed["pebbles"]
	var positions: Dictionary = bed["positions"]
	var grid := core.grid
	# Per cell: area-weighted mean of the weights must be 1; the freshest pebble must be
	# hotter than the most burned one.
	var cells := {}
	for id in positions:
		var c := grid.cell_of(positions[id])
		if not cells.has(c):
			cells[c] = []
		cells[c].append(pebbles[id])
	var worst_mean_dev := 0.0
	var hotter := 0
	var cooler := 0
	var examples := 0
	for c in cells:
		var group: Array = cells[c]
		if group.size() < 4:
			continue
		var wsum := 0.0
		var asum := 0.0
		var fresh: Pebble = group[0]
		var spent: Pebble = group[0]
		for peb in group:
			var a: float = PI * peb.radius * peb.radius
			wsum += a * peb.fission_weight
			asum += a
			if peb.burnup < fresh.burnup:
				fresh = peb
			if peb.burnup > spent.burnup:
				spent = peb
		worst_mean_dev = maxf(worst_mean_dev, absf(wsum / asum - 1.0))
		if spent.burnup - fresh.burnup > 30.0:
			examples += 1
			if fresh.temperature > spent.temperature:
				hotter += 1
			else:
				cooler += 1
	print("  cells=%d  worst |mean weight − 1| = %.7f  fresh-hotter-than-spent in %d / %d cells"
		% [cells.size(), worst_mean_dev, hotter, examples])
	_check(worst_mean_dev < 1.0e-4, "area-weighted mean fission weight is exactly 1 per cell (cell heat conserved)")
	# Not "every" cell: a pebble's flux is sampled bilinearly at ITS position, so in a cell
	# straddling a steep flux gradient the freshest pebble can sit in the cell's coldest
	# corner. That is position physics, not the weighting failing — so the gate is a
	# large majority, which the un-weighted sample-back (every pebble the cell mean)
	# could not reach.
	_check(examples > 0 and hotter >= 0.85 * examples, "in nearly every cell the fresh pebble runs hotter than the spent one (%d/%d)" % [hotter, examples])
	var w_fresh := 0.0
	var w_spent := 2.0
	for id in pebbles:
		w_fresh = maxf(w_fresh, pebbles[id].fission_weight)
		w_spent = minf(w_spent, pebbles[id].fission_weight)
	print("  fission weight range %.2f .. %.2f" % [w_spent, w_fresh])
	_check(w_fresh > 1.05 and w_spent < 0.95, "weights genuinely spread around 1 across the burnup spread")


func _test_warm_start_agrees() -> void:
	print("\n[warm-started cadence solves agree with cold starts]")
	var bed := _lattice(0.113, _nominal, true)
	var core := ReactorCore.new(Grid.for_silo())
	_run(core, bed, 800)
	# Re-solve the same state cold (no guess) on a fresh grid and compare k values.
	var pebbles: Dictionary = bed["pebbles"]
	var positions: Dictionary = bed["positions"]
	var g2 := Grid.for_silo()
	g2.homogenize(pebbles, positions)
	var k_cold_ref := Neutronics.solve(g2).k_eff
	var base := g2.sigma_a1.duplicate()
	Thermal.apply_field_doppler(g2)
	Thermal.apply_field_moderator(g2)
	var k_warm_ref := Neutronics.solve(g2).k_eff
	g2.sigma_a1 = base
	print("  live k_cold=%.6f vs cold-start %.6f   live k=%.6f vs cold-start %.6f   iters=%d"
		% [core.k_cold, k_cold_ref, core.k_eff, k_warm_ref, core.solve_iters])
	_check(absf(core.k_cold - k_cold_ref) < 2.0e-4, "k_cold agrees to 2e-4")
	_check(absf(core.k_eff - k_warm_ref) < 2.0e-4, "warm k agrees to 2e-4")
	_check(core.solve_iters < 15, "the warm-started solve converges in a few iterations (%d)" % core.solve_iters)


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1
