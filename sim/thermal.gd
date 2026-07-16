# sim/thermal.gd
#
# Thermal & cooling core (M4) — the energy balance that turns M2's INSTANT
# Doppler regulation into a real, time-lagged, self-regulating thermal system
# (CLAUDE.md M4). This is the one field that genuinely time-integrates on the
# fast (physics) clock: the flux is clockless/quasi-static and burnup is on the
# slow campaign clock, but pebble temperature has a tens-of-seconds inertia that
# IS the source of lag, overshoot, and settling.
#
# The honest feedback loop it closes (CLAUDE.md):
#     power → heat → pebble temperature (with inertia) → Doppler reactivity → power
#
# Two coupled state variables, each with a numerically-robust integrator:
#
#   1. Power amplitude A  — how many "real" fissions the peak-normalized flux
#      shape stands for. Toy point-kinetics: dA/dt = A·(k−1)·KINETICS_GAIN. Over
#      one step k is frozen (re-solved on a cadence), so this is the LINEAR ODE
#      dA/dt = A·c, whose EXACT solution is A·exp(c·dt) — used directly. That is
#      unconditionally stable and never goes negative, unlike explicit Euler,
#      which would blow up the moment (k−1) is sizeable during a transient.
#
#   2. Pebble temperature T — lumped single-node energy balance:
#          C·dT/dt = P_fission − G_conv·(T − T_cool) − G_amb·(T − T_amb)
#      Integrated SEMI-IMPLICITLY (backward Euler on the loss terms), which is
#      stable for any step / any conductance — critical because high coolant flow
#      makes G_conv large, exactly where explicit Euler dies.
#
# WHY the always-on ambient term G_amb: with coolant flow → 0 (loss-of-flow),
# G_conv → 0, and a purely convective balance has NO steady state — temperature
# would rise forever. A small, flow-INDEPENDENT passive loss (radiation /
# conduction to structure) gives the walk-away-safe demo a BOUNDED settling
# temperature, which is the whole point of that demo (advisor).
#
# Pure and engine-agnostic (CLAUDE.md principle 5): no Godot, no physics engine.
# Every constant is a TOY value pinned by tests/test_thermal.gd, exactly as the
# neutronics/feedback constants were — only signs, time constants, and settling
# behavior carry meaning here, not absolute watts.
class_name Thermal
extends RefCounted

# Cold inlet coolant / ambient reference (K). Matches Feedback.T_REF and
# Grid.T_INLET — Doppler feedback is defined to be zero here.
const T_INLET := 293.15
const T_AMBIENT := 293.15

# --- Per-pebble lumped energy balance ---------------------------------------

# Lumped heat capacity of one pebble (toy energy/K). This is the THERMAL INERTIA:
# larger C → slower response → more pronounced lag and overshoot. Tuned with the
# conductances below so the pebble time constant τ = C/(G_conv+G_amb) lands in the
# tens-of-seconds range real pebbles have (CLAUDE.md: ~tens of seconds).
const HEAT_CAPACITY := 1.0

# Convective conductance to the coolant at NOMINAL flow (toy energy/K/s). Folds
# the Newton-cooling h·A_surface into one lumped term. h_of_flow() scales it with
# coolant mass flow; this is its value at flow = 1.0 (the nominal operating point).
const G_CONV_NOMINAL := 0.05
# Turbulent-ish convection: h grows sub-linearly with mass flow (real packed beds
# ~flow^0.6-0.8). Fitted, not a Nusselt correlation (CLAUDE.md: no real
# correlations for the toy).
const H_FLOW_EXP := 0.8

# Always-on passive loss conductance (toy energy/K/s), flow-INDEPENDENT. Small
# (~10% of nominal convection) so it barely perturbs normal operation, but it is
# what bounds the loss-of-flow steady state (see module header).
const G_AMBIENT := 0.005

# --- Fission heat source ----------------------------------------------------

# Maps (power amplitude A × peak-normalized local flux) → a pebble heat-generation
# rate. A carries the absolute power level, so this is only an overall scale; the
# equilibrium fuel temperature is pinned by Doppler, NOT by this number (a
# self-consistency the test checks).
const HEAT_PER_FLUX := 1.0

