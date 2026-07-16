# tests/test_control_rods.gd
#
# Headless calibration + correctness gate for the M5d control rods. Runs pure
# (no scene, no physics) via:
#   godot --headless --script res://tests/test_control_rods.gd
#
# WHY these particular checks (mirrors test_neutronics / test_xenon): ROD_SIGMA_A2 is
# a toy, pixel-native constant, so its absolute value means nothing. What carries
# meaning is that the rods behave like rods:
#
#   1. THE LOAD-BEARING ONE — fully withdrawn, they change NOTHING. Every calibration
#      this project fought for (A_REF, the operating point, the whole suite) predates
#      the rods, so a withdrawn rod must be provably, exactly inert. Not "close" — the
#      same cross-sections and the same k, bit for bit.
#   2. They sit where they bite: the reflector columns against the wall, which is where
#      the THERMAL flux peaks in this two-group model. Placement is asserted against
#      the measured flux, not against a hardcoded column index.
#   3. Worth is positive and monotone in insertion, and it is EMERGENT — nothing in
#      sim/control_rods.gd names a worth; it is whatever the eigenproblem charges.
#   4. THE S-CURVE: differential worth tracks the local thermal flux the rod tip is
#      passing through — small beside the void above the bed, largest crossing the
#      bed's flux peak. This is the classic rod-worth curve, and here it is a
#      CONSEQUENCE of the flux profile rather than a shape anyone coded.
#   5. THE HEADLINE — rods hold a core Doppler alone cannot. This is the milestone's
#      entire reason to exist: main.gd has always been able to print "OVER-TEMP —
#      Doppler can't hold" while offering no way out. Now there is one.
#
# NOTE on what this does NOT claim: rod worth here is bounded (two reflector banks
# saturate — see _test_worth_saturates), so a sufficiently over-reactive core is still
# beyond them. That is honest: real reflector rods have finite worth too, which is why
# HTR-PM carries a second, independent shutdown system.
extends SceneTree

var _failures := 0

# Mirrors main.gd's over-temp line (as test_depletion / test_xenon do).
const OVER_TEMP_K := 1800.0

# An enrichment whose ALL-FRESH core is genuinely beyond Doppler: k_cold ~ 1.10 and the
# critical-power search saturates DT_MAX (peak fuel ~4293 K, feedback_insufficient).
# Still plainly LEU (CLAUDE.md: keep it civilian). This is not a contrived number — a
# freshly-loaded core carrying its full excess reactivity is exactly the situation real
# operators hold down with rods and then withdraw as the fuel burns in.
const HOT_ENRICH := 0.093
# The nominal, Doppler-holdable core (test_neutronics' calibrated lattice point).
const NOMINAL_ENRICH := 0.085


func _initialize() -> void:
	print("=== M5d control-rod calibration ===")
	_test_zero_insertion_is_inert()
	_test_rods_only_touch_their_columns()
	_test_placement_is_where_the_thermal_flux_peaks()
	_test_worth_positive_and_monotone()
	_test_s_curve_tracks_local_flux()
	_test_worth_saturates()
	_test_rods_hold_a_core_doppler_cannot()
	_test_full_insertion_shuts_down_a_critical_core()
	if _failures == 0:
		print("\nALL CHECKS PASSED")
	else:
		print("\n%d CHECK(S) FAILED" % _failures)
	quit(_failures)


# --- 1. Calibration neutrality ----------------------------------------------

## Fully withdrawn rods must be EXACTLY inert — not approximately. This is the
## property that lets M5d land on top of four milestones of hard-won calibration
## without re-tuning any of it, so it is asserted bit-for-bit rather than with a
## tolerance: a tolerance would hide precisely the kind of small, everywhere drift
## that silently moves an operating point.
func _test_zero_insertion_is_inert() -> void:
	var grid := _core(NOMINAL_ENRICH)
	var before := grid.sigma_a2.duplicate()
	var k_before := Neutronics.solve(grid).k_eff
	ControlRods.apply_rods(grid, 0.0)
	var identical := true
	for c in range(grid.cell_count()):
		if grid.sigma_a2[c] != before[c]:
			identical = false
			break
	var k_after := Neutronics.solve(grid).k_eff
	print("\n[inert] k %.8f -> %.8f   sigma_a2 untouched=%s" % [k_before, k_after, str(identical)])
	_check(identical, "withdrawn rods leave sigma_a2 bit-for-bit unchanged")
	_check(k_after == k_before, "withdrawn rods leave k-eff exactly unchanged")


