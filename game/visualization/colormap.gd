# game/visualization/colormap.gd
#
# Perceptually-uniform, colorblind-safe colormaps (CLAUDE.md field-viz rules:
# viridis/inferno, never rainbow/jet — jet invents false gradients and fails for
# colorblind users). Sequential maps for magnitudes; the diverging map is for
# signed/pivoted quantities (moderation ratio around the k_inf peak), where
# "which side am I on" matters more than magnitude.
#
# Small anchor tables + linear interpolation — accurate enough for a heatmap and
# dependency-free. Fields pick a map via FieldDescriptor.colormap so related
# quantities share a visual language (all temperatures = inferno heat, all
# fluxes = viridis) instead of every field looking the same.
class_name Colormap
extends RefCounted

const VIRIDIS := 0    # fluxes, burnup — the general-purpose magnitude map
const INFERNO := 1    # temperatures / heat — reads as "hot"
const MAGMA := 2      # xenon — distinct from the heat fields it accompanies
const COOLWARM := 3   # diverging: moderation regime around the k_inf(M) peak

# viridis anchors at t = 0.0, 0.1, ... 1.0 (matplotlib reference values).
const _VIRIDIS := [
	Vector3(0.267, 0.005, 0.329),
	Vector3(0.283, 0.141, 0.458),
	Vector3(0.254, 0.265, 0.530),
	Vector3(0.207, 0.372, 0.553),
	Vector3(0.164, 0.471, 0.558),
	Vector3(0.128, 0.567, 0.551),
	Vector3(0.135, 0.659, 0.518),
	Vector3(0.267, 0.749, 0.441),
	Vector3(0.478, 0.821, 0.318),
	Vector3(0.741, 0.873, 0.150),
	Vector3(0.993, 0.906, 0.144),
]

# inferno anchors at t = 0.0, 0.1, ... 1.0 (matplotlib reference values).
const _INFERNO := [
	Vector3(0.001, 0.000, 0.014),
	Vector3(0.087, 0.045, 0.225),
	Vector3(0.258, 0.039, 0.406),
	Vector3(0.416, 0.090, 0.433),
	Vector3(0.578, 0.148, 0.404),
	Vector3(0.736, 0.216, 0.330),
	Vector3(0.865, 0.317, 0.226),
	Vector3(0.955, 0.469, 0.100),
	Vector3(0.988, 0.645, 0.040),
	Vector3(0.964, 0.844, 0.273),
	Vector3(0.988, 0.998, 0.645),
]

# magma anchors at t = 0.0, 0.1, ... 1.0 (matplotlib reference values).
const _MAGMA := [
	Vector3(0.001, 0.000, 0.014),
	Vector3(0.079, 0.054, 0.212),
	Vector3(0.232, 0.060, 0.438),
	Vector3(0.390, 0.100, 0.502),
	Vector3(0.550, 0.161, 0.506),
	Vector3(0.716, 0.215, 0.475),
	Vector3(0.869, 0.288, 0.409),
	Vector3(0.968, 0.440, 0.360),
	Vector3(0.995, 0.624, 0.427),
	Vector3(0.996, 0.813, 0.573),
	Vector3(0.987, 0.991, 0.750),
]

# coolwarm (Moreland) anchors — diverging blue → neutral grey → red. Blue = below
# the pivot (under-moderated, stable MTC), red = above it (over-moderated,
# unstable): the sign convention the moderation field's regime labels use.
const _COOLWARM := [
	Vector3(0.230, 0.299, 0.754),
	Vector3(0.384, 0.511, 0.918),
	Vector3(0.553, 0.691, 0.996),
	Vector3(0.716, 0.817, 0.987),
	Vector3(0.865, 0.865, 0.865),
	Vector3(0.959, 0.770, 0.678),
	Vector3(0.936, 0.601, 0.463),
	Vector3(0.833, 0.399, 0.283),
	Vector3(0.706, 0.016, 0.150),
]


## Sample colormap `map` (one of the const ids) at t in [0, 1].
static func sample(map: int, t: float) -> Color:
	match map:
		INFERNO: return _sample(_INFERNO, t)
		MAGMA: return _sample(_MAGMA, t)
		COOLWARM: return _sample(_COOLWARM, t)
		_: return _sample(_VIRIDIS, t)


static func _sample(anchors: Array, t: float) -> Color:
	t = clampf(t, 0.0, 1.0)
	var last := anchors.size() - 1
	var x := t * last
	var i := int(floor(x))
	if i >= last:
		var c: Vector3 = anchors[last]
		return Color(c.x, c.y, c.z)
	var f := x - i
	var a: Vector3 = anchors[i]
	var b: Vector3 = anchors[i + 1]
	var v := a.lerp(b, f)
	return Color(v.x, v.y, v.z)
