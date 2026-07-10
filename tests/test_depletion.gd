# tests/test_depletion.gd
#
# Headless calibration + correctness gate for the M3 depletion core. Runs pure
# (no scene, no physics) via:
#   godot --headless --script res://tests/test_depletion.gd
#
# WHY (mirrors test_neutronics.gd / test_feedback.gd): the depletion micro-rates
# are toy, fluence-native constants, so we cannot know a priori how fast fuel
# burns or how far k moves. This test both PROVES the chain is right (signs:
# U-235 down, Pu-239 breed-then-burn, poison + burnup up; higher flux burns
# faster) and DRIVES the tuning against two coupling targets that make M3
# actually demonstrate something:
#   1. a nominal pebble reaches discharge burnup over ~6-15 passes (the realistic
#      multi-pass fuel cycle), and
#   2. k(all-fresh core) is meaningfully HIGHER than k(all-at-discharge core) —
#      if depletion doesn't move k, online refueling would show nothing.
extends SceneTree

var _failures := 0

# A representative fluence a pebble accrues traversing the bed once at nominal
# flux (peak-normalized ~0.5 over a full pass). The live sim's TIME_ACCEL is
# tuned so its measured per-pass fluence lands near this; here it lets us count
# passes-to-discharge in isolation.
const FLUENCE_PER_PASS := 9.0


func _initialize() -> void:
	print("=== M3 depletion calibration ===")
	_test_signs_and_monotonicity()
	_test_pu_breed_then_burn()
	_test_higher_flux_burns_faster()
	_test_passes_to_discharge()
	_test_burnup_drops_keff()
	_test_equilibrium_mix_enrichment()
	if _failures == 0:
		print("\nALL CHECKS PASSED")
	else:
		print("\n%d CHECK(S) FAILED" % _failures)
	quit(_failures)


## A single fresh pebble at reference enrichment.
func _fresh_pebble(enrichment := CrossSections.E_REF) -> Pebble:
	var peb := Pebble.new(0, 8.0)
	peb.u235 = enrichment
	peb.u238 = 1.0 - enrichment
	return peb


## Deplete a pebble to a target fluence in many small steps (so the Pu chain
## integrates correctly — see Depletion.step). flux held at 1.0, so campaign_dt
## sums to `fluence`.
func _deplete_to_fluence(peb: Pebble, fluence: float, steps := 200) -> void:
	var dt := fluence / steps
	for _i in steps:
		Depletion.step(peb, 1.0, dt)


func _test_signs_and_monotonicity() -> void:
	print("\n[signs + monotonicity]")
	var peb := _fresh_pebble()
	var u235_0 := peb.u235
	var prev_burnup := -1.0
	var prev_poison := -1.0
	var burnup_mono := true
	var poison_mono := true
	# Step in modest fluence increments across a full life, checking direction.
	for _i in 30:
		Depletion.step(peb, 1.0, 3.0)
		if peb.burnup <= prev_burnup:
			burnup_mono = false
		if peb.poison <= prev_poison:
			poison_mono = false
		prev_burnup = peb.burnup
		prev_poison = peb.poison
	_check(peb.u235 < u235_0, "U-235 depletes (fissile burns away)")
	_check(peb.pu239 > 0.0, "Pu-239 is bred from U-238 (starts at zero)")
	_check(peb.u238 < 1.0 - CrossSections.E_REF, "U-238 is consumed by capture")
	_check(burnup_mono, "burnup increases monotonically under flux")
	_check(poison_mono, "fission-product poison accumulates monotonically")
	# Heavy metal is only rearranged (U-238 → Pu-239) and burned, never created.
	var hm := peb.u235 + peb.u238 + peb.pu239
	_check(hm < 1.0 and hm > 0.7, "heavy metal conserved-ish (rearranged + burned, hm=%.3f)" % hm)


