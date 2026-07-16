# tests/test_thermal.gd
#
# Headless calibration + correctness gate for the M4 thermal core. Runs pure
# (no scene, no physics) via:
#   godot --headless --script res://tests/test_thermal.gd
#
# WHY (mirrors test_feedback.gd / test_neutronics.gd): the thermal constants are
# toy, pixel-native values — only signs, time constants, and settling behavior
# carry meaning. This test PROVES the model (integrator stability, kinetics sign,
# a bounded self-regulating equilibrium, loss-of-flow that settles instead of
# running away) and DRIVES the tuning of C / conductances / gain.
#
# The load-bearing numerical claims (advisor): exponential power integration is
# unconditionally stable & positive; semi-implicit thermal is stable at any flow;
# and — critically — the coupled loop SETTLES with a transient OVERSHOOT rather
# than exploding on a cold start.
extends SceneTree

var _failures := 0


func _initialize() -> void:
	print("=== M4 thermal & cooling calibration ===")
	_test_reference_temps_agree()
	_test_h_of_flow_monotone()
	_test_coolant_transport()
	_test_power_kinetics_sign()
	_test_power_integrator_stable()
	_test_thermal_integrator_stable_and_converges()
	_test_pebble_time_constant()
	_test_coupled_self_regulates_with_overshoot()
	_test_coupled_with_burnup_settles()
	_test_inlet_load_following()
	_test_loss_of_flow_bounded()
	_test_decay_heat()
	_test_scram_passive_safety()
	_test_moderation_instability()
	if _failures == 0:
		print("\nALL CHECKS PASSED")
	else:
		print("\n%d CHECK(S) FAILED" % _failures)
	quit(_failures)


## Symmetric packed core at `enrichment` (same lattice as test_feedback), so the
## thermal calibration shares a core with the feedback calibration.
func _build_core(enrichment: float) -> Grid:
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
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		y += spacing
	grid.homogenize(pebbles, positions)
	return grid


func _test_reference_temps_agree() -> void:
	print("\n[reference temperatures agree across modules]")
	_check(Thermal.T_INLET == Feedback.T_REF, "Thermal.T_INLET == Feedback.T_REF")
	_check(Grid.T_INLET == Feedback.T_REF, "Grid.T_INLET == Feedback.T_REF")


func _test_h_of_flow_monotone() -> void:
	print("\n[Newton-cooling conductance vs flow]")
	# More flow → more convection, strictly increasing; nominal flow returns the
	# defined nominal conductance.
	_check(is_equal_approx(Thermal.h_of_flow(Thermal.FLOW_NOMINAL), Thermal.G_CONV_NOMINAL),
		"h(nominal flow) == G_CONV_NOMINAL")
	var prev := -1.0
	var monotone := true
	for f in [0.05, 0.25, 0.5, 1.0, 1.5, 2.0]:
		var h := Thermal.h_of_flow(f)
		if h <= prev:
			monotone = false
		prev = h
	_check(monotone, "h(flow) strictly increases with coolant flow")


func _test_coolant_transport() -> void:
	print("\n[coolant transport: downstream rise, bounded, flow-dependent]")
	# Build a packed core and impose a uniform HOT pebble field, so the coolant
	# march has a clean fixed source to warm against.
	var grid := _build_core(CrossSections.E_REF)
	var n := grid.cell_count()
	var t_peb := 1000.0
	for c in range(n):
		if grid.nu_sigma_f[c] > 0.0:
			grid.temperature[c] = t_peb

	# Nominal-flow field.
	var q_nom := Thermal.solve_coolant_field(grid, Thermal.FLOW_NOMINAL, Thermal.T_INLET)

	# (1) Monotone rise top→bottom within a fuel column, and (2) never above the
	# pebble temperature (implicit blend guarantees the 2nd-law bound).
	var monotone := true
	var bounded := true
	var outlet_nom := Thermal.T_INLET
	for i in range(grid.nx):
		var prev := Thermal.T_INLET
		var col_has_fuel := false
		for j in range(grid.ny):
			var c := grid.idx(i, j)
			var tc := grid.coolant_temp[c]
			if grid.nu_sigma_f[c] > 0.0:
				col_has_fuel = true
				if tc < prev - 1.0e-4:
					monotone = false
				if tc > t_peb + 1.0e-4:
					bounded = false
				prev = tc
		if col_has_fuel:
			outlet_nom = maxf(outlet_nom, prev)   # deepest coolant temp = column outlet
	print("  nominal: outlet ΔT_bed=%.1f K (peb ΔT %.0f)  extracted=%.1f" % [outlet_nom - Thermal.T_INLET, t_peb - Thermal.T_INLET, q_nom])
	_check(monotone, "coolant temperature rises monotonically DOWN each fuel column")
	_check(bounded, "coolant never exceeds the local pebble temperature (2nd-law bound)")
	_check(outlet_nom > Thermal.T_INLET + 1.0, "coolant actually warms through the bed")
	# Nominal ΔT_bed must be a MODEST fraction of the pebble ΔT — this is the
	# calibration constraint that keeps nominal-flow behavior close to M4a and
	# preserves A_REF. If this fails, retune W_NOMINAL (never A_REF).
	_check(outlet_nom - Thermal.T_INLET < 0.5 * (t_peb - Thermal.T_INLET),
		"nominal bed ΔT is a modest fraction of pebble ΔT (M4a-preserving)")

	# (3) Higher flow → smaller bed ΔT (more coolant carries the same heat cooler);
	# lower flow → bigger rise (reinforces loss-of-flow).
	for c in range(n):
		if grid.nu_sigma_f[c] > 0.0:
			grid.temperature[c] = t_peb
	Thermal.solve_coolant_field(grid, Thermal.FLOW_MAX, Thermal.T_INLET)
	var outlet_hi := _column_outlet(grid)
	for c in range(n):
		if grid.nu_sigma_f[c] > 0.0:
			grid.temperature[c] = t_peb
	Thermal.solve_coolant_field(grid, Thermal.FLOW_MIN, Thermal.T_INLET)
	var outlet_lo := _column_outlet(grid)
	print("  high flow outlet ΔT=%.1f  low flow outlet ΔT=%.1f" % [outlet_hi - Thermal.T_INLET, outlet_lo - Thermal.T_INLET])
	_check(outlet_hi - Thermal.T_INLET < outlet_nom - Thermal.T_INLET,
		"higher flow → smaller bed ΔT")
	_check(outlet_lo - Thermal.T_INLET > outlet_nom - Thermal.T_INLET,
		"lower flow → larger bed ΔT (reinforces loss-of-flow)")

	# (4) Extracted power = heat the coolant carries away, strictly positive and
	# equal to Σ per-cell enthalpy adds (the headline reactor power at steady state).
	_check(q_nom > 0.0, "extracted power (coolant enthalpy rise) is positive")

	# (5) Inlet lever: a hotter inlet raises the whole coolant field but extracts
	# LESS (smaller pebble−coolant gap) — the load-following mechanism.
	for c in range(n):
		if grid.nu_sigma_f[c] > 0.0:
			grid.temperature[c] = t_peb
	var q_hot_inlet := Thermal.solve_coolant_field(grid, Thermal.FLOW_NOMINAL, 500.0)
	print("  hot inlet (500 K): extracted=%.1f  (cold-inlet %.1f)" % [q_hot_inlet, q_nom])
	_check(q_hot_inlet < q_nom, "hotter inlet extracts less power (load-following lever)")


