# sim/feedback.gd
#
# Doppler resonance-absorption feedback (M2) — the negative fuel-temperature
# coefficient that makes the reactor self-regulate (CLAUDE.md M2: the "it's
# alive" moment; glossary "Doppler broadening").
#
# Physics: as fuel heats, U-238 resonance capture broadens (Doppler), so
# absorption rises and reactivity falls. The correlation uses the sqrt(T) form
# real reactors follow — the Doppler *coefficient* goes as 1/sqrt(T), so the
# reactivity worth of heating goes as (sqrt(T) - sqrt(T_ref)). Like the M1
# cross-sections, the strength is TUNED to this pixel-native toy where only the
# SIGN and the self-regulation behavior carry meaning (tests/test_feedback.gd
# pins DOPPLER_C down, exactly as test_neutronics.gd pinned the M1 constants).
#
# This is the temperature-dependent LAYER on top of the base, temperature-free
# cross-sections in cross_sections.gd (the module layout keeps the two separate).
#
# Timescale (CLAUDE.md principle 1): M2's fuel temperature is an INSTANT
# placeholder — T proportional to local power, no thermal inertia. So the coupled
# steady state is a quasi-static CRITICAL-POWER SEARCH: find the power (hence
# temperature) at which Doppler feedback makes the core exactly critical. The
# result is history-independent — a pure function of the current geometry and
# enrichment, NOT of the previous solve. M4 replaces this instant placeholder
# with a real, time-lagged energy balance, turning instant regulation into
# genuine dynamics (lag, overshoot, settling).
class_name Feedback
extends RefCounted

const T_REF := 293.15       # reference (cold / inlet) fuel temperature, K.
                            # Doppler feedback is defined to be zero here.

# sqrt(T) Doppler strength. Tuned so the nominal core (cold k ~ 1.01) burns off
# its ~1% excess reactivity at a plausible fuel temperature (a few hundred K above
# inlet), not at 10^4 K. See tests/test_feedback.gd, which drives this.
#
# M5b: raised from 4.3e-5. Doppler now perturbs the FAST group (Sigma_a1), which
# has a weaker k-sensitivity than the old one-group total absorption, so the same
# strength left the nominal equilibrium too hot (~750 K rise) and the search
# saturating DT_MAX across a small enrichment range. The larger constant restores
# the ~few-hundred-K operating point AND steepens the feedback (equilibria sit
# where the sqrt(T) slope is larger), so k stays pinned across the enrichment sweep.
const DOPPLER_C := 7.5e-5

# Critical-power search: k decreases monotonically with peak fuel temperature, so
# a bisection on the peak temperature rise is bulletproof.
const DT_MAX := 4000.0      # widest peak fuel-temperature rise the search considers (K)
const K_TOL := 1.0e-3       # regulate until |k - 1| < this
const MAX_ITERS := 40


## Extra FAST-group (Sigma_a1) absorption from Doppler broadening at fuel
## temperature `temp`. Doppler resonance capture (U-238) is EPITHERMAL, so in the
## two-group model (M5b) it lands on the fast group, not the thermal group. Zero
## at (and below) T_REF, monotonically increasing above it — the source of the
## negative reactivity feedback. Non-fuel cells never see this because their
## temperature stays at T_REF (no fission power → no heating; see solve_equilibrium).
static func doppler_sigma_a(temp: float) -> float:
	if temp <= T_REF:
		return 0.0
	return DOPPLER_C * (sqrt(temp) - sqrt(T_REF))


# --- Moderator-temperature coefficient (M5b) --------------------------------
#
# The SECOND temperature feedback (CLAUDE.md M4/M5), driven by the COOLANT/moderator
# temperature rather than the fuel temperature. Its defining feature — and the reason
# it earns its own milestone — is that its SIGN IS EMERGENT, not hardcoded: coolant
# heat perturbs the moderation ratio M, and because k_inf(M) is PEAKED (see
# cross_sections.gd header), the reactivity response is NEGATIVE below the peak
# (under-moderated → self-stabilizing) but POSITIVE above it (over-moderated →
# runaway). That sign flip is the "a player can accidentally build an unstable core
# and see why" teaching target (CLAUDE.md validation targets).
#
# The DRIVER has a single fixed sign: a hotter moderator thermally hardens the
# neutron spectrum (graphite expands / density drops, slowing-down weakens), so the
# EFFECTIVE moderation M_eff FALLS with temperature — always, regardless of regime.
# Whether that falling M raises or lowers k is precisely what the peak decides. Same
# sqrt(T) form as Doppler; zero at T_REF so a cold core sits at its design M.
#
# MTC_C magnitude is the calibration that matters (advisor): large enough that the
# over-moderated core visibly destabilizes, small enough that the nominal
# (under-moderated) core stays settled. Tuned live against those two behaviors; the
# static sign flip (tests/test_neutronics.gd) holds at ANY positive MTC_C.
const MTC_C := 2.0e-3

## Effective moderation ratio at coolant/moderator temperature `t_cool`, given the
## design (cold) ratio `m_base`. Hotter coolant → LESS effective moderation
## (m_eff < m_base) — the fixed-sign driver. The k-response sign flip lives in
## k_inf(M), not here. Floored at a small positive fraction so the sigma_r rescale
## (which is proportional to m) can never go negative in a hot transient.
static func moderator_m_eff(m_base: float, t_cool: float) -> float:
	if t_cool <= T_REF or m_base <= 0.0:
		return m_base
	return maxf(m_base * (1.0 - MTC_C * (sqrt(t_cool) - sqrt(T_REF))), 0.05 * m_base)


