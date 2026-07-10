# sim/depletion.gd
#
# Per-pebble fuel depletion (M3) — the slow-clock chemistry that turns the
# player's design and the flux field into an evolving isotopic vector. This is
# the "deplete isotopics" step of the coupling loop (CLAUDE.md two-worlds).
#
# WHY a simplified Bateman chain, not a real depletion solver: this is a toy
# (CLAUDE.md principle 3-4). We track the few isotopes that carry the qualitative
# behavior and evolve them with smooth, TUNED micro-rates whose only jobs are to
# get the SIGNS right and to move k-eff by a visible margin over a pebble's life.
# The chain we model:
#
#     U-235  --(absorb)-->  gone           (fissile burns away → reactivity falls)
#     U-238  --(capture)-->  Pu-239         (breeding → partly offsets the loss)
#     Pu-239 --(absorb)-->  gone            (bred fissile also burns → breed-then-burn)
#     fissions  -->  lumped fission-product poison   (parasitic absorption grows)
#
# Reactivity feedback of burnup flows ENTIRELY through this isotopic vector:
# grid.homogenize() reads back the fissile fraction (→ nu_sigma_f) and the poison
# (→ sigma_a). So CrossSections.BURN_PENALTY stays 0 — driving k down BOTH via a
# burnup penalty and via the isotopics would double-count the same physics.
#
# TIMESCALE (CLAUDE.md principle 1): this runs on the CAMPAIGN clock only. The
# caller passes `campaign_dt` (accelerated burn-time) and the pebble's local
# flux; nothing here touches the physics or flux clocks. Burnup rate uses the
# peak-normalized flux SHAPE, not M2's eq.power — see the note on BURN_RATE.
#
# Pure and engine-agnostic: mutates a Pebble's fields, returns nothing. No Godot.
class_name Depletion
extends RefCounted

# --- Toy one-group micro-absorption rates, per unit FLUENCE (flux * campaign_dt).
# Tuned in tests/test_depletion.gd exactly as DOPPLER_C / the M1 constants were:
# the pixel-native flux and campaign clock make absolute values meaningless, so
# these are pinned by "a nominal pebble reaches discharge burnup over ~6-15 passes
# and k(fresh) >> k(discharge)" — not by nuclear data.
const SIGA5 := 0.0075   # U-235 total absorption (fission + capture)
const SIGC8 := 0.00040  # U-238 capture → Pu-239 (the breeding rate)
const SIGA9 := 0.0110   # Pu-239 total absorption. Larger than SIGA5 because Pu-239
                        # has the bigger thermal absorption cross-section — so bred
                        # Pu eventually burns faster than it breeds (breed-then-burn).

# Fraction of each absorption that is a fission (the rest is parasitic capture).
# Only fissions make heat/burnup and fission-product poison.
const FF5 := 0.85
const FF9 := 0.65

# Lumped fission-product poison produced per fission (absorption units added to
# the pebble's `poison`, which homogenize adds straight into sigma_a).
const POISON_YIELD := 0.11

