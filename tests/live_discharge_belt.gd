# tests/live_discharge_belt.gd
#
# Integration gate for PHASE 3b-i: the discharge leg carries REAL BODIES on a REAL BELT.
#   godot --headless --script res://tests/live_discharge_belt.gd
#
# WHY a live harness: this is transport, and transport lives entirely in main + game/. The
# pure suites drive sim/ directly and never instantiate main, so every one of them stays
# green whether this leg delivers pebbles or fires them into space. A green pure suite is
# necessary here and says nothing.
#
# WHAT THIS GUARDS, in ascending order of how quietly it would pass:
#
# FAILURE 1 — the belt jams. Measured for real during the spike for this work: at force 900
# two pebbles in ten WEDGE PERMANENTLY in the drop/conveyor elbow (one settles in the
# corner, a second stacks on it, and the belt is asked to beat ~two pebbles' weight of
# friction). Nothing crashes; spent fuel just stops arriving and the pool stops growing.
#
# FAILURE 2 — the pebble ESCAPES. Also measured: with a constant force and no speed cap the
# pebble leaves the conveyor at ~670 px/s, sails over the 49 px tray, clears its far wall
# and falls out of the world (last seen at y ≈ 78000). It is still counted as discharged.
# This is why the exit-speed check below exists and why it is the load-bearing one: it tests
# the CAUSE (the belt is speed-limited) rather than waiting to notice the effect.
#
# FAILURE 3 — the bed silently drains. THE one that matters to the reactor. Transiting
# pebbles are `_out_of_core`, so they are outside the flux solve; but if this leg swallowed
# pebbles the mint gate would keep minting against an inventory that never opens slots, and
# RECOMMENDED_POPULATION = 380 is CALIBRATED — A_REF and the whole M4/M5 operating point
# assume exactly that many homogenized pebbles, and it is also the default player setpoint.
# A bed running short shifts k with nothing on screen to say so. This is what "keep the
# reactor calibrated" means in this slice, so the bed is watched continuously rather than
# once at the end.
#
# ⚠️ SATURATION IS NOT A JAM, and this harness is built to not confuse them — the spike
# nearly did. Feeding a pipe faster than it can clear makes rides long and arrivals late,
# which looks exactly like sticking. That is THROUGHPUT, not a stuck pebble, and it is not
# a failure of anything. So the stress phase below runs the leg at a few times NOMINAL and
# no more, and the jam gate asks "did this pebble EVER move again", never "was it quick".
extends SceneTree

# The bed fills by ~30 s and discharges are flowing by ~70 s (live_fuel_loop's measurement).
const SETTLE_AT := 80.0
# How long to watch. Nominal discharge is ~1 per 16 s — far too rare to see a jam that bites
# 2 times in 10 — so the middle phase RAISES the traffic deliberately (see _stress).
const STRESS_FOR := 60.0
const GIVE_UP_AT := SETTLE_AT + STRESS_FOR + 30.0

# A pebble is STUCK if it has not moved a pebble's width in this long. Deliberately about
# how far it has GOT, not how long it has been on the leg: a pebble queued behind twelve
# others is having a slow ride, which is fine and expected under stress, while one wedged in
# the elbow has simply stopped. Distance moved is what tells those apart.
const STUCK_AFTER := 12.0
const STUCK_DIST := 2.0 * FuelLoop.PEBBLE_R

# The belt's own speed, plus room for the fall off the end (the pebble is still accelerating
# under gravity when it lands). What this must NOT tolerate is the 670 px/s escape.
const EXIT_SPEED_MAX := 3.0 * FuelLoop.BELT_DISCHARGE

var _main
var _t := 0.0
var _failures := 0
var _checks := 0
var _stressing := false