# --- Decay heat (M5) --------------------------------------------------------
#
# After fission stops, decaying fission products keep releasing heat — the reason a
# reactor must still be cooled post-scram and the basis of the passive-safety demo
# (CLAUDE.md glossary "decay heat"). Modeled ENERGY-CONSERVINGLY so it does NOT
# perturb the M4 operating point (advisor): the total fission power S is RE-
# PARTITIONED, not augmented. A fraction (1 − DECAY_GAMMA) of S is deposited
# promptly; the rest feeds a few decay-heat reservoirs E_i that fill from fission
# and drain at their own rate λ_i:
#     dE_i/dt = f_i·S − λ_i·E_i,   delivered decay power = Σ λ_i·E_i
# At steady state λ_i·E_i = f_i·S, so decay delivers Σf_i·S = DECAY_GAMMA·S and the
# TOTAL delivered heat (1−γ)S + γS = S — identical to M4, so A_REF and the operating
# temperatures are untouched. ONLY the post-scram transient differs: the prompt part
# vanishes with the fission power, and the reservoirs drain to give the characteristic
# fast-drop-then-slow-tail decay-heat curve that keeps the core hot after shutdown.
#
# Three toy groups span fast→slow (τ ≈ seconds → ~2 min) so the tail is VISIBLE over a
# demo rather than a Way-Wigner fit to real half-lives (CLAUDE.md: qualitative toy).
# γ ≈ 6.5% echoes the ~7% of reactor power that is decay heat just after shutdown.
# Pinned by tests/test_thermal.gd; γ and the λ's are the ONLY knobs (never A_REF).
const DECAY_FRACS := [0.030, 0.025, 0.010]     # f_i (Σ = DECAY_GAMMA)
const DECAY_LAMBDAS := [0.40, 0.05, 0.008]     # λ_i (1/s): τ ≈ 2.5 / 20 / 125 s
const DECAY_GAMMA := 0.065                      # Σ f_i; prompt fraction = 1 − this

# --- Scram: MOVED (M5a → M5d-unified) ---------------------------------------
#
# Scram used to live here as `SCRAM_WORTH := 0.15` — a lumped negative reactivity
# subtracted from k in the kinetics only. It is GONE: scram is now simply a full
# insertion of the real control rods (main._toggle_scram → _rod_insertion = 1.0,
# sim/control_rods.gd), so its worth is EMERGENT from the eigenvalue solve like every
# other reactivity effect in this sim, rather than a constant that had to be
# hand-calibrated to be "big enough".
#
# WHY the unification is a strict improvement, not just a tidy-up: the lumped term was
# invisible to the flux — it could not depress the flux shape, could not interact with
# xenon, and its worth could not depend on core state. The rod bank does all three, and
# it measures DEEPER than the constant it replaces (full insertion is worth 0.3845 Δk on
# the nominal core, k 1.0091 → 0.6247 — see tests/test_control_rods.gd), so the trip is
# stronger than it was: the e-fold tightens from ~1.7 s to ~0.7 s, and the core stays
# subcritical after Doppler fully releases with far more margin than the old ≫0.02 need.
#
# UNCHANGED, and still the point: scram does NOT freeze the thermal / decay-heat loop
# (unlike the feedback-OFF demo). Heat CONTINUES after fission stops — that is the
# walk-away-safe demo, gated by tests/test_thermal.gd _test_scram_passive_safety.

# --- Power kinetics (toy point-kinetics) ------------------------------------

# dA/dt = A·(k−1)·KINETICS_GAIN. GAIN sets the power e-folding time: at a typical
# residual (k−1) ≈ 0.015 the response time ≈ 1/(0.015·GAIN). Tuned so power responds
# over a VISIBLE few-to-tens of seconds AND — critically — NO FASTER than the pebble
# thermal time constant τ ≈ 18 s. WHY: if power outruns the thermal feedback it
# overshoots the critical level, and (with burnup ∝ power) that pulse of extra
# fission over-depletes k, driving a relaxation oscillation / limit cycle (observed
# live at GAIN=10). Keeping the power e-fold ≳ τ makes temperature LEAD power, so
# Doppler damps the approach instead of ringing. e-fold at k−1=0.015 ≈ 17 s ≈ τ.
const KINETICS_GAIN := 4.0

