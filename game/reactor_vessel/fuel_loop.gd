# game/reactor_vessel/fuel_loop.gd
#
# The fuel-handling machine OUTSIDE the vessel: the conveyor that carries a
# discharged pebble back up to the top for another pass, the spent-fuel pool that
# a pebble settles into once it has finished its last pass, and the shared INLET
# that every pebble bound for the bed — fresh, recirculated, or re-injected —
# falls through.
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
# EVERY LEG IS NOW REAL PHYSICS (superseding the "riders are presentation, not
# physics" design this file used through Phase 3b). RECIRC/FRESH/REINJECT used
# to finish their trip as a drawn dot gliding along a polyline with no collision
# body — deliberately, because the ride ended at each pebble's own spawn_x (a
# hole that moves, which a real pipe cannot be built around) and because bed
# admission was hard-pinned to a calibrated count a real jam would have put at
# the solver's mercy. Both reasons are gone: admission now enters through ONE
# FIXED point (`INLET_X`, not a moving spawn_x), and the bed count is a player
# setpoint rather than a pin, so a real jam at the inlet is an honest, wanted
# consequence (overfilling) rather than a hazard to design around. So a pebble
# is a real, colliding body from the instant it is minted or leaves the pool
# until it settles in the bed — full stop, nothing in the plant is a rider any
# more. A body waiting for room simply piles up against the inlet's closed
# floor, exactly as spent fuel already piles up in the pool tray below.
#
# Geometry is pure data like Silo; main.gd remains the sole owner of every
# Pebble and of every body (this file never spawns or removes one).
class_name FuelLoop
extends Node2D

# Leg/kind tags. Plain int consts, NOT a nested enum: cross-file nested enum
# access is unreliable in GDScript (see the project memory / M3 notes).
const RECIRC := 0     # below discharge burnup → back to the top for another pass
const DISCHARGE := 1  # spent → out to the bin, gone for good
const REINJECT := 3   # the player pulled one back out of the spent pool
# FRESH no longer needs a leg tag: a freshly minted pebble is never on a belt
# (it is dropped straight into the inlet, see `inlet_top`), so it never occupies
# `_transit` and nothing ever asks "which leg is this" about it. Kept as a
# comment rather than a dead constant — do not resurrect it as a `_transit` tag.

# Machine geometry. The vessel is x ∈ [560, 900], y ∈ [120, 900]; the neutronics
# grid rect (drawn dimmed by FieldDisplay) reaches x ∈ [424, 1036], so the plant
# necessarily overlays the reflector band — that is fine, it reads as "outside the
# vessel", which is exactly what it is. The bottom key-hints bar starts at y ≈ 1026.
const HUB_Y := 955.0                  # the sorter: where recirc/discharge part ways
const RISER_X := 975.0                # the riser, in the right-hand reflector margin
# The height at which a climbing RECIRC/REINJECT riser bends over into a horizontal run
# toward the shared inlet (Phase 3c). Kept above the vessel top (120) for the same reason
# it always was: the plant lives outside the vessel, and this is where the vertical climb
# ends and the merge toward `INLET_X` begins. Formerly the line a presentation-only
# "rider" glided along; now the height a real, driven body is pushed along (see
# `in_recirc_merge` / `in_reinject_merge` and `main._drive`).
const CHUTE_Y := 75.0
const BIN_X := 480.0                  # spent-fuel bin, left-hand margin

