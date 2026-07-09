# game/visualization/field_descriptor.gd
#
# One entry in the field registry (CLAUDE.md field-viz): everything the generic
# renderer needs to draw a scalar field, and nothing about HOW it is drawn.
# Adding a field (burnup at M3, coolant temp at M4, xenon at M5) is registering
# one of these — not writing new render code.
#
# WHY a descriptor object instead of hard-coded per-field rendering: the sim will
# grow many displayable fields across milestones; the renderer must stay
# field-agnostic so each new field is data, not code.
class_name FieldDescriptor
extends RefCounted

# Which world the field lives in — sets the render mode (CLAUDE.md two modes):
# GRID = Eulerian (flux, power, coolant temp) → upscaled texture.
# PEBBLE = Lagrangian (burnup, pebble temp, xenon) → per-pebble color. Declared
# now so M3 fields register the same way; only GRID is rendered at M1.
const GRID := 0
const PEBBLE := 1

var name: String = ""
var units: String = ""
var world: int = GRID
var vmin: float = 0.0        # stable normalization range (CLAUDE.md: do NOT
var vmax: float = 1.0        # auto-range every frame — transients become unreadable)
var log_scale: bool = false


func _init(p_name := "", p_units := "", p_world := GRID, p_vmin := 0.0, p_vmax := 1.0, p_log := false) -> void:
	name = p_name
	units = p_units
	world = p_world
	vmin = p_vmin
	vmax = p_vmax
	log_scale = p_log


## Map a raw field value to [0, 1] for the colormap, honoring the fixed range and
## optional log scaling (log for quantities spanning orders of magnitude).
func normalize(v: float) -> float:
	if log_scale:
		var lo: float = log(maxf(vmin, 1.0e-9))
		var hi: float = log(maxf(vmax, 1.0e-9))
		var lv: float = log(maxf(v, 1.0e-9))
		return clampf((lv - lo) / (hi - lo), 0.0, 1.0)
	return clampf((v - vmin) / (vmax - vmin), 0.0, 1.0)