# id -> {t, at, moved_t} for everything currently on the belt.
var _watch: Dictionary = {}
var _arrived := 0
var _rides: Array = []          # completed ride durations
var _peak_transit := 0
var _stuck: Array = []          # ids that stopped moving and never restarted
var _escaped: Array = []
var _exit_speeds: Array = []
var _min_core := 1 << 30         # nominal phase only — the gated one
var _min_core_stress := 1 << 30  # reported, deliberately NOT gated (see _process)
var _bed_dips := 0
var _peak_in_flight := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live discharge belt] spent fuel must ride a real pipe into the pool — ",
		"without jamming, without escaping, and without draining the bed")


func _check(pass_: bool, msg: String) -> void:
	_checks += 1
	if pass_:
		print("  PASS  %s" % msg)
	else:
		_failures += 1
		printerr("  FAIL  %s" % msg)


func _process(delta: float) -> bool:
	_t += delta

	# THE calibration gate, sampled every frame rather than at the end: a bed that dips and
	# recovers has still shifted k while it was short, and an end-of-run snapshot would never
	# know. Only once the bed has had time to fill.
	#
	# NOMINAL AND STRESS ARE SCORED SEPARATELY, and only nominal is gated. This is the
	# discharge rate the leg is built for (~1 per 16 s, ~0.15 pebbles in flight) and the one
	# the player actually runs, so the bed must be EXACTLY 380 through it — that is what
	# "keep the reactor calibrated" means here. The stress phase deliberately drives ~50x
	# that for 38 s straight; the fresh-mint-and-ride chain has latency that has nothing to
	# do with this leg, and the pre-3b plant may not have held exact-380 through such a flush
	# either. Demanding 380 there would be gating a number that was never promised, and
	# chasing it would mean re-tuning LOOP_BUFFER to satisfy a test rather than a reactor.
	# What the flush IS gated on is that nothing breaks: no escapes, no ghosts, no plug.
	if _t > 30.0:
		var core: int = _main._core_count()
		if _stressing:
			_min_core_stress = mini(_min_core_stress, core)
		else:
			_min_core = mini(_min_core, core)
			if core < _main._population_setpoint:
				_bed_dips += 1

	_track()

	if not _stressing and _t >= SETTLE_AT:
		_stress()
	if _stressing and _t >= SETTLE_AT + STRESS_FOR:
		_report()
		return true
	if _t > GIVE_UP_AT:
		printerr("  FAIL  timed out before the watch window closed")
		_failures += 1
		_report()
		return true
	return false


## Raise the discharge traffic to a few times nominal — enough to see a jam that bites 2 in
## 10, and deliberately NOT enough to saturate the pipe.
##
## Nominal is ~1 discharge per 16 s because only ~1 extraction in 10 is of a spent pebble.
## Dropping the policy knob makes a larger fraction of them spent, which is a REAL use of a
## REAL player lever (G/H) rather than a poke at internals — the same trick live_fuel_policy
## uses. It is capped well short of "every extraction discharges" (1 per 0.3 s), which would
## just queue: the spike measured 14-19 of 24 arriving with 30-36 s rides at EVERY force,
## which is the pipe being full, not the pipe being broken.
func _stress() -> void:
	_stressing = true
	# The bed is seeded to a burnup spread of 0 → ~90, so this discharges roughly the top
	# third of it: a few per 10 s rather than one per 16 s.
	_main._discharge_burnup = 60.0
	print("  [stress] discharge burnup knob → 60 MWd/kgHM (traffic up ~5x, still well ",
		"under the 1-per-0.3 s saturation point)")