# The centreline of the single fixed PIPE every pebble bound for the bed falls through
# (Phase 3c) — fresh, recirculated, or re-injected alike. Centred on the vessel for the same
# reason the reference schematic draws one fuel pipe down the middle: ONE pipe reads as a
# source, where the old per-pebble `Silo.spawn_x` scatter read as pebbles materializing out
# of thin air across the whole top. It carries multiple LANES side by side (`INLET_LANES`)
# rather than a single file, but they share one casing and one centreline — individual
# pebbles still land in different spots in the bed, and that is purely the physics of
# falling and piling onto whatever is already there, never a pre-chosen x.
const INLET_X := Silo.CENTER_X
# Top of the visible inlet pipe — where a freshly minted pebble is dropped in. Well above
# CHUTE_Y so a fresh pebble free-falls a visible stretch before joining the recirc/reinject
# traffic at the merge junction, the same way the old hopper's spout gave FRESH its own
# short drop before the chute.
const INLET_TOP_Y := 20.0
# The inlet's CLOSED floor, just above the vessel's open top (120) — this vessel has no
# lid (`Silo.wall_segments`), so without a floor here a pebble dropped into the inlet
# would fall straight into the bed with no admission control at all. Mirrors the vessel's
# own closed hopper floor at the OUTLET (`Silo`'s doc comment): a real plant meters fuel
# in exactly as it meters fuel out, and a queue that cannot be seen is not a queue — see
# `main._admit_batch`. Pebbles waiting for room pile up on this floor as REAL, colliding
# bodies, in full view, rather than vanishing into a data structure.
const INLET_FLOOR_Y := Silo.TOP - 4.0
# How many pebble-wide LANES run side by side down the inlet bore (Phase 3c widening).
#
# WHY MORE THAN ONE: a single-file bore's real throughput is capped by how fast ONE column
# clears — gravity-limited at ~4.5 pebbles/s regardless of the player's fill-rate lever, which
# left most of that lever's range dead (measured: `_fill_rate` up to 100/s, real fill still
# ~4.3/s). Surfaced to the player as an explicit choice against narrowing the lever to match;
# they chose widening the pipe instead. Each lane is independently gated exactly like the
# original single lane was (see `main._feed_inlet_top`/`_admit_batch`), so throughput scales
# with lane count without changing the per-lane physics that was already proven safe.
#
# WHY STILL "ONE PIPE" AND NOT A REGRESSION to the old open-top scatter this phase replaced:
# three lanes sit inside ONE casing (`INLET_BORE_W`/`INLET_CASING_W`), a fixed width the whole
# vessel is built around — visually and physically one source, just a wider one, not N
# independent entry points scattered across the top the way `Silo.spawn_x` used to be.
const INLET_LANES := 3
# The bore's CONTAINMENT width — deliberately NOT `INLET_LANES * BORE_W` any more (that was
# 66px). See [[reinject-inlet-bore-overflow]] in project memory for the full story: under
# real sustained operation the pile waiting at the inlet (bounded by `main.LOOP_BUFFER=48`)
# measured 33-35 bodies deep, more than double what a 66px-wide bore can hold, and once it
# saturated the excess had nowhere to go but sideways — spilling out through the open-air
# gap above `merge_floor` (see `inlet_walls`) and physically jamming both merge runs, most
# visibly stranding a re-injected pebble ~160px short of the bore.
#
# WIDENED, not deepened or re-walled: the fully-contained floor band (`merge_floor` to
# `INLET_FLOOR_Y`, only 30px tall) can't be made much taller without eating into the bed
# itself, and extending the SIDE walls up past `merge_floor` was tried in reasoning and
# rejected — a body arriving off either merge run is *itself* still elevated above
# `merge_floor` in the ordinary case (measured y≈56 on delivery, not the y≈75 corridor
# centreline), so a full-height wall at the bore's own edge would trap ordinary arrivals,
# not just the overflow — the exact failure the "open air above merge_floor" comment below
# already documents from the FIRST time this was tried. Widening sideways instead multiplies
# the contained floor area directly and, as a free side effect, shrinks the merge-roof
# "shelf" on both sides (`inlet_walls`' recirc/reinject roof segments run from the riser's
# near edge to `inlet_l`/`inlet_r` — moving those out means less shelf for a spill to reach).
# 240px clears the vessel's own side walls (Silo.LEFT/RIGHT = 560/900) with ~50px margin on
# each side, and clears both risers (REINJECT_X=380, RISER_X=975) with well over 100px to
# spare — nowhere near either corridor's own geometry.
const INLET_BORE_W := 240.0
const INLET_CASING_W := INLET_BORE_W + 2.0 * PIPE_WALL
# REINJECT's own riser (Phase 3b-iii). A belt runs ONE way, and re-injection is the discharge
# leg backwards, so it needs a route the discharge leg is not already using. Both routes the
# earlier notes here considered — tunnelling under the shared duct, or merging into the main
# riser from underneath — have to breach the duct floor that recirculating fuel is dragged
# along. This one does not: it climbs from beside the pool, in the dead corridor LEFT of the
# duct's own mouth wall (`mouth_l` in `plant_walls`, at BIN_X - half), which nothing else in
# the plant ever occupies. Placed 380 rather than nearer the pool for casing clearance from the
# pool's own left wall (POOL_LEFT), and far enough from the M5d rod channel (~526) that the two
# never compete on screen — surfaced to and confirmed by the user before building, since the
# pool's shallow-tray design deliberately kept this corridor clear for the rod visual.
const REINJECT_X := 380.0
const REINJECT_MOUTH_Y := 995.0       # roughly the pool's mid-height — departs beside the
                                       # tray, not from inside it
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

# --- The belts (Phase 3b, extended to the inlet at 3c) ---
#
# NEITHER leg out of the sorter is a ride any more. An extracted pebble is a REAL BODY from
# the moment it enters the drop: it falls to the duct, and then a belt drags it either LEFT to
# the pool and off the end into the tray (if it is spent) or RIGHT and 880 px UP the riser (if
# it is going back around). Nothing about where it goes is scripted — `plant_walls` and the
# belts are the only inputs, and the path is what the solver makes of them.
#
# THE DISCHARGE LEG WENT FIRST, deliberately, and 3b-i's reasoning is worth keeping because it
# is what made the order safe: the sorter discharges only ~1 pebble in 10 extractions, so that
# pipe carries ~0.15 pebbles in flight and CANNOT congest. The riser is the opposite — it takes
# EVERY extraction, 1 per EXTRACT_INTERVAL — which is exactly why it went second and why it
# needed measuring rather than assuming.
#
# What makes both legs free, whatever the bodies do: a transiting pebble is flagged
# `_out_of_core` by main, so it is outside the flux solve for its whole journey. The pipes
# cross valid grid cells and cost nothing. The one thing physics must NOT be handed is
# admission to the BED — that stays gated by `main._admit_batch` against the player's
# population setpoint and fill rate (Phase 3c superseded the old hard TARGET_POPULATION
# pin), because a count set by solver timing alone is a count that wanders.
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
# is a lost pebble. Low traffic means slow costs nothing here — and the riser, which empties
# somewhere quite different, gets its own speed rather than this one (see BELT_RISER).
const BELT_DISCHARGE := 95.0
# The RECIRCULATION belt: the duct run out to the riser, and the climb itself (Phase 3b-ii).
#
# FOUR TIMES the discharge belt, and the two numbers are not a matter of taste — each leg's
# speed is set by the thing at the far end of it, which is why one constant could never have
# covered both. The discharge belt tips into an open tray, so it must be slow. This one ends
# by bending over into the horizontal merge run toward the shared inlet (`CHUTE_Y`), not an
# open exit a pebble could overshoot, so the escape hazard that pins BELT_DISCHARGE at 95
# simply does not exist here.
#
# It is not free speed for its own sake. This leg carries EVERY extraction (1 per
# EXTRACT_INTERVAL = 0.3 s), where the discharge leg carries roughly 1 in 10 of them, so it
# is the only pipe in the plant that can genuinely congest. At 95 px/s the 880 px riser takes
# ~9 s and would hold ~28 pebbles nose-to-tail; at 380 it takes ~2.3 s and holds ~8. That
# matters beyond looking better, because a pebble in the pipe is a pebble not in the bed:
# LOOP_BUFFER is what absorbs the ones in flight against the player's population setpoint,
# and a slow riser would eat it and starve the inlet — the bed would run short and shift k
# with nothing on screen to say so.
#
# MEASURED, not reasoned: a velocity-capped belt at 380 carries the riser fed at the real
# extraction rate with 132 of 132 arriving, nothing stuck, a 3.0 s mean ride and a PEAK OF 11
# IN FLIGHT against LOOP_BUFFER's 48. (The pre-3b fake riders used this same 380 and peaked
# near 30 — real bodies are BETTER, because a rider glides the whole path while a body cuts
# the corners.) The fear that this leg would need ~50 in flight came from assuming the
# discharge belt's 95; it does not survive contact with the measurement.
const BELT_RISER := 380.0
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

