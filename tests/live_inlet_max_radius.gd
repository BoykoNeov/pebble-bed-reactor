# tests/live_inlet_max_radius.gd
#
# Regression gate for a lane-overlap hazard found by inspection, not by symptom, while
# reviewing the Phase 3c multi-lane inlet (`FuelLoop.INLET_LANES`): `inlet_walls()` builds
# only the two OUTER bore walls — there are no physical dividers between lanes — yet
# `_inlet_top_clear`/`_admit_mouth_clear` gate each lane with a FIXED axis-aligned box
# (`INLET_LANE_HALF_WIDTH`, `INLET_MOUTH_CLEAR`) sized off the nominal `PEBBLE_R`, not the
# player's actual `_pebble_radius`. At `RADIUS_MAX` (== `BORE_W * 0.5`, i.e. a pebble that
# exactly fills one lane's pitch with zero slack — "the pebble must fit the pipe it rides
# in") a resting pebble just outside one lane's box is geometrically close enough to a
# neighbouring lane's spawn point to overlap it on paper: box half-width 7.7px vs. a
# required 22px of separation for two RADIUS_MAX bodies. That is a real gap in the check's
# guarantee — spawning a body ON TOP of another is exactly the tunnelling failure class
# `3be4e7b` and the time_scale bug both hit.
#
# THE FIX WAS NOT TO CHANGE THE CHECK. An empirical probe (forced RADIUS_MAX, restarted
# empty, overfilled to `OVERFILL_MAX` so the pile backs up all the way to the inlet TOP —
# where the hazard concentrates, not just the admit-into-bed point at the bottom) ran 120s
# with zero escapes; the core plateaued at a genuine mechanical jam (mint_pending backed up,
# core count flat) rather than any explosive event. Godot's solver resolves the geometric
# overlap this check theoretically permits with an ordinary soft position correction, not a
# violent kick — the same reason two pebbles admitted with slightly overlapping jitter never
# explode anywhere else in this plant. This test is the permanent version of that probe: it
# exists so a FUTURE change to the clear-check geometry, lane pitch, or solver tuning that
# reintroduces real energy at that overlap gets caught, even though today's geometry is safe
# in practice.
#   godot --headless --script res://tests/live_inlet_max_radius.gd
extends SceneTree

const BOOT_SETTLE := 3.0
const OVERFILL_TARGET := 800   # main.OVERFILL_MAX — push the pile all the way to the brim
const WATCH_FOR := 120.0
const ESCAPE_BOUND := 1500.0

var _main
var _t := 0.0
var _next_sample := 0.0
var _escaped: Array = []
var _flagged := {}
var _forced := false
var _restarted := false

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live inlet max-radius] force RADIUS_MAX -> restart empty -> overfill to brim -> watch for escapes")


func _check(pass_: bool, msg: String) -> void:
	_checks += 1
	if pass_:
		print("  PASS  %s" % msg)
	else:
		_failures += 1
		printerr("  FAIL  %s" % msg)


func _process(delta: float) -> bool:
	_t += delta

	if not _forced:
		_forced = true
		_main._pebble_radius = _main.RADIUS_MAX
		print("[live inlet max-radius] forced _pebble_radius = %.1f (RADIUS_MAX)" % _main.RADIUS_MAX)

	_watch_escapes()

	if not _restarted and _t >= BOOT_SETTLE:
		_restarted = true
		print("[live inlet max-radius] restarting empty, then overfilling to %d at RADIUS_MAX" % OVERFILL_TARGET)
		_main._population_setpoint = 0
		_main._restart_reactor()
		_main._pebble_radius = _main.RADIUS_MAX   # restart doesn't touch the radius lever; keep it forced
		_main._population_setpoint = OVERFILL_TARGET

	if _t >= _next_sample:
		_next_sample += 10.0
		print("  t=%6.1f  core=%3d/%3d  mint_pending=%3d  escaped=%d"
			% [_t, _main._core_count(), _main._population_setpoint, _main._mint_pending.size(), _escaped.size()])

	if _t >= BOOT_SETTLE + WATCH_FOR:
		_report()
		return true

	return false


## Every body, every frame — the direct signature of an overlap-driven ejection: a body
## flung to an absurd position after being spawned on top of another.
func _watch_escapes() -> void:
	var positions: Dictionary = _main._physics.positions()
	for id in positions:
		var at: Vector2 = positions[id]
		if not _flagged.has(id) and (absf(at.x) > ESCAPE_BOUND or absf(at.y) > ESCAPE_BOUND):
			_flagged[id] = true
			_escaped.append(id)
			printerr("  [ESCAPED] id=%d at t=%.2f pos=(%.0f, %.0f)" % [id, _t, at.x, at.y])


func _report() -> void:
	print("\n=== live inlet max-radius report ===")
	print("  final core=%d/%d  mint_pending=%d" % [_main._core_count(), _main._population_setpoint, _main._mint_pending.size()])
	print("  escaped bodies: %d" % _escaped.size())

	_check(_escaped.is_empty(),
		"no body was ejected out of the plant's bounds at RADIUS_MAX under overfill (%d escaped)" % _escaped.size())
	_check(_main._core_count() > 0, "the max-radius fill actually admitted pebbles at all (%d)" % _main._core_count())

	print("\n%s  (%d checks, %d failed)" %
		["ALL CHECKS PASSED" if _failures == 0 else "FAILURES", _checks, _failures])
	quit(1 if _failures > 0 else 0)