# Source floor on the amplitude: a shut-down core keeps a vanishing "power" so it
# can physically restart if it later goes supercritical again, and never divides
# by or multiplies from an exact zero. Well below any running level.
const A_MIN := 1.0e-4
# Display ceiling. Only bites with feedback OFF, where k stays > 1 and power grows
# without bound — the "no self-limiting" teaching demo. The cap keeps the readout
# finite (the point is the runaway, not a numeric overflow); a regulating core
# never approaches it.
const A_MAX := 1.0e6
# Above this amplitude the core is meaningfully producing power. A display/status
# threshold only — depletion no longer cliff-gates on it (burnup scales smoothly
# with A/A_REF instead), so an idling core reads "shut down" without a hard cutoff.
const A_RUNNING := 0.05

# DESIGN-POINT operating amplitude — the reference that normalizes burnup fluence.
# Real fluence = absolute flux = A × (peak-normalized shape), so burnup must scale
# with A/A_REF (advisor): at the design point A ≈ A_REF → the rate equals M3's
# calibration (TIME_ACCEL and the depletion constants are PRESERVED, not re-tuned);
# an idling core (A ≪ A_REF) barely burns; an over-powered one burns faster. Its
# value must be a SELF-CONSISTENT fixed point, because A_REF is NOT mere display
# bookkeeping — it feeds the physics through a loop: power_frac = A/A_REF scales the
# burnup rate → the equilibrium burnup distribution → k_cold → the Doppler ΔT the core
# settles at → the settled amplitude A itself. So "the core settles at A, therefore set
# A_REF = A" is CIRCULAR: a settled A measured at one A_REF is not the A the core would
# settle at under a different A_REF. 87 is the value at which the loop closes on itself
# — the coupled settle test converges to A ≈ 86 at A_REF = 87 (power_frac ≈ 1), and the
# live main scene, run AT A_REF = 87, settles stable at ~900 K. Both worlds are stable
# here; it is the only validated fixed point.
#
# WHY not the ~32 the live scene reads: that sample was taken with A_REF = 87 (power_frac
# ≈ 0.37), so it is an OFF-fixed-point reading, not the amplitude the live core would
# reach at power_frac 1. Chasing it (A_REF = 32) drove power_frac to ~2.7× in the coupled
# tests → 2.7× burnup → k droops faster than refueling restores → a relaxation LIMIT
# CYCLE (and the scram walk-away-safe bound broke as the over-powered core spiked post-
# scram). The cost of staying at 87 is purely COSMETIC: the live core burns ~2.7× slow,
# a timescale already compressed by TIME_ACCEL and invisible unless the player counts
# passes — the burnup GRADIENT, flat-reactivity, and discharge-composition targets are
# spatial/relative and survive. KNOWN follow-up: at power_frac ~0.37 a pebble needs
# more passes to reach DISCHARGE_BURNUP, which can bump against the MAX_PASSES = 15
# backstop and discharge it under-burned. Pinning A_REF to the live fixed point (an
# iterative several-run calibration) is the real fix if the fuel cycle ever matters
# quantitatively; for now the slow burn is an accepted cosmetic timescale offset.
const A_REF := 87.0
# Startup amplitude — a nominal running level. Paired with seeding pebble
# temperatures to the M2 equilibrium so the sim starts NEAR steady state and just
# settles, rather than launching with a violent cold-start transient (advisor).
const A_NOMINAL := 1.0

# Nominal coolant mass flow (the "1.0" that G_CONV_NOMINAL is defined at) and the
# player-adjustable range. Flow is the PRIMARY operating lever (CLAUDE.md M4):
# lower flow → hotter pebbles → stronger Doppler → power self-limits.
const FLOW_MIN := 0.05    # near loss-of-flow (not exactly 0 so h(flow) is smooth)
const FLOW_MAX := 2.0
const FLOW_NOMINAL := 1.0
const FLOW_STEP := 0.1

# --- Coolant transport (M4b) ------------------------------------------------
#
# The downstream coolant energy balance: helium enters cold at the top and warms
# as it flows DOWN through the bed (co-current with the falling pebbles), picking
# up each cell's convective heat. A per-column top-down march (solve_coolant_field)
# turns the per-cell pebble→coolant heat into a spatial coolant-temperature field,
# so a deep pebble is cooled by hotter helium than a shallow one — the missing
# spatial structure M4a stubbed out with a uniform inlet.

