# game/physics/physics_backend.gd
#
# The one load-bearing abstraction: everything mechanical goes through here so
# the physics engine stays swappable (CLAUDE.md tech decision). Native Godot
# physics fills this today; Rapier/Box2D could fill it later WITHOUT touching
# the coupling loop, homogenization, or neutronics.
#
# Deliberately minimal — spawn a body, read positions, step. This is not a
# speculative plugin framework; add a method only when a milestone needs it.
#
# WHY a step() that native leaves as a no-op: Godot steps its own physics inside
# the scene tree, but an external engine (Rapier/Box2D) must be advanced
# manually. Keeping step() in the interface means the coupling loop reads the
# same regardless of backend.
class_name PhysicsBackend
extends RefCounted


## Attach the backend to a node it may parent bodies under (native needs this;
## an external engine can ignore it).
func setup(_world_root: Node) -> void:
	pass


## Add an immovable wall segment (silo shell, funnel). Called once at build.
func add_static_segment(_a: Vector2, _b: Vector2) -> void:
	_todo()


## Create a dynamic circular pebble body keyed by id.
func spawn_pebble(_id: int, _pos: Vector2, _radius: float) -> void:
	_todo()


## Destroy the body for id (extraction at the bottom).
func remove_pebble(_id: int) -> void:
	_todo()


## Current position of one body. Returns Vector2.ZERO if unknown.
func get_position(_id: int) -> Vector2:
	_todo()
	return Vector2.ZERO


## id -> Vector2 for every live body. This is the homogenization input at M1.
func positions() -> Dictionary:
	_todo()
	return {}


## Current velocity of one body. Returns Vector2.ZERO if unknown.
##
## Exists for the transport BELTS (M5+/Phase 3b), which are speed-limited rather than
## force-limited: a belt drags what is on it up to its own speed and then stops pushing,
## so the drive has to be able to ask how fast the thing it is carrying is already going.
## Without this the only option is a constant force, which accelerates a pebble down the
## whole run and throws it out of the end of the pipe.
func get_velocity(_id: int) -> Vector2:
	_todo()
	return Vector2.ZERO


## Push one body this step (a belt driving a pebble along a pipe). Accumulated by the
## engine and consumed by the next step, so it must be re-applied every frame it should
## act — a belt is a continuous drive, not an impulse.
func apply_force(_id: int, _force: Vector2) -> void:
	_todo()


## Ask the engine to test where this body SWEPT, not just where it ended up.
##
## Ordinary discrete collision only checks a body's position each step, never the line it
## travelled along to get there, so a fast body can be clear of a wall at step N and clear of
## it on the FAR side at step N+1, with the wall never consulted. Crossing takes roughly a
## body's own DIAMETER of travel in one step — that is the whole rule, and both quantities in
## it matter.
##
## ⚠️ THE HAZARD IS THE SIZE LEVER, NOT THE BELT SPEED — measured, and the opposite of what
## was assumed. At the riser's 380 px/s a pebble travels ~6.3 px per step, so the NOMINAL 8 px
## pebble (16 px across, a 2.5x margin) does not tunnel at all: 0 lost in ~1100 pebbles with
## this off. But radius is a PLAYER DESIGN KNOB, and at main.RADIUS_MIN = 5 the pebble is only
## 10 px across — a 1.5x margin, which the corner impact closes. Same belt, same geometry,
## with this off: **12, 26 and 14 recirculating pebbles lost in three runs of ~70** (up to
## 37%), every one of them punched through the riser's right face at x = 986 and last seen at
## x ≈ 1057. With it on: 0, 0, 0, and 69 of 69 arriving. So the question "is the pipe solid"
## has no answer until you ask "solid for WHICH pebble" — the plant must hold the smallest
## thing the player can build, not the default one.
##
## That makes this mandatory rather than cosmetic: a recirculating pebble that leaves through
## a wall is one the BED never gets back, and TARGET_POPULATION = 380 is calibrated, so the
## bill arrives as a quiet shift in k with nothing on screen to explain it.
##
## ⚠️ ON BY DEFAULT AT SPAWN NOW (`GodotPhysicsBackend.spawn_pebble`), not opt-in per call
## site — this function exists to override that default, not to establish it. It used to be
## off by default on the theory that 380 settling bed pebbles jostling at walking pace would
## pay for a hazard they do not have; that theory was never wrong about the settled bed's own
## motion, but it left a bug CLASS open — every spawn site had to remember to turn CCD on for
## itself, and one (`_pool_push`) simply never did. MEASURED before defaulting it on for every
## body: `live_riser.gd` (45 s, alternating belt traffic) held 2701/2700 physics ticks — no
## lag — and `live_fill_escape.gd` (25 s) still filled the full 380-pebble bed with 0
## breaches. CAST_RAY's cost turned out negligible at this population, so correctness-by-
## construction won over the theoretical saving. The two `--no-ccd` test harnesses
## (`live_riser.gd`, `live_reinject_riser.gd`) are the reason this function still exists: they
## call it explicitly to turn CCD back OFF and reproduce the original tunnelling failure as a
## regression guard.
func set_continuous_cd(_id: int, _on: bool) -> void:
	pass


## Allow (or forbid) the engine's own sleep system to park this body.
##
## A sleeping RigidBody2D ignores `apply_force` entirely until something collides it awake —
## Godot's normal, correct behavior for a settled bed (380 pebbles resting quietly should not
## burn cycles), but the wrong behavior for a body a BELT is actively driving: a transit
## pebble that dips under the linear sleep threshold for a moment (queued behind others,
## momentarily stalled at a corner) could go to sleep mid-journey, at which point the belt's
## force becomes a no-op and nothing wakes it on its own.
##
## NOT WHAT CAUSED the one real freeze this project hit (`tests/live_fuel_policy.gd`, a
## permanently frozen recirc column that halted the whole fuel cycle) — that was a genuine
## missing-wall-gap bug (see `FuelLoop.inlet_walls`), confirmed by instrumenting the actual
## stuck body: `sleeping` read `false` throughout, this guard forcing `can_sleep=false` on it
## changed nothing, and the freeze persisted until the real walls were fixed. Kept anyway as
## deliberate, cheap defensive hardening against a real hazard this investigation surfaced,
## not as evidence it was ever triggered — a transit body sleeping mid-belt is still a
## plausible failure mode even though it wasn't THIS one.
func set_can_sleep(_id: int, _on: bool) -> void:
	pass


## Recolor one body for the per-pebble (Lagrangian) field heatmap (M3+). Pure
## visualization — a consumer of sim state, routed through the backend only
## because it owns the render bodies. No-op if the backend has no drawable body.
func set_pebble_tint(_id: int, _color: Color) -> void:
	pass


## Advance the mechanical world. No-op for engines that self-step (native).
func step(_delta: float) -> void:
	pass


func _todo() -> void:
	push_error("PhysicsBackend method not implemented by subclass")
