# tests/live_fill_escape.gd
#
# Integration gate for the INITIAL FILL: godot --headless --script res://tests/live_fill_escape.gd
#
# WHY THIS EXISTS. Silo.wall_segments() is a CLOSED hopper — main.gd's own comments are explicit
# that the floor has no free outlet, discharge is a METERED removal, and the bed cannot
# physically drain. So a core-flagged body (not `_out_of_core`) ever found below Silo.OUTLET_Y is
# proof a wall was crossed, not landed through — the closed floor is a SegmentShape2D with zero
# thickness, and Godot does not sweep a fast body against one without continuous collision on.
#
# WHY THE INITIAL FILL SPECIFICALLY. Every OTHER body that ever enters the bed (`_spawn_from_queue`
# after the first pass, `_feed_drop`, `_feed_reinject`) lands on top of an already-settled pile —
# a few px of fall. The initial fill is the one moment nothing is underneath: a pebble spawned at
# Silo.spawn_y() (140) free-falls the full ~760 px to the closed floor at OUTLET_Y (900) and
# reaches ~1220 px/s, well over a diameter per physics step at 32 solver iterations.
#
# WHAT A BREACH LOOKS LIKE ON SCREEN, player-reported and reproduced here: the escaped pebble
# comes to rest above the transport duct (it looks like it "fell through and stopped"), sits there
# because `_extract_lowest` is gated off until the bed reaches TARGET_POPULATION, and once the
# gate opens it reads as the single lowest pebble in the core (it is, by a wide margin) and gets
# extracted — reappearing at the fixed drop mouth (Silo.CENTER_X) instead of wherever it actually
# fell, which is the "disappears, then reappears on a different x" half of the report.
#
# MEASURED with `_spawn_from_queue`'s `set_continuous_cd` call absent: 16 of the first 150
# pebbles breached the closed floor in the first ~8 s of a fill, velocity at breach almost always
# (0, ~980-1000) px/s — a straight vertical pass through the floor, not a lateral solver-ejection
# spike, which is what point this gate at CCD rather than at spawn clearance. With the call
# present: 0 in 25 s.
extends SceneTree

var _main
var _t := 0.0
var _failures := 0
var _spawn_pos: Dictionary = {}    # id -> spawn x, for bodies just placed at the top
var _breaches: Array = []          # [{id, t, pos, vel}]


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live fill escape] the closed hopper floor must hold during the initial (empty-core) fill")


func _process(delta: float) -> bool:
	_t += delta

	for id in _main._physics._bodies:
		if not _spawn_pos.has(id) and not _main._out_of_core.has(id):
			var pos: Vector2 = _main._physics.get_position(id)
			if pos.y < Silo.TOP + 60.0:
				_spawn_pos[id] = pos.x

	for id in _main._core_positions():
		var pos: Vector2 = _main._physics.get_position(id)
		if pos.y > Silo.OUTLET_Y + 4.0:
			var already := false
			for b in _breaches:
				if b["id"] == id:
					already = true
					break
			if not already:
				var vel: Vector2 = _main._physics.get_velocity(id)
				_breaches.append({"id": id, "t": _t, "pos": pos, "vel": vel})
				print("  BREACH t=%.2fs id=%d pos=(%.1f,%.1f) vel=(%.1f,%.1f) spawn_x=%.1f" % [
					_t, id, pos.x, pos.y, vel.x, vel.y, _spawn_pos.get(id, -1.0)])

	if _t >= 25.0:
		print("  core=%d/%d over 25 s of fill" % [_main._core_count(), _main.TARGET_POPULATION])
		_check(_breaches.is_empty(),
			"no core-flagged body ever breached the closed hopper floor (%d breach(es))"
				% _breaches.size())
		_check(_main._core_count() == _main.TARGET_POPULATION,
			"bed reached its calibrated population (%d/%d)"
				% [_main._core_count(), _main.TARGET_POPULATION])
		_report()
		return true
	return false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  PASS  %s" % what)
	else:
		print("  FAIL  %s" % what)
		_failures += 1


func _report() -> void:
	if _failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