# Pipe cross-section. Every leg is a real body now, so the pipe has to look like something
# a pebble travels INSIDE rather than a line it slides along: a casing band, a darker
# hollow bore inset into it, and the bore's two edges picked out. A pebble goes down the
# middle of the bore with clearance on both sides, and reads as being CONTAINED. BORE_W is
# sized off the pebble it must carry (2·PEBBLE_R + clearance both sides), so a pebble can
# never appear wider than the pipe conveying it — including the inlet, which reuses this
# same bore rather than a separate thinner one (Phase 3c retired the old FRESH-only line
# and its FRESH_BORE_W once FRESH stopped needing a lane of its own to avoid colliding
# with RECIRC/REINJECT — real collision handles that now, at the merge itself).
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

# What the pool's CAPTION says. Counts only: the settled pebbles are real bodies that
# draw themselves, so the tray holds no view state about them at all — it is a vessel,
# and what is in it is the physics engine's business. (It used to hold a tint per
# pebble, because it drew them.)
var _pool_held := 0      # currently in the tray
var _pool_total := 0     # every pebble ever discharged, including those since shipped
var _pool_shipped := 0   # of those, the ones the full pool sent to a cask


## The whole transport plant below the vessel as wall segments — the pipes made solid.
##
## Every face here is BORE_W/2 off a centreline in `_pipe_runs`, which is the same
## centreline `_draw_plant` insets the dark bore into and the same one a rider slides
## down. So the wall a pebble rolls on is the wall the player sees: the Silo.wall_segments
## discipline (the drawn face IS the physics face), extended to the plant. Restating the
## coordinates instead would let the pipe and its lining drift apart, and the pebble would
## roll along a surface that is not there.
##
## THE SHAPE, in one sentence: pebbles fall down ONE drop from the outlet into ONE duct,
## and the duct runs from the pool's mouth on the left to the foot of the riser on the
## right, with the sorter in the middle of it. That is why this is one function and not a
## `discharge_walls` plus a `riser_walls` — the two legs do not have separate pipes to
## describe. They share the drop and they share the duct, and the SORT hub is not a fitting
## anyone built, it is just the place in the duct where the leftward belt ends and the
## rightward one begins. Two functions would each own half of a shared thing and would have
## to agree about the seam between them; one function has no seam to get wrong.
##
## THE GAPS ARE THE POINT — this plant is a set of pipes that MEET, and a wall carried
## through a junction is a lid over the pipe feeding it. Four are deliberate:
##   * the top of the drop, where pebbles arrive from the outlet;
##   * the drop's own mouth: the roof is in TWO spans and the hole between them is where
##     the shaft pours into the duct;
##   * the floor's left end, which IS the pool's mouth — the pebble runs out of floor and
##     falls, so the drop into the tray is an absence of pipe rather than a special case;
##   * the roof's right end, where the riser's bore opens upward out of the duct.
## The plant is entirely AXIS-ALIGNED (every run is vertical or horizontal), which is why
## this needs no mitring or offset-polyline machinery: literal segments and honest gaps.
##
## ⚠️ THE DROP'S RIGHT FACE USED TO BE THE DISCHARGE CONVEYOR'S END CAP, running unbroken
## from the outlet down to the floor, and Phase 3b-ii had to CUT it back to the roof. That
## is not tidying — it is the change that makes a recirculation leg possible at all, because
## that wall stood squarely between the drop and everything to the right of it. It also
## removes the thing that used to catch a discharge pebble bouncing rightward off the corner.
## What replaces it is not another wall but the DRIVE: main pushes a body along its OWN leg's
## belt wherever in the duct it is (`main._drive`), so a discharge pebble that wanders right
## is simply pushed back left. The containment moved from geometry into the belt, deliberately
## — the alternative is a wall that recirculating fuel cannot get past either.
static func plant_walls() -> Array:
	var half := BORE_W * 0.5
	var drop_l := Silo.CENTER_X - half       # the drop's left face
	var drop_r := Silo.CENTER_X + half       # the drop's right face
	var roof := HUB_Y - half                 # the duct's upper face
	var floor_y := HUB_Y + half              # the duct's lower face — what pebbles roll on
	var mouth_l := BIN_X - half              # the pool mouth's far side
	var mouth_r := BIN_X + half              # where the floor stops and the pebble tips off
	var riser_l := RISER_X - half            # the riser's left face
	var riser_r := RISER_X + half            # the riser's right face
	# The climb's walls stop exactly AT the chute line, not past it. This used to carry a
	# bore's half-width further UP (smaller y) than CHUTE_Y, on the old rider design's
	# reasoning: main REMOVED the body at CHUTE_Y, so the walls had to still be there for
	# the instant of removal, catching a fast body's one-step overshoot past the line.
	#
	# THAT REASONING DIED WITH THE RIDER (Phase 3c): a body is not removed at CHUTE_Y any
	# more, it is re-driven sideways (`in_recirc_merge`/`in_reinject_merge`), and `in_riser`'s
	# own UP force already stops at `at.y > CHUTE_Y` — i.e. at CHUTE_Y itself, not a bore's
	# width past it. The stale margin left the WALLS extending past where the FORCE stops, so
	# a body climbing into that gap (`CHUTE_Y - half < y < CHUTE_Y`) had no upward push left
	# (in_riser false) and was still boxed in by the riser's own side walls (too narrow, and
	# in the wrong direction, for the leftward in_recirc_merge push to clear) — a genuine dead
	# pocket with no force able to move a body out of it. MEASURED, and a real fix for what it
	# targets: a traced pebble that used to park at (960.70, 71.70) — inside that exact pocket
	# — now clears it and reaches (960.70, 93.70) instead. But this alone did NOT deliver a
	# single pebble: the SAME trace still froze, just at that later point, against a
	# completely separate bug (see `inlet_walls`'s merge-run floor/roof and inlet side-wall
	# gaps) — this fix closes one real dead pocket on the climb, not the delivery freeze
	# itself, which needed both.
	var riser_top := CHUTE_Y
	var rx_l := REINJECT_X - half            # reinject riser's left face
	var rx_r := REINJECT_X + half            # reinject riser's right face
	return [
		# --- The drop: outlet → duct. BOTH faces stop at the roof, and symmetrically:
		# below that line is the duct, and either face carried further would wall the duct
		# off from the pipe feeding it. The left face has always stopped here; the right
		# one now does too (see the note above).
		[Vector2(drop_l, Silo.OUTLET_Y), Vector2(drop_l, roof)],
		[Vector2(drop_r, Silo.OUTLET_Y), Vector2(drop_r, roof)],
		# --- The duct roof, in two spans. The gap between them is the drop's mouth: this
		# is the one wall in the plant with a hole in the MIDDLE of it rather than at an
		# end, because it is the one wall a pipe arrives through from above.
		[Vector2(mouth_l, roof), Vector2(drop_l, roof)],
		# The right span stops at the riser's left face — past that the roof would be a lid
		# on the climb.
		[Vector2(drop_r, roof), Vector2(riser_l, roof)],
		# --- The duct floor: ONE run, the pool's mouth to the foot of the riser. It is the
		# surface both belts drag along, and it STOPS at the mouth's right edge — the missing
		# span is the hole a spent pebble falls through, and it is exactly the stub of pipe
		# `_pipe_runs` draws heading down to the tray.
		[Vector2(mouth_r, floor_y), Vector2(riser_r, floor_y)],
		# --- The pool mouth's far wall: a pebble is travelling left at belt speed when the
		# floor runs out, so this is what stops it carrying on past the tray.
		[Vector2(mouth_l, roof), Vector2(mouth_l, floor_y)],
		# --- The riser: the climb up to the chute. Its LEFT face starts at the roof (the
		# elbow's inside corner) and its RIGHT face starts at the floor (the elbow's outside
		# corner) — which is also the wall a pebble arriving at 380 px/s runs into and turns
		# up against, so it is the one face in the plant that gets hit hard.
		[Vector2(riser_l, roof), Vector2(riser_l, riser_top)],
		[Vector2(riser_r, floor_y), Vector2(riser_r, riser_top)],
		# --- Reinject's own riser (Phase 3b-iii): a dedicated climb beside the pool, sharing
		# no wall and no belt with anything above. It has no floor and needs none — like the
		# main riser, a pebble arrives with the belt already pushing UP, not resting on
		# anything — so this is just the two side faces of the bore, full height from beside
		# the pool floor to the chute.
		[Vector2(rx_l, POOL_FLOOR), Vector2(rx_l, riser_top)],
		[Vector2(rx_r, POOL_FLOOR), Vector2(rx_r, riser_top)],
	] + inlet_walls()


