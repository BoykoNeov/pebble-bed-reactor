# game/reactor_vessel/fuel_loop.gd
#
# The fuel-handling machine OUTSIDE the vessel: the conveyor that carries a
# discharged pebble back up to the top for another pass, the spent-fuel pool that
# a pebble settles into once it has finished its last pass, and the fresh-fuel
# hopper that feeds a replacement in.
#
# WHY it exists: through M5 every pebble moved by TELEPORT — a recirculating
# pebble vanished at the outlet and reappeared in the spawn band in the same
# frame, fresh fuel materialized at the top, and spent fuel blinked out of
# existence. The multi-pass fuel cycle (CLAUDE.md M3: ~10 passes before
# discharge, the thing that keeps reactivity flat instead of a batch sawtooth) is
# one of the behaviors this toy exists to SHOW, and it was the one part of the
# flow the player could not see. This makes the cycle visible: you can watch a
# single pebble ride up and re-enter, and watch a spent one leave for good — and,
# since the pool, watch where it ends up instead of watching it wink out.
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
const REINJECT := 3   # the player pulled one back out of the spent pool

# Machine geometry. The vessel is x ∈ [560, 900], y ∈ [120, 900]; the neutronics
# grid rect (drawn dimmed by FieldDisplay) reaches x ∈ [424, 1036], so the plant
# necessarily overlays the reflector band — that is fine, it reads as "outside the
# vessel", which is exactly what it is. The bottom key-hints bar starts at y ≈ 1026.
const HUB_Y := 955.0                  # the sorter: where recirc/discharge part ways
const RISER_X := 975.0                # the riser, in the right-hand reflector margin
const CHUTE_Y := 75.0                 # the feed chute, above the vessel top (120)
const BIN_X := 480.0                  # spent-fuel bin, left-hand margin
# The discharge pipe's MOUTH — where a spent pebble leaves the plant and falls into the
# pool. It sits just ABOVE the tray rim (POOL_FLOOR - POOL_H ≈ 968), and that clearance
# is load-bearing rather than cosmetic: the arriving pebble is a real body now, so if the
# mouth were inside the tray it would spawn INSIDE whatever is already piled there and
# the solver would fire the two apart. It used to be 986 — a third of the way down the
# tray — which was unremarkable while the pool was slots and paint.
#
# That leaves only a stub of vertical pipe below the conveyor at HUB_Y = 955, because
# there is barely 60 px between the sorter and the key-hints bar (y ≈ 1026) and the tray
# needs ~50 of it. Reads correctly anyway: the discharge conveyor runs out to the left
# and dumps into the pool directly below it, which is what a transfer pool looks like.
const BIN_Y := 958.0
const HOPPER := Vector2(480.0, 44.0)  # fresh-fuel hopper, top-left

