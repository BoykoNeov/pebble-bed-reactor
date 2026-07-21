# tests/live_fresh_gate.gd
#
# Integration gate for the FRESH/RECIRC belt split (Phase 3b-iv): fresh fuel rides its OWN
# line above the recirc/reinject chute, and that upper belt holds its drop through CHUTE_Y
# until the lower line is clear at that x (`FuelLoop._gate_clear`).
#
#   godot --headless --script res://tests/live_fresh_gate.gd
#
# WHY THIS EXISTS. Before this split, EVERY rider bound for the bed — FRESH, RECIRC, and
# REINJECT alike — rode the exact same Vector2(spawn_x, CHUTE_Y) point on the exact same
# horizontal line. Riders have no physics body (fuel_loop.gd's own class doc: this machine is
# presentation, not physics) and never tested against each other, so a fresh pebble and a
# recirculating one really could occupy the identical point on screen at the identical
# instant — this is the "new pebbles... on the same horizontal axis as the recirculating
# pebbles, without coliding" report. Giving FRESH its own line (FRESH_CHUTE_Y, 20 px above
# CHUTE_Y) removes the coincidence everywhere except FRESH's own final drop, which still has
# to cross down through CHUTE_Y at the pebble's own spawn_x — so THAT crossing is what needs
# a real check, not just distance.
#
# WHAT THIS RUNS: the live scene (main.tscn) through the initial fill and into steady-state
# operation, where both FRESH (mint-gate replacements for discharged fuel) and RECIRC/REINJECT
# traffic are actually live at once — the only conditions under which a collision could ever
# have been observed in the first place.
extends SceneTree

const RUN_FOR := 100.0

var _main
var _t := 0.0
var _failures := 0
var _closest := INF
var _overlaps: Array = []          # [{t, fresh_id, other_id, dist, clear}]
var _fresh_ids_seen: Dictionary = {}


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live fresh gate] FRESH must never overlap a RECIRC/REINJECT rider at the CHUTE_Y crossing")


func _process(delta: float) -> bool:
	_t += delta

	var riders: Array = _main._loop._riders
	var fresh: Array = []
	var lower: Array = []
	for r in riders:
		if r["kind"] == FuelLoop.FRESH:
			fresh.append(r)
			_fresh_ids_seen[r["id"]] = true
		elif r["kind"] == FuelLoop.RECIRC or r["kind"] == FuelLoop.REINJECT:
			lower.append(r)

	for f in fresh:
		var fp: Vector2 = FuelLoop._point_at(f["pts"], f["d"])
		for l in lower:
			var lp: Vector2 = FuelLoop._point_at(l["pts"], l["d"])
			var dist: float = fp.distance_to(lp)
			var clear: float = float(f["r"]) + float(l["r"])
			_closest = minf(_closest, dist - clear)
			if dist < clear:
				_overlaps.append({"t": _t, "fresh": f["id"], "other": l["id"],
					"dist": dist, "clear": clear})

	if _t >= RUN_FOR:
		print("  %d distinct FRESH riders seen over %.0f s, closest margin %.2f px"
			% [_fresh_ids_seen.size(), RUN_FOR, _closest])
		for o in _overlaps.slice(0, min(5, _overlaps.size())):
			printerr("  OVERLAP t=%.2fs fresh#%d vs #%d dist=%.1f clear=%.1f"
				% [o["t"], o["fresh"], o["other"], o["dist"], o["clear"]])
		_check(_fresh_ids_seen.size() > 0,
			"FRESH traffic actually ran during this window (%d distinct riders)"
				% _fresh_ids_seen.size())
		_check(_overlaps.is_empty(),
			"no FRESH rider ever overlapped a RECIRC/REINJECT rider at the crossing (%d overlap(s))"
				% _overlaps.size())
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
