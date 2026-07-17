# tests/live_riser.gd
#
# Integration gate for PHASE 3b-ii: the RECIRCULATION leg carries real bodies out of a drop it
# SHARES with the discharge leg, and lifts them 880 px up the riser.
#
#   godot --headless --script res://tests/live_riser.gd
#   godot --headless --script res://tests/live_riser.gd -- --no-ccd --radius=5   # see FAILURE 2
#
# WHY THIS EXISTS ALONGSIDE live_fuel_loop AND live_discharge_belt, rather than inside them.
# Those two drive the real plant and answer "is the reactor still calibrated" — bed pinned at
# 380, peak in flight under LOOP_BUFFER, nothing leaked. They are the right gates for that and
# they cover the wiring. What they cannot do is make the RARE cases happen: the live sorter
# sends ~9 of 10 extractions to the riser, so the drop is almost always carrying traffic in one
# direction, and the live design lever is almost always at the nominal radius. Both failures
# below live precisely in the cases the plant does not naturally produce. So this harness
# builds the geometry and the drive WITHOUT main — no bed, no neutronics, no 80 s fill — and
# feeds them the worst case on purpose. A run costs seconds.
#
# WHAT THIS GUARDS, both measured, neither hypothetical:
#
# FAILURE 1 — THE HEAD-ON. Both legs leave the same drop and are driven OPPOSITE ways out of
# the same duct. Two bodies pushed into each other at BELT_FORCE apiece stand there forever,
# and a plugged drop is a plugged fuel cycle: the queue starves, the bed runs short, k shifts
# with nothing on screen to say why. It should be impossible — every pebble enters at the
# drop's x and is driven AWAY from it, so `discharge_x <= drop_x <= recirc_x` holds
# structurally — but that is an argument, and this is the test. The feed below ALTERNATES leg
# every single pebble, which real traffic never does: steady state is ~90% recirc (all
# rightward) and the middle of a discharge wave is ~all discharge (all leftward), both
# one-directional and safe. The head-on window is only at the EDGES of a wave, so this runs
# nothing but edges.
#
# FAILURE 2 — TUNNELLING, AND IT IS THE SIZE LEVER THAT CAUSES IT, not the belt speed. Crossing
# a wall in one step takes roughly a body's own DIAMETER of travel. At 380 px/s a pebble moves
# ~6.3 px per step, so the NOMINAL 8 px pebble (16 px across) is never close — measured, 0 lost
# in ~1100. But radius is a PLAYER KNOB, and at RADIUS_MIN the pebble is 10 px across. Measured
# with CCD off at that radius: **12, 26 and 14 recirculating pebbles lost in three runs of ~70**
# — up to 37% — every one punched clean through the riser's right face and last seen at x ≈
# 1057. With CCD on: 0, 0, 0. A recirculating pebble that leaves through a wall is one the
# calibrated bed never gets back, so this is the gate standing under `_feed_drop`'s
# `set_continuous_cd` call. DEFAULTS TO RADIUS_MIN for exactly that reason: the nominal pebble
# passes this suite whether or not the plant is safe for the pebbles the player can build.
#
# ⚠️ SATURATION IS NOT A JAM. Feeding a pipe faster than it clears makes rides long, which
# looks like sticking and is not. The jam check below asks "did this body EVER move again",
# never "was it quick".
extends SceneTree

const DROP_EVERY := 0.30       # main's EXTRACT_INTERVAL: every extraction goes down this drop
const RUN_FOR := 45.0
# STUCK is about distance covered, not time on the leg: a pebble queued behind others is having
# a slow ride; one wedged in an elbow — or nose-to-nose with a pebble driven the other way —
# has stopped. A head-on shows up here, as two bodies that stop within a diameter of each other.
const STUCK_AFTER := 8.0
const STUCK_DIST := 2.0 * FuelLoop.PEBBLE_R

var _ccd := true
var _radius := 0.0             # resolved from main.RADIUS_MIN in _initialize
var _loop_buffer := 48

var _physics: PhysicsBackend
var _t := 0.0
var _next_id := 0
var _accum := 0.0
var _recirc_next := true
var _phys_ticks := 0
var _checks := 0
var _failures := 0