# Coolant heat-capacity rate ṁ·cp per column at nominal flow (toy energy/K/s). This
# is the KEY M4b calibration knob (advisor): it sets how much the coolant warms per
# unit heat picked up (ΔT_bed = Q_column / W). Chosen LARGE relative to a cell's
# convective conductance so the NOMINAL-flow bed temperature rise is a modest
# fraction of the pebble ΔT — that keeps nominal-flow behavior close to M4a and
# PRESERVES the A_REF operating point (tune THIS, never A_REF, if the coupled test
# drifts). W scales linearly with mass flow, so LOW flow shrinks W → a bigger
# coolant rise → hotter deep pebbles: it reinforces the loss-of-flow transient
# alongside the h(flow) drop. Pinned by tests/test_thermal.gd.
const W_NOMINAL := 30.0

# Pebbles per fully-packed grid cell — the geometric factor turning a cell's
# per-pebble convective conductance h into the cell's TOTAL conductance
# (G_cell = h · packing · CELL_PEBBLES). For the default 68 px cell and 8 px pebble
# this is cell_area/(π r²) ≈ 23, so the coolant picks up exactly the heat the
# pebbles in the cell shed (energy-consistent with the per-pebble Newton cooling in
# the thermal step). A toy geometric constant, not a free parameter.
const CELL_PEBBLES := 23.0

# Player inlet-temperature lever (M4b) — the load-following knob (advisor). Raising
# the returning coolant temperature shrinks the convective gap (T_pebble − T_cool),
# so at the Doppler-pinned fuel temperature each pebble sheds LESS power and the core
# settles at a LOWER power level: honest load-following through the existing loop, no
# new reactivity coefficient (the moderator coefficient stays M5). Range from cold
# inlet up to a hot return; default is the cold reference so M4a behavior is the
# starting point.
const INLET_MIN := 293.15
const INLET_MAX := 700.0
const INLET_STEP := 15.0


## Coolant heat-capacity rate ṁ·cp at a given mass flow (toy). Linear in mass flow:
## more coolant carries more enthalpy per kelvin, so a given heat load warms it less.
static func w_of_flow(flow: float) -> float:
	return W_NOMINAL * maxf(flow, 0.0) / FLOW_NOMINAL


## Solve the quasi-steady coolant-transport field in place on `grid.coolant_temp`,
## and return the total extracted thermal power (coolant enthalpy rise summed over
## columns) — the heat the secondary side / heat exchanger harvests, i.e. the
## headline reactor power at steady state.
##
## Co-current top-down march, each column independent (the funnel is handled for
## free — a column simply stops picking up heat once it leaves the fuel). For each
## fuel cell the coolant passes through, an IMPLICIT single-cell balance
##     W·(T_out − T_in) = G_cell·(T_peb − T_out)
##  ⇒ T_out = (W·T_in + G_cell·T_peb) / (W + G_cell)
## makes T_out a convex blend of the incoming coolant and the local pebble
## temperature: it can NEVER exceed T_peb, so at low flow (W → small) the coolant
## asymptotes to the pebble temperature instead of overshooting it and (2nd-law
## violation) heating pebbles downstream — the same stability reasoning that made
## the pebble update semi-implicit. The cell's stored coolant temperature is the
## outlet value the next cell down (and the pebbles here) see.
static func solve_coolant_field(grid: Grid, flow: float, t_inlet: float) -> float:
	var w := w_of_flow(flow)
	var h := h_of_flow(flow)
	var extracted := 0.0
	for i in range(grid.nx):
		var t_cool := t_inlet
		for j in range(grid.ny):
			var c := grid.idx(i, j)
			# Only fuel cells hold heat-shedding pebbles; void/reflector cells pass
			# the coolant through unchanged (nu_sigma_f flags a fuel cell as in the
			# rest of the coupling).
			if grid.nu_sigma_f[c] > 0.0:
				var g_cell := h * grid.packing[c] * CELL_PEBBLES
				var t_peb := grid.temperature[c]
				var t_out := (w * t_cool + g_cell * t_peb) / (w + g_cell)
				extracted += w * (t_out - t_cool)   # enthalpy this cell added to the coolant
				t_cool = t_out
			grid.coolant_temp[c] = t_cool
	return extracted