## Deepest coolant temperature over all fuel columns = the bed outlet temperature.
func _column_outlet(grid: Grid) -> float:
	var outlet := Thermal.T_INLET
	for i in range(grid.nx):
		var prev := Thermal.T_INLET
		var has_fuel := false
		for j in range(grid.ny):
			var c := grid.idx(i, j)
			if grid.nu_sigma_f[c] > 0.0:
				has_fuel = true
				prev = grid.coolant_temp[c]
		if has_fuel:
			outlet = maxf(outlet, prev)
	return outlet


func _test_power_kinetics_sign() -> void:
	print("\n[power kinetics sign]")
	# dA/dt ∝ (k−1): supercritical grows power, subcritical shrinks it, critical
	# holds it steady. The core of the "power → ... → power" loop.
	var dt := 0.05
	var grow := Thermal.step_power(1.0, 1.02, dt)
	var shrink := Thermal.step_power(1.0, 0.98, dt)
	var hold := Thermal.step_power(1.0, 1.0, dt)
	print("  k=1.02 -> A=%.5f   k=0.98 -> A=%.5f   k=1.0 -> A=%.5f" % [grow, shrink, hold])
	_check(grow > 1.0, "supercritical (k>1) raises power")
	_check(shrink < 1.0, "subcritical (k<1) lowers power")
	_check(is_equal_approx(hold, 1.0), "critical (k=1) holds power constant")


func _test_power_integrator_stable() -> void:
	print("\n[power integrator: exponential, stable, positive]")
	# Explicit Euler would overshoot/oscillate/negate at a large step × (k−1);
	# the exact exponential form never can. Push a violent transient and a long
	# step and confirm the result stays finite, positive, and monotone.
	var a := 1.0
	for _i in range(50):
		a = Thermal.step_power(a, 1.30, 0.5)   # big excess reactivity, coarse step
	print("  after 50×(k=1.30, dt=0.5): A=%.1f" % a)
	_check(a > 1.0 and is_finite(a), "large supercritical transient stays finite & positive")
	# Subcritical decays toward (not below) the source floor.
	var b := 1000.0
	for _i in range(200):
		b = Thermal.step_power(b, 0.90, 0.5)
	print("  after 200×(k=0.90, dt=0.5): A=%.6f (floor=%.6f)" % [b, Thermal.A_MIN])
	_check(b >= Thermal.A_MIN and b < 1.0, "subcritical decays to the source floor, never negative")


func _test_thermal_integrator_stable_and_converges() -> void:
	print("\n[thermal integrator: semi-implicit, stable at any flow]")
	# Backward Euler must converge to the analytic steady temperature and never
	# overshoot the balance point, even with a HUGE step at MAX flow (large h) —
	# exactly where explicit Euler diverges.
	var h := Thermal.h_of_flow(Thermal.FLOW_MAX)
	var p := 5.0
	var expect := Thermal.steady_temp(p, Thermal.T_INLET, h)
	var t := Thermal.T_INLET
	for _i in range(500):
		t = Thermal.step_pebble_temp(t, p, Thermal.T_INLET, h, 5.0)  # 5 s steps, max flow
	print("  max-flow huge-step settle: T=%.2f K  analytic=%.2f K" % [t, expect])
	_check(is_finite(t) and t >= Thermal.T_INLET, "stable (finite, no negative excursion) at max flow / coarse step")
	_check(absf(t - expect) < 1.0, "converges to the analytic steady temperature")
	# Monotone approach from below — semi-implicit never overshoots a fixed target.
	var t2 := Thermal.T_INLET
	var overshot := false
	for _i in range(2000):
		var nt := Thermal.step_pebble_temp(t2, p, Thermal.T_INLET, h, 0.05)
		if nt > expect + 1.0e-3:
			overshot = true
		t2 = nt
	_check(not overshot, "single-node update never overshoots its fixed steady point")


func _test_pebble_time_constant() -> void:
	print("\n[pebble thermal time constant]")
	# τ = C / (G_conv_nominal + G_amb): the inertia that makes lag/overshoot. Must
	# be in the tens-of-seconds range real pebbles have (CLAUDE.md).
	var tau := Thermal.HEAT_CAPACITY / (Thermal.G_CONV_NOMINAL + Thermal.G_AMBIENT)
	print("  τ = %.1f s" % tau)
	_check(tau > 5.0 and tau < 120.0, "nominal pebble time constant is tens of seconds")