var _pending: Array = []          # legs waiting for the mouth to clear
var _transit: Dictionary = {}     # id -> leg
var _watch: Dictionary = {}       # id -> {t, at, moved_t}
var _arrived := {FuelLoop.RECIRC: 0, FuelLoop.DISCHARGE: 0}
var _fed := {FuelLoop.RECIRC: 0, FuelLoop.DISCHARGE: 0}
var _rides: Array = []
var _stuck: Array = []
var _escaped: Array = []
var _peak := 0
var _climbed := 0                 # bodies seen ABOVE the duct — proof the riser lifts at all
var _riser_exit_speeds: Array = []


func _initialize() -> void:
	# The real levers, read off main rather than restated here: this suite's whole claim is
	# about the pebbles the PLAYER can design, so a local copy of RADIUS_MIN that drifted from
	# main's would leave it certifying a pebble nobody can build.
	var cfg = load("res://main.gd")
	_radius = cfg.RADIUS_MIN
	_loop_buffer = cfg.LOOP_BUFFER
	for a in OS.get_cmdline_user_args():
		if a == "--no-ccd":
			_ccd = false
		elif a.begins_with("--radius="):
			_radius = float(a.split("=")[1])
	# ⚠️ WITHOUT THIS, REPEATS ARE NOT SAMPLES. Godot's global RNG is fixed-seed unless it is
	# randomized, so the bore play — the only disorder here — replays identically and N runs
	# return the same pack N times (measured: arrivals matching to the pebble across 8 runs).
	# That is exactly how a rare, pack-dependent failure hides.
	randomize()

	var world := Node2D.new()
	root.add_child(world)
	_physics = GodotPhysicsBackend.new()
	_physics.setup(world)
	# Built HERE rather than from main.tscn deliberately: the first spike for this work silently
	# dropped every wall (main's `_ready` had not run, so its `_physics` was null), the pebbles
	# free-fell past the arrival line, and it passed 10/10. Owning the backend means there is no
	# half-built scene to be fooled by.
	for seg in FuelLoop.plant_walls():
		_physics.add_static_segment(seg[0], seg[1])
	for seg in FuelLoop.pool_walls():
		_physics.add_static_segment(seg[0], seg[1])
	print("[live riser] shared drop, opposing belts, alternating EVERY pebble — ",
		"radius %.1f (%.1f px across vs %.1f px/step at belt speed), CCD %s"
			% [_radius, _radius * 2.0, FuelLoop.BELT_RISER / 60.0, "ON" if _ccd else "OFF"])


func _check(pass_: bool, msg: String) -> void:
	_checks += 1
	if pass_:
		print("  PASS  %s" % msg)
	else:
		_failures += 1
		printerr("  FAIL  %s" % msg)


# THE PHYSICS STEP, NOT THE RENDER STEP, and the difference is not pedantry. Godot ACCUMULATES
# applied force and consumes it on the next physics step, so pushing once per rendered frame
# while headless renders at ~1000 fps stacks ~16 pushes into every 60 Hz step: the belt would
# press with ~40000 instead of BELT_FORCE and clear every elbow effortlessly. The first run of
# this harness did exactly that and reported a riser exit speed of 524 px/s on a 380 px/s belt
# — impossible for a velocity-capped drive, which is what gave it away. main drives from
# `_physics_process` (`main._belt_step`) and so must this, or the machine under test is not the
# machine that ships.
func _physics_process(delta: float) -> bool:
	_phys_ticks += 1
	_t += delta
	_feed(delta)
	_step()
	if _t >= RUN_FOR:
		_report()
		return true
	return false


## The sorter, alternating: one pebble per EXTRACT_INTERVAL, legs strictly interleaved. Then the
## door — never materialize a body into an occupied mouth (`MOUTH_CLEAR`).
func _feed(delta: float) -> void:
	_accum += delta
	while _accum >= DROP_EVERY:
		_accum -= DROP_EVERY
		_pending.push_back(FuelLoop.RECIRC if _recirc_next else FuelLoop.DISCHARGE)
		_recirc_next = not _recirc_next
	if _pending.is_empty() or not _mouth_clear():
		return
	var leg: int = _pending.pop_front()
	var id := _next_id
	_next_id += 1
	_physics.spawn_pebble(id, FuelLoop.drop_mouth(randf_range(-1.0, 1.0), _radius), _radius)
	if _ccd:
		_physics.set_continuous_cd(id, true)
	_transit[id] = leg
	_fed[leg] += 1