## Newton-cooling conductance at a given coolant mass flow. Monotonically
## increasing (more flow → better convection → cooler pebbles), sub-linear.
static func h_of_flow(flow: float) -> float:
	return G_CONV_NOMINAL * pow(maxf(flow, 0.0) / FLOW_NOMINAL, H_FLOW_EXP)


## Exponential (EXACT over a frozen-k step) update of the power amplitude.
## Unconditionally stable and strictly positive. Clamped to A_MIN as a source
## floor so a subcritical core can later restart.
static func step_power(amplitude: float, k_eff: float, dt: float) -> float:
	var a := amplitude * exp((k_eff - 1.0) * KINETICS_GAIN * dt)
	return clampf(a, A_MIN, A_MAX)


## Semi-implicit (backward-Euler) update of a pebble's lumped temperature for one
## physics step. `p_fission` is the heat-generation rate, `h_conv` the convective
## conductance from h_of_flow(). Stable for any dt and any conductance.
##
##   C·(T' − T)/dt = P − G_conv·(T' − T_cool) − G_amb·(T' − T_amb)
##   ⇒ T' = (C·T + dt·(P + G_conv·T_cool + G_amb·T_amb)) / (C + dt·(G_conv + G_amb))
static func step_pebble_temp(temp: float, p_fission: float, t_coolant: float, h_conv: float, dt: float) -> float:
	var gain := HEAT_CAPACITY + dt * (h_conv + G_AMBIENT)
	var src := HEAT_CAPACITY * temp + dt * (p_fission + h_conv * t_coolant + G_AMBIENT * T_AMBIENT)
	return src / gain


## Per-pebble TOTAL fission heat-generation rate S from the current power amplitude
## and the pebble's local (peak-normalized) flux. The M4 heat source; at M5 it is
## split into a prompt part (prompt_power) and the decay-heat reservoirs.
static func pebble_power(amplitude: float, local_flux: float) -> float:
	return HEAT_PER_FLUX * amplitude * local_flux


## Number of decay-heat groups (reservoirs per pebble).
static func decay_group_count() -> int:
	return DECAY_FRACS.size()


## The PROMPT (instantaneous) fraction of the total fission power S — the part NOT
## routed through the decay reservoirs. Delivered pebble heat = prompt_power(S) +
## step_decay_heat(...); at steady state that sums back to exactly S (see header).
static func prompt_power(s: float) -> float:
	return (1.0 - DECAY_GAMMA) * s


## Semi-implicit (backward-Euler) multi-group decay-heat update for one pebble's
## reservoirs `e` (lazily sized/zeroed on first use — fresh fuel has no fission-
## product inventory), fed by the total fission power `s`. Returns the decay power
## DELIVERED this step (Σ λ_i·E_i') — the heat that persists after fission stops.
##
##   E_i' = (E_i + dt·f_i·s) / (1 + dt·λ_i)
##
## Backward Euler ⇒ unconditionally stable and strictly non-negative at any step,
## matching step_power / step_pebble_temp (advisor: don't reintroduce an explicit
## integrator that can go negative during a fast scram transient).
static func step_decay_heat(e: PackedFloat32Array, s: float, dt: float) -> float:
	if e.size() != DECAY_FRACS.size():
		e.resize(DECAY_FRACS.size())   # zero-initialized: no inventory yet
	var delivered := 0.0
	for i in range(DECAY_FRACS.size()):
		var ei := (e[i] + dt * float(DECAY_FRACS[i]) * s) / (1.0 + dt * float(DECAY_LAMBDAS[i]))
		e[i] = ei
		delivered += float(DECAY_LAMBDAS[i]) * ei
	return delivered


## Seed the reservoirs to the steady state for a constant fission power `s`
## (E_i = f_i·s / λ_i), so the core can OPEN at its operating decay-heat inventory
## instead of building it up from zero — the same reason pebble temperatures are
## seeded at startup (advisor: avoid a spurious decay-heat build-up transient).
static func seed_decay_heat(e: PackedFloat32Array, s: float) -> void:
	e.resize(DECAY_FRACS.size())
	for i in range(DECAY_FRACS.size()):
		e[i] = float(DECAY_FRACS[i]) * s / float(DECAY_LAMBDAS[i])


