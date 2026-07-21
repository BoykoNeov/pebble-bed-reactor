# tests/live_reinject.gd
#
# MANUAL / real-time integration check for RE-INJECTION — pulling a pebble back out of
# the spent pool, redesigning it, and sending it round again.
#   godot --headless --script res://tests/live_reinject.gd
#
# WHY this harness has to exist: nothing else presses re-inject. The pure suites never
# instantiate main, and every other live harness watches the cycle run ITSELF — this is
# the one player action that puts a pebble back into the fuel cycle by hand, so it is the
# one path where the population arithmetic can be got wrong with no other test noticing.
#
# FAILURE 1 — RE-INJECTION MINTS A PEBBLE THAT SHOULD NOT EXIST. This is the sharp one and
# the whole reason Phase 2a moved the pool inside `_pebbles`. The bed is pinned at a
# CALIBRATED TARGET_POPULATION, and the mint gate holds the circulating population at
# target + buffer. A returning pebble must therefore be ABSORBED — the plant mints one
# fewer to make room — not ADDED on top. Get it wrong and the core carries extra fuel: k
# shifts, headline power reads high, and every M4/M5 calibration is quietly off with
# nothing on screen to show it. The claim is that this needs no bookkeeping at all:
# leaving `_spent` raises `_inventory()`, which is the number the gate already reads, so
# the debit happens by itself. That is a strong claim and this is what tests it.
#
# FAILURE 2 — THE EDIT IS A NO-OP, or edits the wrong thing. "Burn a pebble down, tweak
# it, send it back" is the feature; a restamp that silently fails to change the design, or
# that quietly resets what the pebble has LIVED THROUGH (burnup, passes, isotopics), makes
# the pool a decoration. The second half matters as much as the first: re-injection must
# not become an un-burn button.
#
# FAILURE 3 — THE PEBBLE VANISHES OR TELEPORTS. It must leave the pool, physically ride
# its OWN riser (Phase 3b-iii — a real body, not the old fake-rider glide through the
# discharge leg backwards), and arrive — not blink into the bed and not disappear en route.
extends SceneTree

# Let the plant fill and settle, and give the discharge leg time to put real pebbles in
# the pool. Discharge runs ~1 per 16 s, so this is a handful of arrivals.
const ACT_AT := 80.0
# Queue for REINJECT's own mouth (near-instant, nothing else competes for it), climb ~920 px
# of riser at BELT_RISER (measured ~2.5 s in tests/live_reinject_riser.gd), then the same
# short chute tail RECIRC rides. Comfortably longer than any of that takes.
const ARRIVE_BY := 22.0

var _main
var _t := 0.0
var _failures := 0
var _acted := false
var _done := false

# Snapshotted from the pebble we send back, so the assertions can prove it is the SAME
# pebble that came out the other end and that its history survived the trip.
var _id := -1
var _burnup := 0.0
var _passes := 0
var _u235 := 0.0
var _pu239 := 0.0
var _poison := 0.0
var _inv_before := 0
var _core_before := 0
var _made_before := 0
var _spent_before := 0


func _init() -> void:
	print("[live reinject] pull a spent pebble back, redesign it, send it round again")
	_main = load("res://main.gd").new()
	root.add_child(_main)


func _process(delta: float) -> bool:
	_t += delta
	if not _acted and _t >= ACT_AT:
		_acted = true
		return _act()
	if _acted and not _done and _t >= ACT_AT + ARRIVE_BY:
		_done = true
		return _assert_arrived()
	return false


