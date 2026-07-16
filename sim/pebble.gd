# sim/pebble.gd
#
# Engine-agnostic per-pebble state (the Lagrangian world).
#
# WHY this is a plain RefCounted with no Node/physics types: the simulation
# core must stay swappable and unit-testable without a physics backend or the
# scene tree. A pebble is *data* — its position is owned by whatever physics
# backend is driving it (see game/physics/physics_backend.gd), and is looked up
# by id. Neutronics/depletion/thermal (M1+) read and write the fields here.
class_name Pebble
extends RefCounted

## Stable identity. The physics backend keys its bodies by this id, so the
## Lagrangian state here and the Eulerian body over there never get confused.
var id: int = -1

## Pebble radius in simulation units.
##
## What this actually drives TODAY, which is not what CLAUDE.md's physics note might
## lead you to expect. Radius reaches the neutronics through exactly one path:
## grid.gd sums PI*r^2 into each cell's pebble area, and packing = area / cell_area.
##
##   - UNIFORM size change: packing fraction is SCALE-INVARIANT — bigger circles settle
##     at the same ~0.61 areal packing — so no cross-section moves. The effect is
##     GEOMETRIC instead: the bed holds a pinned COUNT, so bigger pebbles need more
##     volume, the bed grows into more fuel cells, and leakage falls (k rises).
##   - MIXED sizes: small pebbles fill the gaps between big ones, packing genuinely
##     rises, and the area-summing homogenization captures that with no new physics.
##
## CLAUDE.md says uniform size change "affects surface-to-volume and self-shielding".
## That is true of a real PBR and is NOT modelled here — there is no self-shielding
## term in cross_sections.gd. This comment used to assert the effect existed, which was
## a lie the code never backed; adding it would be new physics (and, per the M5d
## pattern, would want a factor of exactly 1.0 at the nominal radius so every existing
## calibration survives).
var radius: float = 8.0

## Fuel loading: heavy-metal mass per pebble relative to nominal (1.0). One of
## CLAUDE.md's three player design knobs (size, fuel loading, enrichment), wired
## at M5b. It sets the graphite : heavy-metal ratio, hence the MODERATION of the
## cell the pebble sits in (CrossSections.moderation): LOWER loading = more
## graphite per gram of fuel = MORE moderation. Homogenize area-weights it into a
## per-cell moderation ratio that drives the two-group removal / thermal
## absorption — and therefore the sign of the moderator-temperature coefficient.
var fuel_loading: float = 1.0

## Minimal isotopic vector (atoms, arbitrary toy units). Expanded at M3.
## Kept as named fields rather than an array so the physics meaning stays legible.
var u235: float = 0.0
var u238: float = 0.0
var pu239: float = 0.0
var poison: float = 0.0  # one lumped fission-product absorber

## Transient poisons (M5c — xenon). Unlike `poison` (a permanent absorber that only
## grows with burnup), these rise AND fall on an intermediate timescale, so they must
## be tracked separately. I-135 is a fission product that decays into Xe-135; Xe-135
## is a very strong thermal absorber removed by its own decay AND by neutron burnout
## (flux-dependent). The interplay — production tied to fission, decay tied to TIME —
## is what makes the reactor droop as xenon builds and, after a shutdown, spike into
## the post-scram "iodine pit" as trapped I-135 keeps decaying into Xe with no flux to
## burn it out. Evolved by Depletion.step; homogenized into sigma_a2 like `poison`.
var i135: float = 0.0    # I-135 precursor (decays to Xe-135)
var xe135: float = 0.0   # Xe-135 absorber (the reactivity-transient poison)

## Slow-clock accumulators, driven by the campaign clock at M3.
var burnup: float = 0.0      # MWd/kgHM proxy
var pass_count: int = 0      # multi-pass fuel cycling

## Placeholder lumped temperature (K). M2 uses a stand-in; M4 makes it a real
## energy balance. Kept here so feedback has something to read from day one.
var temperature: float = 293.15

## Local scalar flux sampled back from the grid solve (M1). Read-only downstream
## for now — M3 turns it into a burnup rate. Populated by main.gd's coupling step.
var local_flux: float = 0.0

## Local coolant (helium) temperature the pebble is bathed in, sampled from the
## grid coolant-transport field (M4b). Rises going DOWN the bed as the coolant
## picks up heat — so a deep pebble is cooled by hotter helium than a shallow one.
## This is the Newton-cooling sink temperature, replacing M4a's uniform inlet.
var local_coolant: float = 293.15

## Decay-heat reservoir energies (toy units), one per Thermal decay group (M5).
## Fission products build these up in proportion to fission power and drain them by
## radioactive decay, so a pebble keeps producing heat AFTER fission stops — the
## basis of the decay-heat / post-scram passive-safety demo (CLAUDE.md glossary
## "decay heat"). Sized and driven by the Thermal step; an empty array means "no
## fission-product inventory yet" (fresh fuel), which the step initializes to zeros.
var decay_e: PackedFloat32Array = PackedFloat32Array()


func _init(p_id: int = -1, p_radius: float = 8.0) -> void:
	id = p_id
	radius = p_radius
