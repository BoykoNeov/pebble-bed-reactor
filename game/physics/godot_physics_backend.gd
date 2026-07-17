# game/physics/godot_physics_backend.gd
#
# Native Godot 4 physics implementation of PhysicsBackend — the ONLY file the
# "which engine" decision touches. Everything above the interface is unchanged
# if this is swapped for Rapier/Box2D later.
#
# Decision (CLAUDE.md): start native. Hundreds-to-a-few-thousand circles sit
# comfortably inside GodotPhysics2D. Revisit only if a real benchmark shows a
# flow-quality or throughput problem.
class_name GodotPhysicsBackend
extends PhysicsBackend

var _root: Node
var _bodies: Dictionary = {}  # id -> PebbleBody


func setup(world_root: Node) -> void:
	_root = world_root


func add_static_segment(a: Vector2, b: Vector2) -> void:
	var wall := StaticBody2D.new()
	var col := CollisionShape2D.new()
	var seg := SegmentShape2D.new()
	seg.a = a
	seg.b = b
	col.shape = seg
	wall.add_child(col)
	_root.add_child(wall)


func spawn_pebble(id: int, pos: Vector2, radius: float) -> void:
	var body := PebbleBody.new()
	body.configure(radius)
	body.position = pos
	_root.add_child(body)
	_bodies[id] = body


func remove_pebble(id: int) -> void:
	var body: PebbleBody = _bodies.get(id)
	if body != null:
		body.queue_free()
		_bodies.erase(id)


func get_position(id: int) -> Vector2:
	var body: PebbleBody = _bodies.get(id)
	return body.position if body != null else Vector2.ZERO


func positions() -> Dictionary:
	var out := {}
	for id in _bodies:
		out[id] = (_bodies[id] as PebbleBody).position
	return out


func get_velocity(id: int) -> Vector2:
	var body: PebbleBody = _bodies.get(id)
	return body.linear_velocity if body != null else Vector2.ZERO


func apply_force(id: int, force: Vector2) -> void:
	var body: PebbleBody = _bodies.get(id)
	if body != null:
		# Central, not at an offset: a belt under a round pebble drives it along, and
		# torquing it would be inventing a spin the contact does not imply.
		body.apply_central_force(force)


func set_pebble_tint(id: int, color: Color) -> void:
	var body: PebbleBody = _bodies.get(id)
	if body != null:
		body.set_tint(color)