# --- Spent-fuel pool ---
#
# The bin used to be a labelled hole: main erased the Pebble the instant a rider
# reached it, so the one thing this machine exists to show — where spent fuel ENDS
# UP — was the one thing it did not. The pool is that ending made real: discharged
# pebbles settle into it and stay, carrying their own field color, so the outflow
# can be looked at (CLAUDE.md: "see the composition of outflowing pebbles").
#
# WHY IT IS A SHALLOW TRAY AND NOT A TALL SILO, which is the obvious thing to want:
# the only tall free space is the left corridor x ∈ [414, 546] — and that corridor
# is NOT free. It is the neutronics grid's LEFT REFLECTOR BAND, and the M5d rod
# channel runs down it at x ≈ 526 from y = 120. A column there would bury the rod
# the vessel shell was deliberately kept thin enough (WALL_T = 14) to leave visible.
# So the pool takes the space that is genuinely dead: below the vessel floor, where
# the grid cells are void and no rod reaches. That is what caps it: the tray is as big
# as the dead space allows, and POOL_CAP is however many pebbles fit in it.
#
# The cap is honest rather than hidden: the pool holds the most RECENT arrivals and
# main reports the true total discharged alongside it. A pile that silently stopped
# growing would read as "discharge stopped" — the exact misreading this replaces.
# Physically it is a transfer pool being emptied to casks, which is what a real
# plant does with spent pebbles anyway.
#
# THE PEBBLES IN IT ARE REAL BODIES. They used to be tints painted into a fixed
# lattice: `pool_slot(i)` put arrival i at column i%7, row i/7, and the tray was a
# PICTURE of a pool rather than a pool. It read as a lattice because it WAS one — a
# square grid of touching disks is not something gravity ever produces (disks roll
# into the hex gaps of the row below), so the one place the player goes to inspect
# the outflow was the one place the pebbles were arranged by an array index instead
# of by physics.
#
# Now the tray has a real floor and real side walls (`pool_walls`, handed to the
# physics backend exactly like Silo's shell), a discharged pebble drops in at
# `pool_drop` and settles into the pile, and where it lands is EMERGENT. Nothing in
# this file knows where a pooled pebble is any more: main reads it off the body, the
# same way it reads the bed. That is also why `pool_slot`/`pool_index_at` are gone
# rather than kept "for reference" — a layout function that no longer describes where
# anything is is precisely the two-sources-of-truth drift this project has already
# paid for once (commit 7b0be70).
#
# Safe because a pooled pebble is flagged `_out_of_core`: the coupling reads
# `main._core_positions()`, which filters on that flag, so a body parked here is
# visible to the physics and invisible to the neutronics. The tray sits over VALID
# grid cells, so without that filter this pile would homogenize as if it were fuel in
# the core and silently shift k. That guard was built and gated ahead of this change
# (tests/live_spent_pool.gd parks a ghost body on the tray and proves the boundary
# discriminates) — this is the change it was built for.
const POOL_LEFT := 418.0
const POOL_FLOOR := 1017.0    # tray floor; pebbles pile UPWARD from here
const POOL_W := 114.8         # ~7 pebble diameters wide
const POOL_H := 49.2          # ~3 pebble diameters deep — see the corridor note above
# How many settled pebbles the tray holds. MEASURED, not counted.
#
# The old value was COLS x ROWS = 21 — the number of slots the fake lattice had, which
# was a statement about an array rather than about a tray. A real pile does not reach
# it: dropped in through one pipe, pebbles heap up under the mouth and roll outward
# rather than filling row by row, so the tray runs out of DEPTH before it runs out of
# floor. (The disks themselves are not the limit — 2D disks pack to ~0.82 random-close,
# far above the ~0.61 figure CLAUDE.md quotes for 3D spheres. The tray is ~3 diameters
# deep and fed from a single point; that is the limit.)
#
# WHY THE WORST CASE AND NOT THE TYPICAL ONE. A settled pile's capacity is genuinely
# random — the same drop sequence with different bore play gives a different pack. Over
# seven fill runs (Phase 3a) the last count with every pebble resting fully inside the rim
# was 12, 15, 15, 12, 16, 12, 16. So 12 was not a pessimistic reading of that data, it was
# the outcome in three of seven runs, and the cap has to hold in the run it gets, not on
# average.
#
# ⚠️ 12 → 8 AT PHASE 3b-i, AND THOSE SEVEN RUNS ARE WHY IT HAD TO MOVE — not evidence that
# it did not. Every one of them fed the tray through `pool_drop`: a body materialized just
# above the rim, at rest. The plant does not deliver that way any more. A spent pebble now
# rides a belt and TIPS OFF THE END of the conveyor, arriving with ~95-150 px/s of leftward
# travel and landing well left of the mouth. Same tray, different feed — so the old number
# certified a delivery nothing performs. A cap is a claim about how the pebbles ARRIVE, not
# only about the box they arrive in.
#
# RE-MEASURED AGAINST THE BELT (tests/live_discharge_belt.gd dumps every held pebble's
# resting place). The pile is NOT a tower — the feed spreads honestly: six across the floor
# at y≈1009, three at y≈996, one at y≈983. It is a heap that runs out of DEPTH before it
# runs out of floor, exactly as the paragraph above already said. TEN rest clear, the apex
# at y≈983 with its crown 9 px below the conveyor. The ELEVENTH comes to rest at y≈967.7 —
# and that is not merely "outside the tray", it is IN THE MOUTH, the x ∈ [469, 491] gap the
# pipe pours through. So capacity is ~10, and 8 takes a two-pebble margin under it because
# the pack is random and this is one fill, not seven.
#
# THE MARGIN IS WIDER THAN 3a's BECAUSE THE FAILURE IS WORSE. Overfilling used to mean one
# pebble rolled off the rim and out of the world: bad, visible, and limited to that pebble.
# Now the pile's apex plugs the pipe that FEEDS it, and the plug is self-sealing in both
# directions — nothing can arrive, so nothing is admitted, so the cap never fires, so the
# oldest is never casked, so the room that would clear the plug is never made. Measured
# before the cap moved: the tray stuck at 11 held and spent fuel backed up nose-to-tail
# along the conveyor to the sorter. A cap at or above capacity is not "a bit too full", it
# is a discharge leg that has stopped for good.
#
# The tray still has no lid and still CANNOT have taller walls — the discharge conveyor runs
# across at y = 955, so a wall reaching above the rim would stand in the pipe and stop the
# pebbles it is supposed to be catching. Gated by tests/live_discharge_belt.gd, which fills
# the tray THROUGH THE BELT and fails if any pebble the pool claims to hold is not actually
# resting in it.
const POOL_CAP := 8
const POOL_WALL := Color(0.10, 0.06, 0.06, 0.92)
const POOL_EDGE := Color(0.55, 0.35, 0.35, 0.8)