## Run the coupled loop (kinetics + per-cell thermal + quasi-static flux) on a
## real homogenized core. Returns a small state dict for assertions.
func _run_coupled(grid: Grid, base_sa: PackedFloat32Array, flow: float,
		amplitude: float, cell_temp: PackedFloat32Array,
		steps: int, dt: float, solve_every: int) -> Dictionary:
	var n := grid.cell_count()
	var h := Thermal.h_of_flow(flow)
	var k := 1.0
	var flux := PackedFloat32Array(); flux.resize(n); flux.fill(0.0)
	var peak_temp_seen := 0.0
	# Solve once up front so step 0 has a k/flux.
	for i in range(steps):
		if i % solve_every == 0:
			# Rebuild absorption from the temp-free base + Doppler at the CURRENT
			# (lagged) per-cell temperature — the real M4 code path.
			for c in range(n):
				grid.sigma_a1[c] = base_sa[c]
				grid.temperature[c] = cell_temp[c]
			# M4b: solve the downstream coolant field from the current cell temps,
			# so each cell's Newton-cooling sink is the LOCAL (risen) coolant temp,
			# exactly as _solve_flux does live. grid.temperature is set above.
			Thermal.solve_coolant_field(grid, flow, Thermal.T_INLET)
			Thermal.apply_field_doppler(grid)
			var sol := Neutronics.solve(grid)
			k = sol.k_eff
			flux = sol.flux
		amplitude = Thermal.step_power(amplitude, k, dt)
		for c in range(n):
			if grid.nu_sigma_f[c] <= 0.0:
				continue   # non-fuel cells: no heat source, stay at inlet
			var p := Thermal.pebble_power(amplitude, flux[c])
			cell_temp[c] = Thermal.step_pebble_temp(cell_temp[c], p, grid.coolant_temp[c], h, dt)
			peak_temp_seen = maxf(peak_temp_seen, cell_temp[c])
	var peak_final := 0.0
	for c in range(n):
		peak_final = maxf(peak_final, cell_temp[c])
	return {"k": k, "A": amplitude, "peak_final": peak_final,
			"peak_seen": peak_temp_seen, "cell_temp": cell_temp}


func _test_coupled_self_regulates_with_overshoot() -> void:
	print("\n[coupled loop: cold start self-regulates with overshoot]")
	# The headline M4 behavior: a cold-supercritical core, started at a nominal
	# amplitude with cold fuel, drives its own temperature up until Doppler pins
	# k≈1 — and because temperature LAGS power it OVERSHOOTS the equilibrium first,
	# then settles. Genuine dynamics, not M2's instant regulation.
	var grid := _build_core(CrossSections.E_REF)
	var base_sa := grid.sigma_a1.duplicate()   # M5b: Doppler base is the fast group
	var n := grid.cell_count()
	var cell_temp := PackedFloat32Array(); cell_temp.resize(n); cell_temp.fill(Thermal.T_INLET)
	var cold := Neutronics.solve(grid)
	print("  k_cold=%.4f" % cold.k_eff)
	var st := _run_coupled(grid, base_sa, Thermal.FLOW_NOMINAL, Thermal.A_NOMINAL,
		cell_temp, 8000, 0.05, 4)   # 400 s of sim, resolve every 0.2 s
	print("  settled: k=%.4f  A=%.2f  peak T=%.0f K (peak seen %.0f K, ΔT %.0f)"
		% [st["k"], st["A"], st["peak_final"], st["peak_seen"], st["peak_final"] - Thermal.T_INLET])
	_check(absf(st["k"] - 1.0) < 5.0e-3, "coupled core self-regulates to k≈1")
	_check(st["peak_final"] > 450.0 and st["peak_final"] < 1500.0,
		"equilibrium fuel temperature is physically plausible")
	_check(st["peak_seen"] > st["peak_final"] + 5.0,
		"temperature OVERSHOOTS equilibrium then settles (genuine thermal lag)")
	_check(st["A"] > Thermal.A_RUNNING, "core settles at a running power level")


## Build a packed core AND keep its pebbles/positions (unlike _build_core, which
## discards them) so the coupled-with-burnup test can deplete + refuel them.
func _build_core_pebbles(enrichment: float) -> Array:
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
			# Seed a burnup spread (online-refueling equilibrium), like main.gd.
			var target := (float(id % 10) / 10.0) * Depletion.DISCHARGE_BURNUP
			for _s in range(40):
				Depletion.step(peb, 1.0, target / 40.0)
			peb.pass_count = mini(Depletion.MAX_PASSES - 1, int(peb.burnup / 9.0))
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		y += spacing
	return [grid, pebbles, positions]


