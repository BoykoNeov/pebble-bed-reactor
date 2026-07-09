# sim/cross_sections.gd
#
# Parameterized macroscopic cross-sections (CLAUDE.md principle 3: smooth
# functions of enrichment / packing / temperature / burnup — NO nuclear data
# libraries). One-group, toy, qualitative.
#
# WHY the constants are unit-less/pixel-native and "tuned", not physical: the
# whole sim works in pixel length units (positions come from the physics
# backend in pixels). Absolute magnitudes are meaningless for a teaching toy;
# what matters is that the DEPENDENCIES have the right sign and the nominal core
# lands k-eff ~ 1. tests/test_neutronics.gd is what pins these numbers down.
#
# Only the dependencies M1 needs are live. Temperature (Doppler, M2), burnup and
# poison (M3) are present in the signatures with their hooks stubbed to 0 so the
# later milestones plug in without reshaping the call sites.
class_name CrossSections
extends RefCounted

## What a homogenized cell is made of. Drives which correlation applies.
## Plain int consts, not a named enum: GDScript 4.7 does not resolve a nested
## enum member of another class_name across files (CrossSections.Material.FUEL
## fails to parse), but plain consts resolve fine.
const FUEL := 0
const REFLECTOR := 1
const VOID := 2

const E_REF := 0.085          # reference enrichment (HTR-PM-flavored LEU)

# --- Fuel (pebble bed) ---
const FUEL_NU_SIGF := 0.0470  # νΣf per unit packing, per (e / E_REF)
const FUEL_SIGA := 0.030      # absorption per unit packing (fuel + structure)
const FUEL_SIGA_BASE := 0.002 # background absorption independent of loading
const FUEL_D0 := 260.0        # diffusion-coefficient scale (pixels)
const FUEL_D_PACK := 0.60     # denser bed → more scattering → shorter L → lower D
const BURN_PENALTY := 0.0     # M3 turns this on: νΣf falls as fuel depletes

# --- Reflector (graphite band around the core) ---
# Source-free, low absorption, moderate D: scatters leaked neutrons back into
# the fuel. This is what turns edge DEPRESSION into edge FLATTENING (M1 target).
const REFL_SIGA := 0.0010
const REFL_D := 200.0

# --- Void (helium gap above the settled bed, inside the vessel) ---
# Near-transparent: neutrons stream through and leak. High D, ~0 absorption.
const VOID_SIGA := 0.00002
const VOID_D := 500.0


## Fission production. Rises with fissile loading (packing) and enrichment;
## depletes with burnup (M3). Zero for non-fuel cells (handled by the caller).
static func nu_sigma_f(packing: float, enrichment: float, burnup: float) -> float:
	return FUEL_NU_SIGF * packing * (enrichment / E_REF) * (1.0 - BURN_PENALTY * burnup)


## Absorption. Grows with loading and with lumped fission-product poison (M3).
## Deliberately independent of enrichment at M1 so k-inf is strictly monotone in
## enrichment — the calibration test asserts exactly that.
static func sigma_a_fuel(packing: float, poison: float) -> float:
	return FUEL_SIGA_BASE + FUEL_SIGA * packing + poison


## Diffusion coefficient of the fuel region. Denser packing shortens the
## diffusion length (more scattering centers), so leakage drops as the bed fills.
static func diffusion_fuel(packing: float) -> float:
	return FUEL_D0 / (1.0 + FUEL_D_PACK * packing)