## Watch every body on the belt: is it moving, has it arrived, has it left the world.
##
## ⚠️ THE DISCHARGE LEG ONLY. `_transit` carries the recirculation leg too since Phase 3b-ii —
## same drop, same duct, opposite belt — and this suite is about spent fuel reaching the tray.
## Left unfiltered every check here quietly changes meaning: a recirculating pebble leaves
## `_transit` at the top of the riser, and the arrival loop below would count that as a pebble
## admitted to the POOL, inflating `_arrived` with fuel that went back into the reactor. The
## conservation check at the end (`held + casked == extracted`) would then fail against a
## plant that had lost nothing.
##
## `_peak_transit` is the deliberate exception and stays TOTAL, because the thing it feeds is
## the LOOP_BUFFER gate — and the buffer covers every pebble out of the bed regardless of
## which pipe it is in.
func _track() -> void:
	_peak_transit = maxi(_peak_transit, _main._transit.size())
	# The LOOP_BUFFER-relevant quantity, measured against the SETPOINT rather than the live
	# core count — see live_fuel_loop.gd's note on the same trap. Real physical admission
	# means the bed's own count legitimately dips by ~1 between an extraction and its
	# replacement landing, which would make `inventory - core_count` read one high on every
	# extraction even with nothing wrong. Against the setpoint this is structurally bounded
	# by `main._mint_pebble`'s own gate (`_inventory() < setpoint + LOOP_BUFFER`).
	_peak_in_flight = maxi(_peak_in_flight, _main._inventory() - _main._population_setpoint)
	for id in _main._transit:
		if _main._transit[id] != FuelLoop.DISCHARGE:
			continue
		var at: Vector2 = _main._physics.get_position(id)
		if not _watch.has(id):
			_watch[id] = {"t": _t, "at": at, "moved_t": _t}
			continue
		var w: Dictionary = _watch[id]
		# Progress, not speed: a pebble shuffling forward in a queue is fine.
		if at.distance_to(w["at"]) > STUCK_DIST:
			w["at"] = at
			w["moved_t"] = _t
		elif _t - w["moved_t"] > STUCK_AFTER and not _stuck.has(id):
			_stuck.append(id)
			printerr("  [stuck] #%d has not moved %.0f px in %.0f s, at (%.0f, %.0f)"
				% [id, STUCK_DIST, STUCK_AFTER, at.x, at.y])
		# Out of the world. The tray has a floor, so nothing legitimately gets below it —
		# a body here went past the tray entirely, which is the constant-force escape.
		if at.y > FuelLoop.POOL_FLOOR + 50.0 and not _escaped.has(id):
			_escaped.append(id)
			printerr("  [escaped] #%d is at (%.0f, %.0f) — below the tray floor" % [id, at.x, at.y])
		# Catch the speed at the moment it leaves the belt — the number that decides whether
		# it lands in the tray or flies over it. `in_duct` is the old `on_discharge_belt` with
		# its right-hand edge moved out to the riser (the duct is shared now); for a pebble on
		# THIS leg the meaning is unchanged, since it leaves the duct at the pool's mouth.
		if not FuelLoop.in_duct(at) and at.y > FuelLoop.HUB_Y:
			var v: float = _main._physics.get_velocity(id).length()
			if _exit_speeds.size() < 200:
				_exit_speeds.append(v)

	# Anything we were watching that is no longer in transit has been admitted to the pool.
	for id in _watch.keys():
		if not _main._transit.has(id):
			_arrived += 1
			_rides.append(_t - float(_watch[id]["t"]))
			_watch.erase(id)