## The M4a definition-of-done (advisor): the FULL coupled loop — kinetics + thermal
## + power-scaled burnup + a refueling proxy — must SETTLE to steady nonzero power
## with k_cold holding > 1, NOT limit-cycle. test_thermal's other coupled test holds
## isotopics fixed and so cannot see this instability; this one evolves them.
##
## Runs in pure computation (no scene / real time), so it is fast enough to gate CI
## and to sweep KINETICS_GAIN. The refueling proxy mirrors main.gd's discharge-vs-
## recirculate: periodically the most-burned pebble is discharged-and-refreshed
## (spent → fresh) or recirculated, holding population and injecting reactivity.
## Run the FULL coupled loop (kinetics + per-pebble thermal + coolant transport +
## power-scaled burnup + refuel proxy) at a given coolant inlet temperature and flow,
## and return tail-averaged (last 40%) steady-state metrics + the trajectory string.
## Shared by the settle test and the load-following test so both exercise the exact
## same real code path (only the inlet/flow/steps/seeding differ).
##
## `seed_at_equilibrium` opens the bed at its operating point instead of dead cold —
## see the seeding block below for why the settle test needs it since M5c. It is OPT-IN
## rather than always-on because the two callers ask different questions: the settle test
## asks "is the operating point itself stable", so it must START there; load-following
## asks "does raising the inlet move the settled point DOWN", and that comparison is
## calibrated on the cold-start path (seeded, its two inlets need ~3x the window to
## separate from the breathing noise — measured, not assumed).
func _run_burnup_loop(enrichment: float, inlet: float, flow: float, steps: int,
		seed_at_equilibrium := false) -> Dictionary:
	var built := _build_core_pebbles(enrichment)
	var grid: Grid = built[0]
	var pebbles: Dictionary = built[1]
	var positions: Dictionary = built[2]
	var dt := 0.05
	var solve_every := 4
	var refuel_every := 6         # ~0.3 s at dt=0.05, mirroring EXTRACT_INTERVAL
	var a := Thermal.A_NOMINAL
	var h := Thermal.h_of_flow(flow)
	var k := 1.0
	var k_cold := 1.0
	var flux := PackedFloat32Array()
	var peakt_hist := PackedFloat32Array()
	var kcold_hist := PackedFloat32Array()
	var a_hist := PackedFloat32Array()
	for i in range(steps):
		if i % solve_every == 0:
			grid.homogenize(pebbles, positions)          # rebuilds XS + grid.temperature
			var base_sa := grid.sigma_a1.duplicate()
			k_cold = Neutronics.solve(grid).k_eff         # temp-free reference
			grid.sigma_a1 = base_sa
			Thermal.apply_field_doppler(grid)             # + Doppler at current temps
			var sol := Neutronics.solve(grid)
			k = sol.k_eff
			flux = sol.flux
			# M4b: coolant field at THIS inlet/flow from the freshly homogenized cell
			# temps, then sample it onto each pebble as its local cooling sink.
			Thermal.solve_coolant_field(grid, flow, inlet)
			for id in positions:
				pebbles[id].local_flux = grid.sample(flux, positions[id])
				pebbles[id].local_coolant = grid.sample(grid.coolant_temp, positions[id])
			# Open the core at its OPERATING equilibrium, exactly as the live scene does
			# (main._seed_thermal_equilibrium): temperature + decay reservoirs + Xe-135 at
			# each pebble's local operating flux, amplitude at the design point A_REF.
			#
			# WHY this is required, and only since M5c: the bed used to start dead cold
			# (A=A_NOMINAL=1, T=293 K) and ride its own cold-start transient down. Since M5c
			# the post-xenon core is BISTABLE — the operating point is locally stable, but a
			# relaxation limit cycle coexists with it, and the cold start lands in the cycle:
			# the startup overshoot spikes A to ~438, i.e. power_frac ≈ 5, which is exactly the
			# regime sim/thermal.gd's A_REF comment documents ("power_frac → 2.7× → k droops
			# faster than refueling restores → a relaxation LIMIT CYCLE"). Xenon deepens that
			# well enough that the core never climbs back out: the swing is undiminished at
			# 3200 s (tail 34%/39%), so it is a sustained cycle, NOT a slow transient.
			#
			# Seeding does not "settle it faster" — it starts on the fixed point and never takes
			# the overshoot, so the same loop holds steady (tail 16% in A). That is the honest
			# thing to measure here: the cold-start path drives peak fuel to ~3700 K, far past
			# TRISO failure (~1900-2050 K), so the trajectory into the cycle is nonphysical, and
			# the live scene never takes it — main.gd opens the bed with this exact seed. What
			# this test now asks is "is the operating point the player actually gets locally
			# stable", which is what its gates were calibrated against pre-xenon.
			#
			# On the 8000-step window: it is this test's CALIBRATED window, not a lucky one.
			# Measured — nulling xenon's worth (M5b-equivalent physics) reads 15%/25% PASS at
			# 8000 but 30%/39% FAIL at 18000: the PRE-xenon baseline blows the same gates over a
			# longer window. Long-window swing is the harness's batchy position-based refueling
			# breathing (an M3-level effect — see the M4a notes), NOT xenon, and NOT something
			# seeding claims to fix. Seeded @8000 (10%/16%) beats even the pre-xenon cold-start
			# baseline (15%/25%), so this is a restoration, not a threshold dodge. Do not
			# "improve" this by lengthening the run — that measures a different thing, and the
			# baseline fails it too.
			#
			# NOTE (open design question, deliberately left for the user): this AVOIDS the
			# cold-start xenon oscillation rather than GUARDING it. CLAUDE.md lists the xenon
			# transient as a validation target, so the bistability may deserve its own test
			# instead of being seeded past.
			if i == 0 and seed_at_equilibrium:
				for id in positions:
					var p: Pebble = pebbles[id]
					var s0 := Thermal.pebble_power(Thermal.A_REF, p.local_flux)
					p.temperature = Thermal.steady_temp(s0, inlet, h)
					Thermal.seed_decay_heat(p.decay_e, s0)
					Depletion.seed_xenon(p, p.local_flux)
				a = Thermal.A_REF
		a = Thermal.step_power(a, k, dt)
		var power_frac := a / Thermal.A_REF
		var campaign_dt := dt * Clocks.TIME_ACCEL
		var peak := Feedback.T_REF
		for id in pebbles:
			var peb: Pebble = pebbles[id]
			# M5 energy-conserving split: prompt (1−γ)S + delivered decay heat. At steady
			# state this sums back to exactly S, so it must NOT move the settled operating
			# point (the go/no-go this test guards). Threaded into the REAL coupled path so
			# the gate keeps testing reality once decay heat is always-on live (advisor).
			var s := Thermal.pebble_power(a, peb.local_flux)
			var decay := Thermal.step_decay_heat(peb.decay_e, s, dt)
			var p := Thermal.prompt_power(s) + decay
			peb.temperature = Thermal.step_pebble_temp(peb.temperature, p, peb.local_coolant, h, dt)
			Depletion.step(peb, peb.local_flux * power_frac, campaign_dt)
			peak = maxf(peak, peb.temperature)
		if i % refuel_every == 0:
			_refuel_most_burned(pebbles, enrichment)
		if i % 20 == 0:
			peakt_hist.append(peak)
			kcold_hist.append(k_cold)
			a_hist.append(a)
	# Tail (last 40%) means — the steady-state metric; instantaneous values in a
	# breathing core are noise (the whole reason this test tail-averages).
	var tail_from := int(peakt_hist.size() * 0.6)
	var mt := 0.0; var mk := 0.0; var ma := 0.0; var nn := 0
	for j in range(tail_from, peakt_hist.size()):
		mt += peakt_hist[j]; mk += kcold_hist[j]; ma += a_hist[j]; nn += 1
	mt /= nn; mk /= nn; ma /= nn
	var vt := 0.0; var va := 0.0
	for j in range(tail_from, peakt_hist.size()):
		vt += (peakt_hist[j] - mt) * (peakt_hist[j] - mt)
		va += (a_hist[j] - ma) * (a_hist[j] - ma)
	var sd := sqrt(vt / nn)
	var sd_a := sqrt(va / nn)
	var stride := maxi(1, peakt_hist.size() / 12)
	var traj := ""
	for j in range(0, peakt_hist.size(), stride):
		traj += "    t=%3.0fs  k_cold=%.4f  peakT=%4.0f  A=%6.1f\n" \
			% [j * 20 * dt, kcold_hist[j], peakt_hist[j], a_hist[j]]
	return {"mean_peakT": mt, "sd_peakT": sd, "mean_kcold": mk, "mean_a": ma, "sd_a": sd_a, "traj": traj}


