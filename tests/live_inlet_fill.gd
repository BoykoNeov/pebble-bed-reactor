# tests/live_inlet_fill.gd
#
# Integration gate for PHASE 3c: the single shared inlet — boot's instant seed, a player
# restart's REAL admission fill, and the steady-state loop (extraction/recirc/discharge/
# reinject) all converging on that one fixed point.
#   godot --headless --script res://tests/live_inlet_fill.gd
#
# WHY THIS EXISTS: Phase 3c replaced per-leg riders and a hard-pinned TARGET_POPULATION with
# one real, physically-collidable inlet plus a player population setpoint. The first version
# of the boot path used `Engine.time_scale = 8.0` to play the real fill back fast — MEASURED,
# via a throwaway probe, to reliably punch settled BED pebbles straight through the silo's
# closed hopper floor (0 escapes in 70s at time_scale=1.0, dozens once restored to 8.0).
# Godot hands `_physics_process` a delta already scaled by `time_scale`, and that same delta
# is what the physics integrator steps with — so 8x isn't "call physics 8x more often", it is
# "every body takes an 8x bigger stride every step", which is a fundamentally different (and
# much larger) hazard than the single long first-drop `3be4e7b` proved CCD safe against. Boot
# now places an already-settled bed directly (`_seed_initial_bed`, no physics playback at
# all); a restart runs the real fill at ordinary speed. This test is the regression gate for
# both halves, plus the one thing neither throwaway probe covered: whether the LOOP — the
# brand-new Phase 3c merge-run-to-inlet-bore code every recirc/discharge/reinject pebble now
# has to pass through — actually keeps moving once the bed is full, or silently jams the way
# `drop_pending` was observed to during the very same time_scale=8 run that produced the
# escapes (never re-confirmed once that root cause was removed).
extends SceneTree

const BOOT_SETTLE := 5.0          # watch the seeded lattice on its own before touching it
const FILL_SETPOINT := 380
const FILL_GIVE_UP := 150.0       # generous: measured ~4.3/s -> ~90s, this leaves real margin
const LOOP_WATCH_FOR := 90.0      # time after the bed is full to prove the loop keeps moving
const ESCAPE_BOUND := 1500.0      # plant span is roughly x[380,1050] y[0,1080]
# `drop_pending` (discharge/recirc pebbles staged at the shared drop, waiting for the mouth
# to clear) is allowed to sit nonzero — that is a normal queue — but not UNCHANGED this long,
# which is what a jammed mouth or a stuck belt looks like.
const DROP_PENDING_STUCK_AFTER := 20.0

var _main
var _t := 0.0
var _next_sample := 0.0
var _escaped: Array = []
var _flagged := {}

var _phase := "boot"              # boot -> filling -> looping -> done
var _fill_start_t := 0.0
var _full_at_t := -1.0

var _drop_pending_last_size := -1
var _drop_pending_last_change_t := 0.0
var _drop_pending_stuck := false

# Snapshot at the HALFWAY point of the loop-watch window, so the final report can assert the
# loop made real progress in the back half — not just that recirc+extract is nonzero overall.
# A cumulative "moved SOME pebbles" check is satisfiable by a burst that happens once, early,
# then jams solid for good (measured: exactly this shape shipped green once — a wall-gap bug
# let ~45 pebbles cycle before freezing the whole fuel cycle permanently, and the cumulative
# check never noticed because the burst alone cleared it). A back-half delta cannot be fooled
# that way: it is zero unless the loop is still genuinely running near the end of the watch.
var _halfway_recirc := -1
var _halfway_extracted := -1
var _halfway_taken := false

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live inlet fill] boot -> restart-to-empty -> real fill -> steady-state loop")


func _check(pass_: bool, msg: String) -> void:
	_checks += 1
	if pass_:
		print("  PASS  %s" % msg)
	else:
		_failures += 1
		printerr("  FAIL  %s" % msg)


func _process(delta: float) -> bool:
	_t += delta
	_watch_escapes()

	match _phase:
		"boot":
			if _t >= BOOT_SETTLE:
				_check(_main._core_count() == FILL_SETPOINT,
					"boot seeds the recommended population instantly (%d/%d)"
						% [_main._core_count(), FILL_SETPOINT])
				# NOT a velocity-magnitude check: extraction is immediately live at boot (core
				# already >= setpoint on frame one), so removing the lowest pebble from a
				# freshly-packed lattice causes normal local resettling in the pile above it —
				# ordinary granular mechanics (the same thing every extraction does in real
				# play), not a defect, and a velocity threshold has no principled place to sit
				# between "that" and "an actual explosion" (measured: a benign settle already
				# reaches 774 px/s here). What actually matters is answered by `_watch_escapes`
				# across the whole run; this checks the one thing specific to the SEED itself —
				# every body it placed is still inside the vessel it was placed in.
				_check(_all_bed_pebbles_inside_vessel(),
					"every seeded pebble is still inside the vessel at t=%.0fs (not popped through a wall)"
						% BOOT_SETTLE)
				print("[live inlet fill] boot settled — restarting to empty, target %d" % FILL_SETPOINT)
				_main._population_setpoint = 0
				_main._restart_reactor()
				_main._population_setpoint = FILL_SETPOINT
				_fill_start_t = _t
				_phase = "filling"
		"filling":
			if _main._core_count() >= FILL_SETPOINT:
				_full_at_t = _t
				print("[live inlet fill] bed reached setpoint at t=%.1f (%.1fs after restart) — watching the loop for %.0fs"
					% [_t, _t - _fill_start_t, LOOP_WATCH_FOR])
				_phase = "looping"
			elif _t - _fill_start_t > FILL_GIVE_UP:
				_check(false, "the real admission fill reached setpoint within %.0fs (stuck at %d/%d)"
					% [FILL_GIVE_UP, _main._core_count(), FILL_SETPOINT])
				_report()
				return true
		"looping":
			_watch_drop_pending()
			if not _halfway_taken and _t - _full_at_t > LOOP_WATCH_FOR * 0.5:
				_halfway_taken = true
				_halfway_recirc = _main._total_recirculated
				_halfway_extracted = _main._total_extracted
			if _t - _full_at_t > LOOP_WATCH_FOR:
				_phase = "done"
				_report()
				return true

	if _t >= _next_sample:
		_next_sample += 3.0
		print("  t=%6.2f [%s]  core=%3d/%3d  mint_pending=%3d  drop_pending=%2d  recirc=%d  extracted=%d  shipped=%d  reinjected=%d"
			% [_t, _phase, _main._core_count(), _main._population_setpoint, _main._mint_pending.size(),
				_main._drop_pending.size(), _main._total_recirculated, _main._total_extracted,
				_main._total_shipped, _main._total_reinjected])

	return false