func _test_pu_breed_then_burn() -> void:
	# Bred Pu-239 must first RISE (breeding dominates) then eventually TURN OVER
	# (its own absorption overtakes fresh breeding as U-238 and reactivity fall).
	print("\n[Pu-239 breed-then-burn]")
	var peb := _fresh_pebble()
	var peak_pu := 0.0
	var peak_at := 0.0
	var f := 0.0
	var final_pu := 0.0
	# Push well beyond a normal discharge (~90) to expose the turnover.
	while f < 600.0:
		Depletion.step(peb, 1.0, 4.0)
		f += 4.0
		if peb.pu239 > peak_pu:
			peak_pu = peb.pu239
			peak_at = f
		final_pu = peb.pu239
	print("  peak Pu-239=%.4f at fluence=%.0f, final=%.4f at fluence=600" % [peak_pu, peak_at, final_pu])
	_check(peak_pu > 0.0, "Pu-239 builds up (breeding)")
	_check(final_pu < peak_pu, "Pu-239 turns over and burns down past its peak")


func _test_higher_flux_burns_faster() -> void:
	# The burnup GRADIENT driver: over the SAME campaign time, a pebble in higher
	# flux must accrue more burnup (and deplete more U-235).
	print("\n[higher flux → faster burnup]")
	var lo := _fresh_pebble()
	var hi := _fresh_pebble()
	for _i in 50:
		Depletion.step(lo, 0.3, 1.0)
		Depletion.step(hi, 0.9, 1.0)
	print("  low-flux burnup=%.2f  high-flux burnup=%.2f" % [lo.burnup, hi.burnup])
	_check(hi.burnup > lo.burnup, "higher local flux accrues more burnup")
	_check(hi.u235 < lo.u235, "higher local flux depletes U-235 faster")


func _test_passes_to_discharge() -> void:
	# The fuel-cycle target: a nominal pebble under representative per-pass fluence
	# should cross DISCHARGE_BURNUP in a realistic number of passes (~6-15). This
	# ties BURN_RATE, FLUENCE_PER_PASS and DISCHARGE_BURNUP together.
	print("\n[passes to discharge]")
	var peb := _fresh_pebble()
	var passes := 0
	while peb.burnup < Depletion.DISCHARGE_BURNUP and passes < 100:
		_deplete_to_fluence(peb, FLUENCE_PER_PASS, 20)
		passes += 1
	var e_disch := (peb.u235 + peb.pu239) / (peb.u235 + peb.u238 + peb.pu239)
	print("  discharged after %d passes  burnup=%.1f  U-235=%.4f  Pu-239=%.4f  poison=%.4f  fissile frac=%.4f"
		% [passes, peb.burnup, peb.u235, peb.pu239, peb.poison, e_disch])
	_check(passes >= 6 and passes <= 15, "nominal pebble discharges in 6-15 passes (got %d)" % passes)
	_check(peb.u235 < 0.6 * CrossSections.E_REF, "significant U-235 burned by discharge")
	_check(peb.poison > 0.0, "poison present at discharge")


func _test_burnup_drops_keff() -> void:
	# THE coupling target: depletion must move k-eff by a visible margin, or online
	# refueling demonstrates nothing. Build two identical cores — one all-fresh,
	# one with every pebble depleted to discharge burnup — homogenize + solve both.
	print("\n[burnup lowers k-eff — the refueling driver]")
	var k_fresh := _solve_core(false)
	var k_burned := _solve_core(true)
	print("  k(fresh core)=%.4f   k(discharge-burnup core)=%.4f   Δk=%.4f"
		% [k_fresh, k_burned, k_fresh - k_burned])
	_check(k_fresh > k_burned, "burned core is less reactive than fresh core")
	_check((k_fresh - k_burned) > 0.05, "burnup moves k by a visible margin (Δk > 0.05)")


