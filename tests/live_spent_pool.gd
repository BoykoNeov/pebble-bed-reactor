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
# settled pebble ever got a physics body, homogenize() would read it through
# positions() and blend the spent pool into the flux solve as core fuel, quietly
# shifting k. The test asserts the hazard is real (the slots ARE in-grid) and that the
# pool is nonetheless invisible to the physics — otherwise the guard is untestable and
# the next person "optimizes" the bodiless pile into real bodies.
#
# FAILURE 2 — the pool perturbs the fuel cycle's arithmetic. Catching a Pebble on its
# way out must not change what leaving MEANS: discharge is still the only thing that
# shrinks the inventory and so the only thing that opens a fresh-fuel slot. If a spent
# pebble kept its slot in `_pebbles`, it would hold the mint gate closed
# (`_pebbles.size() < TARGET_POPULATION + LOOP_BUFFER`) and the bed would starve —
# the exact silent-k-shift class of bug LOOP_BUFFER exists to prevent.
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

	# 4. ...and yet nothing physical is there. No body may sit on a pool slot.
	var positions: Dictionary = _main._physics.positions()
	var intruders := 0
	for id in positions:
		var p: Vector2 = positions[id]
		for i in cap:
			if p.distance_to(FuelLoop.pool_slot(i)) < FuelLoop.PEBBLE_R:
				intruders += 1
				break
	_ok(intruders == 0,
		"no physics body sits in the pool (%d intruders) — it cannot reach the flux" % intruders)

	# 5. A settled pebble is out of the inventory entirely: no body, no rider, no slot.
	var still_held := 0
	for peb in spent:
		if _main._pebbles.has(peb.id):
			still_held += 1
	_ok(still_held == 0,
		"settled pebbles are out of the inventory (%d still held)" % still_held)

	# 6. The fuel cycle's arithmetic is untouched — the calibration-neutrality claim.
	_ok(_main._pebbles.size() == _main.TARGET_POPULATION + _main.LOOP_BUFFER,
		"inventory still target + buffer (%d)" % _main._pebbles.size())
	_ok(_main._core_count() == _main.TARGET_POPULATION,
		"bed still pinned at its calibrated population (%d)" % _main._core_count())

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