## Every body, every frame — the direct signature of the tunnelling failure this test guards
## against: a body flung to an absurd position never seen again.
func _watch_escapes() -> void:
	var positions: Dictionary = _main._physics.positions()
	for id in positions:
		var at: Vector2 = positions[id]
		if not _flagged.has(id) and (absf(at.x) > ESCAPE_BOUND or absf(at.y) > ESCAPE_BOUND):
			_flagged[id] = true
			_escaped.append(id)
			printerr("  [ESCAPED] id=%d at t=%.2f phase=%s  pos=(%.0f, %.0f)" % [id, _t, _phase, at.x, at.y])


## Are all CORE (bed) pebbles still within the vessel's outer bounds, with a small margin for
## the pebble's own radius? This is what "the seed itself is valid" actually means — not a
## velocity magnitude (see the call site), but positions still where they were placed, not
## popped through a wall by an overlap the lattice's clearance should have prevented.
func _all_bed_pebbles_inside_vessel() -> bool:
	var margin := 20.0
	var positions: Dictionary = _main._physics.positions()
	for id in positions:
		if _main._out_of_core.has(id) or _main._transit.has(id):
			continue
		var at: Vector2 = positions[id]
		if at.x < Silo.LEFT - margin or at.x > Silo.RIGHT + margin \
				or at.y < Silo.TOP - margin or at.y > Silo.OUTLET_Y + margin:
			printerr("  [outside vessel] core pebble id=%d at (%.0f, %.0f)" % [id, at.x, at.y])
			return false
	return true


## `drop_pending` is the shared discharge/recirc staging list at the outlet — the ONE queue
## upstream of all the brand-new Phase 3c merge-run/inlet-bore plumbing. If the new inlet ever
## backs traffic up far enough to stall the risers, this is where it would first show as stuck
## (as opposed to merely long — see the project's own "saturation is not a jam" discipline).
func _watch_drop_pending() -> void:
	var size: int = _main._drop_pending.size()
	if size != _drop_pending_last_size:
		_drop_pending_last_size = size
		_drop_pending_last_change_t = _t
	elif size > 0 and _t - _drop_pending_last_change_t > DROP_PENDING_STUCK_AFTER and not _drop_pending_stuck:
		_drop_pending_stuck = true
		printerr("  [stuck] drop_pending has held at %d for over %.0fs at t=%.1f" % [size, DROP_PENDING_STUCK_AFTER, _t])


func _report() -> void:
	print("\n=== live inlet fill report ===")
	print("  fill: restart at t=%.1f, setpoint reached at t=%.1f (%s)" %
		[_fill_start_t, _full_at_t, "%.1fs" % (_full_at_t - _fill_start_t) if _full_at_t >= 0.0 else "NEVER"])
	print("  final core=%d/%d  mint_pending=%d  drop_pending=%d"
		% [_main._core_count(), _main._population_setpoint, _main._mint_pending.size(), _main._drop_pending.size()])
	print("  loop activity: recirculated=%d  extracted=%d  shipped=%d  reinjected=%d"
		% [_main._total_recirculated, _main._total_extracted, _main._total_shipped, _main._total_reinjected])
	print("  escaped bodies: %d" % _escaped.size())

	_check(_escaped.is_empty(), "no body was ever flung out of the plant's bounds (%d escaped)" % _escaped.size())
	if _full_at_t >= 0.0:
		_check(not _drop_pending_stuck, "the shared drop never got stuck for the loop-watch window")
		# BACK-HALF DELTA, not a cumulative total: a total > 0 is satisfied by a burst that
		# runs once early and then jams for good — measured, this exact shape shipped green
		# once (a wall-gap bug let ~45 pebbles cycle through before permanently freezing the
		# whole fuel cycle, and "recirc+extract > 0" never noticed). Comparing the SECOND half
		# of the watch against the snapshot taken at the halfway point catches a freeze
		# anywhere in the back half, not just a total absence of ever moving anything.
		var recirc_progress: int = _main._total_recirculated - _halfway_recirc
		var extracted_progress: int = _main._total_extracted - _halfway_extracted
		_check(_halfway_taken and recirc_progress + extracted_progress > 0,
			"the loop keeps moving pebbles through the SECOND half of the watch, not just an early burst (+%d recirc, +%d extracted since the halfway mark)"
				% [recirc_progress, extracted_progress])
		_check(_main._core_count() >= FILL_SETPOINT - 5,
			"the bed HELD near setpoint through the loop-watch window, not draining (%d/%d)"
				% [_main._core_count(), FILL_SETPOINT])

	print("\n%s  (%d checks, %d failed)" %
		["ALL CHECKS PASSED" if _failures == 0 else "FAILURES", _checks, _failures])
	quit(1 if _failures > 0 else 0)