func _mouth_clear() -> bool:
	var mouth := FuelLoop.drop_mouth()
	for id in _transit:
		if _physics.get_position(id).distance_to(mouth) < FuelLoop.MOUTH_CLEAR:
			return false
	return true


func _step() -> void:
	_peak = maxi(_peak, _transit.size())
	var done: Array = []
	for id in _transit:
		var at: Vector2 = _physics.get_position(id)
		var leg: int = _transit[id]
		if leg == FuelLoop.RECIRC and at.y < FuelLoop.HUB_Y - FuelLoop.BORE_W:
			_climbed += 1
		if _delivered(at, leg):
			done.append(id)
			continue
		_track(id, at)
		_drive(id, at, leg)
	for id in done:
		var leg: int = _transit[id]
		_arrived[leg] += 1
		if leg == FuelLoop.RECIRC:
			_riser_exit_speeds.append(_physics.get_velocity(id).length())
		if _watch.has(id):
			_rides.append(_t - float(_watch[id]["t"]))
			_watch.erase(id)
		_transit.erase(id)
		# Both legs end in a REMOVAL — the pool would admit (and eventually cask), the riser
		# head hands off to a chute rider. Removing here keeps the tray from filling and
		# plugging its own mouth: a real failure, but a different one, and POOL_CAP already
		# gates it (live_discharge_belt).
		_physics.remove_pebble(id)


## Arrived — in BOTH axes, never a bare y-line. A pipe with no walls passes a y-line check
## beautifully; that is exactly how the first spike for this work falsely passed 10/10.
func _delivered(at: Vector2, leg: int) -> bool:
	if leg == FuelLoop.RECIRC:
		return FuelLoop.riser_delivered(at)
	return FuelLoop.pool_contains(at)


## Mirrors `main._drive`. THE point: the direction comes from the pebble's LEG, never from where
## it is standing — both belts share this duct and run opposite ways.
func _drive(id: int, at: Vector2, leg: int) -> void:
	if leg == FuelLoop.DISCHARGE:
		if FuelLoop.in_duct(at):
			_belt(id, Vector2.LEFT, FuelLoop.BELT_DISCHARGE)
		return
	if FuelLoop.in_duct(at):
		_belt(id, Vector2.RIGHT, FuelLoop.BELT_RISER)
	if FuelLoop.in_riser(at):
		_belt(id, Vector2.UP, FuelLoop.BELT_RISER)


func _belt(id: int, dir: Vector2, speed: float) -> void:
	if _physics.get_velocity(id).dot(dir) < speed:
		_physics.apply_force(id, dir * FuelLoop.BELT_FORCE)


func _track(id: int, at: Vector2) -> void:
	if not _watch.has(id):
		_watch[id] = {"t": _t, "at": at, "moved_t": _t}
		return
	var w: Dictionary = _watch[id]
	if at.distance_to(w["at"]) > STUCK_DIST:
		w["at"] = at
		w["moved_t"] = _t
	elif _t - w["moved_t"] > STUCK_AFTER and not _stuck.has(id):
		_stuck.append(id)
		printerr("  [stuck] #%d (%s) has not moved %.0f px in %.0f s, at (%.0f, %.0f)"
			% [id, _leg_name(_transit[id]), STUCK_DIST, STUCK_AFTER, at.x, at.y])
	# Outside the plant entirely. The box is drawn well clear of every real run, so only a body
	# that has left through a wall can be in it — the tunnelling failure parks them at x ≈ 1057
	# with the riser's right face at 986.
	if (at.x < FuelLoop.POOL_LEFT - 60.0 or at.x > FuelLoop.RISER_X + 80.0
			or at.y > FuelLoop.POOL_FLOOR + 60.0 or at.y < FuelLoop.CHUTE_Y - 60.0) \
			and not _escaped.has(id):
		_escaped.append(id)
		printerr("  [escaped] #%d (%s) at (%.0f, %.0f) — outside the plant"
			% [id, _leg_name(_transit[id]), at.x, at.y])


func _leg_name(leg: int) -> String:
	return "recirc" if leg == FuelLoop.RECIRC else "discharge"


