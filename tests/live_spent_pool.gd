# tests/live_spent_pool.gd
#
# Integration check for the SPENT-FUEL POOL — discharged pebbles settle and stay.
#   godot --headless --script res://tests/live_spent_pool.gd
#
# WHY this harness has to exist, and why it is not part of any pure suite: the pool
# lives entirely in main.gd + game/, so the fast suites (which drive sim/ directly)
# cannot see it at all. They would stay green through both of the failures that
# actually matter here.
#
# FAILURE 1 — the pool silently becomes fuel. This is the real hazard, and it is NOT
# hypothetical: the pool sits at x ≈ 418..533, y ≈ 968..1017, and the neutronics grid
# spans x ∈ [424, 1036], y ∈ [-16, 1072] (Grid.for_silo). So a settled pebble lands in a
# VALID grid cell, not outside the grid — cell_of() returns a real index there. If it
# reached homogenize(), the spent pool would blend into the flux solve as core fuel,
# quietly shifting k. The test asserts the hazard is real (the pile IS in-grid) and that
# the pool is nonetheless absent from the flux solve's input — otherwise the guard is
# untestable.
#
# THE HAZARD IS NOW LIVE RATHER THAN HYPOTHETICAL. Phase 3 gave the settled pebbles real
# bodies: they fall out of the discharge pipe, collide, and pile up in a tray with real
# walls. So the engine really is holding bodies in valid grid cells, and only
# `main._out_of_core` keeps them out of the neutronics.
#
# That is why this file no longer parks a synthetic GHOST body in the tray to prove the
# filter discriminates. It used to have to: the pool was static art, there were no bodies
# to catch, so an unfiltered read would have passed too and the check proved nothing. The
# ghost was a stand-in for exactly the situation Phase 3 created — and now that the real
# pool provides it, a fake one would be testing less than the truth sitting next to it.
#
# WHAT THIS TEST IS CAREFUL *NOT* TO FORBID. The guard is "the pool is not fuel", which
# is a claim about the NEUTRONICS. It is not "the pool has no physics bodies" — that was
# only the mechanism that enforced it while the pool was static art, and this test used
# to assert the mechanism, which quietly made it a veto on giving pool pebbles bodies at
# all. They needed them: pebbles must collide under the same rules everywhere in the sim,
# and a pebble must be re-injectable out of the pool. So check 4 reads the flux solve's
# real input (main._core_positions()) rather than the body list. Membership in the bed is
# DECLARED (main._out_of_core), never inferred from whether the engine happens to be
# holding a body — see the rationale on main._core_positions().
#
# FAILURE 2 — the pool perturbs the fuel cycle's arithmetic. Catching a Pebble on its
# way out must not change what leaving MEANS: discharge is still the only thing that
# shrinks the circulating population, and so the only thing that opens a fresh-fuel slot.
# A spent pebble that still held a slot would keep the mint gate closed, the plant would
# stop making fresh fuel as the pool filled, and the bed would starve — the exact
# silent-k-shift class of bug LOOP_BUFFER exists to prevent.
#
# ...AND THE SECOND THING THIS TEST IS CAREFUL NOT TO FORBID. That failure used to be
# stated as "a spent pebble must not keep its slot in `_pebbles`" — again the MECHANISM,
# not the claim. A pool pebble is a `_pebbles` member NOW, and must be: re-injection needs
# it in the registry, and keeping a shadow pool outside would mean hand-maintaining a fuel
# budget the registry already keeps. What must be true is that it holds no slot in the
# CIRCULATING population — `main._inventory()`, which subtracts the pool explicitly. So
# checks 5 and 6 read `_inventory()`, and check 6b proves the distinction is load-bearing
# rather than a rename: the pool really is in the registry, and the gate really cannot
# see it.
extends SceneTree

# The cycle check in live_fuel_loop.gd confirms discharges are flowing by t = 70 s, so
# the pool has settled pebbles to inspect by then. Give it margin.
const ASSERT_AT := 80.0
const GIVE_UP_AT := 200.0
# Overfill pacing. DROP_EVERY spaces the pushes; SETTLE lets the pile stop rolling before
# the tray is measured — at a shorter settle the fit check reads pebbles mid-roll.
#
# DROP_EVERY no longer has to protect anything, and that is worth knowing before someone
# "optimizes" it. It used to be the thing standing between this test and a pile spawned
# inside itself, because `_pool_push` materialized a body in the mouth on demand and pushing
# two in one frame put two bodies in one place. The pebbles now enter a real pipe through
# `_drop_pending`, and the PLANT meters them (`main._feed_drop` will not open the mouth
# while a pebble is still in it). So the pacing is legibility, not a guard — the guard moved
# into the thing being tested, which is where it belongs.
const DROP_EVERY := 1.1
# Generous because a push is no longer an arrival: the last dummy still has a ~2.7 s ride
# ahead of it. The phase only starts once the pipe is empty (see `_overfill_tick`), so this
# is settling time on top of the ride rather than a bet on how long the ride takes.
const SETTLE := 6.0

