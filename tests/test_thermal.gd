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
				grid.sigma_a[c] = base_sa[c]
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
	var base_sa := grid.sigma_a.duplicate()
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
## same real code path (only the inlet/flow/steps differ).
func _run_burnup_loop(enrichment: float, inlet: float, flow: float, steps: int) -> Dictionary:
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
			var base_sa := grid.sigma_a.duplicate()
			k_cold = Neutronics.solve(grid).k_eff         # temp-free reference
			grid.sigma_a = base_sa
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
	var vt := 0.0
	for j in range(tail_from, peakt_hist.size()):
		vt += (peakt_hist[j] - mt) * (peakt_hist[j] - mt)
	var sd := sqrt(vt / nn)
	var stride := maxi(1, peakt_hist.size() / 12)
	var traj := ""
	for j in range(0, peakt_hist.size(), stride):
		traj += "    t=%3.0fs  k_cold=%.4f  peakT=%4.0f  A=%6.1f\n" \
			% [j * 20 * dt, kcold_hist[j], peakt_hist[j], a_hist[j]]
	return {"mean_peakT": mt, "sd_peakT": sd, "mean_kcold": mk, "mean_a": ma, "traj": traj}


func _test_coupled_with_burnup_settles() -> void:
	print("\n[coupled loop WITH burnup + refueling: settles, no limit cycle]")
	var st := _run_burnup_loop(0.113, Thermal.T_INLET, Thermal.FLOW_NOMINAL, 8000)  # 400 s
	var mt: float = st["mean_peakT"]; var sd: float = st["sd_peakT"]
	var mk: float = st["mean_kcold"]; var ma: float = st["mean_a"]
	print(st["traj"])
	print("  tail(last40%%): mean peakT=%.0f K  sd=%.0f K (%.0f%%)  mean k_cold=%.4f  mean A=%.1f"
		% [mt, sd, 100.0 * sd / maxf(mt - Feedback.T_REF, 1.0), mk, ma])
	# The trap (advisor): a running core needs k_cold to HOLD > 1 with nonzero power.
	_check(mk > 1.0, "k_cold holds supercritical at the refueling equilibrium (steady power exists)")
	_check(ma > Thermal.A_RUNNING, "core settles at a running power level (not shut down)")
	# Settled, not limit-cycling: tail peak-temp swing is a modest fraction of ΔT.
	_check(sd < 0.25 * maxf(mt - Feedback.T_REF, 1.0),
		"peak temperature is settled (tail swing < 25%% of ΔT) — no relaxation oscillation")
	# A_REF must match the amplitude the core actually settles at — this is the real
	# operating point (a burnt-down k_cold≈1.016 core), NOT solve_equilibrium on a
	# fresh over-reactive lattice. If A_REF drifts from this, burnup desyncs from the
	# operating power and the limit cycle returns (see thermal.gd A_REF rationale).
	_check(absf(ma - Thermal.A_REF) < 0.5 * Thermal.A_REF,
		"A_REF (%.0f) matches the settled operating amplitude (%.1f)" % [Thermal.A_REF, ma])


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
	var base_sa := grid.sigma_a.duplicate()
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


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  PASS  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1