## The shared inlet (Phase 3c): the merge runs off the tops of both risers, and the
## vertical bore they and a freshly minted pebble all fall into. Split out of
## `plant_walls` only for readability — it is still the one function main hands every
## static segment to.
##
## THE FLOOR IS CLOSED, on purpose, mirroring `Silo`'s own closed hopper floor at the
## OUTLET: this vessel has no lid at all (`Silo.wall_segments`), so without a floor here
## a pebble minted at `inlet_top` would free-fall straight into the bed with no admission
## control whatsoever — the exact same argument that keeps the OUTLET a metered removal
## rather than a hole. `main._admit_batch` is the metering; this is what it meters.
##
## THE MERGE ROOFS STOP SHORT OF THE INLET BORE, on purpose — a roof that crossed the
## inlet bore's own width would cap the one place a freshly minted pebble is meant to
## fall THROUGH from `inlet_top` above. Both merge runs hand off to the vertical bore at
## its outer edge, leaving the bore itself open top to bottom.
##
## THE BORE IS WIDER THAN THE MERGE RUNS FEEDING IT (`INLET_BORE_W` vs `BORE_W`), on
## purpose (Phase 3c widening, `INLET_LANES`) — it is the one place three feeds actually
## converge (fresh mint straight down the middle, recirc and reinject arriving from either
## side), so it is the natural place for the plant to be widest, the same way a funnel
## opens up at a junction rather than staying pipe-width throughout.
static func inlet_walls() -> Array:
	var half := BORE_W * 0.5
	var inlet_half := INLET_BORE_W * 0.5
	var inlet_l := INLET_X - inlet_half
	var inlet_r := INLET_X + inlet_half
	# The NEAR edge of each riser's own bore — where its merge run's floor/roof must STOP,
	# not where the riser's OUTER wall sits. `riser_r`/`rx_l` (the outer edges) were what this
	# used before, and that was the bug: a floor/roof spanning all the way to the riser's
	# outer wall leaves NO GAP for the riser's own bore to pass through, so a pebble climbing
	# dead centre in the riser hits the merge floor's solid underside and stops — it can
	# never cross from the vertical climb into the horizontal run at all. MEASURED (not
	# reasoned): traced a single, uncontested recirculating pebble frame-by-frame
	# (tests/live_fuel_policy.gd's probe) — it climbed the riser cleanly, began turning left
	# the instant `in_recirc_merge` engaged, and then stopped DEAD at y=93.7, wedged against
	# the merge floor from below (merge_floor sat at y=86; pebble radius ~8 puts its top edge
	# exactly there). Not sleeping, not frozen, not force-starved — one prior "fix" doubled
	# the riser's width and another multiplied the belt force by 10x, and BOTH left this
	# exact pebble on this exact spot, because neither touched the actual wall gap. The SAME
	# comment already states this principle for the INLET side of these walls ("stop short of
	# the inlet bore... leaving the bore itself open top to bottom") — this was simply never
	# applied to the RISER side too.
	var riser_l := RISER_X - half
	var rx_r := REINJECT_X + half
	var merge_roof := CHUTE_Y - half
	var merge_floor := CHUTE_Y + half
	return [
		# --- Recirc's merge run: bent left toward the inlet's WIDE right face, stopping at
		# the NEAR (left) edge of the riser's own bore so a climbing body has a hole to pass
		# through rather than a floor to hit.
		[Vector2(inlet_r, merge_roof), Vector2(riser_l, merge_roof)],
		[Vector2(inlet_r, merge_floor), Vector2(riser_l, merge_floor)],
		# --- Reinject's merge run: bent right toward the inlet's WIDE left face, stopping at
		# the NEAR (right) edge of ITS riser's own bore for the identical reason.
		[Vector2(rx_r, merge_roof), Vector2(inlet_l, merge_roof)],
		[Vector2(rx_r, merge_floor), Vector2(inlet_l, merge_floor)],
		# --- The inlet bore's side walls: NOT full height, on purpose — this is the second
		# half of the same wall-gap bug the riser-side fix above addresses. A body arriving
		# off a merge run does not arrive AT merge_roof/merge_floor exactly: it is still
		# carrying real vertical momentum from the climb when the belt switches it to a
		# horizontal push (nothing zeroes vertical velocity at the hand-off — a real conveyor
		# transfer doesn't either), so it overshoots well past the intended corridor height
		# before gravity brings it back down. MEASURED: a traced pebble climbing this leg blew
		# straight through the merge run's own roof to y=15.9 (INLET_TOP_Y is 20 — it nearly
		# reached the fresh-mint drop point) before settling back to y≈56, still 8-30 px above
		# merge_roof=64. A side wall starting at INLET_TOP_Y, sized to the narrow undershot
		# corridor, catches exactly that overshoot from the side and pins the body against it
		# — the fix the riser-side gap alone left in place, and the reason a single lone
		# pebble still failed to arrive even after that fix. So the wall starts at
		# `merge_floor`, not `INLET_TOP_Y`: everything above the merge floor is open air the
		# whole width of the bore, wide enough to absorb any realistic overshoot, and the
		# side walls exist only where they matter — containing the settled pile down at
		# `INLET_FLOOR_Y`.
		[Vector2(inlet_l, merge_floor), Vector2(inlet_l, INLET_FLOOR_Y)],
		[Vector2(inlet_r, merge_floor), Vector2(inlet_r, INLET_FLOOR_Y)],
		[Vector2(inlet_l, INLET_FLOOR_Y), Vector2(inlet_r, INLET_FLOOR_Y)],
	]


