# tests/live_inspector.gd
#
# Integration check for the read-only pebble INSPECTOR.
#   godot --headless --script res://tests/live_inspector.gd
#
# WHY: picking lives in main.gd + game/, so the pure suites cannot see it. The failure
# it guards is quiet rather than loud — a click that selects the WRONG pebble still
# fills the panel with a plausible-looking pebble, and nothing crashes. The pool is
# the sharp edge: it draws a WINDOW of the newest arrivals, so its slot index is not
# an index into main._spent, and an off-by-one there reads as "the inspector works"
# while reporting a neighbour's composition.
#
# Also guards the property the inspector's whole design rests on: it is a pure
# CONSUMER (CLAUDE.md — visualization never writes back). Selecting a pebble must not
# perturb the pebble, the inventory, or the bed.
extends SceneTree

const ASSERT_AT := 80.0    # discharges are flowing by ~70 s, so the pool is populated

var _main
var _t := 0.0
var _failures := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	print("[live inspector] a click must select the pebble under it — and change nothing")


func _ok(pass_: bool, msg: String) -> void:
	print("  %s  %s" % ["PASS" if pass_ else "FAIL", msg])
	if not pass_:
		_failures += 1


func _process(delta: float) -> bool:
	_t += delta
	if _t < ASSERT_AT:
		return false

	# --- A bed pebble ---
	var positions: Dictionary = _main._physics.positions()
	var bed_id: int = positions.keys()[positions.size() / 2]
	var bed_at: Vector2 = positions[bed_id]
	_main._pick_at(bed_at)
	_ok(_main._selected != null and _main._selected.id == bed_id,
		"clicking a bed pebble selects THAT pebble (#%d)" % bed_id)
	_ok(_main._selected_where == "core bed", "...and reports where it is (%s)" % _main._selected_where)
	# The ring must track the pebble, not a stale position — the bed is flowing.
	_ok(_main._selected_pos().distance_to(bed_at) < 1.0,
		"the selection ring resolves to the pebble's live position")

	# --- The spent pool: clicking a slot must select the pebble drawn in it ---
	#
	# THIS USED TO BE "the window-offset trap", and the rewrite is the point. The pool is
	# now CAPPED at what the tray draws (main._pool_push), so the window it guarded cannot
	# arise: `from = maxi(0, _spent.size() - cap)` is identically zero once the cap holds,
	# and slot i IS _spent[i]. The old test manufactured `from > 0` by pushing dummies
	# straight onto `_spent`, BYPASSING the cap — so keeping it would mean asserting an
	# offset that only exists when the test itself breaks the invariant. That is guarding
	# the MECHANISM instead of the claim, the same trap live_spent_pool and live_fuel_loop
	# each had to be re-pointed out of.
	#
	# The HAZARD is unchanged and still guarded: a click must select the pebble the player
	# sees at that pixel. Both ends of the tray are checked, because an off-by-one that
	# happens to work at one end will not work at both.
	var cap := FuelLoop.pool_capacity()
	# Fill THROUGH the real push site, and overfill it: the cap is what makes the offset
	# vanish, so it has to be exercised here rather than assumed. Pushing past the tray is
	# now a test of the cap, not a way to sneak past it.
	for i in cap + 4:
		var dummy := Pebble.new(800000 + i, _main.PEBBLE_RADIUS)
		dummy.burnup = Depletion.DISCHARGE_BURNUP
		_main._pool_push(dummy)
	_main._refresh_pool()
	_ok(_main._spent.size() == cap,
		"the pool is capped at the tray, so every pooled pebble is on screen (%d == %d)"
			% [_main._spent.size(), cap])
	var shown: int = _main._loop._pool_tints.size()
	_ok(shown == _main._spent.size(),
		"the tray draws the WHOLE pool — no pebble is retained but unreachable (%d drawn, %d held)"
			% [shown, _main._spent.size()])
	if shown > 0:
		var newest_slot := shown - 1
		_main._pick_at(FuelLoop.pool_slot(newest_slot))
		_ok(_main._selected == _main._spent[newest_slot],
			"clicking the pool's newest slot selects the newest settled pebble")
		_ok(_main._selected_where == "spent pool", "...and reports the pool (%s)" % _main._selected_where)
		_main._pick_at(FuelLoop.pool_slot(0))
		_ok(_main._selected == _main._spent[0],
			"clicking the pool's first slot selects the oldest settled pebble")
		_ok(_main._selected_pos().distance_to(FuelLoop.pool_slot(0)) < 1.0,
			"a settled pebble's ring lands on its slot")
	else:
		_ok(false, "the pool had settled pebbles to click (none by %.0f s)" % _t)

	# --- A rider ---
	if _main._loop.count() > 0:
		var r: Dictionary = _main._loop._riders[0]
		var rp: Vector2 = _main._loop.rider_position(r["id"])
		_main._pick_at(rp)
		_ok(_main._selected != null and _main._selected.id == r["id"],
			"clicking a pebble riding the machine selects it (#%d)" % r["id"])
	else:
		print("  (no rider in flight at the assert moment — rider pick not exercised)")

	# --- The panel actually RENDERS ---
	#
	# Added after the panel threw "unsupported format character" every frame (GDScript's
	# % operator has no %e) and this suite still went green: every check above is about
	# WHICH pebble is selected, and none of them ever read the text the inspector exists
	# to produce. A readout that silently fails to format is the whole feature failing.
	_main._pick_at(bed_at)
	_main._update_inspector()
	var txt: String = _main._inspector.text
	var peb0: Pebble = _main._pebbles[bed_id]
	for want in ["#%d" % bed_id, "Xe-135", "burnup", "U-235", "fissile", "passes"]:
		_ok(txt.contains(want), "the panel reports '%s'" % want)
	_ok(txt.contains("%.0f K" % peb0.temperature),
		"the panel reports the pebble's real temperature (%.0f K)" % peb0.temperature)
	# No unformatted placeholder may survive. This is the check with teeth, and the
	# substring checks above are NOT a substitute: a failed `%` in GDScript pushes an
	# error and returns the FORMAT STRING UNCHANGED, so a broken "Xe-135 %.2e" row still
	# contains "Xe-135" and every check above passes while the panel shows raw
	# specifiers. Verified: this is the only assertion that fails when %e is restored.
	_ok(not txt.contains("%."),
		"no unformatted placeholder survives in the panel (a failed %% returns the format string)")
	# ...and no raw full-precision dump either. The %e fix above traded a format ERROR for
	# a legibility one: String.num_scientific(3.58e-5) prints "3.584744868790257e-05", which
	# every check above happily passes — it is a valid string containing "Xe-135". Only the
	# GPU capture caught it. This is the generic form of that bug: every quantity here is
	# formatted to a fixed few decimals, so a long digit run means someone interpolated a
	# float raw. Guards the whole panel, not just the one row that bit.
	var longest := 0
	for run in RegEx.create_from_string("\\d+").search_all(txt):
		longest = maxi(longest, run.get_string().length())
	_ok(longest <= 8, "no full-precision float dump in the panel (longest digit run = %d)" % longest)

	# --- Empty space clears ---
	_main._pick_at(Vector2(20.0, 1070.0))
	_ok(_main._selected == null, "clicking empty space clears the selection")
	_main._update_inspector()
	_ok(_main._inspector.text.contains("click any pebble"),
		"with nothing selected the panel says what to do")

	# --- READ-ONLY: selecting must not perturb anything ---
	# Snapshot a bed pebble, then hammer picking across the whole scene and re-check.
	# Compared against the SAME pebble object, so any write through the inspector path
	# shows up. No pause needed, and that is the point: this loop runs synchronously
	# inside one _process call, so main._physics_process cannot interleave and evolve
	# the pebble between the two snapshots. Any difference is the inspector's doing.
	var peb: Pebble = _main._pebbles[bed_id]
	var before := [peb.radius, peb.burnup, peb.temperature, peb.u235, peb.u238,
		peb.pu239, peb.poison, peb.xe135, peb.pass_count, peb.fuel_loading]
	# Explicitly typed: _main is a Variant here, so `:=` cannot infer from it.
	var inv: int = _main._pebbles.size()
	var core: int = _main._core_count()
	var spent: int = _main._spent.size()
	for i in 200:
		_main._pick_at(Vector2(float(400 + (i * 37) % 700), float(100 + (i * 53) % 900)))
	var after := [peb.radius, peb.burnup, peb.temperature, peb.u235, peb.u238,
		peb.pu239, peb.poison, peb.xe135, peb.pass_count, peb.fuel_loading]
	_ok(before == after, "200 picks did not touch the pebble's state (read-only)")
	_ok(_main._pebbles.size() == inv and _main._core_count() == core
			and _main._spent.size() == spent,
		"200 picks did not touch the inventory (%d), the bed (%d) or the pool (%d)"
			% [inv, core, spent])

	print("ALL CHECKS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
	return true