var _main
var _t := 0.0
var _failures := 0
var _peak_spent := 0
var _phase := 0            # 0 = run the reactor, 1 = overfill the tray, 2 = let it settle
var _pushed: Array = []    # everything ever pushed at the pool, oldest first
var _dummies := 0          # how many of those this test manufactured
var _next_drop := 0.0
var _settle_until := 0.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live spent pool] discharged pebbles must SETTLE — and stay out of the flux")


func _ok(pass_: bool, msg: String) -> void:
	print("  %s  %s" % ["PASS" if pass_ else "FAIL", msg])
	if not pass_:
		_failures += 1


func _process(delta: float) -> bool:
	_t += delta
	_peak_spent = maxi(_peak_spent, _main._spent.size())
	# EVERY FRAME, not once per drip tick. `_pushed` has to be ARRIVAL order (see
	# `_sync_pushed`), and since Phase 3b-i an arrival is a pebble finishing a ~2.7 s ride
	# rather than something this test causes — so the only way to observe the order is to
	# look often enough that nothing can arrive and be casked between two looks.
	_sync_pushed()

	if _t > GIVE_UP_AT:
		print("TIMED OUT before the pool filled (phase %d)" % _phase)
		quit(1)
		return true

	if _phase == 1:
		if _t >= _next_drop:
			_next_drop = _t + DROP_EVERY
			_overfill_tick()
		return false
	if _phase == 2:
		if _t >= _settle_until:
			_final_checks()
			return true
		return false

	if _t < ASSERT_AT:
		return false

	var spent: Array = _main._spent
	var cap := FuelLoop.pool_capacity()

	# 1. The pebbles stopped vanishing. This is the whole ask.
	_ok(spent.size() > 0, "discharged pebbles ACCUMULATE in the pool (%d settled)" % spent.size())
	_ok(spent.size() == _main._total_extracted,
		"every discharged pebble is in the pool — none dropped (%d == %d)"
			% [spent.size(), _main._total_extracted])

	# 2. The pool holds genuinely SPENT fuel, not whatever happened to arrive: a pebble
	#    is discharged only past discharge burnup or its last pass (main._extract_lowest).
	var wrong := 0
	for peb in spent:
		if peb.burnup < Depletion.DISCHARGE_BURNUP and peb.pass_count < Depletion.MAX_PASSES:
			wrong += 1
	_ok(wrong == 0, "the pool holds only genuinely spent fuel (%d live pebbles in it)" % wrong)

	# 3. THE HAZARD IS REAL, and it is no longer a thought experiment: every settled pebble
	#    is a BODY, and it is resting in a valid grid cell. Asserted first, because check 4
	#    is meaningless without it — read off the actual pile rather than a layout function,
	#    because where these pebbles are is now a physics outcome and nothing else knows it.
	var grid := Grid.for_silo()
	var in_grid := 0
	var bodied := 0
	var raw: Dictionary = _main._physics.positions()
	for peb in spent:
		if raw.has(peb.id):
			bodied += 1
		if grid.cell_of(_main._physics.get_position(peb.id)) != -1:
			in_grid += 1
	_ok(bodied == spent.size(),
		"every settled pebble is a real BODY in the tray (%d/%d) — the guard has something to catch"
			% [bodied, spent.size()])
	_ok(in_grid == spent.size(),
		"...and every one rests in a VALID grid cell (%d/%d) — each WOULD become fuel unfiltered"
			% [in_grid, spent.size()])

	# 4. ...and yet nothing in the pool reaches the NEUTRONICS. Note what this asserts and
	#    what it deliberately does NOT: it checks the flux solve's actual input
	#    (_core_positions() — the dictionary handed to grid.homogenize), not the physics
	#    backend's body list.
	#
	#    This check used to read _physics.positions() and assert "no body sits in a pool
	#    slot". That guarded the right hazard through the wrong mechanism. The invariant
	#    that matters is "the pool is not fuel" — a NEUTRONICS claim. "No body exists
	#    there" was merely the way it happened to be enforced, back when the pool was
	#    static art. Asserting the mechanism instead of the invariant made this test a
	#    veto on ever giving pool pebbles bodies, which is now a requirement (they must
	#    collide and be re-injectable). So the check now names the boundary it always
	#    meant: bodies anywhere are fine; reaching homogenize() is not.
	#
	#    This is strictly STRONGER, not a loosening, and the swap was made at the one
	#    moment that is provable: when it landed, the pool had no bodies at all, so the
	#    old form and this one were both green — the invariant is a superset of the
	#    mechanism it replaced. A body in the pool now fails this check if and only if it
	#    is also fuel, which is the actual bug.
	#
	#    Checked by IDENTITY, not by geometry. It used to ask whether any homogenized
	#    position happened to land near a pool slot — a proximity test, because the pool
	#    had no ids in the engine to ask about. The pebbles are bodies now, so the question
	#    can be put directly: is this exact pebble in the flux solve's input? That cannot
	#    be fooled by a pebble sitting a pixel outside the search radius.
	var filtered: Dictionary = _main._core_positions()
	var intruders := 0
	for peb in spent:
		if filtered.has(peb.id):
			intruders += 1
	_ok(intruders == 0,
		"no settled pebble reaches the flux solve (%d intruders in homogenize input)"
			% intruders)

	# 4b. ...and the filter is not over-eager. The opposite failure is just as silent: if
	#     this dropped real bed pebbles out of the solve it would shift k the other way. So
	#     pin the exact size — the input must be precisely the pebbles that are NOT declared
	#     out of core, no more and no fewer.
	_ok(filtered.size() == _main._core_count(),
		"the filter removes ONLY what is out of core (%d in solve == %d in bed) — no bed pebble dropped"
			% [filtered.size(), _main._core_count()])
	_ok(raw.size() > filtered.size(),
		"...and it really is removing something (%d bodies -> %d fuel) — the check can bite"
			% [raw.size(), filtered.size()])

	# 5. A settled pebble is out of the CYCLE — but deliberately NOT out of the registry.
	#    It stays a `_pebbles` member so it can be re-injected, and it stays flagged
	#    out-of-core so it is not fuel. That single flag is what keeps it out of the flux
	#    solve, the depletion walk and the thermal walk without any of them knowing the
	#    pool exists at all, so it is worth asserting directly rather than inferring.
	var not_registered := 0
	var not_flagged := 0
	for peb in spent:
		if not _main._pebbles.has(peb.id):
			not_registered += 1
		if not _main._out_of_core.has(peb.id):
			not_flagged += 1
	_ok(not_registered == 0,
		"settled pebbles stay in the registry, ready to re-inject (%d missing)" % not_registered)
	_ok(not_flagged == 0,
		"...and every one is flagged OUT OF CORE, so none of them is fuel (%d unflagged)"
			% not_flagged)

	# 6. The fuel cycle's arithmetic is untouched — the calibration-neutrality claim.
	_ok(_main._inventory() == _main.TARGET_POPULATION + _main.LOOP_BUFFER,
		"the circulating population is still target + buffer (%d)" % _main._inventory())
	_ok(_main._core_count() == _main.TARGET_POPULATION,
		"bed still pinned at its calibrated population (%d)" % _main._core_count())

	# 6b. ...and that exclusion is REAL, not a rename. Same two-sided shape as check 4b:
	#     first prove the hazard is live — the pool really is in the registry, so a gate
	#     reading `_pebbles.size()` really would be throttled as it fills — then prove the
	#     gate is blind to it anyway. If `_inventory()` ever quietly collapsed back into
	#     `_pebbles.size()`, check 6 above would still pass; this is what would fail.
	_ok(_main._pebbles.size() == _main._inventory() + spent.size(),
		"the pool IS in the registry (%d = %d circulating + %d pooled) — the gate has something to exclude"
			% [_main._pebbles.size(), _main._inventory(), spent.size()])
	_ok(_main._pebbles.size() > _main.TARGET_POPULATION + _main.LOOP_BUFFER,
		"...and the raw registry has outgrown target + buffer (%d) — so the gate CANNOT be reading it"
			% _main._pebbles.size())

	# 7. The capped VIEW is honest: it holds what fits and reports the true total. Counts
	#    only — the tray does not draw the pebbles any more, they draw themselves, so what
	#    crosses this seam is the caption and nothing else.
	_ok(_main._loop._pool_held == spent.size(),
		"the tray states what it is holding (%d held, %d settled)"
			% [_main._loop._pool_held, spent.size()])
	_ok(_main._loop._pool_total == _main._total_extracted,
		"pool reports the TRUE total discharged, not the held count (%d)" % _main._loop._pool_total)

	# Hand over to the OVERFILL phase — see _overfill_tick. It runs on the clock rather
	# than in one burst because the pebbles are bodies now and need time to fall.
	#
	# Seeding the push history from the pool itself is only complete while nothing has
	# been casked yet — a shipped pebble is gone from `_spent` and could not be recovered
	# from it. True by a wide margin here (the cap is 12 and a slow discharge has put a
	# handful in), but asserted rather than assumed: if the pool ever filled before
	# ASSERT_AT this reconstruction would silently lose its head and the ordering checks
	# would be measuring the wrong window.
	_ok(_main._total_shipped == 0,
		"nothing has casked yet, so the pool IS the whole push history (%d shipped)"
			% _main._total_shipped)
	_pushed = spent.duplicate()
	_phase = 1
	return false