## Where an EXTRACTED pebble becomes a body — just inside the drop, below the hopper floor.
##
## One mouth for both legs, because the vessel has one outlet. Which way the pebble goes when
## it lands is the belt's business, not this function's: the sorter's decision travels with the
## pebble (`main._transit`) rather than being expressed as a second hole in the hopper. That is
## also what the plant has always DRAWN — one pipe out of the vessel, parting left or right only
## at the SORT hub — so the picture and the machine now say the same thing.
##
## `across` is its offset across the bore, -1 (left face) to +1 (right face); main passes a
## random one, for the same reason `pool_drop` takes one (see there).
##
## THERE IS AN HONEST SEAM HERE and it is worth naming rather than hiding. The silo is a
## CLOSED hopper — extraction is metered, the floor has no hole, and it must not get one:
## an open outlet would let the bed drain uncontrollably. So the pebble cannot physically
## fall out of the core; it is removed at the outlet and appears in the pipe it was
## discharged into, which is what metered discharge means.
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
##
## ⚠️ SINCE PHASE 3b-ii THIS DOOR CARRIES EVERY EXTRACTION, not one in ten. The recirculation
## leg shares the drop, so the load went from ~0.06/s to a steady 1 per EXTRACT_INTERVAL =
## 3.33/s, against a door that admits ~4.5/s (a pebble clears BORE_W of free fall in ~0.22 s).
## That ~35% margin is the reason this stayed one shared door instead of being split into two
## lanes at the outlet, and it is MEASURED rather than computed: fed at the full rate with the
## legs alternating, `tests/live_riser.gd` sees the pending queue never back up. If the drop is
## ever asked to carry more (a shorter EXTRACT_INTERVAL, say), this is the number that runs out
## first — and it fails safely, as back-pressure in `_drop_pending`, not as overlapping bodies.
const MOUTH_CLEAR := BORE_W + 2.0