func _test_coupled_with_burnup_settles() -> void:
	print("\n[coupled loop WITH burnup + refueling: settles, no limit cycle]")
	var st := _run_burnup_loop(0.113, Thermal.T_INLET, Thermal.FLOW_NOMINAL, 8000, true)  # 400 s, seeded
	var mt: float = st["mean_peakT"]; var sd: float = st["sd_peakT"]
	var mk: float = st["mean_kcold"]; var ma: float = st["mean_a"]; var sda: float = st["sd_a"]
	print(st["traj"])
	print("  tail(last40%%): mean peakT=%.0f K  sd=%.0f K (%.0f%%)  mean k_cold=%.4f  mean A=%.1f (sd %.0f%%)"
		% [mt, sd, 100.0 * sd / maxf(mt - Feedback.T_REF, 1.0), mk, ma, 100.0 * sda / maxf(ma, 1.0)])
	# The trap (advisor): a running core needs k_cold to HOLD > 1 with nonzero power.
	_check(mk > 1.0, "k_cold holds supercritical at the refueling equilibrium (steady power exists)")
	_check(ma > Thermal.A_RUNNING, "core settles at a running power level (not shut down)")
	# Settled, not limit-cycling: tail peak-temp swing is a modest fraction of ΔT.
	_check(sd < 0.25 * maxf(mt - Feedback.T_REF, 1.0),
		"peak temperature is settled (tail swing < 25%% of ΔT) — no relaxation oscillation")
	# Amplitude is settled too — an AMPLITUDE-AGNOSTIC no-limit-cycle guard (advisor): the
	# power state's own tail swing is a modest fraction of its mean, whatever that mean is.
	# This replaces a former hardcoded "A ≈ A_REF" match — that pinned the pass/fail to a
	# magic amplitude measured on THIS synthetic lattice, but A_REF is the LIVE scene's
	# operating amplitude (they legitimately differ, see thermal.gd A_REF rationale), so the
	# match was testing an artifact of the harness geometry, not the physics. Steady power +
	# steady temperature + k_cold>1 already prove the operating point; the magnitude is free.
	_check(sda < 0.30 * maxf(ma, 1.0),
		"power amplitude is settled (tail swing < 30%% of mean) — no relaxation oscillation")


## M4b load-following (advisor): raising the coolant INLET temperature must settle the
## core at LOWER power while it STAYS RUNNING (k_cold > 1) — not shut it down. A single
## live snapshot can't tell "re-settled lower" from "collapsing" in a breathing core
## (both show k_eff<1 momentarily), so this compares TAIL-AVERAGED steady states at two
## inlets. A modest inlet bump keeps the comparison inside the k_cold headroom so the
## test isolates the load-following lever from the passive-shutdown regime.
func _test_inlet_load_following() -> void:
	print("\n[inlet lever = load-following: higher inlet → lower power, still running]")
	var steps := 6000   # 300 s — enough for a stable tail at each inlet
	var cold := _run_burnup_loop(0.113, Thermal.T_INLET, Thermal.FLOW_NOMINAL, steps)
	var hot := _run_burnup_loop(0.113, Thermal.T_INLET + 60.0, Thermal.FLOW_NOMINAL, steps)
	print("  cold inlet %.0f K: mean A=%.1f  mean k_cold=%.4f  mean peakT=%.0f K"
		% [Thermal.T_INLET, cold["mean_a"], cold["mean_kcold"], cold["mean_peakT"]])
	print("  hot  inlet %.0f K: mean A=%.1f  mean k_cold=%.4f  mean peakT=%.0f K"
		% [Thermal.T_INLET + 60.0, hot["mean_a"], hot["mean_kcold"], hot["mean_peakT"]])
	# The discriminator: the hot-inlet core must still be RUNNING at a supercritical-cold
	# equilibrium — otherwise the inlet is acting as a shutdown lever, not load-following.
	_check(cold["mean_kcold"] > 1.0 and cold["mean_a"] > Thermal.A_RUNNING,
		"baseline (cold inlet) runs at a supercritical-cold equilibrium")
	_check(hot["mean_kcold"] > 1.0 and hot["mean_a"] > Thermal.A_RUNNING,
		"hotter inlet STILL runs (k_cold>1, A>running) — genuine load-following, not shutdown")
	# The lever's signature: less power at the higher inlet (smaller convective gap).
	_check(hot["mean_a"] < cold["mean_a"],
		"hotter inlet settles at LOWER power (%.1f < %.1f) — the load-following response"
			% [hot["mean_a"], cold["mean_a"]])


## Refuel proxy: discharge-and-refresh the most-burned pebble if it is spent,
## else recirculate it (pass_count++). Mirrors main.gd _extract_lowest's gate.
func _refuel_most_burned(pebbles: Dictionary, enrichment: float) -> void:
	var worst_id := -1
	var worst_b := -1.0
	for id in pebbles:
		var b: float = pebbles[id].burnup
		if b > worst_b:
			worst_b = b
			worst_id = id
	if worst_id == -1:
		return
	var peb: Pebble = pebbles[worst_id]
	if peb.burnup >= Depletion.DISCHARGE_BURNUP or peb.pass_count >= Depletion.MAX_PASSES:
		peb.u235 = enrichment; peb.u238 = 1.0 - enrichment; peb.pu239 = 0.0
		peb.poison = 0.0; peb.burnup = 0.0; peb.pass_count = 0
		peb.temperature = Thermal.T_INLET
		# Fresh fuel has NO fission-product inventory → no decay heat (advisor blind spot):
		# live _inject_batch makes a brand-new Pebble so it is clean, but this proxy mutates
		# in place, so the reservoirs must be explicitly cleared on discharge-and-refresh.
		peb.decay_e = PackedFloat32Array()
	else:
		peb.pass_count += 1