func _act() -> bool:
	var spent: Array = _main._spent
	if spent.is_empty():
		_ok(false, "the pool had a settled pebble to re-inject (none by %.0f s)" % _t)
		return _report()

	# Select it the way a player does — through the picker, at the pixel the pebble is
	# lying on — rather than reaching into `_spent`. The action keys operate on the
	# SELECTION, so selecting by hand here would leave the click path untested and could
	# pass while the feature is unreachable in the actual game.
	#
	# Read off the BODY, because that is where the pebble is. This used to click
	# `pool_slot(0)`, the lattice's idea of where the oldest arrival belonged; a settled
	# pebble now lies wherever the pile put it, and clicking the old slot would generally
	# select nothing at all.
	_main._pick_at(_main._physics.get_position(spent[0].id))
	_ok(_main._selected == spent[0] and _main._selected_where == "spent pool",
		"clicking a settled pebble selects it (%s)" % _main._selected_where)

	var peb: Pebble = _main._selected
	_id = peb.id
	_burnup = peb.burnup
	_passes = peb.pass_count
	_u235 = peb.u235
	_pu239 = peb.pu239
	_poison = peb.poison
	_inv_before = _main._inventory()
	_core_before = _main._core_count()
	_made_before = _main._total_injected
	_spent_before = spent.size()
	print("  chose #%d: burnup %.1f  passes %d  r %.2f  loading %.2f"
		% [_id, _burnup, _passes, peb.radius, peb.fuel_loading])

	# --- The edit ---
	#
	# Drive the DESIGN levers to something clearly different, then restamp. Both are the
	# real player path (_set_radius / _set_loading are what the keys call).
	var old_r: float = peb.radius
	var old_load: float = peb.fuel_loading
	_main._set_radius(old_r + 1.5)
	_main._set_loading(old_load - 0.25)
	# Guard the guard: if the levers clamped to where they already were, every check below
	# would pass on a restamp that changed nothing.
	_ok(not is_equal_approx(_main._pebble_radius, old_r)
			and not is_equal_approx(_main._fuel_loading, old_load),
		"the design levers actually moved (r %.2f -> %.2f, loading %.2f -> %.2f)"
			% [old_r, _main._pebble_radius, old_load, _main._fuel_loading])
	_main._restamp_selected()
	_ok(is_equal_approx(peb.radius, _main._pebble_radius)
			and is_equal_approx(peb.fuel_loading, _main._fuel_loading),
		"restamp applies the CURRENT design to the pebble (r %.2f, loading %.2f)"
			% [peb.radius, peb.fuel_loading])

	# FAILURE 2's second half: the redesign must not un-burn it. A pebble's history is not
	# a design field — re-injection is emphatically not a reset button.
	_ok(is_equal_approx(peb.burnup, _burnup) and peb.pass_count == _passes,
		"...and does NOT touch what it has lived through (burnup %.1f, passes %d)"
			% [peb.burnup, peb.pass_count])
	_ok(is_equal_approx(peb.u235, _u235) and is_equal_approx(peb.pu239, _pu239)
			and is_equal_approx(peb.poison, _poison),
		"...nor its isotopics — a restamp is not an enrichment (U-235 %.4f, Pu-239 %.4f)"
			% [peb.u235, peb.pu239])

	# --- The re-injection ---
	_main._reinject_selected()
	_ok(_main._spent.size() == _spent_before - 1,
		"the pebble left the pool (%d -> %d)" % [_spent_before, _main._spent.size()])
	_ok(not _main._spent.has(peb), "...and is no longer pooled")
	_ok(_main._pebbles.has(_id), "...but is STILL in the registry — it was never destroyed")
	_ok(_main._out_of_core.has(_id),
		"...and is still flagged out of core: riding is not being in the bed")
	# Phase 3b-iii: it is neither a rider nor a bed body the instant `_reinject_selected`
	# returns — it is queued for its OWN riser's mouth, the same bodiless wait a discharge
	# or recirculating pebble takes at the shared drop's. Checking `rider_position` here
	# would test the OLD mechanism (immediate glide); this checks the new one's first step.
	_ok(_main._reinject_pending.has(peb),
		"it is queued at REINJECT's own mouth — not yet a body, not a rider, not in the bed")
	_ok(_main._total_reinjected == 1, "the re-injection is counted (%d)" % _main._total_reinjected)

	# FAILURE 1, the calibration claim. Leaving the pool puts it back in the circulating
	# population THE SAME INSTANT — that is the whole self-accounting mechanism.
	_ok(_main._inventory() == _inv_before + 1,
		"the returning pebble is back in the circulating population at once (%d -> %d)"
			% [_inv_before, _main._inventory()])
	# ...and it is ABSORBED, not added: the discharge that put it in the pool already
	# opened a fresh-fuel slot, so the gate must now decline to mint into it.
	_ok(_main._core_count() == _core_before,
		"the bed is untouched by the re-injection itself (%d)" % _main._core_count())
	return false


