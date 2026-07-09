# game/visualization/colormap.gd
#
# Perceptually-uniform, colorblind-safe colormaps (CLAUDE.md field-viz rules:
# viridis/inferno, never rainbow/jet — jet invents false gradients and fails for
# colorblind users). Sequential maps for magnitudes; a diverging map is added
# when the first signed field (reactivity, M2+) needs one.
#
# Small anchor tables + linear interpolation — accurate enough for a heatmap and
# dependency-free.
class_name Colormap
extends RefCounted

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


## Sample viridis at t in [0, 1].
static func viridis(t: float) -> Color:
	return _sample(_VIRIDIS, t)


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