# Ride speed (px/s) for the pebbles still carried as RIDERS (recirc, fresh, reinject).
# Purely a legibility knob with ZERO physics cost: main pins the IN-CORE population
# regardless of how many pebbles are riding (see LOOP_BUFFER), so a slow, watchable ride
# does not dilute the bed or shift reactivity.
const SPEED := 380.0

# --- The discharge belt (Phase 3b-i) ---
#
# The discharge leg is no longer a ride. A pebble leaving the sorter for the pool is a
# REAL BODY from the outlet to the pile: it falls down the drop, lands on a real conveyor
# floor, is dragged along it by a belt, and tips off the end into the tray. Nothing about
# where it goes is scripted — `discharge_walls` and the belt are the only inputs, and the
# path is what the solver makes of them.
#
# WHY THIS LEG FIRST, and why it is safe: the sorter discharges only ~1 pebble in 10
# extractions, so this pipe carries ~0.15 pebbles in flight. It CANNOT congest, and a
# transiting body is flagged `_out_of_core` by main, so it is outside the flux solve for
# its whole journey. This leg therefore cannot move k no matter how the bodies behave —
# which is exactly why it goes first (the riser, at 1 per EXTRACT_INTERVAL, can).
#
# THE BELT IS A SPEED, NOT A FORCE, and that distinction is measured rather than stylistic.
# A constant force accelerates over the whole 250 px run and the pebble leaves the end at
# ~670 px/s — it sails clean over the 49 px-deep tray, clears the far wall and falls out of
# the world (3 of 10 lost, last seen at y ≈ 78000). A real belt does not do that: it drags
# what is on it up to ITS OWN speed and then stops adding energy. So the drive only pushes
# while the pebble is still slower than the belt, and the exit speed is BELT_DISCHARGE by
# construction, whatever the force.
#
# WHY THE SPEED IS THIS LOW: a belt's speed is bounded by what it empties INTO. This one
# empties into an open, lidless tray (POOL_H is ~3 pebble diameters and the discharge
# conveyor crossing at HUB_Y forbids taller walls — see the pool notes), so a fast pebble
# is a lost pebble. Low traffic means slow costs nothing here. The riser will NOT be able
# to take this speed and must not be given it (see the per-leg note in _pipe_runs).
const BELT_DISCHARGE := 95.0
# What the belt presses with. High, and high ON PURPOSE — it is a friction-vs-force
# problem, not a speed one. At 900 the belt loses to the drop/conveyor elbow: one pebble
# rests in the corner, a second stacks on top of it, and the belt is asked to overcome
# roughly two pebbles' weight of friction (~1960) and cannot. 2 of 10 wedged there
# PERMANENTLY. At 2500 the elbow clears 10 of 10 (2500/5000/9000 all clean, so this sits
# well inside the working band rather than on its edge).
#
# Raising it is safe ONLY because of the velocity cap above: more force means the pebble
# reaches belt speed sooner, never that it leaves faster. Without the cap this number is
# precisely how pebbles get thrown out of the world.
const BELT_FORCE := 2500.0

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