# --- Xenon transient (M5c) --------------------------------------------------
#
# I-135 / Xe-135, the intermediate-timescale poison whose whole point is that it
# rises AND falls (unlike the monotone `poison`). The classic teaching transient —
# the post-shutdown "iodine pit" — falls straight out of ONE structural fact: the
# production terms are FLUX-driven (fissions), but the decay terms are TIME-driven
# and keep running at zero flux. Continuous form (F = fission rate, phi = flux):
#
#     dI/dt  = gamma_I * F                       - lambda_I * I
#     dXe/dt = gamma_Xe * F + lambda_I * I       - lambda_Xe * Xe - sigma_Xe * phi * Xe
#                              \__ dominant Xe source __/           \__ flux burnout __/
#
# When flux collapses (scram / flow cut), F -> 0 (production stops) and the burnout
# term sigma_Xe*phi*Xe -> 0 (removal weakens), but the I ALREADY in inventory keeps
# decaying into Xe (lambda_I * I continues). So Xe RISES above its operating level,
# peaks, then decays away — the pit. That behavior REQUIRES:
#   * lambda_I > lambda_Xe  (iodine dumps into xenon faster than xenon clears), and
#   * sigma_Xe * phi_op  comparable to (or above) lambda_Xe at the operating flux,
#     so cutting flux meaningfully drops the removal rate (else no pit).
# Both are pinned by tests/test_xenon.gd. Values are toy, campaign-time-native (same
# spirit as the depletion micro-rates): only the ORDERING and the pit shape matter.
const I_YIELD := 0.060     # I-135 fission yield (the dominant Xe route, via decay)
const XE_YIELD := 0.003    # direct Xe-135 fission yield (small — most Xe comes from I)
const LAMBDA_I := 0.30     # I-135 decay (1/campaign-time). > LAMBDA_XE (real ordering).
const LAMBDA_XE := 0.12    # Xe-135 decay (1/campaign-time).
const SIGMA_XE := 1.10     # Xe-135 neutron-burnout per unit FLUENCE. At operating flux
                           # phi ~ 0.5, sigma_Xe*phi ~ 0.55 ~ 4.6*LAMBDA_XE, so while the
                           # core runs burnout is the DOMINANT Xe removal path — and its
                           # collapse on shutdown is what opens the pit. Raised from an
                           # earlier 0.55 to DEEPEN the pit (the bigger the running-burnout
                           # share, the further Xe overshoots when it stops); it also lowers
                           # equilibrium Xe, so the operating-point disruption shrinks while
                           # the transient grows (XENON_A2 carries the worth back up). See
                           # the header burnout condition; pinned by tests/test_xenon.gd.

# Burnup accrued per unit fluence. Kept at 1.0 so `burnup` reads directly in the
# MWd/kgHM-proxy units the discharge threshold is expressed in.
#
# WHY burnup uses the flux SHAPE (peak-normalized) and NOT M2's eq.power: in M2
# eq.power is proportional to the EXCESS reactivity Doppler burns off, not to
# thermal power — a core relaxing toward k=1 has eq.power→0, which would stall
# burnup at a false fixed point. The peak-normalized flux gives the correct
# spatial burnup GRADIENT (hotter center burns faster) and keeps refueling
# equilibrium honest. A real power-coupled burnup rate is exactly what M4's
# energy balance provides; until then, shape-only is the right toy.
const BURN_RATE := 1.0

# --- Fuel-cycle policy (calibration-linked, so it lives with the rates it is
# tuned against). A pebble is discharged once burnup crosses DISCHARGE_BURNUP;
# MAX_PASSES is a backstop so a pebble in a cold spot can't recirculate forever.
# DISCHARGE_BURNUP sits in the HTR-PM ~90-100 MWd/kgHM proxy band (CLAUDE.md).
const DISCHARGE_BURNUP := 90.0
const MAX_PASSES := 15


