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

# Pipe cross-section. The runs used to be a single fat line with a bright stripe down the
# middle, which read as a LINE the pebbles slid along — the rider (r=8) covered the stripe
# and filled the band, so there was nothing to see them travel *inside*.
#
# A pipe is a bore with walls around it, so it is drawn as one: a casing band, a darker
# hollow bore inset into it, and the bore's two edges picked out. The rider then goes down
# the middle of the bore with clearance on both sides, and reads as being CONTAINED.
# BORE_W is sized off the pebble it must carry (2·PEBBLE_R + clearance both sides), so a
# pebble can never appear wider than the pipe conveying it.
const BORE_CLEARANCE := 3.0
const BORE_W := 2.0 * (PEBBLE_R + BORE_CLEARANCE)
# Wall thickness of the pipe itself, per side. 3 px was tried first and rendered as a
# hairline — the pipe read as an outlined slot rather than something with walls. 6 px is
# what makes the casing legible at this zoom; it also roughly matches the vessel's own
# 14 px shell, so the plant and the pressure vessel look like the same machine.
const PIPE_WALL := 6.0
const CASING_W := BORE_W + 2.0 * PIPE_WALL

# Plant livery — dim structural greys, so the machine frames the core without
# competing with the field heatmap it sits on top of.
const PIPE_CASING := Color(0.24, 0.27, 0.34, 1.0)  # the pipe wall
const PIPE_BORE := Color(0.05, 0.06, 0.08, 1.0)    # the hollow interior
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
##
## A leaving pebble now routes via the OUTLET MOUTH before the sorter, rather than cutting
## a straight diagonal from wherever it happened to be lying to the hub. Two reasons: it
## is what metered extraction physically means (the pebble is drawn to the outlet, then
## down the discharge pipe), and now that the vessel has a real floor and the runs are
## real pipes, the old diagonal had pebbles drifting through 14 px of steel and entering
## the pipe from its side. The detour is ~50 px ≈ 0.13 s of a ~2.3 s ride — absorbed by
## LOOP_BUFFER, which is sized ~2x the measured peak-in-flight (tests/live_fuel_loop.gd
## measures the real peak and fails if it ever reaches the buffer).
static func _path_for(kind: int, from: Vector2, spawn_x: float) -> PackedVector2Array:
	var hub := Vector2(Silo.CENTER_X, HUB_Y)
	var mouth := Vector2(Silo.CENTER_X, Silo.OUTLET_Y)
	match kind:
		DISCHARGE:
			# Out of the sorter to the left and down into the bin.
			return PackedVector2Array([from, mouth, hub, Vector2(BIN_X, HUB_Y), Vector2(BIN_X, BIN_Y)])
		FRESH:
			# Down out of the hopper, then along the shared feed chute.
			return PackedVector2Array([HOPPER, Vector2(HOPPER.x, CHUTE_Y),
					Vector2(spawn_x, CHUTE_Y), Vector2(spawn_x, Silo.spawn_y())])
		_:
			# RECIRC: down to the sorter, right, up the riser, across the chute,
			# and drop back into the bed.
			return PackedVector2Array([from, mouth, hub, Vector2(RISER_X, HUB_Y),
					Vector2(RISER_X, CHUTE_Y), Vector2(spawn_x, CHUTE_Y),
					Vector2(spawn_x, Silo.spawn_y())])


## The fixed pipework, as POLYLINES (not loose segments) so every interior vertex is a
## real elbow the draw can fit a bend to.
##
## These are the same coordinates _path_for rides along, so a rider is always centred in
## its bore by construction — the pipe cannot drift away from the path it carries.
static func _pipe_runs() -> Array:
	var hub := Vector2(Silo.CENTER_X, HUB_Y)
	return [
		# Outlet → sorter. Starts flush with the hopper's inner floor face and pierces the
		# vessel wall, so the discharge pipe is visibly socketed into the bottom of the core.
		PackedVector2Array([Vector2(Silo.CENTER_X, Silo.OUTLET_Y), hub]),
		# Sorter → riser → chute → over the bed (the recirculation leg). The chute runs all
		# the way to the hopper: recirculated fuel comes in along it from the right and fresh
		# fuel joins it from the left, so the two legs visibly MERGE onto one feed — which is
		# exactly what they do. Stopping it at the vessel wall left the hopper floating
		# unconnected with fresh pebbles gliding over a gap.
		PackedVector2Array([hub, Vector2(RISER_X, HUB_Y), Vector2(RISER_X, CHUTE_Y),
				Vector2(HOPPER.x, CHUTE_Y)]),
		# Sorter → spent bin (the discharge leg).
		PackedVector2Array([hub, Vector2(BIN_X, HUB_Y), Vector2(BIN_X, BIN_Y - 10.0)]),
		# Hopper → chute (the fresh-fuel leg).
		PackedVector2Array([Vector2(HOPPER.x, HOPPER.y), Vector2(HOPPER.x, CHUTE_Y)]),
	]