## The rods live in the reflector and must never reach into the fuel — the property
## that keeps the Lagrangian/pebble world (and every per-pebble calibration) untouched
## by construction. Checks the columns the rod does NOT occupy are all untouched.
func _test_rods_only_touch_their_columns() -> void:
	var grid := _core(NOMINAL_ENRICH)
	var before := grid.sigma_a2.duplicate()
	var cols := ControlRods.rod_columns(grid)
	ControlRods.apply_rods(grid, 1.0)
	var stray := 0
	var fuel_touched := 0
	for j in range(grid.ny):
		for i in range(grid.nx):
			var c := grid.idx(i, j)
			if grid.sigma_a2[c] == before[c]:
				continue
			if not (i in cols):
				stray += 1
			if grid.material[c] == CrossSections.FUEL:
				fuel_touched += 1
	print("\n[placement] rod columns %s of %d   stray cells=%d   fuel cells touched=%d"
		% [str(cols), grid.nx, stray, fuel_touched])
	_check(cols.size() == 2, "one rod bank per side (%d)" % cols.size())
	_check(stray == 0, "rods perturb only their own columns")
	_check(fuel_touched == 0, "rods never absorb inside the FUEL — they are reflector rods")


# --- 2. Placement is justified by the flux, not by a magic index --------------

## The rod columns must be the reflector columns where the THERMAL flux is highest —
## that is the whole physical argument for reflector rods in a pebble bed, and it is
## only true because two-group diffusion piles thermal flux up in the graphite
## (test_neutronics _test_spectrum_peaks). Asserted against the SOLVED flux so that a
## change to the band width or the cross-sections that moved the peak would fail here
## rather than silently leaving the rods parked somewhere useless.
func _test_placement_is_where_the_thermal_flux_peaks() -> void:
	var grid := _core(NOMINAL_ENRICH)
	var sol := Neutronics.solve(grid)
	var cols := ControlRods.rod_columns(grid)
	var rod_peak := 0.0
	var fuel_peak := 0.0
	var other_refl_peak := 0.0
	for i in range(grid.nx):
		for j in range(grid.ny):
			var c := grid.idx(i, j)
			var v := sol.flux_thermal[c]
			if i in cols:
				rod_peak = maxf(rod_peak, v)
			elif grid.material[c] == CrossSections.FUEL:
				fuel_peak = maxf(fuel_peak, v)
			elif grid.material[c] == CrossSections.REFLECTOR:
				other_refl_peak = maxf(other_refl_peak, v)
	print("\n[thermal peak] rod columns=%.2f   fuel=%.2f   other reflector=%.2f"
		% [rod_peak, fuel_peak, other_refl_peak])
	_check(rod_peak > fuel_peak,
		"rod columns see MORE thermal flux than the fuel (%.2f > %.2f)" % [rod_peak, fuel_peak])
	_check(rod_peak > other_refl_peak,
		"rod columns are the BEST reflector columns (%.2f > %.2f)" % [rod_peak, other_refl_peak])


# --- 3. Worth: positive, monotone, emergent ----------------------------------

## k must fall monotonically as the rods go in. Monotonicity is what makes the lever
## trustworthy: a non-monotone worth curve would mean pushing a rod further in could
## ADD reactivity, which no operator (or player) could reason about.
func _test_worth_positive_and_monotone() -> void:
	var curve := _worth_curve(NOMINAL_ENRICH, 20)
	var monotone := true
	for n in range(1, curve.size()):
		if curve[n].worth <= curve[n - 1].worth:
			monotone = false
	print("\n[worth] insertion 0.25/0.50/0.75/1.00 -> %.4f / %.4f / %.4f / %.4f Dk"
		% [curve[5].worth, curve[10].worth, curve[15].worth, curve[20].worth])
	_check(curve[20].worth > 0.0, "full insertion has positive worth (%.4f)" % curve[20].worth)
	_check(monotone, "worth increases monotonically with insertion (no dead or inverted band)")