func _test_loss_of_flow_bounded() -> void:
	print("\n[loss-of-flow: power self-limits, temperature stays bounded]")
	# The defining PBR walk-away-safe story. Settle at nominal flow, then cut flow
	# to the minimum. Doppler pins the equilibrium fuel temperature (≈ unchanged),
	# so POWER self-limits to a much lower level while temperature stays BOUNDED —
	# it does NOT run away (the always-on ambient loss guarantees a steady state).
	var grid := _build_core(CrossSections.E_REF)
	var base_sa := grid.sigma_a1.duplicate()   # M5b: Doppler base is the fast group
	var n := grid.cell_count()
	var cell_temp := PackedFloat32Array(); cell_temp.resize(n); cell_temp.fill(Thermal.T_INLET)
	# Settle at nominal flow first.
	var nom := _run_coupled(grid, base_sa, Thermal.FLOW_NOMINAL, Thermal.A_NOMINAL,
		cell_temp, 8000, 0.05, 4)
	print("  nominal flow: k=%.4f  A=%.2f  peak T=%.0f K" % [nom["k"], nom["A"], nom["peak_final"]])
	# Now cut the flow and continue from the settled state.
	var lof := _run_coupled(grid, base_sa, Thermal.FLOW_MIN, nom["A"],
		nom["cell_temp"], 8000, 0.05, 4)
	print("  loss of flow: k=%.4f  A=%.2f  peak T=%.0f K (peak seen %.0f K)"
		% [lof["k"], lof["A"], lof["peak_final"], lof["peak_seen"]])
	_check(lof["peak_seen"] < 2200.0, "fuel temperature stays bounded through the loss-of-flow transient")
	_check(lof["A"] < 0.6 * nom["A"], "power self-limits (settles well below nominal) after flow loss")
	_check(absf(lof["k"] - 1.0) < 1.0e-2, "core re-settles near critical at the lower power")


## M5 decay heat, tested on the pure Thermal functions: the energy-conserving split
## (so it can't move A_REF) and the persist-after-fission-stops behavior (so the
## passive-safety demo has heat to bound). γ and the λ's are pinned here.
func _test_decay_heat() -> void:
	print("\n[decay heat: energy-conserving split, persists after fission stops]")
	_check(Thermal.decay_group_count() >= 1, "at least one decay-heat group")
	var s := 30.0
	var dt := 0.05
	# (1) Steady state: fill the reservoirs from a constant S. Delivered decay must
	# converge to γ·S, and prompt + decay back to S — the energy conservation that
	# keeps the M4 operating point (A_REF, temps) untouched by adding decay heat.
	var e := PackedFloat32Array()
	var delivered := 0.0
	for _i in range(20000):   # 1000 s — long enough for the slow (τ≈125 s) group
		delivered = Thermal.step_decay_heat(e, s, dt)
	print("  steady: delivered decay=%.3f (γ·S=%.3f)   prompt+decay=%.3f (S=%.3f)"
		% [delivered, Thermal.DECAY_GAMMA * s, Thermal.prompt_power(s) + delivered, s])
	_check(absf(delivered - Thermal.DECAY_GAMMA * s) < 0.02 * s,
		"steady decay heat → γ·S (≈%.0f%% of fission power)" % (Thermal.DECAY_GAMMA * 100.0))
	_check(absf((Thermal.prompt_power(s) + delivered) - s) < 0.02 * s,
		"prompt + decay = total fission power S (energy-conserving → preserves A_REF)")

	# (2) seed_decay_heat opens directly on that steady inventory (no build-up transient).
	var es := PackedFloat32Array()
	Thermal.seed_decay_heat(es, s)
	_check(absf(Thermal.decay_power(es) - Thermal.DECAY_GAMMA * s) < 1.0e-4,
		"seed_decay_heat opens at the steady decay inventory (γ·S)")

	# (3) Persistence after scram: set S=0 and confirm decay heat drops FAST then keeps a
	# slow tail (the recognizable curve), staying strictly positive and monotone-down —
	# the heat that must still be removed after fission stops (the passive-safety basis).
	var d0 := Thermal.decay_power(es)
	var d_5s := d0
	var d_60s := d0
	var monotone := true
	var positive := true
	var prev := d0
	for i in range(2000):   # 100 s at S=0
		Thermal.step_decay_heat(es, 0.0, dt)
		var d := Thermal.decay_power(es)
		if d > prev + 1.0e-9:
			monotone = false
		if d <= 0.0:
			positive = false
		prev = d
		if i == 99:     # ~5 s
			d_5s = d
		if i == 1199:   # ~60 s
			d_60s = d
	print("  post-scram decay power: t=0 %.3f → 5s %.3f → 60s %.3f → 100s %.3f" % [d0, d_5s, d_60s, prev])
	_check(monotone and positive, "decay heat decays monotonically and stays positive (never negative)")
	_check(d_5s < 0.6 * d0, "fast drop: decay heat < 60%% of shutdown value within ~5 s")
	_check(d_60s > 0.02 * d0 and d_60s < d_5s, "slow tail: a residual persists after ~60 s (core stays warm)")