func _test_equilibrium_mix_enrichment() -> void:
	# THE operating-point check (advisor). The M3 core is never uniform: at online-
	# refueling equilibrium it holds a SPREAD of burnups from 0 (fresh, top) to
	# DISCHARGE_BURNUP (spent, bottom). That MIXED core — not an all-fresh core — is
	# what must sit ~critical. A uniform-fresh core burns in lockstep and freezes
	# subcritical long before discharge (the deadlock), so the design enrichment has
	# to make the *mix* critical, i.e. fresh fuel genuinely supercritical.
	#
	# Two competing constraints pin the operating enrichment:
	#   - k(mix) must be > 1 with enough MARGIN that normal fluctuations don't dip
	#     the core subcritical (which the gate would freeze), and
	#   - the excess must be SMALL enough that Doppler holds the equilibrium BELOW
	#     the over-temp line — too much excess and the mix regulates by running the
	#     fuel too hot (which the player should reach only by deliberately over-
	#     enriching, not at the default operating point).
	# The sweep prints both k(mix) and the regulated peak temperature so the
	# tradeoff is visible; the operating point is the sweet spot between them.
	print("\n[equilibrium mixed-core k + regulated temp vs enrichment — the M3 operating point]")
	for e in [0.085, 0.100, 0.108, 0.110, 0.112, 0.116, 0.120, 0.150]:
		var eq := Feedback.solve_equilibrium(_mixed_grid(e))
		print("  e=%.3f  k(mix)=%.4f  regulated peak T=%.0f K%s"
			% [e, eq.k_cold, Feedback.T_REF + eq.peak_dt,
			   "  (over-temp)" if (Feedback.T_REF + eq.peak_dt) >= OVER_TEMP_K else ""])
	# There must EXIST a LEU operating point on this idealized lattice that is
	# supercritical-with-margin AND regulates comfortably below over-temp. main.gd
	# runs a hair above this (the settled funnel bed reads ~2% lower k than the
	# lattice, so the live value is tuned up to compensate — see ENRICH_DEFAULT).
	var op := lattice_operating_enrichment()
	var op_eq := Feedback.solve_equilibrium(_mixed_grid(op))
	var op_peak := Feedback.T_REF + op_eq.peak_dt
	_check(op <= 0.20, "a LEU lattice operating point exists (%.1f%%)" % (op * 100.0))
	_check(op_eq.k_cold > 1.008, "lattice operating mix is supercritical with margin above the gate (k=%.4f)" % op_eq.k_cold)
	_check(op_eq.regulated and not op_eq.feedback_insufficient and op_peak < OVER_TEMP_K,
		"lattice operating mix self-regulates comfortably below over-temp (peak %.0f K < %.0f K)" % [op_peak, OVER_TEMP_K])


## The enrichment at which the idealized LATTICE mix is comfortably critical. This
## validates the METHOD and that a workable LEU point exists; main.gd's ENRICH_DEFAULT
## runs slightly higher because the live settled bed is less reactive than the lattice
## (a live-geometry tuning, like TIME_ACCEL). OVER_TEMP_K mirrors main.gd's line.
##
## M5c: bumped 0.110 → 0.112. The depletion step now also evolves the Xe-135 chain, so
## these mixed-core pebbles carry their equilibrium xenon (~0.7% Δk of parasitic
## absorption), which pushed the old 0.110 point (k was 1.010, barely above the 1.008
## gate) below the margin. 0.112 restores a comfortable supercritical mix WITH xenon in,
## still regulating well under over-temp — the same recalibration every physics layer
## has triggered here. tests/test_xenon.gd owns the xenon-worth calibration.
const OVER_TEMP_K := 1800.0
func lattice_operating_enrichment() -> float:
	return 0.112


## A core whose pebbles carry a uniform SPREAD of burnups across [0, discharge] —
## a proxy for the online-refueling equilibrium distribution. Returns k-eff.
func _solve_mixed_core(enrichment: float) -> float:
	return Neutronics.solve(_mixed_grid(enrichment)).k_eff


## Homogenized grid for the equilibrium-spread mixed core (see _solve_mixed_core).
func _mixed_grid(enrichment: float) -> Grid:
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
		# Burnup increases down the bed (fresh at top → spent at bottom), spread
		# uniformly across the discharge window.
		var frac: float = float(row) / maxf(1.0, float(rows - 1))
		var target := frac * Depletion.DISCHARGE_BURNUP
		for k in range(-half_cols, half_cols + 1):
			var x := Silo.CENTER_X + k * spacing
			if x <= Silo.LEFT + 8.0 or x >= Silo.RIGHT - 8.0:
				continue
			var peb := _fresh_pebble(enrichment)
			peb.id = id
			if target > 0.0:
				_deplete_to_fluence(peb, target, 200)
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		row += 1
		y += spacing
	grid.homogenize(pebbles, positions)
	return grid


## Build the same symmetric lattice as the other tests; optionally deplete every
## pebble to discharge burnup first. Homogenize + solve, return k-eff.
func _solve_core(burned: bool) -> float:
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
			var peb := _fresh_pebble()
			peb.id = id
			if burned:
				_deplete_to_fluence(peb, Depletion.DISCHARGE_BURNUP, 200)
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		y += spacing
	grid.homogenize(pebbles, positions)
	return Neutronics.solve(grid).k_eff


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1