## THE S-CURVE. Differential worth must track the thermal flux the rod TIP is moving
## through: nearly flat while the tip is beside the void above the bed (no fuel there to
## starve), steepest as it crosses the bed where the thermal flux peaks, tapering past
## it. Nothing in control_rods.gd encodes this shape — it falls out of the flux profile,
## which is exactly why it is worth asserting.
##
## Asserted as ORDERINGS (advisor), not as a fit to a textbook S: the bed here sits low
## in the silo and is refueled from the top, so the curve is not symmetric and never
## needed to be. What must hold is that the steep part is where the flux is.
func _test_s_curve_tracks_local_flux() -> void:
	var grid := _core(NOMINAL_ENRICH)
	var sol := Neutronics.solve(grid)
	var cols := ControlRods.rod_columns(grid)
	# The row where the rod column's own thermal flux peaks — the row worth the most.
	var flux_peak_row := 0
	var best := -1.0
	for j in range(grid.ny):
		var v := sol.flux_thermal[grid.idx(cols[0], j)]
		if v > best:
			best = v
			flux_peak_row = j
	# The rows that actually hold fuel.
	var fuel_top := grid.ny
	var fuel_bottom := -1
	for j in range(grid.ny):
		for i in range(grid.nx):
			if grid.material[grid.idx(i, j)] == CrossSections.FUEL:
				fuel_top = mini(fuel_top, j)
				fuel_bottom = maxi(fuel_bottom, j)

	var curve := _worth_curve(NOMINAL_ENRICH, 20)
	# Differential worth per step, and the tip row where it is largest.
	var peak_dw := -1.0
	var peak_dw_tip := 0.0
	for n in range(1, curve.size()):
		var dw: float = curve[n].worth - curve[n - 1].worth
		if dw > peak_dw:
			peak_dw = dw
			peak_dw_tip = curve[n].tip_row
	# Mean differential worth in the lead-in (tip above the fuel) vs crossing the bed.
	var lead := _mean_dw(curve, 0, float(fuel_top))
	var cross := _mean_dw(curve, float(fuel_top), float(fuel_bottom) + 1.0)
	print("\n[S-curve] fuel rows %d-%d   thermal-flux peak row %d   dW peak at tip row %.1f"
		% [fuel_top, fuel_bottom, flux_peak_row, peak_dw_tip])
	print("          mean dW: lead-in (above bed)=%.4f   crossing bed=%.4f   ratio=%.1fx"
		% [lead, cross, cross / maxf(lead, 1e-9)])
	_check(cross > 2.0 * lead,
		"worth per step is much larger crossing the bed than above it (%.1fx) — the S" % (cross / maxf(lead, 1e-9)))
	_check(peak_dw_tip >= float(fuel_top) and peak_dw_tip <= float(fuel_bottom) + 1.0,
		"differential worth peaks with the tip in the fuel (row %.1f in %d-%d)" % [peak_dw_tip, fuel_top, fuel_bottom])
	_check(absf(peak_dw_tip - float(flux_peak_row)) <= 2.0,
		"differential-worth peak coincides with the thermal-flux peak (tip %.1f vs flux row %d)"
		% [peak_dw_tip, flux_peak_row])


## Worth SATURATES in absorber strength: past a point the rod is already black to
## thermal neutrons and more absorber buys almost nothing. Two consequences worth
## pinning: (a) ROD_SIGMA_A2 sits on the plateau, so the milestone does not rest on a
## precisely-tuned constant — a factor-of-2 error in it barely moves the worth; and
## (b) rod worth is BOUNDED, which is why a hot enough core stays beyond them.
func _test_worth_saturates() -> void:
	var weak := _full_worth_at(0.03)
	var chosen := _full_worth_at(ControlRods.ROD_SIGMA_A2)
	var double := _full_worth_at(ControlRods.ROD_SIGMA_A2 * 2.0)
	var quad := _full_worth_at(ControlRods.ROD_SIGMA_A2 * 4.0)
	print("\n[saturation] full-insertion worth vs strength: 0.03=%.4f  %.2f=%.4f  x2=%.4f  x4=%.4f"
		% [weak, ControlRods.ROD_SIGMA_A2, chosen, double, quad])
	_check(double - chosen < 0.5 * (chosen - weak),
		"worth is on the saturated plateau: doubling ROD_SIGMA_A2 adds little (+%.4f)" % (double - chosen))
	_check(quad < chosen * 1.35,
		"even 4x the absorber cannot run worth away (%.4f < %.4f) — rod worth is bounded"
		% [quad, chosen * 1.35])


# --- 4. The headline ---------------------------------------------------------

