# tests/live_inspector.gd
#
# Integration check for the read-only pebble INSPECTOR.
#   godot --headless --script res://tests/live_inspector.gd
#
# WHY: picking lives in main.gd + game/, so the pure suites cannot see it. The failure
# it guards is quiet rather than loud — a click that selects the WRONG pebble still
# fills the panel with a plausible-looking pebble, and nothing crashes. The pool used to
# be the sharp edge (it drew a WINDOW of the newest arrivals into fixed slots, so an
# off-by-one in the index read as "the inspector works" while reporting a neighbour's
# composition); settled pebbles are bodies now and are picked at their own positions, so
# that edge is gone and what is left to check is that the click reaches them at all.
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
	# Picked out of `_core_positions()`, not the raw body list. Every body used to be a bed
	# pebble, so the raw list was the same thing; the spent pool is bodied now, so reaching
	# into the middle of the raw list can hand back a pebble sitting in the TRAY and this
	# would fail on "core bed" while the inspector was working perfectly.
	var positions: Dictionary = _main._core_positions()
	var bed_id: int = positions.keys()[positions.size() / 2]
	var bed_at: Vector2 = positions[bed_id]
	_main._pick_at(bed_at)
	_ok(_main._selected != null and _main._selected.id == bed_id,
		"clicking a bed pebble selects THAT pebble (#%d)" % bed_id)
	_ok(_main._selected_where == "core bed", "...and reports where it is (%s)" % _main._selected_where)
	# The ring must track the pebble, not a stale position — the bed is flowing.
	_ok(_main._selected_pos().distance_to(bed_at) < 1.0,
		"the selection ring resolves to the pebble's live position")

	# --- The spent pool: clicking a settled pebble must select THAT pebble ---
	#
	# THIS USED TO BE "the window-offset trap", then "the slot-index trap", and now it is
	# neither — which is the point. A settled pebble is a BODY: the picker finds it at its
	# own position, by the same nearest-hit search that finds a bed pebble, so there is no
	# index to be off by and no second layout to disagree with the renderer. The bug class
	# this section was written to guard stopped existing rather than being supervised.
	#
	# It also stopped needing to manufacture the situation. The old form pushed cap+4 dummy
	# pebbles in one frame to force a full tray; done now, all of them would spawn inside
	# one another at the pipe mouth and the solver would scatter the pile, so clicking "the
	# newest" would be clicking into a heap of overlapping bodies. The real pool the
	# reactor has produced by 80 s is a better subject than any dummy — those pebbles fell
	# down a real pipe and settled where physics put them. The cap itself is gated where it
	# belongs, in live_spent_pool.gd, which fills the tray on the clock and measures the fit.
	#
	# The HAZARD is unchanged and still guarded: a click must select the pebble the player
	# sees at that pixel. Both ends of the pile are checked, because a mis-pick that happens
	# to work for one pebble will not work for both.
	var pool: Array = _main._spent
	if pool.size() < 2:
		_ok(false, "the pool had settled pebbles to click (%d by %.0f s)" % [pool.size(), _t])
	else:
		var oldest: Pebble = pool[0]
		var newest: Pebble = pool[pool.size() - 1]
		var at_old: Vector2 = _main._physics.get_position(oldest.id)
		var at_new: Vector2 = _main._physics.get_position(newest.id)
		# Guard the guard: two pebbles resting in the same place would make "clicked the
		# right one" unfalsifiable. They are solid bodies, so they cannot — but if the pile
		# were ever spawned overlapping (see above) this is what would say so.
		_ok(at_old.distance_to(at_new) > FuelLoop.PEBBLE_R,
			"the pile's oldest and newest rest apart (%.0f px) — a click can tell them apart"
				% at_old.distance_to(at_new))
		_main._pick_at(at_old)
		_ok(_main._selected == oldest,
			"clicking the oldest settled pebble selects it (#%d)" % oldest.id)
		_ok(_main._selected_where == "spent pool", "...and reports the pool (%s)" % _main._selected_where)
		_ok(_main._selected_pos().distance_to(at_old) < 1.0,
			"a settled pebble's ring lands on the pebble itself")
		_main._pick_at(at_new)
		_ok(_main._selected == newest,
			"clicking the newest settled pebble selects it (#%d)" % newest.id)
		_ok(_main._selected_where == "spent pool", "...and reports the pool too (%s)" % _main._selected_where)

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
