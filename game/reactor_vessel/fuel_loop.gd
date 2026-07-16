# game/reactor_vessel/fuel_loop.gd
#
# The fuel-handling machine OUTSIDE the vessel: the conveyor that carries a
# discharged pebble back up to the top for another pass, the spent-fuel bin that
# swallows a pebble that has finished its last pass, and the fresh-fuel hopper
# that feeds a replacement in.
#
# WHY it exists: through M5 every pebble moved by TELEPORT — a recirculating
# pebble vanished at the outlet and reappeared in the spawn band in the same
# frame, fresh fuel materialized at the top, and spent fuel blinked out of
# existence. The multi-pass fuel cycle (CLAUDE.md M3: ~10 passes before
# discharge, the thing that keeps reactivity flat instead of a batch sawtooth) is
# one of the behaviors this toy exists to SHOW, and it was the one part of the
# flow the player could not see. This makes the cycle visible: you can watch a
# single pebble ride up and re-enter, and watch a spent one leave for good.
#
# This is PRESENTATION + bookkeeping, NOT physics. A rider has no body, so it is
# absent from `positions()` and therefore never homogenized — it is out of the
# flux by construction, and main freezes its state while it rides (a pebble in the
# transport pipe neither fissions nor burns). Geometry is pure data like Silo;
# main.gd remains the sole owner of every Pebble.
class_name FuelLoop
extends Node2D

# Rider kinds. Plain int consts, NOT a nested enum: cross-file nested enum access
# is unreliable in GDScript (see the project memory / M3 notes).
const RECIRC := 0     # below discharge burnup → back to the top for another pass
const DISCHARGE := 1  # spent → out to the bin, gone for good
const FRESH := 2      # a replacement for a discharged pebble, in from the hopper

# Machine geometry. The vessel is x ∈ [560, 900], y ∈ [120, 900]; the neutronics
# grid rect (drawn dimmed by FieldDisplay) reaches x ∈ [424, 1036], so the plant
# necessarily overlays the reflector band — that is fine, it reads as "outside the
# vessel", which is exactly what it is. The bottom key-hints bar starts at y ≈ 1026.
const HUB_Y := 955.0                  # the sorter: where recirc/discharge part ways
const RISER_X := 975.0                # the riser, in the right-hand reflector margin
const CHUTE_Y := 75.0                 # the feed chute, above the vessel top (120)
const BIN_X := 480.0                  # spent-fuel bin, left-hand margin
const BIN_Y := 986.0                  # clear of the key-hints bar at y ≈ 1026
const HOPPER := Vector2(480.0, 44.0)  # fresh-fuel hopper, top-left

# Ride speed (px/s). Purely a legibility knob with ZERO physics cost: main pins the
# IN-CORE population regardless of how many pebbles are riding (see LOOP_BUFFER),
# so a slow, watchable ride does not dilute the bed or shift reactivity.
const SPEED := 380.0

const PEBBLE_R := 8.0

# Plant livery — dim structural greys, so the machine frames the core without
# competing with the field heatmap it sits on top of.
const PIPE_DARK := Color(0.07, 0.08, 0.11, 0.95)
const PIPE_EDGE := Color(0.42, 0.47, 0.57, 0.85)
const GRAPHITE := Color(0.62, 0.64, 0.68)

# Riders in flight. Each: id, kind, pts (polyline), d (distance travelled),
# len (total), x (the spawn-band x it is bound for), tint.
var _riders: Array = []


## Push a pebble onto the machine. `from` is where it physically left the bed (or
## the hopper mouth for FRESH); `spawn_x` is the x it will re-enter the bed at, so
## the ride ENDS exactly where the body will appear — no jump at the hand-off.
func add(id: int, kind: int, from: Vector2, spawn_x: float, tint: Color) -> void:
	var pts := _path_for(kind, from, spawn_x)
	_riders.append({
		"id": id, "kind": kind, "pts": pts, "d": 0.0,
		"len": _length_of(pts), "x": spawn_x, "tint": tint,
	})


## Advance every rider on the RENDER/physics clock and return those that reached
## the end: [{id, kind, x}, ...]. Main decides what an arrival means (a RECIRC or
## FRESH arrival joins the staging queue; a DISCHARGE arrival leaves the inventory).
func advance(delta: float) -> Array:
	var arrived: Array = []
	var still: Array = []
	for r in _riders:
		r["d"] += SPEED * delta
		if r["d"] >= r["len"]:
			arrived.append({"id": r["id"], "kind": r["kind"], "x": r["x"]})
		else:
			still.append(r)
	_riders = still
	return arrived


## Recolor one rider for the per-pebble field heatmap — the Lagrangian view should
## not stop at the vessel wall: a hot or heavily-burned pebble stays legible while
## it rides. No-op if the id is not on the machine.
func set_rider_tint(id: int, tint: Color) -> void:
	for r in _riders:
		if r["id"] == id:
			r["tint"] = tint
			return


func count() -> int:
	return _riders.size()


# Riders move every frame, so the machine repaints on the RENDER clock. Like the
# rest of visualization it is a pure consumer — it may lag the sim harmlessly.
func _process(_delta: float) -> void:
	queue_redraw()


