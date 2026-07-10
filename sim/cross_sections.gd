# sim/cross_sections.gd
#
# Parameterized macroscopic cross-sections (CLAUDE.md principle 3: smooth
# functions of enrichment / packing / temperature / burnup / MODERATION — NO
# nuclear data libraries). TWO-GROUP (M5b), toy, qualitative.
#
# Two energy groups: group 1 = FAST (neutrons born from fission), group 2 =
# THERMAL (slowed down by the graphite moderator, where most fission happens).
# Fission is born entirely fast (chi_1 = 1); the thermal group is fed only by
# down-scatter (removal Sigma_r) from the fast group. The infinite-medium k for
# this structure is
#
#     k_inf = [nuSigf1 + nuSigf2 * (Sigma_r / Sigma_a2)] / (Sigma_a1 + Sigma_r)
#
# and the MODERATION story lives in the two M-dependent terms:
#   * Sigma_r  (fast->thermal removal) RISES with moderation M — more graphite
#     slows more neutrons past the resonances (resonance-escape-like factor
#     p = Sigma_r/(Sigma_a1+Sigma_r) climbs toward 1).
#   * Sigma_a2 = a_fuel + a_mod*M — thermal absorption RISES with moderation too,
#     because added graphite/structure parasitically eats thermal neutrons
#     (thermal-utilization-like factor falls).
# Their product PEAKS: k_inf(M) has a maximum. Below it the core is
# UNDER-moderated (dk/dM > 0), above it OVER-moderated (dk/dM < 0). That peak is
# what makes the moderator-temperature coefficient flip sign (feedback.gd, M5b) —
# and it exists ONLY because a_mod is a real fraction of Sigma_a2. Omitting the
# a_mod term makes k_inf saturate monotonically and the sign flip unreachable.
#
# WHY the constants are unit-less/pixel-native and "tuned", not physical: the
# whole sim works in pixel length units. Absolute magnitudes are meaningless for
# a teaching toy; what matters is that the DEPENDENCIES have the right sign, the
# nominal core lands k-eff ~ 1, and k_inf(M) is peaked. tests/test_neutronics.gd
# pins these numbers down (nominal k band + a moderation sweep that must peak).
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

# --- Moderation ---
# M is an INTENSIVE property of the pebble composition (graphite : heavy-metal
# ratio), set by the player's fuel-loading design knob — NOT by packing (packing
# is how many pebbles, and it cancels out of the k_inf ratio above). Nominal
# fuel_loading = 1.0 gives M = M_REF = 1.0, which sits just UNDER the k_inf peak
# (~M = 1.2), so the default core is slightly under-moderated and stable. Lower
# fuel loading = more graphite per gram of fuel = MORE moderation = higher M, so
# dialing loading down walks the core up over the peak into the unstable
# over-moderated regime.
const M_REF := 1.0

# --- Fuel: fast group (group 1) ---
const FAST_D0 := 340.0        # fast diffusion-coefficient scale (px); fast neutrons roam far
const FAST_D_PACK := 0.40     # denser bed → shorter mean free path → lower D
const FAST_SIGA := 0.020      # fast absorption per unit packing (epithermal / resonance
                              # capture). Doppler broadening ADDS here (feedback.gd) — the
                              # resonance region is epithermal, hence the fast group.
const FAST_SIGA_BASE := 0.001 # background fast absorption independent of loading
const FAST_NUSIGF := 0.00342  # fast fission production per pack, per (e/E_REF) — small.
                              # νΣf scales k_inf uniformly WITHOUT moving the moderation peak
                              # (the peak is set by the absorption/removal ratios), so this and
                              # THERM_NUSIGF are jointly scaled to match the old one-group k_eff
                              # at every enrichment — preserving the M2/M4 feedback calibration.

# --- Fuel: fast → thermal removal (down-scatter) ---
const REMOVAL_0 := 0.0467     # Sigma_r per unit packing at M = 1; rises linearly in M
                              # (more moderator → more slowing-down). This is what feeds
                              # the thermal group and drives the resonance-escape factor.

# --- Fuel: thermal group (group 2) ---
const THERM_D0 := 120.0       # thermal diffusion scale (px); thermal neutrons diffuse less
const THERM_D_PACK := 0.80
const THERM_A_FUEL := 0.01541 # thermal absorption in the FUEL+structure, per pack —
                              # moderation-independent (the "useful" absorber). Poison (M3)
                              # and the burnup penalty add on top of this.
const THERM_A_MOD := 0.00459  # thermal absorption in the MODERATOR, per pack, × M — the
                              # parasitic term that makes k_inf(M) peak (see header). Chosen
                              # with THERM_A_FUEL / FAST_SIGA / REMOVAL_0 so the peak sits at
                              # M ≈ 1.2, just above nominal.
const THERM_NUSIGF := 0.0441  # thermal fission production per pack, per (e/E_REF) — the
                              # dominant fission term (most fission is thermal). Jointly scaled
                              # with FAST_NUSIGF to match the old one-group k_eff (see above).