# What the pool's CAPTION says. Counts only: the settled pebbles are real bodies that
# draw themselves, so the tray holds no view state about them at all — it is a vessel,
# and what is in it is the physics engine's business. (It used to hold a tint per
# pebble, because it drew them.)
var _pool_held := 0      # currently in the tray
var _pool_total := 0     # every pebble ever discharged, including those since shipped
var _pool_shipped := 0   # of those, the ones the full pool sent to a cask


## The bore of the DISCHARGE leg as wall segments — the pipe made solid (Phase 3b-i).
##
## Every face here is BORE_W/2 off a centreline in `_pipe_runs`, which is the same
## centreline `_draw_plant` insets the dark bore into and the same one the old rider slid
## down. So the wall a pebble rolls on is the wall the player sees: the Silo.wall_segments
## discipline (the drawn face IS the physics face), extended to the plant. Restating the
## coordinates instead would let the pipe and its lining drift apart, and the pebble would
## roll along a surface that is not there.
##
## THE GAPS ARE THE POINT — this plant is a set of pipes that MEET, and a wall carried
## through a junction is a lid over the pipe feeding it. Two are deliberate:
##   * the top of the drop, where pebbles arrive from the outlet;
##   * the floor's left end, which IS the pool's mouth — the pebble runs out of floor and
##     falls, so the drop into the tray is an absence of pipe rather than a special case.
## The plant is entirely AXIS-ALIGNED (every run is vertical or horizontal), which is why
## this needs no mitring or offset-polyline machinery: literal segments and honest gaps.
static func discharge_walls() -> Array:
	var half := BORE_W * 0.5
	var inner := Silo.CENTER_X - half        # the drop's left face
	var outer := Silo.CENTER_X + half        # the drop's right face
	var roof := HUB_Y - half                 # the conveyor's upper face
	var floor_y := HUB_Y + half              # the conveyor's lower face — what it rolls on
	var mouth_l := BIN_X - half              # the pool mouth's far side
	var mouth_r := BIN_X + half              # where the floor stops and the pebble tips off
	return [
		# The drop, outlet → conveyor. Its LEFT face stops at the roof: below that is the
		# elbow's inside corner, and continuing it would wall the conveyor off from the
		# pipe feeding it.
		[Vector2(inner, Silo.OUTLET_Y), Vector2(inner, roof)],
		# The RIGHT face runs unbroken from the outlet all the way down to the floor,
		# because the drop's right wall and the conveyor's end cap are the same surface —
		# the outside of a 90° bend. Nothing is driving a pebble right, but a bounced one
		# would otherwise leave through the corner.
		[Vector2(outer, Silo.OUTLET_Y), Vector2(outer, floor_y)],
		# The conveyor roof, from the mouth back to the elbow's inside corner.
		[Vector2(mouth_l, roof), Vector2(inner, roof)],
		# The conveyor floor. It STOPS at the mouth's right edge — the missing span is the
		# hole the pebble falls through, and it is exactly the stub of pipe `_pipe_runs`
		# draws heading down to the tray.
		[Vector2(mouth_r, floor_y), Vector2(outer, floor_y)],
		# The mouth's far wall: a pebble is travelling left at belt speed when the floor
		# runs out, so this is what stops it carrying on past the tray.
		[Vector2(mouth_l, roof), Vector2(mouth_l, floor_y)],
	]


## Where a discharged pebble becomes a body — just inside the drop, below the hopper floor.
##
## `across` is its offset across the bore, -1 (left face) to +1 (right face); main passes a
## random one, for the same reason `pool_drop` takes one (see there).
##
## THERE IS AN HONEST SEAM HERE and it is worth naming rather than hiding. The silo is a
## CLOSED hopper — extraction is metered, the floor has no hole, and it must not get one:
## a real outlet would let the bed drain and TARGET_POPULATION is calibrated. So the pebble
## cannot physically fall out of the core; it is removed at the outlet and appears in the
## pipe it was discharged into, which is what metered discharge means. The old rider glided
## the same gap, but glided it THROUGH the hopper's steel floor and through its neighbours.
## Neither is more real than the other; this one at least ends with the pebble contained in
## pipework for the rest of its journey.
static func drop_mouth(across := 0.0, radius := PEBBLE_R) -> Vector2:
	# Kept a clear radius below the hopper floor so the new body cannot be born overlapping
	# it — a body spawned inside geometry is fired out of it by the solver.
	return Vector2(Silo.CENTER_X + across * BORE_CLEARANCE, Silo.OUTLET_Y + radius + 2.0)