## One pass of pipe: a line of `w` along every run, plus a disc of `w/2` at every vertex.
##
## The discs are the elbow fittings, and they are what makes a bend look like pipework: two
## offset straight runs meeting at an angle leave a wedge-shaped notch on the outside of
## the corner, and a disc of the same width fills it exactly for any bend angle — no mitre
## math, and it reads as a real bend fitting rather than a patch.
func _pipe_pass(runs: Array, w: float, col: Color) -> void:
	for run in runs:
		var pts: PackedVector2Array = run
		for i in range(1, pts.size()):
			draw_line(pts[i - 1], pts[i], col, w)
		for p in pts:
			draw_circle(p, w * 0.5, col)


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


## The static plant: pipework, the sorter, the bin, the hopper. Drawn every frame with
## the riders (one Node2D, one pass) — trivial next to the bed.
func _draw_plant() -> void:
	var hub := Vector2(Silo.CENTER_X, HUB_Y)
	var runs := _pipe_runs()

	# The pipe is built from outside in: the casing wall, then the hollow bore inset into
	# it, then (below) the bore's outline. Drawing whole PASSES — every run's casing before
	# any run's bore — rather than finishing each run in turn is what makes the junctions
	# work: three pipes meet at the sorter, and a later run's casing would otherwise paint
	# over an earlier run's bore and plug it.
	_pipe_pass(runs, CASING_W, PIPE_CASING)
	_pipe_pass(runs, BORE_W, PIPE_BORE)

	# The bore's outline, as one mitred ring per run.
	#
	# WHY offset_polyline and not two offset lines per segment: drawing each segment's two
	# edges full-length to its end vertex makes them overshoot past each other at every
	# bend, stamping a small cross on the elbow. Covering it with a disc at the vertex does
	# NOT work — the overshoot lands on the INNER side of the corner, outside any disc
	# centred on the vertex. offset_polyline solves the actual problem: it terminates each
	# edge at the join, mitring the inside of the bend and rounding the outside to exactly
	# the same radius as the bore disc already drawn there.
	for run in runs:
		var pts: PackedVector2Array = run
		for outline in Geometry2D.offset_polyline(pts, BORE_W * 0.5,
				Geometry2D.JOIN_ROUND, Geometry2D.END_BUTT):
			var ring: PackedVector2Array = outline
			draw_polyline(ring + PackedVector2Array([ring[0]]), PIPE_EDGE, 1.0)

	# Where the fresh-fuel leg MEETS the chute: both runs butt-cap here, and two
	# perpendicular caps read as a cross. A merge fitting is what is physically there
	# anyway — this is the junction where hopper fuel joins recirculated fuel on the one
	# feed — so drawing it both states the mechanism and covers the seam.
	var merge := Vector2(HOPPER.x, CHUTE_Y)
	draw_circle(merge, CASING_W * 0.5, PIPE_CASING)
	draw_circle(merge, BORE_W * 0.5, PIPE_BORE)
	draw_arc(merge, CASING_W * 0.5, 0.0, TAU, 24, PIPE_EDGE, 1.0)

	# The sorter — this is the recirculate-vs-discharge DECISION made visible
	# (main._extract_lowest): a pebble under discharge burnup turns right and goes
	# back up, a spent one goes left to the bin. Drawn as a housing WRAPPING the
	# three-way junction (wider than the casing), so it reads as the valve body the
	# pipes run into rather than a bead sitting inside the bore.
	draw_circle(hub, CASING_W * 0.62, Color(0.14, 0.16, 0.21, 1.0))
	draw_arc(hub, CASING_W * 0.62, 0.0, TAU, 28, PIPE_EDGE, 1.5)
	draw_circle(hub, BORE_W * 0.5, PIPE_BORE)
	_label("SORT", hub + Vector2(-14.0, 32.0))

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
