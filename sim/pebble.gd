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

## Pebble radius in simulation units. Uniform size changes affect
## surface-to-volume / self-shielding (not packing fraction) — see CLAUDE.md.
var radius: float = 8.0

## Minimal isotopic vector (atoms, arbitrary toy units). Expanded at M3.
## Kept as named fields rather than an array so the physics meaning stays legible.
var u235: float = 0.0
var u238: float = 0.0
var pu239: float = 0.0
var poison: float = 0.0  # one lumped fission-product absorber

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


func _init(p_id: int = -1, p_radius: float = 8.0) -> void:
	id = p_id
	radius = p_radius