## How much room the drop mouth needs before another pebble may be put into it.
##
## THE MOUTH IS A DOOR, NOT A DRAIN, and this is the constant that says so. A body spawned
## on top of another body is not a queue — it is two objects occupying one space, and the
## solver resolves that by firing them apart at whatever speed it takes. MEASURED, by
## flooding this leg with a discharge wave before the guard existed: pebbles were squeezed
## UP through the silo's own hopper floor and ended up loose in the bed at y ≈ 892 (a body
## the flux cannot see, displacing fuel it can), while others were thrown sideways out of
## the bore and fell out of the world past y = 1080. 38 wedged, 4 escaped.
##
## That is the same failure Phase 3a hit at the other end of this pipe, where the pool's
## drop had to be lifted above the tray rim (BIN_Y 986 → 958) because a body spawned inside
## the pile blew the pile apart. Same lesson, same fix: never materialize a body into space
## that is already occupied — wait for the door.
##
## A bore's width of clearance, so the pebble already in the mouth has fully left it before
## the next one appears. Sized off BORE_W rather than PEBBLE_R because radius is a player
## design lever and the pebble in the way may be a big one.
const MOUTH_CLEAR := BORE_W + 2.0


## Is this body on the discharge conveyor, i.e. should the belt be dragging it?
##
## The zone is the conveyor's own bore, and it ENDS at the mouth: past that the pebble has
## left the floor and is falling into the tray, where a belt has nothing to push against
## and pushing anyway would throw it at the far wall. So the belt lets go exactly where the
## floor does.
static func on_discharge_belt(at: Vector2) -> bool:
	var half := BORE_W * 0.5
	return at.y > HUB_Y - half and at.y < HUB_Y + half + PEBBLE_R \
			and at.x > BIN_X + half and at.x < Silo.CENTER_X + half


## Has a falling pebble reached the tray? Inside it in BOTH axes, deliberately.
##
## A y-line alone ("below the conveyor") is the trap: the pipe walls are what put the
## pebble over the tray, so if a wall were ever missing the pebble would free-fall straight
## past the same line and be reported as safely arrived. A pipe with no walls passes a
## y-line arrival check beautifully — that is not a hypothetical, it is how the spike for
## this work first FALSELY passed 10/10. Requiring x as well means "arrived" can only be
## satisfied by geometry that actually exists.
static func pool_contains(at: Vector2) -> bool:
	return at.x >= POOL_LEFT and at.x <= POOL_LEFT + POOL_W and at.y >= POOL_FLOOR - POOL_H


## The tray as wall segments for the physics backend: floor, left wall, right wall.
## Open at the top — that is where pebbles drop in from the discharge pipe.
##
## Traced from the SAME constants the tray is drawn from, so the wall a pebble rests
## on is the wall the player sees (the Silo.wall_segments discipline: the drawn face
## IS the physics face, and the two cannot drift apart).
##
## No lid, and none is wanted. A pebble enters over the rim — off the end of the discharge
## conveyor since Phase 3b-i — and the CAP is what keeps the pile below it. If a pebble ever
## comes to rest on top of the rim, that means POOL_CAP is too high for the tray, which is a
## thing to find out and not to hide behind a lid. It is also, now, a thing that BITES
## rather than merely looks wrong: the rim is directly under the pipe's mouth, so a pile
## that reaches it plugs its own feed for good (see POOL_CAP). A lid would convert a visible
## overfill into a silent deadlock.
static func pool_walls() -> Array:
	var right := POOL_LEFT + POOL_W
	var top := POOL_FLOOR - POOL_H
	return [
		[Vector2(POOL_LEFT, POOL_FLOOR), Vector2(right, POOL_FLOOR)],   # floor
		[Vector2(POOL_LEFT, POOL_FLOOR), Vector2(POOL_LEFT, top)],      # left wall
		[Vector2(right, POOL_FLOOR), Vector2(right, top)],              # right wall
	]