func _assert_arrived() -> bool:
	# FAILURE 3: it must have completed the ride. `rider_position == INF` alone is ambiguous
	# now (Phase 3b-iii) — it is also true while the pebble is still CLIMBING its own riser as
	# a real body, not yet a rider at all. The specific claim is that it landed: no longer
	# `_out_of_core`, which only happens on a genuine bed arrival (`_spawn_from_queue`).
	_ok(_main._loop.rider_position(_id) == Vector2.INF,
		"the re-injected pebble finished its ride (it is off the machine)")
	_ok(not _main._out_of_core.has(_id),
		"...and actually LANDED — it is fuel in the bed again, not still climbing or queued")
	_ok(not _main._transit.has(_id) and not _main._reinject_pending.has(_main._pebbles.get(_id)),
		"...off REINJECT's riser and its mouth queue for good")
	_ok(_main._pebbles.has(_id), "...and still exists (%d)" % _id)

	var peb: Pebble = _main._pebbles[_id]
	_ok(is_equal_approx(peb.burnup, _burnup) or peb.burnup > _burnup,
		"its burnup survived the trip and only ever grew (%.1f -> %.1f)" % [_burnup, peb.burnup])

	# THE HEADLINE. The bed is back at its calibrated population and the plant minted one
	# FEWER pebble than it otherwise would have — the returning pebble took the slot.
	# Checked against `TARGET_POPULATION` rather than a delta so a drifting bed cannot hide
	# inside a self-consistent pair of numbers.
	_ok(_main._core_count() == _main.TARGET_POPULATION,
		"the bed is STILL pinned at its calibrated population (%d / %d) — re-injection did not add fuel"
			% [_main._core_count(), _main.TARGET_POPULATION])
	_ok(_main._inventory() == _main.TARGET_POPULATION + _main.LOOP_BUFFER,
		"the circulating population is still target + buffer (%d)" % _main._inventory())

	# The self-debit, stated as the thing a player would notice. Over this window the plant
	# would normally mint one replacement per discharge; having taken one back by hand, it
	# must have minted at least one fewer than it discharged.
	var minted: int = _main._total_injected - _made_before
	print("  over the ride: minted %d, discharged %d, re-injected %d"
		% [minted, _main._total_extracted, _main._total_reinjected])

	# Accounting closes: everything ever discharged is held, casked, or was sent back.
	_ok(_main._spent.size() + _main._total_shipped + _main._total_reinjected
			== _main._total_extracted,
		"every discharged pebble is held, casked or re-injected (%d + %d + %d == %d)"
			% [_main._spent.size(), _main._total_shipped, _main._total_reinjected,
				_main._total_extracted])
	# And the registry still balances against the mint count (live_fuel_loop's invariant 3,
	# re-checked HERE because re-injection is the one operation that moves a pebble between
	# lists without minting or destroying it — the case most likely to double-count).
	_ok(_main._total_injected == _main._pebbles.size() + _main._total_shipped,
		"every pebble ever made is still accounted for (made %d, registry %d + casked %d)"
			% [_main._total_injected, _main._pebbles.size(), _main._total_shipped])
	return _report()


func _ok(ok: bool, what: String) -> void:
	if ok:
		print("  PASS  %s" % what)
	else:
		print("  FAIL  %s" % what)
		_failures += 1


func _report() -> bool:
	print("ALL CHECKS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
	return true
