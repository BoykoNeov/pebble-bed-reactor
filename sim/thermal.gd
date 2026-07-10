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
# value is the settled amplitude at the LIVE operating point (enrichment ~11.3%,
# k_cold ~ 1.016): (G_CONV_NOMINAL + G_AMBIENT) × the equilibrium ΔT there ≈ 30. WHY
# not the ~15 of the cooler E_REF lattice: the live core runs a hotter, higher-power
# equilibrium, so pinning A_REF to E_REF would read the operating core as ~2× power →
# 2× burnup → k droops twice as fast as refueling restores it → a limit cycle.
# Matching A_REF to the real operating amplitude keeps M3's ~10-pass fuel cycle.
const A_REF := 30.0
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


## Per-pebble fission heat-generation rate from the current power amplitude and
## the pebble's local (peak-normalized) flux. The M4 heat source.
static func pebble_power(amplitude: float, local_flux: float) -> float:
	return HEAT_PER_FLUX * amplitude * local_flux


## The steady-state temperature a pebble would reach at fixed power and cooling —
## the balance point step_pebble_temp() relaxes toward. Exposed for tests and for
## the fast-forward-collapse path (quasi-steady thermal when the campaign clock
## is fast — CLAUDE.md clock model; deferred until a time-skip control exists).
static func steady_temp(p_fission: float, t_coolant: float, h_conv: float) -> float:
	return (p_fission + h_conv * t_coolant + G_AMBIENT * T_AMBIENT) / (h_conv + G_AMBIENT)


## Add the Doppler resonance-absorption feedback to a grid's absorption field
## using its REAL per-cell temperature (from homogenized pebble temperatures),
## in place. This is the M4 replacement for M2's critical-power search: the
## temperature is now a measured state, not a value invented to force k = 1.
## Delegates the correlation itself to Feedback.doppler_sigma_a (unchanged).
static func apply_field_doppler(grid: Grid) -> void:
	for c in range(grid.cell_count()):
		grid.sigma_a[c] += Feedback.doppler_sigma_a(grid.temperature[c])