## Materialize a pebble in the pipe's mouth, ready to fall into the tray.
##
## THE PLANT NO LONGER USES THIS (Phase 3b-i). A discharged pebble arrives here on a belt,
## as a body, under its own momentum — nothing needs placing, which is the whole point of
## the leg being real. What is left is the harnesses that need a full tray in seconds rather
## than the ~2 minutes the sorter takes to discharge one (tests/live_spent_pool.gd,
## live_render_pool.gd): they stage pebbles straight into the mouth through `_pool_push`.
##
## It is kept rather than deleted because it still describes something TRUE — this really is
## where the pipe pours, the x ∈ [BIN_X ± BORE_W/2] gap in the conveyor floor — so it is not
## the kind of stale layout function `pool_slot` became (a claim about where pebbles are
## that had stopped being the case). But note what it CANNOT certify any more: a tray filled
## through here is filled by pebbles dropped at rest, and the belt delivers them moving. The
## cap is measured against the BELT (see POOL_CAP), never against this.
##
## `across` is where the pebble sits ACROSS the bore, -1 (left wall) to +1 (right wall).
## A pebble does not leave a pipe dead-centre — BORE_CLEARANCE of play is exactly what
## the bore is built with — so the caller passes a random one and the pile gets a
## realistically ragged feed.
##
## THIS IS NOT DECORATION, it is what makes the pile a pile. Dropped at a fixed x, every
## pebble lands on the precise centre of the disc below it, and a contact that symmetric
## has no tangential component to roll it off: the solver balances them into a single
## perfectly-stacked COLUMN and holds it there. Measured, before this argument existed:
## 26 pebbles standing in a 26-high tower out of the top of a 3-deep tray. Real granular
## flow is disordered because real arrivals are, and the bore's own play is the honest
## source of that disorder — it is a physical fact of the pipe, not a nudge added to make
## the picture nicer.
static func pool_drop(across := 0.0) -> Vector2:
	return Vector2(BIN_X + across * BORE_CLEARANCE, BIN_Y)


## Tell the tray how many pebbles it is holding, how many have EVER been discharged,
## and how many of those have since gone to a cask. Counts only — the pebbles
## themselves are bodies now and draw themselves, so the tray no longer renders them
## and no longer needs their colors. What is left is the caption, which is the part
## that keeps a capped tray honest.
func set_pool(held: int, total: int, shipped: int) -> void:
	_pool_held = held
	_pool_total = total
	_pool_shipped = shipped
	queue_redraw()


## How many pebbles the pool can actually show — main trims to this and reports
## the remainder as a count rather than dropping it silently.
static func pool_capacity() -> int:
	return POOL_CAP


