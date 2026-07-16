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
var colormap: int = Colormap.VIRIDIS
# Diverging-map pivot: the physically meaningful center value (e.g. the k_inf(M)
# peak for the moderation field), mapped to the colormap midpoint. The pivot is
# generally NOT the midpoint of [vmin, vmax], so the two halves are scaled
# independently — the color says which SIDE of the pivot a cell is on, which is
# the whole point of a diverging map (CLAUDE.md: diverging for signed quantities).
# NAN = plain linear/log mapping (sequential fields).
var pivot: float = NAN


func _init(p_name := "", p_units := "", p_world := GRID, p_vmin := 0.0, p_vmax := 1.0,
		p_log := false, p_colormap := Colormap.VIRIDIS, p_pivot := NAN) -> void:
	name = p_name
	units = p_units
	world = p_world
	vmin = p_vmin
	vmax = p_vmax
	log_scale = p_log
	colormap = p_colormap
	pivot = p_pivot


## Map a raw field value to [0, 1] for the colormap, honoring the fixed range,
## optional log scaling (for quantities spanning orders of magnitude), and the
## optional diverging pivot.
func normalize(v: float) -> float:
	if not is_nan(pivot):
		if v < pivot:
			return 0.5 * clampf((v - vmin) / (pivot - vmin), 0.0, 1.0)
		return 0.5 + 0.5 * clampf((v - pivot) / (vmax - pivot), 0.0, 1.0)
	if log_scale:
		var lo: float = log(maxf(vmin, 1.0e-9))
		var hi: float = log(maxf(vmax, 1.0e-9))
		var lv: float = log(maxf(v, 1.0e-9))
		return clampf((lv - lo) / (hi - lo), 0.0, 1.0)
	return clampf((v - vmin) / (vmax - vmin), 0.0, 1.0)


## Inverse of normalize: the raw field value at normalized position t in [0, 1].
## Used by the colorbar to label ticks — the ticks must be computed through the
## SAME mapping as the colors, or the legend lies about the scale.
func value_at(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	if not is_nan(pivot):
		if t < 0.5:
			return vmin + (t / 0.5) * (pivot - vmin)
		return pivot + ((t - 0.5) / 0.5) * (vmax - pivot)
	if log_scale:
		var lo: float = log(maxf(vmin, 1.0e-9))
		var hi: float = log(maxf(vmax, 1.0e-9))
		return exp(lo + t * (hi - lo))
	return vmin + t * (vmax - vmin)


## Color for a raw field value — the one place normalize + colormap compose, so
## the heatmap, pebble tints, and colorbar can never disagree.
func color(v: float) -> Color:
	return Colormap.sample(colormap, normalize(v))
