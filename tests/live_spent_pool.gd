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
# spans x ∈ [424, 1036], y ∈ [-16, 1072] (Grid.for_silo). So a pool slot lands in a
# VALID grid cell, not outside the grid — cell_of() returns a real index there. If a
# settled pebble reached homogenize(), the spent pool would blend into the flux solve as
# core fuel, quietly shifting k. The test asserts the hazard is real (the slots ARE
# in-grid) and that the pool is nonetheless absent from the flux solve's input —
# otherwise the guard is untestable.
#
# WHAT THIS TEST IS CAREFUL *NOT* TO FORBID. The guard is "the pool is not fuel", which
# is a claim about the NEUTRONICS. It is not "the pool has no physics bodies" — that was
# only the mechanism that enforced it while the pool was static art, and this test used
# to assert the mechanism, which quietly made it a veto on giving pool pebbles bodies at
# all. They now need bodies: pebbles must collide under the same rules everywhere in the
# sim, and a pebble must be re-injectable out of the pool. So check 4 reads the flux
# solve's real input (main._core_positions()) rather than the body list. Membership in
# the bed is DECLARED (main._out_of_core), never inferred from whether the engine happens
# to be holding a body — see the rationale on main._core_positions().
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

var _main
var _t := 0.0
var _failures := 0
var _peak_spent := 0


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

	# 3. THE HAZARD IS REAL — a pool slot is inside the grid, so a body there would be
	#    homogenized. Asserted first, because check 4 is meaningless without it.
	var grid := Grid.for_silo()
	var in_grid := 0
	for i in cap:
		if grid.cell_of(FuelLoop.pool_slot(i)) != -1:
			in_grid += 1
	_ok(in_grid == cap,
		"pool slots sit in VALID grid cells (%d/%d) — a body here WOULD become fuel"
			% [in_grid, cap])

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
	var positions: Dictionary = _main._core_positions()
	var intruders := 0
	for id in positions:
		var p: Vector2 = positions[id]
		for i in cap:
			if p.distance_to(FuelLoop.pool_slot(i)) < FuelLoop.PEBBLE_R:
				intruders += 1
				break
	_ok(intruders == 0,
		"nothing in the pool reaches the flux solve (%d intruders in homogenize input)"
			% intruders)

	# 4b. GUARD THE GUARD. Check 4 above passes right now for a reason that has nothing to
	#     do with the filter: there are no bodies in the pool AT ALL yet, so an unfiltered
	#     read would pass it too. Green there proves nothing until pool pebbles are bodied.
	#     So force the situation the filter exists for — park a real body on a pool slot,
	#     declared out-of-core — and prove the boundary discriminates rather than trusting
	#     that it will when it finally matters.
	#
	#     This is also the clearest statement of what the swap bought: at this instant the
	#     OLD assertion ("no body sits in the pool") FAILS and the new one PASSES. A body
	#     is present; it is simply not fuel. That gap is exactly the freedom Phase 3 needs.
	var ghost_id := 999001
	_main._physics.spawn_pebble(ghost_id, FuelLoop.pool_slot(0), FuelLoop.PEBBLE_R)
	_main._out_of_core[ghost_id] = true
	var raw: Dictionary = _main._physics.positions()
	var filtered: Dictionary = _main._core_positions()
	# The hazard is LIVE: the engine really is holding a body on a pool slot...
	_ok(raw.has(ghost_id),
		"a body parked on a pool slot IS visible to the physics — the guard has something to catch")
	# ...and the coupling boundary refuses it anyway. This is the check that can fail.
	_ok(not filtered.has(ghost_id),
		"a bodied, out-of-core pebble is EXCLUDED from the flux solve's input")
	# And it removes ONLY that one — the filter must not be over-eager and quietly drop
	# real bed pebbles out of the solve, which would shift k in the opposite direction
	# and is just as silent. Exactly one body is out-of-core (the ghost), because every
	# other out-of-core pebble is riding the machine with no body at all.
	_ok(filtered.size() == raw.size() - 1,
		"the filter removes ONLY the ghost (%d -> %d) — no bed pebble is dropped"
			% [raw.size(), filtered.size()])
	_main._physics.remove_pebble(ghost_id)
	_main._out_of_core.erase(ghost_id)

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

	# 7. The capped VIEW is honest: it shows what fits and reports the true total.
	var shown: int = _main._loop._pool_tints.size()
	_ok(shown == mini(spent.size(), cap),
		"pool shows what fits and no more (%d shown, %d settled, cap %d)"
			% [shown, spent.size(), cap])
	_ok(_main._loop._pool_total == spent.size(),
		"pool reports the TRUE total, not the shown count (%d)" % _main._loop._pool_total)
	# 8. OVERFLOW, forced rather than waited for. Real discharge runs ~1 per 16 s, so a
	#    21-slot pool takes ~6 minutes to fill and a timed test would never reach the
	#    cap — leaving the window logic (the part that can actually be wrong) unproven.
	#    So overfill it directly and check the pool keeps the NEWEST arrivals: showing
	#    the oldest would freeze the pile and read as "discharge stopped", which is the
	#    misreading the whole capped-view design exists to avoid.
	#    Select a PEBBLE field FIRST. Without this the check is vacuous and silently so:
	#    the default field is flux, a GRID field, so _pebble_tint returns graphite grey
	#    for every pebble and "newest == oldest" compares grey to grey and passes. Found
	#    by falsifying this test (forcing the window to the oldest) and watching this
	#    assertion still pass. Driven through _cycle_field, not by poking _current_field,
	#    so the field's own display path runs (the trap live_render_capture.gd documents).
	while _main._fields[_main._current_field]["desc"].world != FieldDescriptor.PEBBLE:
		_main._cycle_field()
	#    KEEP THIS LAST. These dummies are pushed straight into `_spent` without ever being
	#    registered in `_pebbles`, which is a state the real fuel cycle cannot produce and
	#    which makes `_inventory()` under-count by cap+3 (it subtracts the whole pool). That
	#    is harmless only because the test quits a few lines below, before the mint gate
	#    reads it again — so any new check that needs a coherent inventory goes ABOVE here.
	var before := spent.size()
	for i in cap + 3:
		var dummy := Pebble.new(900000 + i, _main.PEBBLE_RADIUS)
		# Spread across the field's range so neighbours get DISTINGUISHABLE colors — two
		# pebbles that happen to share a color would make the window check vacuous again.
		dummy.burnup = Depletion.DISCHARGE_BURNUP * float(i) / float(cap + 3)
		dummy.temperature = 400.0 + 40.0 * float(i)
		dummy.xe135 = 1.0e-6 * float(i)
		spent.push_back(dummy)
	_main._refresh_pool()
	_ok(_main._loop._pool_tints.size() == cap,
		"an overfull pool still shows exactly its capacity (%d)" % _main._loop._pool_tints.size())
	_ok(_main._loop._pool_total == before + cap + 3,
		"an overfull pool still reports the true total (%d)" % _main._loop._pool_total)
	# Guard the guard: if every slot were the same color the two checks below would pass
	# no matter which window the pool kept. Prove the colors actually discriminate first.
	var distinct := {}
	for c in _main._loop._pool_tints:
		distinct[c] = true
	_ok(distinct.size() > 1,
		"pool colors discriminate between pebbles (%d distinct) — the checks below can bite"
			% distinct.size())
	# The last slot must be the last pebble that arrived — i.e. the window is the NEWEST.
	_ok(_main._loop._pool_tints[cap - 1] == _main._pebble_tint(spent[spent.size() - 1]),
		"the pool keeps the NEWEST arrivals, not the oldest")
	_ok(_main._loop._pool_tints[0] == _main._pebble_tint(spent[spent.size() - cap]),
		"the pool's window STARTS at the newest-minus-capacity arrival")

	print("ALL CHECKS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
	return true
