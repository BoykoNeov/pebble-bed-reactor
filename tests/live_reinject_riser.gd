# tests/live_reinject_riser.gd
#
# Integration gate for PHASE 3b-iii: REINJECT gets its OWN riser, beside the pool, instead of
# gliding as a fake rider through the discharge leg backwards and the recirc riser (the state
# 3b-ii left it in).
#
#   godot --headless --script res://tests/live_reinject_riser.gd
#   godot --headless --script res://tests/live_reinject_riser.gd -- --no-ccd --radius=5
#
# WHY THIS EXISTS ALONGSIDE live_riser.gd rather than folding into it: this is a DIFFERENT
# corridor (REINJECT_X, well left of the shared drop) with no traffic the other leg produces
# and no head-on to prove — the whole reason it needed its own riser in the first place was
# that it has no lane to SHARE. What is worth measuring here is specific to this route:
#
# FAILURE 1 — TUNNELLING, same cause as the main riser's (rule 4, belt-rules-for-fuel-pipes):
# a body moves roughly its own diameter per physics step at BELT_RISER, and at RADIUS_MIN that
# is close enough to the bore wall's clearance to punch through the corner. Same fix, same gate.
#
# FAILURE 2 — THE MOUTH SPAWNS ABOVE OPEN AIR, NOT A FLOOR. Unlike the shared drop (which drops
# a body onto the duct floor) this riser has no floor under its mouth at all — REINJECT_MOUTH_Y
# is picked so the belt's upward push (2500 against ~980 of gravity) catches the pebble before
# it falls any distance, but that is a claim about ORDERING (spawn then drive, same physics
# frame) rather than geometry, and this is what tests it: a pebble that sags into POOL_FLOOR
# before the belt engages would foul the tray below rather than climb.
#
# ⚠️ SATURATION IS NOT A JAM (see live_riser.gd) — the jam check asks "did this body EVER move
# again", never "was it quick". Re-injection traffic here is deliberately much higher than a
# real player would ever produce (rare, one-at-a-time key presses); this is a stress test of
# the geometry, not a claim about real traffic volume.
extends SceneTree

const FEED_EVERY := 0.10       # far denser than a real player mashing R — stress the geometry
const RUN_FOR := 20.0
const STUCK_AFTER := 6.0
const STUCK_DIST := 2.0 * FuelLoop.PEBBLE_R

var _ccd := true
var _radius := 0.0
var _loop_buffer := 48

var _physics: PhysicsBackend
var _t := 0.0
var _next_id := 0
var _accum := 0.0
var _phys_ticks := 0
var _checks := 0
var _failures := 0

var _pending := 0                 # count waiting for the mouth (mirrors main._reinject_pending)
var _transit: Dictionary = {}     # id -> {t, at, moved_t}
var _fed := 0
var _arrived := 0
var _climbed := 0                 # body-frames seen ABOVE the pool floor — proof it climbs
var _rides: Array = []
var _stuck: Array = []
var _escaped: Array = []
var _sagged := 0.0                # max y seen for any in-flight body, vs the mouth's own y
var _peak := 0
var _exit_speeds: Array = []


func _initialize() -> void:
	var cfg = load("res://main.gd")
	_radius = cfg.RADIUS_MIN
	_loop_buffer = cfg.LOOP_BUFFER
	for a in OS.get_cmdline_user_args():
		if a == "--no-ccd":
			_ccd = false
		elif a.begins_with("--radius="):
			_radius = float(a.split("=")[1])
	randomize()

	var world := Node2D.new()
	root.add_child(world)
	_physics = GodotPhysicsBackend.new()
	_physics.setup(world)
	for seg in FuelLoop.plant_walls():
		_physics.add_static_segment(seg[0], seg[1])
	for seg in FuelLoop.pool_walls():
		_physics.add_static_segment(seg[0], seg[1])
	print("[live reinject riser] its own climb beside the pool — radius %.1f (%.1f px across vs %.1f px/step at belt speed), CCD %s"
			% [_radius, _radius * 2.0, FuelLoop.BELT_RISER / 60.0, "ON" if _ccd else "OFF"])


func _check(pass_: bool, msg: String) -> void:
	_checks += 1
	if pass_:
		print("  PASS  %s" % msg)
	else:
		_failures += 1
		printerr("  FAIL  %s" % msg)


# Physics clock, not render — see live_riser.gd's note on force accumulation for why this is
# not a stylistic choice.
func _physics_process(delta: float) -> bool:
	_phys_ticks += 1
	_t += delta
	_feed(delta)
	_step()
	if _t >= RUN_FOR:
		_report()
		return true
	return false


func _feed(delta: float) -> void:
	_accum += delta
	while _accum >= FEED_EVERY:
		_accum -= FEED_EVERY
		_pending += 1
	if _pending <= 0 or not _mouth_clear():
		return
	_pending -= 1
	var id := _next_id
	_next_id += 1
	_physics.spawn_pebble(id, FuelLoop.reinject_mouth(randf_range(-1.0, 1.0), _radius), _radius)
	# GodotPhysicsBackend.spawn_pebble defaults CCD on now — this harness exists partly to
	# prove CCD is load-bearing (FAILURE 1 above), so --no-ccd must still be able to turn
	# it back OFF rather than the new default silently making the flag a no-op.
	_physics.set_continuous_cd(id, _ccd)
	_transit[id] = {"t": _t, "at": FuelLoop.reinject_mouth(), "moved_t": _t}
	_fed += 1