## Is this body in the DUCT — the horizontal run under the vessel that both legs share?
##
## This answers WHERE a pebble is, and deliberately not WHICH WAY it should be pushed. Both
## belts live in this one duct, running opposite ways from the sorter, so the direction is a
## property of the PEBBLE'S LEG and not of the place it is standing in: main reads it from
## `_transit`, never from geometry (see `main._drive`). A zone that tried to answer both —
## "left of the hub means push left" — would be the same mistake as taking a rider's tangent
## from the nearest point on a path that doubles back on itself: it would decide a pebble's
## direction from where it had drifted to, so one nudge past the hub would turn a spent
## pebble around and send it up the riser.
##
## The zone ENDS at the pool's mouth: past that the pebble has left the floor and is falling
## into the tray, where a belt has nothing to push against and pushing anyway would throw it
## at the far wall. So the belt lets go exactly where the floor does — and, at the other end,
## exactly where the riser's own drive takes over.
static func in_duct(at: Vector2) -> bool:
	var half := BORE_W * 0.5
	return at.y > HUB_Y - half and at.y < HUB_Y + half + PEBBLE_R \
			and at.x > BIN_X + half and at.x < RISER_X + half


## Is this body in the RISER — the climb from the foot of the duct up to the chute?
##
## IT OVERLAPS THE DUCT AT THE BOTTOM CORNER, ON PURPOSE, and that overlap IS the bend. A
## pebble arriving at the foot of the riser is still on the duct floor being dragged right,
## and it is also here being lifted, so it gets both pushes at once and rounds the elbow on a
## diagonal. Exclusive zones — right until x reaches RISER_X, then up — put a hard line at
## the corner instead, and a pebble that touches the riser's far wall and rebounds back
## across that line is driven right again, into the wall it just came off. The overlap is
## what a real transfer between two conveyors looks like anyway: they share the corner.
##
## Wider than the bore (BORE_W either side of the centreline, not BORE_W/2) so the lift has
## already begun while the pebble is still short of the riser proper. It is bounded BELOW by
## the duct floor and ABOVE by the chute, where main lifts the body off.
static func in_riser(at: Vector2) -> bool:
	return absf(at.x - RISER_X) < BORE_W \
			and at.y > CHUTE_Y and at.y < HUB_Y + BORE_W * 0.5


## Has a climbing pebble reached the head of the riser, where the belt should stop lifting
## and start pushing it sideways along the merge run toward the inlet (`main._drive`)?
##
## This is the riser belt's bend, not its end — under the old rider design it WAS the
## terminus (a removal at a fixed point, which is what let this belt run at 380 while the
## discharge belt crawls at 95: no open exit to overshoot). That speed argument still holds
## unchanged; only what happens at the top does. A real body now continues past this point,
## driven horizontally, until `in_inlet_bore` says it has actually arrived.
##
## Both axes, like `pool_contains` and for the same reason: a bare `y <= CHUTE_Y` would be
## satisfied by a pebble that had punched through the riser wall and sailed up the outside of
## it, and would report the escape as having reached the bend. Requiring x as well means only
## a pebble actually in the bore counts.
static func riser_at_bend(at: Vector2) -> bool:
	return at.y <= CHUTE_Y and absf(at.x - RISER_X) < BORE_W


## Is this body on the RECIRC merge run — the horizontal leg from the top of the riser's
## bend to the shared inlet? Wider than the bore, matching `in_riser`'s reasoning: the
## sideways push should catch the pebble the instant it clears the bend, not once it has
## drifted to the run's own centreline first.
static func in_recirc_merge(at: Vector2) -> bool:
	return at.x > INLET_X and at.x < RISER_X + BORE_W \
			and absf(at.y - CHUTE_Y) < BORE_W


## Where the riser hands a climbing pebble off to the merge run — the head of the climb,
## which is also where `_pipe_runs` bends the riser over toward the inlet.
static func riser_head() -> Vector2:
	return Vector2(RISER_X, CHUTE_Y)


## Where a re-injected pebble becomes a body — beside the pool, at the foot of its OWN riser
## (Phase 3b-iii). Mirrors `drop_mouth`: the pebble is respawned here regardless of exactly
## where it was resting in the pile, the same seam the shared drop already uses for a
## discharge/recirc pebble re-materializing at a fixed point rather than its exact bed
## position. `across` takes the same bore play as the other mouths, for the same reason.
static func reinject_mouth(across := 0.0, radius := PEBBLE_R) -> Vector2:
	return Vector2(REINJECT_X + across * BORE_CLEARANCE, REINJECT_MOUTH_Y)


## Is this body in the REINJECT riser? Wider than the bore (BORE_W either side, matching
## `in_riser`) so the belt catches it the instant it is spawned, not after it drifts to the
## centreline first.
static func in_reinject_riser(at: Vector2) -> bool:
	return absf(at.x - REINJECT_X) < BORE_W and at.y > CHUTE_Y and at.y < POOL_FLOOR


## Has a climbing re-injected pebble reached the head of ITS riser — the bend onto its own
## merge run toward the inlet? Both axes, for the same reason `riser_at_bend` checks both: a
## pebble that punched through the bore wall must not be read as safely at the bend just
## because it cleared the y line.
static func reinject_at_bend(at: Vector2) -> bool:
	return at.y <= CHUTE_Y and absf(at.x - REINJECT_X) < BORE_W


## Is this body on REINJECT's own merge run, the horizontal leg from its riser's bend to the
## shared inlet? Mirrors `in_recirc_merge`, mirrored in x (REINJECT_X sits LEFT of the
## inlet, RISER_X sits RIGHT of it).
static func in_reinject_merge(at: Vector2) -> bool:
	return at.x < INLET_X and at.x > REINJECT_X - BORE_W \
			and absf(at.y - CHUTE_Y) < BORE_W