# 8. OVERFLOW + THE PILE ITSELF, forced rather than waited for. Real discharge runs ~1 per
#    16 s, so the pool takes minutes to fill and a timed test would never reach the cap —
#    leaving both the cap logic and the pile's physical fit unproven.
#
# WHY THIS IS DRIP-FED AND NOT A LOOP. It used to push cap+3 dummies in a single frame,
# which was fine when a pooled pebble was a color in an array. They are BODIES now: pushed
# in one frame they all spawn at the same pipe mouth, inside one another, and the solver
# fires the pile across the screen. Dropped one at a time they do what the real plant does
# — fall, roll, and settle — which is the only way the fit check below means anything.
## The tray's ARRIVAL history, oldest first — every pebble ever admitted to the pool,
## including the ones since casked. Read straight off `_spent`, which is FIFO, so this is
## arrival order by construction.
##
## It covers real discharges as well as this test's dummies, and it must: the reactor does
## not stop while the tray is filled, so a genuine spent pebble lands in the pool mid-fill.
## It ships a real pebble, so a history that knew only the dummies would under-count the
## casked total and slide the oldest-survivor identity by one — which is exactly how this
## first failed. Not a flaw in the fill; it is the plant doing its job.
##
## SINCE PHASE 3b-i THIS IS THE ONLY WAY THE HISTORY IS BUILT, and the dummies are no longer
## appended when they are pushed. A push is not an arrival any more: a dummy now enters a
## real pipe and rides a belt for ~2.7 s before it lands, and a real discharge can beat it
## there. Recording it at push time would assert an order the pool never had — the same
## push-is-arrival assumption that only held while `_pool_push` put pebbles in the tray
## instantly. Ask the tray what arrived, in the order it arrived; do not predict it.
func _sync_pushed() -> void:
	for peb in _main._spent:
		if not _pushed.has(peb):
			_pushed.append(peb)