## THE MILESTONE TEST. A freshly-loaded LEU core whose excess reactivity is beyond
## Doppler — the critical-power search saturates DT_MAX and raises feedback_insufficient,
## i.e. "there is no fuel temperature at which this core is critical". main.gd surfaces
## exactly this as "OVER-TEMP — Doppler can't hold". Rods must turn it into a core that
## has a critical equilibrium at a sane temperature.
##
## SCOPE THIS CLAIM HONESTLY (advisor). This runs through Feedback.solve_equilibrium —
## the M2 QUASI-STATIC critical-power search, which main.gd does NOT use in its running
## loop (it integrates dynamic point-kinetics instead; solve_equilibrium survives only as
## the startup seed). So what is proven here is that a critical equilibrium EXISTS with
## rods in — a real neutronics statement, and the one the over-temp condition is about —
## but NOT that the live dynamic loop settles onto it. That distinction has bitten this
## project before: a fine-looking equilibrium coexisting with a relaxation limit cycle is
## exactly the A_REF story (see sim/thermal.gd's A_REF comment).
##
## Why it is nonetheless expected to hold dynamically: the rescued core sits at k_cold
## ~1.007 and peak ~543 K — COOLER and LOWER power than the nominal operating point whose
## dynamic stability is already verified live (~1100 K), and every limit cycle this
## project has hit was a HIGH-power_frac failure. A rod-trimmed core moves AWAY from that
## regime. Plausible, not confirmed; the rod WIRING into the live loop is separately and
## directly proven by tests/live_rods.gd.
##
## Searches for a rescuing rod position rather than asserting a hardcoded one: the claim
## that matters is "a position EXISTS that holds this core", which stays true (and stays
## meaningful) under calibration drift, whereas "0.45 works" would be brittle and would
## assert less.
func _test_rods_hold_a_core_doppler_cannot() -> void:
	var bare := Feedback.solve_equilibrium(_core(HOT_ENRICH))
	var bare_peak := Feedback.T_REF + bare.peak_dt
	print("\n[headline] fresh %.1f%% core, NO rods: k_cold=%.4f  peak=%.0f K  insufficient=%s"
		% [HOT_ENRICH * 100.0, bare.k_cold, bare_peak, str(bare.feedback_insufficient)])
	_check(bare.feedback_insufficient, "the bare core is genuinely beyond Doppler (feedback_insufficient)")
	_check(bare_peak >= OVER_TEMP_K, "the bare core is over-temp (%.0f K >= %.0f K)" % [bare_peak, OVER_TEMP_K])

	# Sweep the stroke for positions that hold it: critical, Doppler coping, sane temperature.
	var good: Array = []
	for step in range(0, 21):
		var ins := float(step) * 0.05
		var g := _core(HOT_ENRICH)
		ControlRods.apply_rods(g, ins)
		var eq := Feedback.solve_equilibrium(g)
		var peak := Feedback.T_REF + eq.peak_dt
		if eq.regulated and not eq.feedback_insufficient and peak < OVER_TEMP_K and eq.power > 0.0:
			good.append({"ins": ins, "k_cold": eq.k_cold, "peak": peak, "k": eq.k_eff})
	if good.is_empty():
		print("          NO rod position holds this core")
	else:
		for g in good:
			print("          rods %.0f%% in -> k_cold=%.4f  regulated k=%.4f  peak=%.0f K"
				% [g.ins * 100.0, g.k_cold, g.k, g.peak])
	_check(not good.is_empty(),
		"a rod position EXISTS that holds a core Doppler alone cannot — the milestone")
	if not good.is_empty():
		# It must still be a POWER reactor at that position, not merely "not over-temp"
		# because it shut down. Doppler is doing the regulating; the rods just brought the
		# excess into its reach — that is the division of labour the milestone teaches.
		var best: Dictionary = good[0]
		_check(absf(best.k - 1.0) < 0.01,
			"the rescued core is CRITICAL (k=%.4f), i.e. still generating — not shut down" % best.k)
		_check(best.peak > Feedback.T_REF + 50.0,
			"the rescued core is genuinely at power (peak %.0f K, well above inlet)" % best.peak)


