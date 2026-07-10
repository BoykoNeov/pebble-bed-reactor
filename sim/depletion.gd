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
	if flux <= 0.0 or campaign_dt <= 0.0:
		return
	var dphi := flux * campaign_dt   # fluence delivered this step

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
	var fissions := FF5 * burn5 + FF9 * burn9
	peb.poison += POISON_YIELD * fissions

	# Burnup integrates local power (∝ flux) over campaign time — see BURN_RATE.
	peb.burnup += BURN_RATE * dphi
