# tests/live_fill_escape.gd
#
# Integration gate for a RESTART-TO-EMPTY FILL: godot --headless --script res://tests/live_fill_escape.gd
#
# WHY THIS EXISTS. Silo.wall_segments() is a CLOSED hopper — main.gd's own comments are explicit
# that the floor has no free outlet, discharge is a METERED removal, and the bed cannot
# physically drain. So a core-flagged body (not `_out_of_core`) ever found below Silo.OUTLET_Y is
# proof a wall was crossed, not landed through — the closed floor is a SegmentShape2D with zero
# thickness, and Godot does not sweep a fast body against one without continuous collision on.
#
# WHY A RESTART-TO-EMPTY FILL SPECIFICALLY (Phase 3c changed this). Boot no longer plays physics
# forward at all — `_seed_initial_bed` places an already-settled lattice directly, so there is no
# free-fall to test at boot any more. Every OTHER body that enters a bed with something already
# under it (`_admit_batch` once the pile has depth, `_feed_drop`, `_feed_reinject`) lands on top
# of an already-settled pile — a few px of fall. A restart-to-empty fill is now the ONLY moment
# nothing is underneath: the first pebbles admitted through `FuelLoop.inlet_admit_point` free-fall
# the full drop to the closed floor at OUTLET_Y and reach real speed, well over a diameter per
# physics step at 32 solver iterations — the same hazard the old boot-time queue fill used to
# produce, just moved to a different trigger.
#
# WHAT A BREACH LOOKS LIKE ON SCREEN, player-reported and reproduced here: the escaped pebble
# comes to rest above the transport duct (it looks like it "fell through and stopped"), sits there
# because `_extract_lowest` is gated off until the bed reaches the population setpoint, and once
# the gate opens it reads as the single lowest pebble in the core (it is, by a wide margin) and
# gets extracted — reappearing at the fixed drop mouth (Silo.CENTER_X) instead of wherever it
# actually fell, which is the "disappears, then reappears on a different x" half of the report.
#
# MEASURED historically with the admission spawn's `set_continuous_cd` call absent: pebbles
# breached the closed floor early in a fill, velocity at breach almost always (0, ~980-1000) px/s
# — a straight vertical pass through the floor, not a lateral solver-ejection spike, which is what
# points this gate at CCD rather than at spawn clearance.
extends SceneTree

const FILL_SETPOINT := 380
const WATCH_FOR := 60.0    # measured ~11/s effective throughput, not the raw 15/s _fill_rate

var _main
var _t := 0.0
var _failures := 0
var _spawn_pos: Dictionary = {}    # id -> spawn x, for bodies just placed at the top
var _breaches: Array = []          # [{id, t, pos, vel}]
var _restarted := false


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live fill escape] the closed hopper floor must hold during a restart-to-empty fill")


func _process(delta: float) -> bool:
	_t += delta

	if not _restarted:
		# Boot itself seeds directly with no physics playback (Phase 3c) — the free-fall hazard
		# this test guards only appears once we force a REAL admission fill from empty.
		_main._population_setpoint = 0
		_main._restart_reactor()
		_main._population_setpoint = FILL_SETPOINT
		_restarted = true
		_t = 0.0
		print("[live fill escape] restarted to empty, target %d — watching the real fill" % FILL_SETPOINT)
		return false

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

	if _t >= WATCH_FOR:
		print("  core=%d/%d over %.0f s of fill" % [_main._core_count(), _main._population_setpoint, WATCH_FOR])
		_check(_breaches.is_empty(),
			"no core-flagged body ever breached the closed hopper floor (%d breach(es))"
				% _breaches.size())
		_check(_main._core_count() >= FILL_SETPOINT - 5,
			"bed reached its fill setpoint (%d/%d)"
				% [_main._core_count(), FILL_SETPOINT])
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