## Where REINJECT's riser hands a climbing pebble off to its own merge run.
static func reinject_riser_head() -> Vector2:
	return Vector2(REINJECT_X, CHUTE_Y)


## Has a pebble arriving from either merge run reached the shared inlet bore — the point
## RECIRC and REINJECT both actually count as "delivered" at (`main._delivered`)? Both axes,
## same reasoning as `pool_contains`: the walls are what put the pebble over the bore, so
## arrival must be checked against real geometry, not a bare y-line a wall gap could let a
## stray body sail past. Checked against the WIDE bore (`INLET_BORE_W`), not one lane, since
## a merge-run pebble can arrive anywhere across it.
static func in_inlet_bore(at: Vector2) -> bool:
	return absf(at.x - INLET_X) < INLET_BORE_W * 0.5 and at.y >= CHUTE_Y - BORE_W and at.y <= INLET_FLOOR_Y


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


## The x-centre of inlet LANE `lane` (0-indexed, 0 .. INLET_LANES-1), spaced one BORE_W
## apart and centred on INLET_X — INLET_LANES=3 gives lanes at INLET_X - BORE_W, INLET_X,
## and INLET_X + BORE_W, so every lane sits a full standard bore's width from its neighbour,
## the same clearance every other single-pebble pipe in the plant already gets.
static func inlet_lane_x(lane: int) -> float:
	return INLET_X + (float(lane) - float(INLET_LANES - 1) * 0.5) * BORE_W


## Where a newly minted (or steady-state fresh) pebble becomes a body — the top of inlet
## LANE `lane`. It free-falls from here, under real gravity, down through the bore and onto
## whatever is already piled against the closed floor (`INLET_FLOOR_Y`). This is the ONE
## PIPE every pebble bound for the bed enters through (`INLET_LANES` columns inside it) —
## see the class doc for why unifying it here is what fixes both "pebbles appear from
## nothing" (no more `Silo.spawn_x` scatter) and "pebbles disappear for a second" (no more
## bodiless staging).
static func inlet_top(lane := 0) -> Vector2:
	return Vector2(inlet_lane_x(lane), INLET_TOP_Y)


## Where an ADMITTED pebble reappears — just below the inlet's closed floor, inside the
## vessel proper, at the given LANE. Mirrors `drop_mouth` exactly, for exactly the same
## reason: the floor is closed (see `inlet_walls`), so admission is a removal from the pile
## above it and a reappearance just below, never a hole. `across`/`radius` behave like every
## other mouth in the plant (see `drop_mouth`) — bore play so the feed does not stack into a
## column within its own lane.
static func inlet_admit_point(lane := 0, across := 0.0, radius := PEBBLE_R) -> Vector2:
	return Vector2(inlet_lane_x(lane) + across * BORE_CLEARANCE, Silo.TOP + radius + 2.0)


## How much VERTICAL room one lane of the inlet needs — above its top or below its floor —
## before another pebble may enter or be admitted through THAT lane. Mirrors `MOUTH_CLEAR`
## exactly, for exactly the same reason (see there): a body spawned on top of another is not
## a queue, it is a collision the solver resolves violently.
##
## Checked AXIS-ALIGNED, not as a Euclidean radius (see `main._lane_clear`): a circular
## clearance this size around one lane's point would reach across `INLET_LANE_HALF_WIDTH`
## into its neighbour and false-block it — exactly the "every lane blocks the next one"
## failure that would defeat the whole point of widening the pipe. Splitting into a Y
## distance (this) and a narrow X band (`INLET_LANE_HALF_WIDTH`) keeps lanes independent.
const INLET_MOUTH_CLEAR := BORE_W + 2.0
# Half-width of the X band a lane's own clearance/ownership check looks at. EXACTLY half the
# lane pitch (BORE_W * 0.5), so the three lanes' bands tile the whole bore edge-to-edge with
# no gap and no overlap: [INLET_X-33,-11) [−11,+11) [+11,+33) for INLET_LANES=3, covering
# `in_inlet_bore`'s full ±33 exactly. A narrower band (0.35 was tried first) leaves a dead
# strip between adjacent lanes that NO lane's check ever looks at — and `_lowest_at_inlet`
# needs a lane to claim a delivered body or it can never be admitted at all. MEASURED: a
# recirculated pebble delivered into that strip (there is nothing to stop it landing there —
# `in_recirc_merge`/`in_reinject_merge` drive a body straight at the bore's outer edge, not
# at a lane centre) sat there forever, permanently short one pebble; because `_extract_lowest`
# gates on `_core_count() >= _population_setpoint`, that one stuck pebble froze the ENTIRE
# fuel cycle — extraction, recirculation, and discharge all together — for the rest of the
# run (tests/live_fuel_policy.gd: 45 successful recirculations, then core stuck at 379/380,
# zero further extractions ever). Full-pitch coverage is the fix, not a bigger clear-check:
# it costs a lane its adjacent-lane independence only in the strip it now shares at each
# border, which is a small throughput cost for actually admitting every pebble that arrives.
const INLET_LANE_HALF_WIDTH := BORE_W * 0.5