## Push a pebble onto the machine. `from` is where it physically left the bed (or
## the hopper mouth for FRESH); `spawn_x` is the x it will re-enter the bed at, so
## the ride ENDS exactly where the body will appear — no jump at the hand-off.
##
## `radius` is the RIDER'S OWN size, not the nominal: once size is a design lever the
## machine carries a mix, and drawing every rider at PEBBLE_R would show a uniform
## stream while the bed fills with pebbles of another size — the transport pipe would
## be the one place the player's edit is invisible. It also sets the pick radius, so
## clicking a big pebble on the conveyor hits where it actually LOOKS.
## Defaults to PEBBLE_R so a caller that has no opinion gets today's behaviour exactly.
func add(id: int, kind: int, from: Vector2, spawn_x: float, tint: Color,
		radius: float = PEBBLE_R) -> void:
	var pts := _path_for(kind, from, spawn_x)
	_riders.append({
		"id": id, "kind": kind, "pts": pts, "d": 0.0,
		"len": _length_of(pts), "x": spawn_x, "tint": tint, "r": radius,
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


## The id of the rider under `at`, or -1 if none.
##
## Deliberately routed through the SAME _point_at the renderer uses: a rider's
## position is not stored anywhere, it is derived from its arc-length each frame, so
## a hit-test with its own idea of where riders are would drift from what is drawn
## and the player would click a pebble and select its neighbour.
func rider_at(at: Vector2) -> int:
	for r in _riders:
		if _point_at(r["pts"], r["d"]).distance_to(at) <= float(r["r"]):
			return r["id"]
	return -1


## Where a rider currently is, or Vector2.INF if it is not on the machine.
func rider_position(id: int) -> Vector2:
	for r in _riders:
		if r["id"] == id:
			return _point_at(r["pts"], r["d"])
	return Vector2.INF


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
		# There is no DISCHARGE case, and its absence is deliberate rather than an
		# oversight. Phase 3b-i put spent fuel on a BELT: it is a real body rolling down a
		# real pipe, so the route it takes is the solver's answer and no longer a polyline
		# anybody can state. Keeping the old branch "for reference" would leave a function
		# claiming to know where discharged pebbles go while they demonstrably went
		# wherever the physics put them — the same two-sources-of-truth drift that made
		# `pool_slot` a liability once the pile became real (commit 7b0be70).
		FRESH:
			# Down out of the hopper, then along the shared feed chute.
			return PackedVector2Array([HOPPER, Vector2(HOPPER.x, CHUTE_Y),
					Vector2(spawn_x, CHUTE_Y), Vector2(spawn_x, Silo.spawn_y())])
		REINJECT:
			# Out of the pool and back into the bed: up the DISCHARGE leg run backwards,
			# through the sorter, then onto the RECIRC riser. Every segment is pipework
			# already drawn by `_pipe_runs` — a re-injected pebble needs no route of its
			# own because the plant already has one, it just runs it the other way. That
			# also means no teleport: the player watches the pebble they edited climb out
			# of the pool and re-enter the core along the same pipes everything else uses.
			return PackedVector2Array([from, Vector2(BIN_X, BIN_Y), Vector2(BIN_X, HUB_Y), hub,
					Vector2(RISER_X, HUB_Y), Vector2(RISER_X, CHUTE_Y),
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
		# Sorter → spent pool (the discharge leg), ending at the mouth it pours from.
		# No fudge factor between the pipe's end and the ride's end any more: they are the
		# same point, so the pebble becomes a body exactly where it was last drawn.
		PackedVector2Array([hub, Vector2(BIN_X, HUB_Y), Vector2(BIN_X, BIN_Y)]),
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
		var rr: float = r["r"]
		draw_circle(p, rr, r["tint"])
		draw_arc(p, rr, 0.0, TAU, 12, Color(0, 0, 0, 0.35), 1.0)


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

	# Spent-fuel pool — where the discharge leg actually ends. Just the vessel: the
	# pebbles in it are bodies and paint themselves on top of this, in whatever color
	# the selected field gives them. A spent pebble arrives carrying what the field
	# says about it (burnup, xenon, temperature) and keeps saying it while it sits.
	#
	# Drawn as walls rather than a filled box, because it now HAS walls — these three
	# faces are the ones `pool_walls` hands the physics engine, so the pile is resting
	# on what it appears to be resting on.
	var right := POOL_LEFT + POOL_W
	var top := POOL_FLOOR - POOL_H
	draw_rect(Rect2(POOL_LEFT, top, POOL_W, POOL_H), POOL_WALL)
	var rim := PackedVector2Array([
		Vector2(POOL_LEFT, top), Vector2(POOL_LEFT, POOL_FLOOR),
		Vector2(right, POOL_FLOOR), Vector2(right, top)])
	draw_polyline(rim, POOL_EDGE, 1.5)
	# Name the pool and state the true total, so a full tray cannot be misread as a
	# stalled one. The count is the honest part of a capped view: the tray stops growing
	# at POOL_CAP, and without the shipped count on screen that would read as "the
	# discharge leg died" rather than "the pool is full and casking the oldest".
	var caption := "SPENT %d" % _pool_total
	if _pool_shipped > 0:
		caption += "  (%d held, %d to cask)" % [_pool_held, _pool_shipped]
	_label(caption, Vector2(POOL_LEFT + 2.0, POOL_FLOOR - POOL_H - 6.0))

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