const POISON_A2 := 0.55       # thermal-absorption weight of the lumped fission-product poison.
                              # < 1 because Sigma_a2 (thermal) is a SMALLER base than the old
                              # one-group total absorption, so adding the M3 poison 1:1 would
                              # over-penalize k and pull the mixed-core operating point off the
                              # hard-won ~11% enrichment. Calibrated by tests/test_depletion.gd
                              # to keep the equilibrium-mix operating point where M3/M4 tuned it.
const XENON_A2 := 4.1         # thermal-absorption weight of Xe-135 (M5c). LARGE relative to
                              # POISON_A2 because Xe-135 has a monstrous thermal cross-section
                              # (~2.6e6 barns) but is present in tiny atomic amounts — the toy
                              # xe135 inventory is a small number, so the weight carries the
                              # potency. Sized (tests/test_xenon.gd) so EQUILIBRIUM xenon is a
                              # modest reactivity worth that fits inside the operating margin,
                              # while the post-shutdown pit (~2-3x equilibrium) is clearly
                              # visible. Only the PRODUCT XENON_A2 * xe135 is physical, so this
                              # absorbs the arbitrary scale of the yields in depletion.gd.
const BURN_PENALTY := 0.0     # M3 turns this on: νΣf falls as fuel depletes

# --- Reflector (graphite band around the core) ---
# Source-free graphite. The thermal-flux PEAK in the reflector (an M1/M5b target
# one-group can only fake) is a two-group effect: fast neutrons leak OUT of the
# fuel into the graphite, slow down THERE (large Sigma_r), and pile up as thermal
# flux because the reflector barely absorbs thermal neutrons (tiny Sigma_a2). So
# the reflector MUST have its own strong removal and near-zero thermal absorption.
const REFL_D1 := 240.0
const REFL_D2 := 120.0
const REFL_SIGA1 := 0.0005
const REFL_SIGR := 0.080      # strong down-scatter: thermalizes the leaked fast neutrons
const REFL_SIGA2 := 0.0004    # near-transparent to thermal → thermal flux accumulates here

# --- Void (helium gap above the settled bed, inside the vessel) ---
# Near-transparent in both groups, and almost NO moderation (helium doesn't slow
# neutrons): fast neutrons stream through and leak rather than thermalizing.
const VOID_D1 := 500.0
const VOID_D2 := 500.0
const VOID_SIGA1 := 0.00002
const VOID_SIGR := 0.001
const VOID_SIGA2 := 0.00002


## Moderation ratio M from the player's fuel-loading knob. Lower loading (more
## graphite per unit heavy metal) → more moderation → higher M. M_REF at nominal.
static func moderation(fuel_loading: float) -> float:
	return M_REF / maxf(fuel_loading, 0.05)


## Fast diffusion coefficient of the fuel region.
static func diffusion_fast(packing: float) -> float:
	return FAST_D0 / (1.0 + FAST_D_PACK * packing)


## Thermal diffusion coefficient of the fuel region.
static func diffusion_thermal(packing: float) -> float:
	return THERM_D0 / (1.0 + THERM_D_PACK * packing)


## Fast-group absorption (base, pre-Doppler). Doppler resonance broadening is
## added on top by the feedback layer, never here (cross_sections is the
## temperature-FREE base; feedback.gd is the temperature-dependent layer).
static func sigma_a1_fuel(packing: float) -> float:
	return FAST_SIGA_BASE + FAST_SIGA * packing


## Fast → thermal removal (down-scatter). Rises with moderation M.
static func sigma_r_fuel(packing: float, m: float) -> float:
	return REMOVAL_0 * packing * m


## Thermal-group absorption. Fuel/structure part + moderator-parasitic part
## (a_mod * M, the term that makes k_inf peak) + lumped fission-product poison (M3)
## + transient Xe-135 poison (M5c). Xenon defaults to 0.0 so existing callers/tests
## that predate M5c are unaffected. Poison and xenon are per-heavy-metal densities
## (area-weighted in homogenize), NOT scaled by packing: they ride the fuel already
## counted in the pebbles binned to the cell.
static func sigma_a2_fuel(packing: float, poison: float, m: float, xenon := 0.0) -> float:
	return (THERM_A_FUEL + THERM_A_MOD * m) * packing + POISON_A2 * poison + XENON_A2 * xenon


## Fast fission production. Small; rises with loading and enrichment; depletes
## with burnup (M3, when BURN_PENALTY turns on).
static func nu_sigma_f1(packing: float, enrichment: float, burnup: float) -> float:
	return FAST_NUSIGF * packing * (enrichment / E_REF) * (1.0 - BURN_PENALTY * burnup)


## Thermal fission production — the dominant fission term.
static func nu_sigma_f2(packing: float, enrichment: float, burnup: float) -> float:
	return THERM_NUSIGF * packing * (enrichment / E_REF) * (1.0 - BURN_PENALTY * burnup)