## The fixed pipework, as POLYLINES (not loose segments) so every interior vertex is a
## real elbow the draw can fit a bend to.
##
## These are the same coordinates the walls (`plant_walls`/`inlet_walls`) are built from,
## so a body is always centred in its bore by construction — the pipe cannot drift away
## from the physics it draws.
##
## The inlet bore itself is NOT here — it is `INLET_BORE_W` wide, wider than every other
## run in the plant (`BORE_W`), so it has to be drawn in its own pass at its own width (see
## `_inlet_bore_run`/`_draw_plant`) rather than sharing one uniform-width pass with these.
static func _pipe_runs() -> Array:
	var hub := Vector2(Silo.CENTER_X, HUB_Y)
	return [
		# Outlet → sorter. Starts flush with the hopper's inner floor face and pierces the
		# vessel wall, so the discharge pipe is visibly socketed into the bottom of the core.
		PackedVector2Array([Vector2(Silo.CENTER_X, Silo.OUTLET_Y), hub]),
		# Sorter → riser → bend → the shared inlet: the RECIRC leg (Phase 3c retired its old
		# rider tail, which used to end at REINJECT_X on this same run — the two legs now
		# merge at the inlet instead of on top of each other).
		PackedVector2Array([hub, Vector2(RISER_X, HUB_Y), Vector2(RISER_X, CHUTE_Y),
				Vector2(INLET_X, CHUTE_Y)]),
		# Sorter → spent pool (the discharge leg), ending at the mouth it pours from.
		# No fudge factor between the pipe's end and the belt's end any more: they are the
		# same point, so the pebble becomes a body exactly where it was last drawn.
		PackedVector2Array([hub, Vector2(BIN_X, HUB_Y), Vector2(BIN_X, BIN_Y)]),
		# Reinject's own riser (Phase 3b-iii) → its own bend → the shared inlet (Phase 3c).
		PackedVector2Array([Vector2(REINJECT_X, POOL_FLOOR), Vector2(REINJECT_X, CHUTE_Y),
				Vector2(INLET_X, CHUTE_Y)]),
	]


## The shared inlet bore itself (Phase 3c, widened for `INLET_LANES`): the ONE visible pipe
## every pebble bound for the bed falls through. Fresh fuel drops straight down it from
## `inlet_top`; the two runs `_pipe_runs` draws join it partway down, at the bend height.
## Its own function (not folded into `_pipe_runs`) because it draws at `INLET_BORE_W`, not
## the uniform `BORE_W` every other run shares.
static func _inlet_bore_run() -> PackedVector2Array:
	return PackedVector2Array([Vector2(INLET_X, INLET_TOP_Y), Vector2(INLET_X, INLET_FLOOR_Y)])


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


## The bore's outline for a set of runs, as one mitred ring per run.
##
## WHY offset_polyline and not two offset lines per segment: drawing each segment's two edges
## full-length to its end vertex makes them overshoot past each other at every bend, stamping
## a small cross on the elbow. Covering it with a disc at the vertex does NOT work — the
## overshoot lands on the INNER side of the corner, outside any disc centred on the vertex.
## offset_polyline solves the actual problem: it terminates each edge at the join, mitring the
## inside of the bend and rounding the outside to exactly the same radius as the bore disc
## already drawn there.
func _pipe_outline(runs: Array, half_w: float) -> void:
	for run in runs:
		var pts: PackedVector2Array = run
		for outline in Geometry2D.offset_polyline(pts, half_w,
				Geometry2D.JOIN_ROUND, Geometry2D.END_BUTT):
			var ring: PackedVector2Array = outline
			draw_polyline(ring + PackedVector2Array([ring[0]]), PIPE_EDGE, 1.0)


func _draw() -> void:
	_draw_plant()
	# No rider pass any more (Phase 3c) — every pebble in the plant is a real physics body
	# now, and bodies draw themselves (`PebbleBody._draw`), the same way the pool's pile
	# always has. This node only draws the fixed pipework and captions around them.


## The static plant: pipework, the sorter, the bin, the inlet. Drawn on demand
## (`queue_redraw`, e.g. from `set_pool`) rather than every frame — nothing here animates
## any more since the riders are gone.
func _draw_plant() -> void:
	var hub := Vector2(Silo.CENTER_X, HUB_Y)
	var runs := _pipe_runs()

	var inlet_run := [_inlet_bore_run()]

	# The pipe is built from outside in: the casing wall, then the hollow bore inset into
	# it, then (below) the bore's outline. Drawing whole PASSES — every run's casing before
	# any run's bore — rather than finishing each run in turn is what makes the junctions
	# work: multiple pipes meet at the sorter and at the inlet, and a later run's casing
	# would otherwise paint over an earlier run's bore and plug it. The wide inlet run gets
	# its own pass at `INLET_CASING_W`/`INLET_BORE_W`, but stays in the SAME casing-then-bore
	# ordering as everything else, for the same junction reason.
	_pipe_pass(runs, CASING_W, PIPE_CASING)
	_pipe_pass(inlet_run, INLET_CASING_W, PIPE_CASING)
	_pipe_pass(runs, BORE_W, PIPE_BORE)
	_pipe_pass(inlet_run, INLET_BORE_W, PIPE_BORE)
	_pipe_outline(runs, BORE_W * 0.5)
	_pipe_outline(inlet_run, INLET_BORE_W * 0.5)

	# The inlet's closed floor (`INLET_FLOOR_Y`, `inlet_walls`), drawn as a cap across the
	# bore so the plant shows what the physics already has: a real, closed door, not an
	# open pipe — this is what a waiting pebble is resting ON, and what disappears for the
	# instant `main._admit_batch` opens it.
	var inlet_half := INLET_BORE_W * 0.5
	draw_line(Vector2(INLET_X - inlet_half, INLET_FLOOR_Y), Vector2(INLET_X + inlet_half, INLET_FLOOR_Y),
			PIPE_EDGE, 2.0)
	_label("NEW FUEL", Vector2(INLET_X - 26.0, INLET_TOP_Y - 6.0))

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


func _label(text: String, at: Vector2) -> void:
	draw_string(ThemeDB.fallback_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			Color(0.62, 0.68, 0.78, 0.9))