## Advance one pebble's isotopics + burnup by one campaign step.
##
## `flux` is the pebble's local, peak-normalized scalar flux (0..~1) sampled back
## from the grid solve. `campaign_dt` is accelerated burn-time. The caller must
## GATE this to a running core (only call when the reactor is regulated/critical);
## a shut-down core has flux but no fission, so it should not burn fuel.
##
## Uses closed-form exponential decay per isotope rather than explicit Euler, so
## each isotope's update stays positive and stable for ANY step size. Note the
## breed-then-burn chain (U-238 → Pu-239 → gone) is still integrated ACROSS steps:
## within a single step Pu-239 first receives this step's conversion, then decays
## by its own absorption, so Pu turnover emerges only over many small steps — as
## it does live on the campaign clock. One giant step would breed without burning.
static func step(peb: Pebble, flux: float, campaign_dt: float) -> void:
	# Gate on TIME, not flux: the xenon decay chain below must keep running when the
	# flux collapses (post-scram / flow cut) — that is exactly what opens the pit. The
	# fluence-driven burn/breed/poison block stays flux-gated (no flux → no fission).
	if campaign_dt <= 0.0:
		return
	var dphi := maxf(flux, 0.0) * campaign_dt   # fluence delivered this step
	var fissions := 0.0

	if dphi > 0.0:
		# U-235 burns away. burn5 = the amount absorbed this step.
		var burn5 := peb.u235 * (1.0 - exp(-SIGA5 * dphi))
		peb.u235 -= burn5

		# U-238 captures into Pu-239 (breeding). conv8 leaves U-238, enters Pu-239.
		var conv8 := peb.u238 * (1.0 - exp(-SIGC8 * dphi))
		peb.u238 -= conv8

		# Pu-239 also burns; net change is what bred in minus what fissioned/captured.
		var burn9 := peb.pu239 * (1.0 - exp(-SIGA9 * dphi))
		peb.pu239 += conv8 - burn9

		# Only the fissioning share of the absorbed fissile makes poison + energy.
		fissions = FF5 * burn5 + FF9 * burn9
		peb.poison += POISON_YIELD * fissions

		# Burnup integrates local power (∝ flux) over campaign time — see BURN_RATE.
		peb.burnup += BURN_RATE * dphi

	# Xenon transient — always runs (decay is time-based). Production uses this step's
	# fissions (0 when flux is 0); burnout uses dphi; decay uses campaign_dt directly.
	_step_xenon(peb, fissions, dphi, campaign_dt)


## Advance the I-135 / Xe-135 pair one step. `fissions` is this step's fission amount
## (the production driver, 0 at zero flux), `dphi` the fluence (drives Xe burnout, 0 at
## zero flux), and `campaign_dt` the TIME (drives radioactive decay, runs at ANY flux).
##
## Backward Euler per isotope (mirrors Thermal.step_decay_heat): unconditionally stable
## and strictly non-negative at any step size — never let a fast scram transient drive an
## isotope negative. I is solved first, then its fresh decayed inventory feeds Xe, so the
## I->Xe transfer over the step is consistent (the same within-step ordering the Pu chain
## relies on). Xenon removal in the denominator combines TIME decay (lambda_Xe*dt) and
## flux burnout (sigma_Xe*dphi): when flux -> 0, only the decay term survives, removal
## drops, and the I still decaying in tops Xe up — the pit.
static func _step_xenon(peb: Pebble, fissions: float, dphi: float, campaign_dt: float) -> void:
	var i_new := (peb.i135 + I_YIELD * fissions) / (1.0 + LAMBDA_I * campaign_dt)
	var xe_src := peb.xe135 + XE_YIELD * fissions + LAMBDA_I * i_new * campaign_dt
	var xe_sink := 1.0 + LAMBDA_XE * campaign_dt + SIGMA_XE * dphi
	peb.i135 = i_new
	peb.xe135 = xe_src / xe_sink


## Xe-135 inventory a pebble settles at under a CONSTANT flux (its equilibrium), used to
## SEED the initial bed so the core opens at its operating xenon load instead of drooping
## as xenon builds from zero (mirrors Thermal.seed_decay_heat). At equilibrium
## I = gamma_I*F/lambda_I and Xe = (gamma_I+gamma_Xe)*F/(lambda_Xe + sigma_Xe*phi), where
## F is the fission RATE. We express F from the same first-order fissile-burn rate
## Depletion.step uses, so the seed matches what the live loop converges to at this flux.
static func seed_xenon(peb: Pebble, flux: float) -> void:
	if flux <= 0.0:
		peb.i135 = 0.0
		peb.xe135 = 0.0
		return
	# Fission RATE per unit campaign-time at this flux (first-order in the small per-step
	# limit): fissile absorption rate * fission fraction. Matches step()'s `fissions/dt`.
	var f_rate := (FF5 * SIGA5 * peb.u235 + FF9 * SIGA9 * peb.pu239) * flux
	peb.i135 = I_YIELD * f_rate / LAMBDA_I
	peb.xe135 = (I_YIELD + XE_YIELD) * f_rate / (LAMBDA_XE + SIGMA_XE * flux)
