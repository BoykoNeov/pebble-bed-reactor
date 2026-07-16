# sim/control_rods.gd
#
# Control rods (M5d) — the operator's direct reactivity lever, and the last of the
# three shutdown/control mechanisms CLAUDE.md's M5 line asks for ("control (rods /
# coolant flow / scram)"; flow is M4a, scram is M5a).
#
# WHY the rods are PHYSICAL ABSORBERS and not a lumped "rod worth" subtracted from
# k: every other reactivity effect in this sim is EARNED through the eigenvalue
# solve — the moderator coefficient's sign emerges from the peaked k_inf(M)
# (cross_sections.gd), xenon's worth emerges from its Sigma_a2 contribution
# (M5c). A hardcoded constant would be the one lever that teaches nothing: it
# could not depress the flux locally, could not interact with xenon, and its worth
# could not depend on where the fuel actually is. Here the rod adds real thermal
# absorption to the cells it occupies and EVERYTHING else follows from the solve —
# most importantly the S-CURVE (see rod_weight / the integral-worth discussion
# below), which no constant can produce.
#
# WHY THE SIDE REFLECTOR, not the bed. This is the real HTR-PM design, and it is
# forced by the same granular physics this sim models: you cannot drive a rod into
# a packed pebble bed — it would crush the pebbles. Real PBRs put their rods in
# borings in the SIDE REFLECTOR. Two things fall out of that for free:
#
#   1. It touches the pebble/Lagrangian world NOT AT ALL. Rods are pure Eulerian
#      grid state, so the granular flow, the fuel loop, and every per-pebble
#      calibration are untouched by construction.
#   2. It is exactly where the rods BITE. The reflector is where the THERMAL flux
#      PEAKS in this two-group model (fast neutrons leak out of the fuel, thermalize
#      in the graphite's strong Sigma_r, and pile up because the reflector barely
#      absorbs them — cross_sections.gd "Reflector"; proven by
#      tests/test_neutronics.gd _test_spectrum_peaks). A thermal absorber parked in
#      the thermal-flux peak is a strong rod. This is not a lucky coincidence of the
#      toy — it is WHY reflector rods work in a real pebble bed reactor, and it is a
#      behavior the one-group M1 model could not have represented at all.
#
# MEASURED (not assumed) on the calibrated lattice: the innermost reflector column
# carries a higher thermal flux (peak ~37.4) than any fuel column (~33.5), so the
# rod columns are the reflector columns ADJACENT to the vessel wall — not the outer
# band (~31.6), and not the fuel.
#
# Pure and engine-agnostic (CLAUDE.md principle 5), like the rest of sim/: it takes
# a Grid and an insertion fraction and edits cross-sections. No Godot, no nodes.
#
# Named ControlRods, not Control: `Control` is a Godot built-in class name.
class_name ControlRods
extends RefCounted

# Thermal absorption (Sigma_a2) a fully-rodded cell adds. Boron carbide is a strong
# 1/v THERMAL absorber, so the rod is modeled as a thermal-group absorber only: the
# teaching point is "the rod eats thermal neutrons where the thermal flux peaks,"
# and giving it a fast-group term as well would blur that without changing any sign.
#
# Scale: the graphite reflector it displaces has REFL_SIGA2 = 0.0004 (near
# transparent), and a fuel cell's total thermal absorption is ~0.012 — so this is a
# LARGE local perturbation, as a real rod is. Calibrated (tests/test_control_rods.gd)
# so that a full insertion is worth enough to hold a core Doppler alone cannot, which
# is the milestone's whole reason to exist. It is NOT tuned to match
# Thermal.SCRAM_WORTH: scram remains an independent lumped kinetics term (M5a), and
# unifying the two is a deliberate, separately-calibrated change — not a side effect
# of this module.
const ROD_SIGMA_A2 := 0.12