func _mouth_clear() -> bool:
	var mouth := FuelLoop.reinject_mouth()
	for id in _transit:
		if _physics.get_position(id).distance_to(mouth) < FuelLoop.MOUTH_CLEAR:
			return false
	return true


func _step() -> void:
	_peak = maxi(_peak, _transit.size())
	var done: Array = []
	for id in _transit:
		var at: Vector2 = _physics.get_position(id)
		_sagged = maxf(_sagged, at.y)
		if at.y < FuelLoop.HUB_Y:
			_climbed += 1
		if FuelLoop.reinject_at_bend(at):
			done.append(id)
			continue
		_track(id, at)
		if FuelLoop.in_reinject_riser(at):
			_belt(id, Vector2.UP, FuelLoop.BELT_RISER)
	for id in done:
		_arrived += 1
		_exit_speeds.append(_physics.get_velocity(id).length())
		var w: Dictionary = _transit[id]
		_rides.append(_t - float(w["t"]))
		_transit.erase(id)
		_physics.remove_pebble(id)


func _belt(id: int, dir: Vector2, speed: float) -> void:
	if _physics.get_velocity(id).dot(dir) < speed:
		_physics.apply_force(id, dir * FuelLoop.BELT_FORCE)


func _track(id: int, at: Vector2) -> void:
	var w: Dictionary = _transit[id]
	if at.distance_to(w["at"]) > STUCK_DIST:
		w["at"] = at
		w["moved_t"] = _t
	elif _t - w["moved_t"] > STUCK_AFTER and not _stuck.has(id):
		_stuck.append(id)
		printerr("  [stuck] #%d has not moved %.0f px in %.0f s, at (%.0f, %.0f)"
			% [id, STUCK_DIST, STUCK_AFTER, at.x, at.y])
	# Outside a box drawn well clear of the reinject riser's own bore — only a tunnelled body
	# can be out here.
	if (at.x < FuelLoop.REINJECT_X - 60.0 or at.x > FuelLoop.REINJECT_X + 60.0
			or at.y > FuelLoop.POOL_FLOOR + 60.0 or at.y < FuelLoop.CHUTE_Y - 60.0) \
			and not _escaped.has(id):
		_escaped.append(id)
		printerr("  [escaped] #%d at (%.0f, %.0f) — outside the reinject riser"
			% [id, at.x, at.y])


func _report() -> void:
	var max_ride := 0.0
	var sum_ride := 0.0
	for r in _rides:
		max_ride = maxf(max_ride, r)
		sum_ride += r
	var max_exit := 0.0
	for v in _exit_speeds:
		max_exit = maxf(max_exit, v)
	print("\n=== reinject riser: its own climb beside the pool ===")
	print("  physics ticks %d (expect ~%d = 60 Hz x %.0f s)"
		% [_phys_ticks, int(RUN_FOR * 60.0), RUN_FOR])
	print("  fed %d   arrived %d   in flight at end %d   peak %d   waiting at mouth %d"
		% [_fed, _arrived, _transit.size(), _peak, _pending])
	print("  ride: mean %.2f s  max %.2f s   exit speed max %.0f px/s (belt %.0f)   max sag y %.1f (mouth %.1f)"
		% [sum_ride / maxf(float(_rides.size()), 1.0), max_ride, max_exit, FuelLoop.BELT_RISER,
			_sagged, FuelLoop.REINJECT_MOUTH_Y])

	_check(_arrived > 0, "re-injected fuel reaches the head of its own riser (%d arrived)" % _arrived)
	_check(_climbed > 0,
		"...by CLIMBING it as a real body above the duct's own height (%d body-frames)" % _climbed)
	_check(_stuck.is_empty(), "nothing wedged in the bore (%d stuck)" % _stuck.size())
	_check(_escaped.is_empty(),
		"nothing tunnelled out of the riser at radius %.1f (%d escaped)" % [_radius, _escaped.size()])
	_check(max_exit < 2.0 * FuelLoop.BELT_RISER,
		"the belt is SPEED-limited: exits at %.0f px/s against a %.0f px/s belt" % [max_exit, FuelLoop.BELT_RISER])
	# FAILURE 2. The belt must catch a spawned body before it sags meaningfully toward the
	# pool floor below the mouth — more than a couple of pebble diameters would mean the belt
	# is losing the opening race, not winning it.
	_check(_sagged < FuelLoop.REINJECT_MOUTH_Y + 4.0 * FuelLoop.PEBBLE_R,
		"the belt catches a spawned body before it sags into the pool below (max y %.1f vs mouth %.1f)"
			% [_sagged, FuelLoop.REINJECT_MOUTH_Y])
	_check(_peak < _loop_buffer,
		"peak in flight (%d) stays well under LOOP_BUFFER (%d)" % [_peak, _loop_buffer])
	var accounted: int = _arrived + _transit.size()
	_check(accounted == _fed, "every pebble is accounted: delivered + in flight (%d) == fed (%d)"
		% [accounted, _fed])

	print("\n%s  (%d checks, %d failed)" %
		["ALL CHECKS PASSED" if _failures == 0 else "FAILURES", _checks, _failures])
	quit(1 if _failures > 0 else 0)
