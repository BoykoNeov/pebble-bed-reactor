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
