# sim/clocks.gd
#
# The three-clock manager (CLAUDE.md principle 1 — the single most important
# design rule). Three subsystems run at wildly different rates and MUST NOT share
# one delta:
#
#   - Physics clock   — the mechanical / Box2D step, real-time-ish. Godot drives
#                       it via _physics_process(delta); this manager just reads it.
#   - Campaign clock  — accelerated burn-time; compresses a fuel campaign into
#                       minutes. THIS is the only clock this class introduces (M3).
#   - Flux            — CLOCKLESS. The neutron flux equilibrates far faster than
#                       anything mechanical, so it is solved at steady state and
#                       never appears here. (Nothing to time-integrate.)
#
# The load-bearing invariant: campaign time is derived from physics time by a
# single acceleration factor, and campaign_dt is fed to NOTHING except the
# depletion step. Accelerating burnup must never accelerate the physics step or
# the flux solve — so this is the one place the two rates are related, and it is
# deliberately tiny and obvious.
class_name Clocks
extends RefCounted

# Maps one physics second to TIME_ACCEL campaign seconds for the depletion step.
#
# WHY this particular value: the pebble bed's MECHANICAL circulation is itself
# heavily compressed (a pebble crosses the whole bed in ~a minute of wall-clock,
# standing in for what is really weeks). TIME_ACCEL scales fluence per mechanical
# pass so that ~6-15 passes accumulate the discharge burnup the depletion module
# is calibrated to — the realistic multi-pass fuel cycle (CLAUDE.md). Kept small
# enough that the burnup accrued between two flux solves is a tiny fraction of a
# pebble's life, so the quasi-static "flux shape ~ constant between solves"
# assumption holds. Pinned live in main.gd against observed passes-to-discharge.
const TIME_ACCEL := 0.20

# Cumulative accelerated burn-time (campaign seconds), purely a readout. Lets the
# HUD show how much "campaign" has elapsed independent of wall-clock.
var campaign_elapsed := 0.0


## Convert one physics step to a campaign step and advance the readout clock.
## The returned value is the ONLY thing that may reach Depletion.step().
func campaign_dt(physics_dt: float) -> float:
	var dt := physics_dt * TIME_ACCEL
	campaign_elapsed += dt
	return dt