## Decay power currently stored in a pebble's reservoirs (Σ λ_i·E_i), without
## advancing them — for the HUD readout and the decay-heat heatmap field. Zero for
## an uninitialized (fresh, never-stepped) reservoir.
static func decay_power(e: PackedFloat32Array) -> float:
	if e.size() != DECAY_FRACS.size():
		return 0.0
	var d := 0.0
	for i in range(DECAY_FRACS.size()):
		d += float(DECAY_LAMBDAS[i]) * e[i]
	return d


## The steady-state temperature a pebble would reach at fixed power and cooling —
## the balance point step_pebble_temp() relaxes toward. Exposed for tests and for
## the fast-forward-collapse path (quasi-steady thermal when the campaign clock
## is fast — CLAUDE.md clock model; deferred until a time-skip control exists).
static func steady_temp(p_fission: float, t_coolant: float, h_conv: float) -> float:
	return (p_fission + h_conv * t_coolant + G_AMBIENT * T_AMBIENT) / (h_conv + G_AMBIENT)


## Add the Doppler resonance-absorption feedback to a grid's FAST-group absorption
## field (M5b: Doppler is epithermal → Sigma_a1) using its REAL per-cell
## temperature (from homogenized pebble temperatures), in place. This is the M4
## replacement for M2's critical-power search: the temperature is now a measured
## state, not a value invented to force k = 1. Delegates the correlation itself to
## Feedback.doppler_sigma_a (unchanged).
static func apply_field_doppler(grid: Grid) -> void:
	for c in range(grid.cell_count()):
		grid.sigma_a1[c] += Feedback.doppler_sigma_a(grid.temperature[c])


## Apply the moderator-temperature coefficient (M5b) to a grid's THERMAL-group
## cross-sections in place, using each fuel cell's LOCAL PEBBLE (graphite) temperature.
## WHY pebble, not coolant: in a gas-cooled pebble bed the helium moderates
## negligibly — the graphite moderator IS inside the pebble, sitting at pebble
## temperature. So the moderator coefficient rides the pebble/fuel temperature
## (grid.temperature — the SAME field Doppler reads), not the coolant. This is both
## the physically honest driver for this reactor type AND the strong one: the pebble
## swing is ~hundreds of K where the coolant bed rise is ~tens, which is what makes an
## over-moderated core visibly destabilize. (CLAUDE.md M4's "coolant temperature feeds
## the moderator coefficient" is a simplification that is weak for a gas-cooled bed;
## corrected here — see the M4 note in CLAUDE.md.)
## Hotter graphite lowers the effective moderation M_eff (Feedback.moderator_m_eff),
## and both M-dependent cross-sections follow it:
##   * sigma_r  ∝ M      → rescaled by the ratio m_eff / m_base
##   * sigma_a2  has only its MODERATOR-parasitic part (THERM_A_MOD·M·pack) move with
##     M; the fuel/poison part is M-independent, so we shift by the exact parasitic
##     delta THERM_A_MOD·(m_eff − m_base)·pack — no need to reconstruct the poison.
## BOTH must move together: perturbing sigma_r alone (at fixed sigma_a2) makes k
## monotone in M with NO sign flip; the emergent-sign MTC only exists because moving
## M walks BOTH terms along the peaked k_inf(M) curve (cross_sections.gd header).
##
## Guarded to fuel cells (moderation > 0): reflector/void carry M = 0, and the
## sigma_r ratio would divide by zero there. Expects the temperature-FREE base
## sigma_r / sigma_a2 in place (as homogenize leaves them); the caller restores the
## base each solve so this never stacks across frames (mirrors apply_field_doppler).
static func apply_field_moderator(grid: Grid) -> void:
	for c in range(grid.cell_count()):
		var m_base := grid.moderation[c]
		if m_base <= 0.0:
			continue
		var m_eff := Feedback.moderator_m_eff(m_base, grid.temperature[c])
		grid.sigma_r[c] *= m_eff / m_base
		grid.sigma_a2[c] += CrossSections.THERM_A_MOD * (m_eff - m_base) * grid.packing[c]