# Player lever range. Insertion is a FRACTION of the grid's full height: 0 = fully
# withdrawn (the default — see apply_rods, which then adds exactly nothing), 1 =
# fully inserted.
const INSERT_MIN := 0.0
const INSERT_MAX := 1.0
# One step is ~0.005-0.008 Dk near the top of the stroke — deliberately the same
# reactivity granularity as the enrichment lever's ENRICH_STEP (~0.006 Dk), so the two
# controls feel alike, and 20 presses covers the full stroke.
#
# KNOWN TRADE-OFF, worth understanding before retuning: the nominal core only carries
# ~2% excess reactivity, so anything past ~20% insertion shuts it down — the live usable
# band is only ~4 steps. That is not a rod problem, it is the narrow Doppler band this
# sim has always had (see the M2 notes: enrichment is steep and Doppler is weak); a core
# with 2% excess is genuinely shut down by 2% of rod worth. Consequence for the player:
# on a NOMINAL core they feel the S-curve's flat lead-in and then shutdown, and only meet
# its steep middle on a hotter core — or by watching the worth readout, which keeps
# climbing (0.025 -> 0.20 -> 0.32) long after the core is off. Halving this to 0.025 buys
# a finer band at the cost of 40 presses for a full stroke; it is a taste call, not a
# physics one.
const INSERT_STEP := 0.05


## The columns the rods occupy: the reflector columns immediately outside each
## vessel wall, one per side (a symmetric bank, so the rods cannot skew the flux
## left-right — HTR-PM likewise spaces its rods symmetrically around the core).
##
## Derived from the grid's own band width rather than hardcoded, so a grid built
## with a different reflector band still puts its rods against the wall, where the
## thermal peak is.
static func rod_columns(grid: Grid) -> PackedInt32Array:
	var b := grid.band_cells
	if b <= 0 or 2 * b >= grid.nx:
		return PackedInt32Array()      # degenerate grid: no reflector band to rod
	return PackedInt32Array([b - 1, grid.nx - b])


## How much of cell row `j` the rod covers at this insertion, in [0, 1].
##
## The FRACTIONAL tip (rather than a whole-cell step) is what makes rod worth a
## SMOOTH, continuous function of insertion. With only ~16 rows a whole-cell rod
## would move k in visible stair-steps, which would both look like a bug and
## destroy the S-curve's shape. The tip cell is partially absorbing — the honest
## reading of "the rod is halfway into this cell".
static func rod_weight(grid: Grid, j: int, insertion: float) -> float:
	return clampf(insertion * float(grid.ny) - float(j), 0.0, 1.0)


## Add the rods' thermal absorption to `grid.sigma_a2`, in place.
##
## Rods enter from the TOP and descend — so insertion sweeps the rod tip down
## through rising thermal flux (low beside the void above the bed, peaking mid-bed),
## which is precisely what gives the INTEGRAL WORTH its S-SHAPE: differential worth
## is ~proportional to the local thermal flux the tip is passing through, so the
## first part of the stroke (beside empty helium — no fuel to starve) buys almost
## nothing, the middle (through the bed's flux peak) buys the most, and the last
## part tapers again. That curve is EMERGENT here: nothing in this file encodes an
## S. It falls out of the flux profile the diffusion solve produces.
##
## CALIBRATION-NEUTRAL AT ZERO (the load-bearing property): at insertion = 0 this
## returns having touched nothing, so every pre-M5d calibration — A_REF, the
## operating point, the whole test suite — is bit-for-bit unaffected by the rods'
## existence. The default core is fully withdrawn.
##
## Expects the temperature-FREE base sigma_a2 in place (as homogenize leaves it) and
## relies on the caller restoring that base each solve, so the rods never stack
## across frames — the same contract Thermal.apply_field_doppler /
## apply_field_moderator follow.
static func apply_rods(grid: Grid, insertion: float) -> void:
	if insertion <= 0.0:
		return
	for i in rod_columns(grid):
		for j in range(grid.ny):
			var w := rod_weight(grid, j, insertion)
			if w <= 0.0:
				break     # rows below the tip are clear; nothing further down is rodded
			grid.sigma_a2[grid.idx(i, j)] += ROD_SIGMA_A2 * w