## Result of one coupled (neutronics + Doppler) quasi-static solve.
class Equilibrium:
	var flux: PackedFloat32Array         # per-cell flux at the regulated state
	var temperature: PackedFloat32Array  # per-cell fuel temperature (K)
	var k_eff: float          # regulated multiplication factor (~1.0 when self-regulating)
	var k_cold: float         # k with feedback OFF (all fuel at T_REF) — the reactivity
	                          # the core WOULD run at uncontrolled. The demo contrast.
	var peak_dt: float        # peak fuel-temperature rise above inlet (K); the state variable
	var power: float          # relative power (a.u.). In the instant placeholder T is
	                          # proportional to power, so power is proportional to peak_dt.
	var regulated: bool       # true if a critical equilibrium exists (cold-supercritical)
	var feedback_insufficient: bool  # true if even DT_MAX can't pin k=1: excess reactivity
	                          # too large for Doppler alone — real reactors hold this with
	                          # control rods (M5). A teaching signal, not a solver failure.
	var iterations: int       # bisection steps taken


## Find the coupled neutronics + Doppler steady state on `grid`.
##
## The instant-placeholder temperature field is T[c] = T_REF + peak_dt * shape[c],
## where shape[c] is the peak-normalized fission-power density (nuSigma_f * flux)
## frozen from the cold solve — its spatial pattern barely moves under the small
## Doppler perturbation, so freezing it keeps the search a clean, monotone 1D
## bisection. We bisect peak_dt for k = 1: the equilibrium power at which feedback
## exactly cancels the excess reactivity.
##
## If the core is not cold-supercritical, NO positive power is critical (feedback
## can only lower k), so it regulates to zero — a passive shutdown.
##
## grid.sigma_a1 (the FAST group) is treated as the temperature-FREE base (as
## homogenize leaves it). The search never corrupts it: it snapshots the base, and
## writes back the equilibrium (warm) absorption so the heatmap/readouts show the
## regulated state.
static func solve_equilibrium(grid: Grid, power_scale := 1.0) -> Equilibrium:
	var n := grid.cell_count()
	var base_sa := grid.sigma_a1.duplicate()   # temperature-free fast-group base absorption

	var eq := Equilibrium.new()

	# Cold reference solve (feedback off): establishes k_cold and the power shape.
	# cold.flux is already the peak-normalized fission-rate density — i.e. exactly the
	# power shape — so no separate _power_shape step is needed (M5b two-group).
	var cold := Neutronics.solve(grid)
	eq.k_cold = cold.k_eff
	var shape := cold.flux.duplicate()

	if cold.k_eff <= 1.0:
		# Subcritical even cold — feedback only lowers k, so there is no critical
		# power. The reactor is off: zero power, fuel at inlet temperature.
		eq.regulated = false
		eq.k_eff = cold.k_eff
		eq.flux = cold.flux
		eq.peak_dt = 0.0
		eq.power = 0.0
		eq.temperature = _temp_field(shape, 0.0, n)
		eq.iterations = 0
		return eq

	# Bisection on peak_dt for k(peak_dt) = 1; k is monotone-decreasing in peak_dt.
	var lo := 0.0
	var hi := DT_MAX
	var mid := 0.0
	var sol := cold
	for it in range(MAX_ITERS):
		mid = 0.5 * (lo + hi)
		_apply_doppler(grid, base_sa, shape, mid, n)
		sol = Neutronics.solve(grid)
		if sol.k_eff > 1.0:
			lo = mid   # still supercritical → needs to run hotter
		else:
			hi = mid   # subcritical → too hot
		eq.iterations = it + 1
		if absf(sol.k_eff - 1.0) < K_TOL:
			break

	eq.regulated = true
	# If we exhausted the temperature headroom and k is still above 1, Doppler
	# alone cannot hold this core: the excess reactivity is beyond what a plausible
	# fuel temperature can burn. Flag it rather than reporting a bogus "critical".
	eq.feedback_insufficient = (sol.k_eff - 1.0) >= K_TOL
	eq.k_eff = sol.k_eff
	eq.flux = sol.flux
	eq.peak_dt = mid
	eq.power = mid * power_scale
	eq.temperature = _temp_field(shape, mid, n)
	return eq


## T[c] = T_REF + peak_dt * shape[c].
static func _temp_field(shape: PackedFloat32Array, peak_dt: float, n: int) -> PackedFloat32Array:
	var t := PackedFloat32Array(); t.resize(n)
	for c in range(n):
		t[c] = T_REF + peak_dt * shape[c]
	return t


## Write the warm FAST-group absorption into grid.sigma_a1: base + Doppler(local
## temperature). (M5b: Doppler is epithermal → fast group.)
static func _apply_doppler(grid: Grid, base_sa: PackedFloat32Array, shape: PackedFloat32Array, peak_dt: float, n: int) -> void:
	for c in range(n):
		var temp := T_REF + peak_dt * shape[c]
		grid.sigma_a1[c] = base_sa[c] + doppler_sigma_a(temp)
