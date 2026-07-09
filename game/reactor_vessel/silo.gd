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

# Inner core rectangle (viewport is 720 x 1080; see project.godot).
const LEFT := 190.0
const RIGHT := 530.0
const TOP := 120.0
const FUNNEL_TOP := 760.0   # where vertical walls give way to the funnel
const OUTLET_Y := 900.0
const OUTLET_HALF := 40.0   # half-width of the flat hopper bottom

const CENTER_X := (LEFT + RIGHT) * 0.5


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


## Random x for injecting a pebble across the top, kept inside the walls.
static func spawn_x(rng: RandomNumberGenerator, margin: float) -> float:
	return rng.randf_range(LEFT + margin, RIGHT - margin)


static func spawn_y() -> float:
	return TOP + 20.0