## The other end of the lever: driving the rods fully in must shut down a core that is
## otherwise happily critical. Without this, "control rod" would be an overstatement —
## a lever that can only trim is not a shutdown mechanism.
##
## SINCE THE SCRAM UNIFICATION this is also the SCRAM's calibration gate, because a full
## insertion is exactly what scram now does (main._toggle_scram; Thermal.SCRAM_WORTH is
## deleted). The margin checked below — k 1.0091 → 0.6247, worth 0.3845 — IS the trip's
## worth, replacing the hand-tuned 0.15 constant with a number the eigenvalue solve
## produces. It is 2.5× deeper than the constant was, so the trip got stronger, not weaker.
func _test_full_insertion_shuts_down_a_critical_core() -> void:
	var bare := Neutronics.solve(_core(NOMINAL_ENRICH)).k_eff
	var g := _core(NOMINAL_ENRICH)
	ControlRods.apply_rods(g, 1.0)
	var rodded := Neutronics.solve(g).k_eff
	var eq := Feedback.solve_equilibrium(g)
	print("\n[shutdown] nominal core k %.4f -> %.4f fully rodded (worth %.4f)   regulated=%s"
		% [bare, rodded, bare - rodded, str(eq.regulated)])
	_check(bare > 1.0, "the unrodded nominal core really is supercritical (%.4f)" % bare)
	_check(rodded < 1.0, "fully inserted rods drive it subcritical (%.4f)" % rodded)
	_check(not eq.regulated, "a fully rodded core has no critical power — it is shut down")
	# Shutdown MARGIN, not just a hair below 1: a rod bank that lands at 0.999 would be
	# useless in practice and would flicker back critical on any small state change.
	_check(rodded < 0.95, "and with real margin (%.4f < 0.95), not marginally" % rodded)


# --- helpers -----------------------------------------------------------------

## Worth curve: [{ins, tip_row, k, worth}] over `steps` insertion steps. Worth is
## measured against the SAME core with rods out, so it isolates the rods.
func _worth_curve(enrichment: float, steps: int) -> Array:
	var grid := _core(enrichment)
	var base := grid.sigma_a2.duplicate()
	var k0 := Neutronics.solve(grid).k_eff
	var out: Array = []
	for n in range(steps + 1):
		var ins := float(n) / float(steps)
		grid.sigma_a2 = base.duplicate()
		ControlRods.apply_rods(grid, ins)
		var k := Neutronics.solve(grid).k_eff
		out.append({"ins": ins, "tip_row": ins * float(grid.ny), "k": k, "worth": k0 - k})
	return out


## Mean differential worth per step over the tip-row window [row_lo, row_hi).
func _mean_dw(curve: Array, row_lo: float, row_hi: float) -> float:
	var sum := 0.0
	var n := 0
	for i in range(1, curve.size()):
		var tip: float = curve[i].tip_row
		if tip > row_lo and tip <= row_hi:
			sum += curve[i].worth - curve[i - 1].worth
			n += 1
	return sum / float(n) if n > 0 else 0.0


## Full-insertion worth at an arbitrary absorber strength (mirrors apply_rods, but with
## the strength as a parameter so saturation can be probed without touching the const).
func _full_worth_at(strength: float) -> float:
	var grid := _core(NOMINAL_ENRICH)
	var k0 := Neutronics.solve(grid).k_eff
	for i in ControlRods.rod_columns(grid):
		for j in range(grid.ny):
			var w := ControlRods.rod_weight(grid, j, 1.0)
			if w <= 0.0:
				break
			grid.sigma_a2[grid.idx(i, j)] += strength * w
	return k0 - Neutronics.solve(grid).k_eff


## The calibrated symmetric lattice (same construction as test_neutronics._solve_core),
## homogenized and ready to solve.
func _core(enrichment: float, fuel_loading := 1.0) -> Grid:
	var grid := Grid.for_silo()
	var pebbles := {}
	var positions := {}
	var id := 0
	var spacing := 18.0
	var half_cols := 8
	var y := Silo.OUTLET_Y - 370.0
	while y <= Silo.OUTLET_Y - spacing:
		for k in range(-half_cols, half_cols + 1):
			var x := Silo.CENTER_X + k * spacing
			if x <= Silo.LEFT + 8.0 or x >= Silo.RIGHT - 8.0:
				continue
			var peb := Pebble.new(id, 8.0)
			peb.u235 = enrichment
			peb.u238 = 1.0 - enrichment
			peb.fuel_loading = fuel_loading
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		y += spacing
	grid.homogenize(pebbles, positions)
	return grid


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  PASS  %s" % what)
	else:
		print("  FAIL  %s" % what)
		_failures += 1