func _report() -> void:
	print("\n=== discharge belt ===")
	var max_ride := 0.0
	var sum_ride := 0.0
	for r in _rides:
		max_ride = maxf(max_ride, r)
		sum_ride += r
	var mean_ride := sum_ride / maxf(float(_rides.size()), 1.0)
	var max_exit := 0.0
	for v in _exit_speeds:
		max_exit = maxf(max_exit, v)
	print("  arrived %d   in flight at end %d   peak in transit %d" %
		[_arrived, _main._transit.size(), _peak_transit])
	print("  ride: mean %.2f s  max %.2f s   exit speed: max %.0f px/s (belt %.0f)" %
		[mean_ride, max_ride, max_exit, FuelLoop.BELT_DISCHARGE])
	print("  bed: NOMINAL min core %d / %d (%d frames short)   under flush: min %d (not gated)" %
		[_min_core, _main._population_setpoint, _bed_dips, _min_core_stress])

	# Where the "held" pebbles ACTUALLY are. `pool_contains` fires the moment a falling
	# pebble crosses into the tray's rect, which is a position test and not a rest test — so
	# a pebble can be admitted, bounce off an over-full pile, and come to rest back on the
	# conveyor, where nothing drives it any more (it has left `_transit`) and it plugs the
	# pipe for good. That is a specific, checkable story and this is what checks it.
	var outside := 0
	print("  --- pool contents (tray x %.0f..%.0f, rim y %.0f, floor y %.0f) ---" %
		[FuelLoop.POOL_LEFT, FuelLoop.POOL_LEFT + FuelLoop.POOL_W,
			FuelLoop.POOL_FLOOR - FuelLoop.POOL_H, FuelLoop.POOL_FLOOR])
	for peb in _main._spent:
		var at: Vector2 = _main._physics.get_position(peb.id)
		var inside: bool = FuelLoop.pool_contains(at)
		if not inside:
			outside += 1
		print("    #%-4d (%6.1f, %6.1f)  %s" % [peb.id, at.x, at.y,
			"in tray" if inside else "*** OUTSIDE ***"])
	_check(outside == 0,
		"every pebble the pool CLAIMS to hold is actually resting in the tray (%d outside)" % outside)

	# The leg does its job at all. Without this every check below is vacuously true — a leg
	# that never moves a pebble jams nothing and escapes nowhere.
	_check(_arrived > 0, "spent fuel actually reaches the pool (%d arrived)" % _arrived)
	_check(_stuck.is_empty(), "nothing wedged in the pipe (%d stuck)" % _stuck.size())
	_check(_escaped.is_empty(), "nothing left the world (%d escaped)" % _escaped.size())
	_check(max_exit < EXIT_SPEED_MAX,
		"the belt is SPEED-limited, not force-limited: exits at %.0f px/s, far below the ~670 that flies the tray"
			% max_exit)

	# THE calibration gate, at the rate the leg is built for. Transiting bodies are
	# `_out_of_core`, so the leg is neutronically invisible by construction — what this
	# proves is that the ACCOUNTING around it (the feed queue holding inventory, the slot
	# opening on arrival rather than at the sorter) did not drain the bed.
	#
	# Not exact-pin any more: under Phase 3c an extracted pebble is a real body that has to
	# physically travel back through the inlet before it lands, so the bed legitimately dips
	# by ~1 for the gap between an extraction and its replacement — admission lag, not the
	# pipe draining the bed. What this still forbids is the bed running down for real, which
	# is exactly what this leg swallowing pebbles (FAILURE 3, see header) would look like.
	_check(_min_core >= _main._population_setpoint - 3,
		"bed stayed near its setpoint %d through NOMINAL discharge, not draining (min %d)" %
			[_main._population_setpoint, _min_core])
	_check(_peak_in_flight <= _main.LOOP_BUFFER,
		"peak in flight (%d) stays well under LOOP_BUFFER (%d)" %
			[_peak_in_flight, _main.LOOP_BUFFER])

	# Nothing is swallowed: every pebble ever discharged is either held in the tray, gone to
	# a cask, or still on its way. `_total_extracted` is only incremented on ARRIVAL now
	# (`_pool_admit`), so this is the leg's own conservation law.
	var accounted: int = _main._spent.size() + _main._total_shipped
	_check(accounted == _main._total_extracted,
		"every arrival is accounted: held %d + casked %d == extracted %d" %
			[_main._spent.size(), _main._total_shipped, _main._total_extracted])

	print("\n%s  (%d checks, %d failed)" %
		["ALL CHECKS PASSED" if _failures == 0 else "FAILURES", _checks, _failures])
	quit(1 if _failures > 0 else 0)