func _overfill_tick() -> void:
	if _dummies >= FuelLoop.pool_capacity() + 3:
		# Everything pushed must have LANDED before the tray is measured — the pipe is real
		# now, so the last dummy is still riding it when the last push happens. Waiting on the
		# plant's own queues (nothing waiting for the mouth, nothing left on the belt) rather
		# than on a guessed duration is what stops this being a race that passes on a fast
		# machine and flakes on a slow one.
		if _main._drop_pending.is_empty() and _main._transit.is_empty():
			_phase = 2
			_settle_until = _t + SETTLE
		return
	var i := _dummies
	_dummies += 1
	var dummy := Pebble.new(900000 + i, _main.PEBBLE_RADIUS)
	dummy.burnup = Depletion.DISCHARGE_BURNUP
	dummy.temperature = 400.0 + 40.0 * float(i)
	# NOT appended to `_pushed` here — see `_sync_pushed`. It is recorded when it ARRIVES,
	# because that is when the pool has it and that is the order the pool is in.
	# Registered like a real pebble, because `_pool_push` now gives it a BODY and declares
	# it out of core. An unregistered dummy would leave `_out_of_core` holding an id with
	# no pebble behind it and walk `_core_count()` down by one per dummy — the exact drift
	# `_ship_to_cask`'s comment warns about. (It used to be safe to skip: no body, no flag,
	# no drift, and the test quit before anything read the count.)
	_main._pebbles[dummy.id] = dummy
	# THROUGH THE BELT — the pipe the plant actually discharges down (Phase 3b-i), entered at
	# the same site `main._discharge` uses. The dummy is put in the queue for the pipe's
	# mouth, `_feed_drop` lets it in when there is room, the belt drags it out to the pool,
	# and it arrives by falling in like everything else.
	#
	# IT USED TO GO THROUGH `_pool_push`, WHICH MATERIALIZED IT IN THE MOUTH AT REST — and
	# that quietly stopped being how spent fuel arrives. The two feeds do NOT build the same
	# pile: dropped from a standstill at a fixed x, pebbles heap in a narrow tower directly
	# under the mouth; delivered by the belt they arrive with ~95-150 px/s of travel and land
	# spread across the floor. So the tray's capacity is different for the two, and this test
	# was the one deciding POOL_CAP. Measured: the belt-fed pile of 8 sits with its apex
	# 5 px clear of the rim, while the same 8 dropped at rest put one pebble UP IN THE
	# CONVEYOR at y = 952. Left alone, this suite would have forced the cap down to satisfy a
	# delivery nothing performs.
	#
	# That is this project's oldest failure wearing new clothes: a test asserting the
	# MECHANISM it remembers rather than the INVARIANT it exists for. The invariant is "a
	# full tray holds its pile"; `pool_drop` was only ever how we got one. Re-point, never
	# loosen — the fix is to feed it the way the plant feeds it, not to lower the bar.
	#
	# The drip pacing below is now belt-limited rather than test-limited, and that is fine:
	# the mouth guard meters arrivals to ~4.5/s no matter how fast this pushes, so the pile
	# cannot spawn inside itself. That hazard is now the PLANT's to prevent, not the test's.
	_main._out_of_core[dummy.id] = true
	_main._drop_pending.push_back(dummy)