func _report() -> void:
	var max_ride := 0.0
	var sum_ride := 0.0
	for r in _rides:
		max_ride = maxf(max_ride, r)
		sum_ride += r
	var max_exit := 0.0
	for v in _riser_exit_speeds:
		max_exit = maxf(max_exit, v)
	print("\n=== riser: shared drop, opposing belts ===")
	# Proves the drive really ran on the physics clock. If this reads far higher, the force is
	# being stacked and every number below is measuring a belt that presses harder than the real
	# one (see `_physics_process`).
	print("  physics ticks %d (expect ~%d = 60 Hz x %.0f s)"
		% [_phys_ticks, int(RUN_FOR * 60.0), RUN_FOR])
	print("  fed      recirc %d   discharge %d" % [_fed[FuelLoop.RECIRC], _fed[FuelLoop.DISCHARGE]])
	print("  arrived  recirc %d   discharge %d" %
		[_arrived[FuelLoop.RECIRC], _arrived[FuelLoop.DISCHARGE]])
	print("  in flight at end %d   peak %d   waiting at the mouth %d" %
		[_transit.size(), _peak, _pending.size()])
	print("  ride: mean %.2f s  max %.2f s   riser exit speed max %.0f px/s (belt %.0f)" %
		[sum_ride / maxf(float(_rides.size()), 1.0), max_ride, max_exit, FuelLoop.BELT_RISER])

	# The leg does its job at all. Without these two every check below is vacuous — a plant that
	# moves nothing jams nothing and loses nothing.
	_check(_arrived[FuelLoop.RECIRC] > 0,
		"recirculating fuel reaches the head of the riser (%d arrived)" % _arrived[FuelLoop.RECIRC])
	_check(_climbed > 0,
		"...by CLIMBING it as real bodies — the leg is a pipe, not a polyline (%d body-frames above the duct)"
			% _climbed)
	_check(_arrived[FuelLoop.DISCHARGE] > 0,
		"spent fuel still reaches the pool out of the SHARED drop (%d arrived)"
			% _arrived[FuelLoop.DISCHARGE])

	# FAILURE 1. Both legs alternating out of one drop, driven at each other's throats.
	_check(_stuck.is_empty(),
		"nothing wedged or stood off head-on, with the legs ALTERNATING every pebble (%d stuck)"
			% _stuck.size())

	# FAILURE 2. THE gate under `main._feed_drop`'s set_continuous_cd call.
	_check(_escaped.is_empty(),
		"nothing tunnelled out of the plant at radius %.1f — the pipe is solid for the SMALLEST pebble the player can design (%d escaped)"
			% [_radius, _escaped.size()])

	# The belt is speed-limited, not force-limited. A one-step overshoot above BELT_RISER is
	# expected and fine (BELT_FORCE adds ~42 px/s in a 1/60 s step); what this forbids is the
	# unbounded acceleration a constant force gives, which is how pebbles leave the world.
	_check(max_exit < 2.0 * FuelLoop.BELT_RISER,
		"the riser belt is SPEED-limited: exits at %.0f px/s against a %.0f px/s belt"
			% [max_exit, FuelLoop.BELT_RISER])

	# The seatbelt for the 380 pin. Transiting bodies are `_out_of_core` and cannot move k
	# directly — the way this leg breaks the reactor is by holding MORE pebbles than LOOP_BUFFER
	# covers, which starves the staging queue and runs the bed short.
	_check(_peak < _loop_buffer,
		"peak in flight (%d) stays well under LOOP_BUFFER (%d) — the staging queue cannot starve"
			% [_peak, _loop_buffer])

	# Nothing is swallowed: every pebble fed is delivered, still travelling, or still waiting.
	var accounted: int = _arrived[FuelLoop.RECIRC] + _arrived[FuelLoop.DISCHARGE] \
			+ _transit.size() + _pending.size()
	var total: int = _fed[FuelLoop.RECIRC] + _fed[FuelLoop.DISCHARGE] + _pending.size()
	_check(accounted == total,
		"every pebble is accounted: delivered + in flight + waiting (%d) == fed (%d)"
			% [accounted, total])

	if not _transit.is_empty():
		print("  --- still in the pipes ---")
		for id in _transit:
			var at: Vector2 = _physics.get_position(id)
			print("    #%-4d %-9s (%6.1f, %6.1f)" % [id, _leg_name(_transit[id]), at.x, at.y])

	print("\n%s  (%d checks, %d failed)" %
		["ALL CHECKS PASSED" if _failures == 0 else "FAILURES", _checks, _failures])
	quit(1 if _failures > 0 else 0)