## Polyline for a ride. Kept to a handful of segments on purpose — this is a
## conveyor, not a spline system.
static func _path_for(kind: int, from: Vector2, spawn_x: float) -> PackedVector2Array:
	var hub := Vector2(Silo.CENTER_X, HUB_Y)
	match kind:
		DISCHARGE:
			# Out of the sorter to the left and down into the bin.
			return PackedVector2Array([from, hub, Vector2(BIN_X, HUB_Y), Vector2(BIN_X, BIN_Y)])
		FRESH:
			# Down out of the hopper, then along the shared feed chute.
			return PackedVector2Array([HOPPER, Vector2(HOPPER.x, CHUTE_Y),
					Vector2(spawn_x, CHUTE_Y), Vector2(spawn_x, Silo.spawn_y())])
		_:
			# RECIRC: down to the sorter, right, up the riser, across the chute,
			# and drop back into the bed.
			return PackedVector2Array([from, hub, Vector2(RISER_X, HUB_Y),
					Vector2(RISER_X, CHUTE_Y), Vector2(spawn_x, CHUTE_Y),
					Vector2(spawn_x, Silo.spawn_y())])


static func _length_of(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
	return maxf(total, 0.001)


## Position at arc-length d along the polyline.
static func _point_at(pts: PackedVector2Array, d: float) -> Vector2:
	var left := d
	for i in range(1, pts.size()):
		var seg := pts[i].distance_to(pts[i - 1])
		if left <= seg:
			return pts[i - 1].lerp(pts[i], left / maxf(seg, 0.001))
		left -= seg
	return pts[pts.size() - 1]


func _draw() -> void:
	_draw_plant()
	# Riders on top of their pipework.
	for r in _riders:
		var p: Vector2 = _point_at(r["pts"], r["d"])
		draw_circle(p, PEBBLE_R, r["tint"])
		draw_arc(p, PEBBLE_R, 0.0, TAU, 12, Color(0, 0, 0, 0.35), 1.0)


## The static plant: conveyor runs, the sorter, the bin, the hopper. Drawn every
## frame with the riders (one Node2D, one pass) — trivial next to the bed.
func _draw_plant() -> void:
	var hub := Vector2(Silo.CENTER_X, HUB_Y)
	var runs := [
		# outlet → sorter
		[Vector2(Silo.CENTER_X, Silo.OUTLET_Y), hub],
		# sorter → riser → chute → over the bed (the recirculation leg). The chute runs
		# all the way to the hopper: recirculated fuel comes in along it from the right
		# and fresh fuel joins it from the left, so the two legs visibly MERGE onto one
		# feed — which is exactly what they do. Stopping it at the vessel wall left the
		# hopper floating unconnected with fresh pebbles gliding over a gap.
		[hub, Vector2(RISER_X, HUB_Y)],
		[Vector2(RISER_X, HUB_Y), Vector2(RISER_X, CHUTE_Y)],
		[Vector2(RISER_X, CHUTE_Y), Vector2(HOPPER.x, CHUTE_Y)],
		# sorter → spent bin (the discharge leg)
		[hub, Vector2(BIN_X, HUB_Y)],
		[Vector2(BIN_X, HUB_Y), Vector2(BIN_X, BIN_Y - 10.0)],
		# hopper → chute (the fresh-fuel leg)
		[Vector2(HOPPER.x, HOPPER.y), Vector2(HOPPER.x, CHUTE_Y)],
	]
	for seg in runs:
		draw_line(seg[0], seg[1], PIPE_DARK, 18.0)
		draw_line(seg[0], seg[1], PIPE_EDGE, 1.5)

	# The sorter — this is the recirculate-vs-discharge DECISION made visible
	# (main._extract_lowest): a pebble under discharge burnup turns right and goes
	# back up, a spent one goes left to the bin.
	draw_circle(hub, 13.0, Color(0.12, 0.14, 0.19, 0.95))
	draw_arc(hub, 13.0, 0.0, TAU, 24, PIPE_EDGE, 1.5)
	_label("SORT", hub + Vector2(-14.0, 30.0))

	# Spent-fuel bin.
	var bin := Rect2(BIN_X - 34.0, BIN_Y - 10.0, 68.0, 34.0)
	draw_rect(bin, Color(0.10, 0.06, 0.06, 0.92))
	draw_rect(bin, Color(0.55, 0.35, 0.35, 0.8), false, 1.5)
	_label("SPENT", Vector2(BIN_X - 20.0, BIN_Y - 18.0))

	# Fresh-fuel hopper — drawn as a funnel feeding the chute.
	var hop := PackedVector2Array([
		Vector2(HOPPER.x - 30.0, HOPPER.y - 26.0), Vector2(HOPPER.x + 30.0, HOPPER.y - 26.0),
		Vector2(HOPPER.x + 9.0, HOPPER.y + 8.0), Vector2(HOPPER.x - 9.0, HOPPER.y + 8.0),
	])
	draw_colored_polygon(hop, Color(0.07, 0.11, 0.09, 0.92))
	draw_polyline(hop + PackedVector2Array([hop[0]]), Color(0.4, 0.6, 0.48, 0.8), 1.5)
	_label("FRESH", Vector2(HOPPER.x - 20.0, HOPPER.y - 32.0))


func _label(text: String, at: Vector2) -> void:
	draw_string(ThemeDB.fallback_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			Color(0.62, 0.68, 0.78, 0.9))