## The M5 headline (advisor): the walk-away-safe story. Settle the coupled core, then
## SCRAM (effective k = k − SCRAM_WORTH) AND cut coolant flow at once — the worst case.
## Fission power must collapse, yet decay heat persists; the always-on ambient loss must
## keep the fuel temperature BOUNDED (never runs away) and the core cools below its
## operating point as the reservoirs drain. Uses the real coupled path incl. decay heat.
func _test_scram_passive_safety() -> void:
	print("\n[scram + decay heat: fission collapses, heat persists, temperature bounded]")
	var built := _build_core_pebbles(0.113)
	var grid: Grid = built[0]
	var pebbles: Dictionary = built[1]
	var positions: Dictionary = built[2]
	var dt := 0.05
	var solve_every := 4
	var refuel_every := 6              # hold the core critical pre-scram (mirrors _run_burnup_loop)
	var a := Thermal.A_NOMINAL
	var flow := Thermal.FLOW_NOMINAL
	var inlet := Thermal.T_INLET
	var k := 1.0
	var flux := PackedFloat32Array()
	var scrammed := false
	var a_before := 0.0
	var peak_before := 0.0
	var decay_at_scram := 0.0
	var peak_seen_after := 0.0
	var decay_5s := 0.0
	var scram_step := 4400   # 220 s to settle
	var post_steps := 3600   # 180 s of scram + loss-of-flow
	for i in range(scram_step + post_steps):
		if i == scram_step:
			scrammed = true
			flow = Thermal.FLOW_MIN            # worst case: scram AND loss of flow
			a_before = a
			peak_before = _bed_peak_temp(pebbles)
			decay_at_scram = _bed_decay_power(pebbles)
		var h := Thermal.h_of_flow(flow)
		if i % solve_every == 0:
			grid.homogenize(pebbles, positions)          # rebuilds XS + grid.temperature
			Thermal.solve_coolant_field(grid, flow, inlet)
			Thermal.apply_field_doppler(grid)
			var sol := Neutronics.solve(grid)
			k = sol.k_eff
			flux = sol.flux
			for id in positions:
				pebbles[id].local_flux = grid.sample(flux, positions[id])
				pebbles[id].local_coolant = grid.sample(grid.coolant_temp, positions[id])
		# Scram is a KINETICS-only negative reactivity; the thermal/decay loop keeps running.
		var k_kin := k - (Thermal.SCRAM_WORTH if scrammed else 0.0)
		a = Thermal.step_power(a, k_kin, dt)
		var power_frac := a / Thermal.A_REF
		var campaign_dt := dt * Clocks.TIME_ACCEL
		for id in pebbles:
			var peb: Pebble = pebbles[id]
			var s := Thermal.pebble_power(a, peb.local_flux)
			var decay := Thermal.step_decay_heat(peb.decay_e, s, dt)
			var p := Thermal.prompt_power(s) + decay
			peb.temperature = Thermal.step_pebble_temp(peb.temperature, p, peb.local_coolant, h, dt)
			Depletion.step(peb, peb.local_flux * power_frac, campaign_dt)
		# Online refueling holds the core at its critical operating point during the pre-
		# scram settle — WITHOUT it the bed depletes itself subcritical (passive burnup
		# shutdown) and A collapses before the scram, so there is no running start to trip.
		if i % refuel_every == 0:
			_refuel_most_burned(pebbles, 0.113)
		if scrammed:
			peak_seen_after = maxf(peak_seen_after, _bed_peak_temp(pebbles))
			if i == scram_step + 100:   # ~5 s after scram
				decay_5s = _bed_decay_power(pebbles)
	var peak_final := _bed_peak_temp(pebbles)
	var decay_final := _bed_decay_power(pebbles)
	print("  pre-scram:  A=%.1f  peakT=%.0f K  decayP=%.1f" % [a_before, peak_before, decay_at_scram])
	print("  post scram+LOF: A=%.4f  peakT seen=%.0f K  final=%.0f K   decayP 5s=%.1f final=%.1f"
		% [a, peak_seen_after, peak_final, decay_5s, decay_final])
	_check(a_before > Thermal.A_RUNNING, "core was running before scram")
	_check(a < Thermal.A_RUNNING and a < 0.05 * a_before,
		"scram collapses fission power to a small fraction of pre-scram")
	_check(peak_seen_after < 2200.0,
		"fuel temperature stays BOUNDED through scram + loss-of-flow (walk-away safe)")
	_check(decay_at_scram > 0.0 and decay_5s > 0.0,
		"decay heat PERSISTS after fission stops (core still producing heat)")
	_check(decay_final < decay_at_scram, "decay heat declines over time as the reservoirs drain")
	_check(peak_final < peak_before, "core cools below its operating point after scram")


## Peak pebble temperature across the bed (test helper).
func _bed_peak_temp(pebbles: Dictionary) -> float:
	var pk := Feedback.T_REF
	for id in pebbles:
		pk = maxf(pk, pebbles[id].temperature)
	return pk


## Total stored decay power across the bed (Σ over pebbles of Σ λ_i·E_i).
func _bed_decay_power(pebbles: Dictionary) -> float:
	var d := 0.0
	for id in pebbles:
		d += Thermal.decay_power(pebbles[id].decay_e)
	return d


## Symmetric packed core at `enrichment` AND design moderation `loading` (M5b). Like
## _build_core but stamps peb.fuel_loading, so homogenize sets each fuel cell's
## moderation ratio M = CrossSections.moderation(loading). loading 1.0 → M 1.0
## (under-moderated, below the k_inf peak); loading 0.5 → M 2.0 (over-moderated, above).
func _build_core_loading(enrichment: float, loading: float) -> Grid:
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
			peb.fuel_loading = loading
			pebbles[id] = peb
			positions[id] = Vector2(x, y)
			id += 1
		y += spacing
	grid.homogenize(pebbles, positions)
	return grid


## Coupled thermal-dynamics loop WITH BOTH feedbacks live — Doppler (fast group) AND
## the moderator-temperature coefficient (rescale Σr/Σa2 by the graphite temperature).
## Mirrors _run_coupled but restores all THREE temperature-free bases each solve and
## applies apply_field_moderator, exactly the live _solve_flux warm path. Isotopics are
## FIXED (no burnup/depletion) — this deliberately keeps MTC OUT of the burnup path that
## validated A_REF (advisor), isolating the moderator feedback's dynamic sign. Returns
## the settled k / A / peak-temp plus the whole trajectory for inspection.
func _run_coupled_mtc(grid: Grid, base_sa1: PackedFloat32Array, base_sr: PackedFloat32Array,
		base_sa2: PackedFloat32Array, flow: float, amplitude: float,
		cell_temp: PackedFloat32Array, steps: int, dt: float, solve_every: int) -> Dictionary:
	var n := grid.cell_count()
	var h := Thermal.h_of_flow(flow)
	var k := 1.0
	var flux := PackedFloat32Array(); flux.resize(n); flux.fill(0.0)
	var peak_seen := 0.0
	var k_hist := PackedFloat32Array()
	var a_hist := PackedFloat32Array()
	var t_hist := PackedFloat32Array()
	for i in range(steps):
		if i % solve_every == 0:
			for c in range(n):
				grid.sigma_a1[c] = base_sa1[c]
				grid.sigma_r[c] = base_sr[c]
				grid.sigma_a2[c] = base_sa2[c]
				grid.temperature[c] = cell_temp[c]   # pebble/graphite T drives BOTH feedbacks
			Thermal.solve_coolant_field(grid, flow, Thermal.T_INLET)
			Thermal.apply_field_doppler(grid)
			Thermal.apply_field_moderator(grid)
			var sol := Neutronics.solve(grid)
			k = sol.k_eff
			flux = sol.flux
		amplitude = Thermal.step_power(amplitude, k, dt)
		var peak := Thermal.T_INLET
		for c in range(n):
			if grid.nu_sigma_f[c] <= 0.0:
				continue
			var p := Thermal.pebble_power(amplitude, flux[c])
			cell_temp[c] = Thermal.step_pebble_temp(cell_temp[c], p, grid.coolant_temp[c], h, dt)
			peak = maxf(peak, cell_temp[c])
		peak_seen = maxf(peak_seen, peak)
		if i % 20 == 0:
			k_hist.append(k); a_hist.append(amplitude); t_hist.append(peak)
	var peak_final := 0.0
	for c in range(n):
		peak_final = maxf(peak_final, cell_temp[c])
	# Tail (last 30%) means — the settled metric.
	var tail_from := int(t_hist.size() * 0.7)
	var mt := 0.0; var mk := 0.0; var ma := 0.0; var nn := 0
	for j in range(tail_from, t_hist.size()):
		mt += t_hist[j]; mk += k_hist[j]; ma += a_hist[j]; nn += 1
	if nn > 0:
		mt /= nn; mk /= nn; ma /= nn
	var stride := maxi(1, t_hist.size() / 12)
	var traj := ""
	for j in range(0, t_hist.size(), stride):
		traj += "    t=%3.0fs  k=%.4f  peakT=%5.0f  A=%9.2f\n" % [j * 20 * dt, k_hist[j], t_hist[j], a_hist[j]]
	return {"k": k, "A": amplitude, "peak_final": peak_final, "peak_seen": peak_seen,
			"mean_k": mk, "mean_A": ma, "mean_peakT": mt, "traj": traj}