func _final_checks() -> void:
	# Anything the plant discharged during the settle counts too.
	_sync_pushed()
	var spent: Array = _main._spent
	var cap := FuelLoop.pool_capacity()

	# The cap holds.
	_ok(spent.size() == cap,
		"an overfull pool trims to exactly its capacity (%d)" % spent.size())
	# The overflow is CASKED, not vanished — the count the caption states.
	_ok(_main._total_shipped == _pushed.size() - cap,
		"the overflow went to a cask rather than the floor (%d shipped of %d pushed, cap %d)"
			% [_main._total_shipped, _pushed.size(), cap])

	# It keeps the NEWEST, and it keeps them IN ORDER. Checked at both ends: an off-by-one
	# that works at one end will not work at both.
	#
	# By IDENTITY now, not by color. The old form compared the tray's tints against
	# `_pebble_tint(...)` of the expected pebble, and needed a "do the colors actually
	# discriminate" guard in front of it precisely because a color is a lossy proxy for a
	# pebble — under a GRID field every tint was graphite grey and the check silently
	# compared grey to grey and passed. The pool holds the Pebbles themselves, so the
	# question can just be asked of them.
	_ok(spent[cap - 1] == _pushed[_pushed.size() - 1],
		"the pool keeps the NEWEST arrival")
	_ok(spent[0] == _pushed[_pushed.size() - cap],
		"...and its oldest is the newest-minus-capacity arrival — the oldest SURVIVOR")

	# THE CAP IS A PHYSICAL CLAIM, so check it physically. POOL_CAP says "this many pebbles
	# FIT" — and the tray has no lid and cannot have one (the discharge conveyor runs across
	# just above the rim), so a pebble that comes to rest proud of the rim can roll off and
	# fall out of the world while still counted as held. This is the check that would catch
	# POOL_CAP being raised past what the tray can actually take.
	var top := FuelLoop.POOL_FLOOR - FuelLoop.POOL_H
	var outside := []
	for peb in spent:
		var p: Vector2 = _main._physics.get_position(peb.id)
		if (p.y - peb.radius < top - 0.5 or p.x < FuelLoop.POOL_LEFT
				or p.x > FuelLoop.POOL_LEFT + FuelLoop.POOL_W or p.y > FuelLoop.POOL_FLOOR):
			outside.append("(%.0f, %.0f)" % [p.x, p.y])
	_ok(outside.is_empty(),
		"a FULL pool (%d) rests entirely inside the tray — %d proud of the rim %s"
			% [spent.size(), outside.size(), "" if outside.is_empty() else str(outside)])

	# And a full tray is still not fuel — the guard has to hold at capacity, not just at
	# the two or three pebbles a timed run happens to discharge.
	var filtered: Dictionary = _main._core_positions()
	var intruders := 0
	for peb in spent:
		if filtered.has(peb.id):
			intruders += 1
	_ok(intruders == 0,
		"...and a FULL pool still reaches the flux solve not at all (%d intruders)" % intruders)

	print("ALL CHECKS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
