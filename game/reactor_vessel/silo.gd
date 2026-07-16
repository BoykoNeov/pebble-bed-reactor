# game/reactor_vessel/silo.gd
#
# Pure geometry of the 2D silo: vertical shell walls converging to a funnel with
# a central outlet. Pebbles are injected across the top band and fall to the
# outlet; anything past the extract line has left the core (extraction at the
# bottom, M0).
#
# WHY geometry lives in its own object: it is data, not behaviour. main.gd
# consumes segments/bands from here; the physics backend never sees the silo
# shape except as a list of static segments. Later the coarse neutronics grid
# (M1) will be laid over this same rect.
class_name Silo
extends RefCounted

# Inner core rectangle (viewport is 1200 x 1080; see project.godot). The vessel
# sits right-of-center so the HUD gets a dedicated column on the left and the
# colorbar one on the right — nothing overlaps the core. Translating LEFT/RIGHT
# together is physically free: the grid, spawn band, and tests all derive from
# these constants, and the diffusion solve is translation-invariant.
const LEFT := 560.0
const RIGHT := 900.0
const TOP := 120.0
const FUNNEL_TOP := 760.0   # where vertical walls give way to the funnel
const OUTLET_Y := 900.0
const OUTLET_HALF := 40.0   # half-width of the flat hopper bottom

const CENTER_X := (LEFT + RIGHT) * 0.5

# Structural thickness of the shell (px), grown OUTWARD from the inner faces above.
#
# WHY outward-only is load-bearing and not a drawing taste: the inner faces ARE the
# physics — wall_segments() collides on them — and the bed volume they enclose is what
# TARGET_POPULATION, A_REF and the whole M4/M5 operating point were calibrated against.
# Thickening inward by even a few px would shrink the bed and silently shift k, with no
# headless test to catch it (the suites drive sim/ and never build a silo). So the shell
# is the inner contour offset along its OUTWARD normal only: wall_segments() is untouched
# and the calibration is neutral BY CONSTRUCTION, not by measurement.
#
# Sized against the neighbours it must not touch: the M5d rod channels sit at x ≈ 526 and
# 934 (grid columns 1 and 7, half-width ROD_W/2 ≈ 6.5), so there is ~27 px of clear space
# outside each wall. 14 px of steel leaves a legible gap on both sides — a wall that
# swallowed the rod channels would hide the one thing they exist to show.
const WALL_T := 14.0


## Wall segments as [a, b] pairs for the physics backend.
##
## WHY the floor is CLOSED (no free outlet): a real PBR meters fuel out of the
## bottom mechanically; it is not an hourglass. Free gravity discharge never
## forms a packed bed (inflow just streams straight out). So the shell is a
## closed hopper and discharge is a metered removal of the lowest pebble
## (see main.gd) — that keeps the bed full and makes it circulate slowly.
static func wall_segments() -> Array:
	var left_gap := CENTER_X - OUTLET_HALF
	var right_gap := CENTER_X + OUTLET_HALF
	return [
		# vertical shell
		[Vector2(LEFT, TOP), Vector2(LEFT, FUNNEL_TOP)],
		[Vector2(RIGHT, TOP), Vector2(RIGHT, FUNNEL_TOP)],
		# converging funnel down to a flat closed bottom
		[Vector2(LEFT, FUNNEL_TOP), Vector2(left_gap, OUTLET_Y)],
		[Vector2(RIGHT, FUNNEL_TOP), Vector2(right_gap, OUTLET_Y)],
		[Vector2(left_gap, OUTLET_Y), Vector2(right_gap, OUTLET_Y)],
	]


## The inner contour of the shell as ONE ordered polyline: down the left wall, through
## the funnel, across the closed hopper bottom, and back up the right wall.
##
## Traces exactly the segments wall_segments() collides on, from the same constants, so
## the drawn shell and the physics face cannot drift apart. Ordered so that the bed
## interior is consistently on ONE side of the direction of travel — that is what lets
## _outward() below be a single expression instead of a per-segment special case.
static func inner_profile() -> PackedVector2Array:
	var left_gap := CENTER_X - OUTLET_HALF
	var right_gap := CENTER_X + OUTLET_HALF
	return PackedVector2Array([
		Vector2(LEFT, TOP),
		Vector2(LEFT, FUNNEL_TOP),
		Vector2(left_gap, OUTLET_Y),
		Vector2(right_gap, OUTLET_Y),
		Vector2(RIGHT, FUNNEL_TOP),
		Vector2(RIGHT, TOP),
	])


## The shell as one convex quad per wall segment: [inner_a, inner_b, outer_b, outer_a].
##
## One quad per segment rather than a single band polygon because the shell is concave
## (the funnel V), and a convex quad triangulates cleanly for draw_colored_polygon while
## a concave ring does not. The shared corners use a MITRE — the intersection of the two
## offset lines — so the funnel knee and the hopper corners close with no gap or overlap.
static func shell_quads(t := WALL_T) -> Array:
	var inner := inner_profile()
	var outer := _offset_outward(inner, t)
	var quads := []
	for i in range(inner.size() - 1):
		quads.append(PackedVector2Array([inner[i], inner[i + 1], outer[i + 1], outer[i]]))
	return quads


## Outward normal of a profile segment — away from the bed, always.
##
## With inner_profile() ordered as it is, the bed interior lies to the RIGHT of the
## direction of travel on every one of the five segments, so (-dy, dx) points AWAY from
## the bed on every one of them. That single invariant is the whole proof that the shell
## can only grow outward; it is worth preserving if the profile is ever reordered.
static func _outward(a: Vector2, b: Vector2) -> Vector2:
	var d := (b - a).normalized()
	return Vector2(-d.y, d.x)


## Offset a profile outward by `t`, mitring the interior joins.
static func _offset_outward(inner: PackedVector2Array, t: float) -> PackedVector2Array:
	var n := inner.size()
	var out := PackedVector2Array()
	for i in n:
		if i == 0:
			out.append(inner[0] + _outward(inner[0], inner[1]) * t)
		elif i == n - 1:
			out.append(inner[n - 1] + _outward(inner[n - 2], inner[n - 1]) * t)
		else:
			var n0 := _outward(inner[i - 1], inner[i])
			var n1 := _outward(inner[i], inner[i + 1])
			var hit := _intersect(inner[i - 1] + n0 * t, inner[i] + n0 * t,
					inner[i] + n1 * t, inner[i + 1] + n1 * t)
			# Collinear joins have no intersection; there the mitre degenerates to the
			# plain normal offset, which the averaged normal gives directly.
			out.append(hit if hit != Vector2.INF else inner[i] + (n0 + n1).normalized() * t)
	return out


## Intersection of two infinite lines, or Vector2.INF when they are parallel.
static func _intersect(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> Vector2:
	var hit: Variant = Geometry2D.line_intersects_line(
			a1, (a2 - a1).normalized(), b1, (b2 - b1).normalized())
	return Vector2.INF if hit == null else hit


## Random x for injecting a pebble across the top, kept inside the walls.
static func spawn_x(rng: RandomNumberGenerator, margin: float) -> float:
	return rng.randf_range(LEFT + margin, RIGHT - margin)


static func spawn_y() -> float:
	return TOP + 20.0