## THE M5b HEADLINE (CLAUDE.md validation target): "under- vs over-moderation flips the
## sign of the moderator coefficient — a player should be able to accidentally build an
## unstable core and see why." Proven here in the COUPLED DYNAMICS (the static sign flip
## lives in test_neutronics): two cores with MATCHED cold reactivity but opposite sides
## of the k_inf(M) peak are integrated from a cold start with Doppler + MTC live.
##  * under-moderated (M=1.0): MTC negative, reinforces Doppler → settles fast at a modest
##    operating temperature (this ALSO guards the nominal core surviving the pebble-temp
##    MTC — the gap the Doppler-only burnup suite can't see, advisor).
##  * over-moderated  (M≈2.0): MTC positive, FIGHTS Doppler → the core must heat far more
##    before Doppler alone finally pins k, so it runs to a much hotter, higher-power
##    excursion (or to the cap). Hotter equilibrium at matched cold k = the instability.
func _test_moderation_instability() -> void:
	print("\n[moderation instability: under- vs over-moderated coupled dynamics]")
	var flow := Thermal.FLOW_NOMINAL
	var dt := 0.05
	var steps := 8000        # 400 s
	var solve_every := 4
	# The clean demo: FLIP ONE KNOB (fuel loading) at the SAME enrichment. At E=0.085
	# both cores are cold-critical to ~1% (probed: M=1.0→1.009, M=2.0→1.015), so any
	# difference in what follows is PURELY the moderator-coefficient sign, not a reactivity
	# handicap. (That the over-moderated core needs no extra fissile to match is a property
	# of THIS k_inf(M) curve — the peak sits at M≈1.2, so M=2.0 and M=1.0 are near-equidistant
	# in k. The physics that matters is the SLOPE dk/dM, opposite-signed on the two sides.)
	var enrich := 0.085

	# Under-moderated core (M=1.0): MTC negative, reinforces Doppler.
	var g_u := _build_core_loading(enrich, 1.0)
	var bu1 := g_u.sigma_a1.duplicate(); var bur := g_u.sigma_r.duplicate(); var bu2 := g_u.sigma_a2.duplicate()
	var ku_cold := Neutronics.solve(g_u).k_eff
	var ct_u := PackedFloat32Array(); ct_u.resize(g_u.cell_count()); ct_u.fill(Thermal.T_INLET)
	var su := _run_coupled_mtc(g_u, bu1, bur, bu2, flow, Thermal.A_NOMINAL, ct_u, steps, dt, solve_every)

	# Over-moderated core (M=2.0 via loading 0.5), SAME enrichment — matched cold reactivity,
	# opposite feedback sign.
	var g_o := _build_core_loading(enrich, 0.5)
	var bo1 := g_o.sigma_a1.duplicate(); var bor := g_o.sigma_r.duplicate(); var bo2 := g_o.sigma_a2.duplicate()
	var ko_cold := Neutronics.solve(g_o).k_eff
	var ct_o := PackedFloat32Array(); ct_o.resize(g_o.cell_count()); ct_o.fill(Thermal.T_INLET)
	var so := _run_coupled_mtc(g_o, bo1, bor, bo2, flow, Thermal.A_NOMINAL, ct_o, steps, dt, solve_every)

	print("  UNDER (M=1.0): k_cold=%.4f" % ku_cold)
	print(su["traj"])
	print("  under settled: k=%.4f  peakT=%.0f K (seen %.0f)  A=%.2f  meanT=%.0f"
		% [su["mean_k"], su["peak_final"], su["peak_seen"], su["mean_A"], su["mean_peakT"]])
	print("  OVER  (M=2.0): k_cold=%.4f" % ko_cold)
	print(so["traj"])
	print("  over settled:  k=%.4f  peakT=%.0f K (seen %.0f)  A=%.2f  meanT=%.0f"
		% [so["mean_k"], so["peak_final"], so["peak_seen"], so["mean_A"], so["mean_peakT"]])

	# Both must start cold-supercritical, else the comparison is meaningless (a subcritical
	# core just shuts down regardless of feedback sign).
	_check(ku_cold > 1.0 and ko_cold > 1.0, "both cores start cold-supercritical (matched setup)")
	# Under-moderated: negative net feedback → self-regulates to a bounded, modest operating point.
	_check(su["mean_peakT"] < 1400.0 and su["mean_A"] > Thermal.A_RUNNING,
		"under-moderated core self-regulates to a modest running operating point")
	# The headline: over-moderated core runs FAR hotter at matched cold reactivity — positive
	# MTC fights Doppler, so the core cannot settle until it is much hotter (the instability).
	_check(so["mean_peakT"] > su["mean_peakT"] + 300.0,
		"over-moderated core settles/excursions FAR hotter (%.0f vs %.0f K) — positive MTC"
			% [so["mean_peakT"], su["mean_peakT"]])
	_check(so["peak_seen"] > su["peak_seen"] + 300.0,
		"over-moderated core overshoots harder (peak seen %.0f vs %.0f K)"
			% [so["peak_seen"], su["peak_seen"]])


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1
