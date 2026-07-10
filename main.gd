# main.gd
#
# Orchestrates the two-world coupling loop (CLAUDE.md). M0 built the mechanical
# world (inject → granular flow → metered discharge). M1 adds neutronics:
#
#   Box2D-ish positions + per-pebble state
#         │  homogenize (grid.gd)
#         ▼
#   coarse-grid macroscopic cross-sections
#         │  quasi-static diffusion solve (neutronics.gd)
#         ▼
#   flux field φ + k-eff  ──►  heatmap + readout, sampled back onto pebbles
#
# M1 is strictly ONE-DIRECTIONAL: the flux is computed, shown, and stored on
# each pebble (for M3 burnup / per-pebble viz), but it feeds back into NOTHING —
# no cross-section change, no motion. Feedback is M2.
#
# The flux is CLOCKLESS (CLAUDE.md principle 1-2): it equilibrates far faster
# than anything mechanical, so we solve it fresh at steady state on a modest
# cadence rather than time-marching it or solving every frame.
extends Node2D

const TARGET_POPULATION := 380  # keep the silo full enough to show bed flow
const SPAWN_PER_TICK := 3
const SPAWN_INTERVAL := 0.12    # seconds between injection ticks
const PEBBLE_RADIUS := 8.0
const EXTRACT_INTERVAL := 0.30  # metered discharge cadence (lowest pebble out)
const SOLVE_INTERVAL := 0.50    # neutronics re-solve cadence (quasi-static)

# Player enrichment lever (M2). Kept LEU and well under 20% (CLAUDE.md: civilian
# teaching toy). Small step because enrichment is a steep reactivity lever and
# Doppler is a weak fine feedback — a few tenths of a percent already moves k ~1%.
const ENRICH_MIN := 0.050
const ENRICH_MAX := 0.120
# The M3 operating point. WHY higher than M1/M2's 8.5% reference: the M3 core runs
# a burnup SPREAD (fresh at 0 → spent at ~90), not fresh fuel, and that equilibrium
# MIX is what must sit critical — so fresh fuel has to be genuinely supercritical.
# The lattice sweep (tests/test_depletion.gd) puts the mix critical at ~11.0%, but
# the settled funnel bed reads ~2% lower k than that idealized lattice, so the LIVE
# equilibrium needs a hair more to sit comfortably supercritical (cold-k ~1.015) and
# let Doppler — not the on/off subcritical gate — do the fine regulation. 11.4% is
# tuned to the live bed (like TIME_ACCEL). Push up with ] toward over-temp (Doppler
# runs out of hold → needs rods, M5); down toward passive shutdown.
#
# The core then SELF-STABILIZES to its critical equilibrium: burnup self-regulation
# (a strong slow negative feedback) drives k_cold toward ~1 by settling the bed's
# average burnup, while Doppler holds the small residual excess. 11.3% lands that
# equilibrium slightly supercritical (reg=true, self-regulating) at a comfortable
# temperature, after a brief hotter startup transient as the seeded bed settles.
const ENRICH_DEFAULT := 0.113
# Fine step: enrichment is a steep reactivity lever, so a coarse step would jump
# straight from self-regulating to over-temp and hide the "flat reactivity, rising
# power" behavior (a CLAUDE.md validation target). Small steps show the core climb
# through several regulating states — power/temperature up, k pinned ~1 — first.
const ENRICH_STEP := 0.0005
# Above this equilibrium fuel temperature the toy calls the core "over-temp": the
# point where Doppler alone stops being a safe hold (real cores use control rods
# for that excess — M5). ~1800 K ≈ 1500 °C, near the TRISO integrity limit.
const OVER_TEMP_K := 1800.0
# A core AT online-refueling equilibrium is critical: k_cold → 1 by definition, so
# it hovers at 1.0 ± a hair and the strict k_cold>1 test flickers. Treat anything
# within this band of 1 as "critical / self-regulating"; only a core clearly below
# it (e.g. enrichment dialed down for the passive-shutdown demo, k ~ 0.6) reads as
# genuinely subcritical / shutting down. Display-only — the depletion gate is untouched.
const CRIT_BAND := 0.01

var _physics: PhysicsBackend
var _pebbles: Dictionary = {}   # id -> Pebble (the Lagrangian registry)
var _rng := RandomNumberGenerator.new()
var _next_id := 0
var _spawn_accum := 0.0
var _extract_accum := 0.0
var _solve_accum := 0.0

# The campaign (burnup) clock (M3). Its campaign_dt drives depletion and NOTHING
# else — never the physics step or the flux solve (CLAUDE.md principle 1).
var _clocks := Clocks.new()

# Neutronics / visualization (M1)
var _grid: Grid
var _field_display: FieldDisplay
var _color_bar: ColorBar
var _flux_desc: FieldDescriptor
var _temp_desc: FieldDescriptor        # M2 fuel-temperature heatmap
var _k_eff := 0.0
var _power := 0.0        # relative fission power (a.u.); becomes real MW at M4
var _solve_iters := 0

# Field switching: keep the latest solved arrays so the player can flip the
# heatmap between fields (V) without waiting for the next solve.
var _fields: Array = []   # [ {desc, get: Callable -> PackedFloat32Array}, ... ]
var _current_field := 0
var _last_flux: PackedFloat32Array = PackedFloat32Array()
var _last_temp: PackedFloat32Array = PackedFloat32Array()

# Doppler feedback (M2): closes the loop so the reactor self-regulates.
var _feedback_on := true
var _enrichment := ENRICH_DEFAULT
var _k_cold := 0.0            # k with feedback OFF — the reactivity being suppressed
var _peak_temp := Feedback.T_REF
var _regulated := false
var _feedback_insufficient := false

# Burnup / outflow (M3)
var _burnup_desc: FieldDescriptor      # first PEBBLE-world (Lagrangian) field
var _total_recirculated := 0           # pebbles sent back for another pass
# Running outflow composition of DISCHARGED pebbles (the "inspect the spent fuel"
# goal). Sums → averages; plus the most recent discharge for an at-a-glance read.
var _out_count := 0
var _out_burnup_sum := 0.0
var _out_passes_sum := 0
var _out_fissile_sum := 0.0
var _out_pu_sum := 0.0
var _out_poison_sum := 0.0
var _last_out_burnup := 0.0
var _last_out_passes := 0
var _last_out_fissile := 0.0

# Readouts
var _total_injected := 0
var _total_extracted := 0
var _label: Label


func _ready() -> void:
	# Fixes the injection x-positions, NOT the settled pile: Godot native physics
	# is not deterministic (CLAUDE.md), so the pack differs run-to-run regardless.
	_rng.seed = 12345

	# Choose the backend here and nowhere else. Swapping engines is a one-line
	# change (see game/physics/physics_backend.gd).
	_physics = GodotPhysicsBackend.new()
	_physics.setup(self)

	for seg in Silo.wall_segments():
		_physics.add_static_segment(seg[0], seg[1])

	# The coarse neutronics mesh over the silo + reflector band.
	_grid = Grid.for_silo()

	# Field heatmap goes in first so it renders BEHIND the pebbles (background
	# field, pebbles on top — the two-worlds-at-once view).
	_field_display = FieldDisplay.new()
	add_child(_field_display)

	# Flux is normalized to peak = 1 by the solver, so a fixed [0, 1] linear
	# range is naturally stable frame-to-frame (CLAUDE.md: no per-frame
	# auto-ranging). It stays within one order of magnitude, so no log needed.
	_flux_desc = FieldDescriptor.new("Neutron flux", "norm", FieldDescriptor.GRID, 0.0, 1.0, false)
	# Fuel temperature (M2). Fixed range from inlet to the over-temp line so the
	# scale is stable across transients (CLAUDE.md); hotter cells clamp to the top.
	_temp_desc = FieldDescriptor.new("Fuel temperature", "K", FieldDescriptor.GRID, Feedback.T_REF, OVER_TEMP_K, false)
	# Burnup (M3) — the FIRST per-pebble (Lagrangian) field: each pebble colored by
	# its own burnup, so you can literally watch a burned pebble descend the bed
	# (CLAUDE.md two render modes). Fixed range [0, discharge] keeps the scale stable.
	_burnup_desc = FieldDescriptor.new("Burnup", "MWd/kgHM", FieldDescriptor.PEBBLE, 0.0, Depletion.DISCHARGE_BURNUP, false)

	# Field registry: each entry pairs a descriptor with a getter for its latest
	# values. GRID fields expose `get` → a per-cell array; PEBBLE fields expose
	# `get_peb` → a scalar per pebble. Adding a field (coolant temp at M4) is one
	# more entry, not new render code.
	_fields = [
		{"desc": _flux_desc, "get": func() -> PackedFloat32Array: return _last_flux},
		{"desc": _temp_desc, "get": func() -> PackedFloat32Array: return _last_temp},
		{"desc": _burnup_desc, "get_peb": func(peb: Pebble) -> float: return peb.burnup},
	]

	_build_hud()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(12, 10)
	_label.add_theme_font_size_override("font_size", 16)
	layer.add_child(_label)

	_color_bar = ColorBar.new()
	_color_bar.position = Vector2(560, 120)
	layer.add_child(_color_bar)


func _process(_delta: float) -> void:
	_update_hud()
	_update_pebble_colors()   # render-clock consumer of sim state (never writes back)


func _physics_process(delta: float) -> void:
	# Native self-steps; kept explicit so an external engine slots in cleanly.
	_physics.step(delta)

	_spawn_accum += delta
	while _spawn_accum >= SPAWN_INTERVAL:
		_spawn_accum -= SPAWN_INTERVAL
		_inject_batch()

	_extract_accum += delta
	while _extract_accum >= EXTRACT_INTERVAL:
		_extract_accum -= EXTRACT_INTERVAL
		_extract_lowest()

	_solve_accum += delta
	while _solve_accum >= SOLVE_INTERVAL:
		_solve_accum -= SOLVE_INTERVAL
		_solve_flux()

	# Deplete on the CAMPAIGN clock (CLAUDE.md principle 1): campaign_dt is derived
	# from the physics step here and reaches ONLY Depletion.step. Gated on a running
	# core — a subcritical/shut-down core has a flux SHAPE but no fission, so it must
	# not burn fuel (advisor). `_regulated` is true when regulated OR over-temp, false
	# when subcritical or feedback-off. Uses each pebble's local_flux from the last solve.
	_deplete(_clocks.campaign_dt(delta))


func _inject_batch() -> void:
	if _pebbles.size() >= TARGET_POPULATION:
		return
	for i in SPAWN_PER_TICK:
		if _pebbles.size() >= TARGET_POPULATION:
			return
		var id := _next_id
		_next_id += 1
		var peb := Pebble.new(id, PEBBLE_RADIUS)
		_stamp_enrichment(peb, _enrichment)
		# The INITIAL bed is seeded to online-refueling equilibrium (a spread of
		# burnups), not all-fresh. Later injections — refuel replacements for
		# discharged pebbles — are genuinely fresh (burnup 0).
		if _total_injected < TARGET_POPULATION:
			_seed_burned(peb)
		_pebbles[id] = peb
		var pos := Vector2(Silo.spawn_x(_rng, PEBBLE_RADIUS + 2.0), Silo.spawn_y())
		_physics.spawn_pebble(id, pos, PEBBLE_RADIUS)
		_total_injected += 1


## Pre-burn a seed pebble to a random point in its life so the INITIAL core starts
## at the online-refueling equilibrium: a spread of burnups from fresh to nearly
## spent (CLAUDE.md M3 flat-reactivity target; advisor).
##
## WHY this is required, not cosmetic: an all-fresh core burns in lockstep and, with
## only ~1% excess reactivity, hits k=1 and freezes SUBCRITICAL at a few MWd/kg —
## long before any pebble reaches discharge burnup, so nothing ever discharges and
## the fuel cycle never starts (a deadlock, confirmed live). Cold-starting an all-
## fresh core would instead need control rods to hold the large fresh excess (M5);
## we begin at the running equilibrium the reactor would already be in.
func _seed_burned(peb: Pebble) -> void:
	var target := _rng.randf() * Depletion.DISCHARGE_BURNUP
	# Evolve the fresh isotopic vector to the burnup target in small steps so the
	# Pu breed-then-burn chain integrates correctly (Depletion.step is exact per
	# isotope but the U-238→Pu-239→burn chain is a multi-step integral).
	var steps := 120
	var dfl := target / steps
	for _i in steps:
		Depletion.step(peb, 1.0, dfl)
	# A plausible pass count for that burnup (~9 MWd/kg per pass), capped below the
	# MAX_PASSES backstop so it stays a burnup-driven, not pass-driven, discharge.
	peb.pass_count = mini(Depletion.MAX_PASSES - 1, int(peb.burnup / 9.0))


func _extract_lowest() -> void:
	# Metered discharge: pull the single lowest (most-descended) pebble out of the
	# closed hopper. Only once the bed is settled at the bottom, so we don't yank
	# pebbles still in free-fall near the top.
	#
	# M3 makes this the recirculate-vs-discharge decision (multi-pass fuel cycle,
	# CLAUDE.md): a pebble still below its discharge burnup goes back to the TOP for
	# another pass (population conserved); a spent pebble leaves for good and its
	# vacancy is refilled by a FRESH pebble at injection — steady online refueling,
	# which holds reactivity roughly flat instead of a batch sawtooth.
	if _pebbles.size() < TARGET_POPULATION:
		return  # let the bed fill first
	var lowest_id := -1
	var lowest_y := -INF
	var positions := _physics.positions()
	for id in positions:
		var y: float = positions[id].y
		if y > lowest_y:
			lowest_y = y
			lowest_id = id
	if lowest_id == -1 or lowest_y < Silo.FUNNEL_TOP:
		return  # nothing has reached the discharge region yet
	var peb: Pebble = _pebbles[lowest_id]
	if peb.burnup < Depletion.DISCHARGE_BURNUP and peb.pass_count < Depletion.MAX_PASSES:
		_recirculate(lowest_id, peb)
	else:
		_discharge(lowest_id, peb)


## Send a not-yet-spent pebble back to the top for another pass, keeping ALL its
## burned state (isotopics, burnup, poison). Population is unchanged, so injection
## does not add a fresh pebble for it — only a true discharge opens a slot.
func _recirculate(id: int, peb: Pebble) -> void:
	peb.pass_count += 1
	_physics.remove_pebble(id)
	var pos := Vector2(Silo.spawn_x(_rng, PEBBLE_RADIUS + 2.0), Silo.spawn_y())
	_physics.spawn_pebble(id, pos, PEBBLE_RADIUS)  # same id → same Pebble in _pebbles
	_total_recirculated += 1


## Remove a spent pebble for good and fold its composition into the outflow readout.
func _discharge(id: int, peb: Pebble) -> void:
	_record_outflow(peb)
	_physics.remove_pebble(id)
	_pebbles.erase(id)
	_total_extracted += 1


## Accumulate the discharged pebble's composition for the outflow readout — the
## "inspect the spent fuel flowing out the bottom" goal (CLAUDE.md project overview).
func _record_outflow(peb: Pebble) -> void:
	var hm := peb.u235 + peb.u238 + peb.pu239
	var fissile := (peb.u235 + peb.pu239) / hm if hm > 0.0 else 0.0
	_out_count += 1
	_out_burnup_sum += peb.burnup
	_out_passes_sum += peb.pass_count
	_out_fissile_sum += fissile
	_out_pu_sum += peb.pu239
	_out_poison_sum += peb.poison
	_last_out_burnup = peb.burnup
	_last_out_passes = peb.pass_count
	_last_out_fissile = fissile


## Deplete every pebble by one campaign step, driven by its local flux from the
## last solve. Gated to a running core (see caller): no fission → no burnup.
func _deplete(campaign_dt: float) -> void:
	if not _regulated or campaign_dt <= 0.0:
		return
	for id in _pebbles:
		var peb: Pebble = _pebbles[id]
		Depletion.step(peb, peb.local_flux, campaign_dt)


func _solve_flux() -> void:
	# The coupling step: homogenize the current pebble field onto the grid, solve
	# the steady-state diffusion problem, then push results outward only.
	#
	# M2 closes the loop the M1 version left open: with feedback ON we solve the
	# COUPLED steady state (Feedback.solve_equilibrium finds the power/temperature
	# at which Doppler makes the core critical); with it OFF we solve the raw
	# eigenproblem, exposing the uncontrolled k so the contrast is visible.
	var positions := _physics.positions()
	if positions.is_empty():
		return
	_grid.homogenize(_pebbles, positions)

	if _feedback_on:
		var eq := Feedback.solve_equilibrium(_grid, 0.1)
		_k_eff = eq.k_eff
		_k_cold = eq.k_cold
		_regulated = eq.regulated
		_feedback_insufficient = eq.feedback_insufficient
		_peak_temp = Feedback.T_REF + eq.peak_dt
		# Relative fission rate (Σ νΣf·φ on the peak-normalized flux) — nonzero at
		# criticality and the M4 heat-source hook. WHY not eq.power: that M2 proxy is
		# the excess reactivity Doppler burns off, which correctly collapses to ~0 at a
		# critical online-refueling equilibrium (k_cold→1) — a degenerate readout for a
		# core that is actually at full power. True thermal power awaits M4's energy balance.
		_power = _fission_rate(eq.flux)
		_solve_iters = eq.iterations
		_last_flux = eq.flux
		_last_temp = eq.temperature
	else:
		# Feedback off: the honest uncontrolled state. No Doppler, so fuel sits at inlet
		# temperature; the fission rate is still a meaningful relative-power readout.
		var sol := Neutronics.solve(_grid)
		_k_eff = sol.k_eff
		_k_cold = sol.k_eff
		_regulated = false
		_feedback_insufficient = false
		_peak_temp = Feedback.T_REF
		_power = sol.fission_rate
		_solve_iters = sol.iterations
		_last_flux = sol.flux
		_last_temp = _flat_temp_field()

	# Update the heatmap for whichever field is selected (consumer of sim state;
	# never writes back).
	_refresh_field_display()

	# Sample fields back onto each pebble: flux (M3 will make it a burnup rate) and
	# the placeholder fuel temperature (viz now; M4 replaces it with a real energy
	# balance). Mirrors the two-worlds map — grid field → per-pebble Lagrangian value.
	for id in positions:
		var peb: Pebble = _pebbles.get(id)
		if peb != null:
			peb.local_flux = _grid.sample(_last_flux, positions[id])
			peb.temperature = _grid.sample(_last_temp, positions[id])


## Push the currently selected field into the heatmap + colorbar. GRID fields
## paint the upscaled background texture; PEBBLE fields hide it and color the
## bodies instead (done each render frame in _update_pebble_colors).
func _refresh_field_display() -> void:
	if _fields.is_empty():
		return
	var entry: Dictionary = _fields[_current_field]
	var desc: FieldDescriptor = entry["desc"]
	_color_bar.set_descriptor(desc)
	if desc.world == FieldDescriptor.GRID:
		var field: PackedFloat32Array = entry["get"].call()
		if not field.is_empty():
			_field_display.set_grid_field(_grid, field, desc)
		_field_display.visible = true
		_reset_pebble_tints()   # drop any per-pebble coloring from a PEBBLE field
	else:
		_field_display.visible = false  # background heatmap off; pebbles carry the field


## Color each pebble by the selected PEBBLE-world field (render clock). A pure
## consumer: reads sim state, writes only body tints, never back into the sim.
func _update_pebble_colors() -> void:
	if _fields.is_empty():
		return
	var entry: Dictionary = _fields[_current_field]
	var desc: FieldDescriptor = entry["desc"]
	if desc.world != FieldDescriptor.PEBBLE:
		return
	var getter: Callable = entry["get_peb"]
	for id in _pebbles:
		var t := desc.normalize(getter.call(_pebbles[id]))
		_physics.set_pebble_tint(id, Colormap.viridis(t))


## Restore graphite grey (used when switching from a PEBBLE field back to a GRID one).
func _reset_pebble_tints() -> void:
	for id in _pebbles:
		_physics.set_pebble_tint(id, PebbleBody.DEFAULT_TINT)


## Total fission rate Σ νΣf·φ on the (peak-normalized) flux — a relative power that
## stays nonzero at criticality, unlike M2's excess-reactivity proxy. νΣf is the
## temperature-free base homogenize wrote, so this is valid whether or not Doppler
## has perturbed the absorption. Becomes the M4 heat source.
func _fission_rate(flux: PackedFloat32Array) -> float:
	var fr := 0.0
	var nsf := _grid.nu_sigma_f
	for c in range(_grid.cell_count()):
		fr += nsf[c] * flux[c]
	return fr


## An all-inlet-temperature field (feedback off / no fission heating yet).
func _flat_temp_field() -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize(_grid.cell_count())
	t.fill(Feedback.T_REF)
	return t


## Stamp FRESH fuel at injection: the toy heavy-metal split grid._enrichment_of()
## reads back as the fissile fraction. From here Depletion.step evolves this vector
## over the pebble's life (U-235 burns, Pu-239 breeds, poison builds).
func _stamp_enrichment(peb: Pebble, e: float) -> void:
	peb.u235 = e
	peb.u238 = 1.0 - e


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F:
			_feedback_on = not _feedback_on
			_solve_flux()   # re-solve immediately so the contrast is instant
		KEY_BRACKETRIGHT, KEY_EQUAL:
			_set_enrichment(_enrichment + ENRICH_STEP)
		KEY_BRACKETLEFT, KEY_MINUS:
			_set_enrichment(_enrichment - ENRICH_STEP)
		KEY_V, KEY_TAB:
			_current_field = (_current_field + 1) % _fields.size()
			_refresh_field_display()


## Change the DESIGN enrichment: applied to freshly injected pebbles only (see
## _inject_batch). It does NOT restamp pebbles already in the core — doing so would
## also wipe their burned isotopics back to fresh (the very state M3 tracks). So a
## new enrichment propagates gradually as fresh fuel refuels the bed — the honest
## online-refueling behavior, not an instant core-wide reset.
func _set_enrichment(e: float) -> void:
	_enrichment = clampf(e, ENRICH_MIN, ENRICH_MAX)


func _draw() -> void:
	# Silo shell, drawn in the parent's pass so it sits above the background
	# heatmap but below the pebbles.
	for seg in Silo.wall_segments():
		draw_line(seg[0], seg[1], Color(0.9, 0.9, 0.95, 0.9), 3.0)


func _update_hud() -> void:
	var field_name: String = _fields[_current_field]["desc"].name if not _fields.is_empty() else "-"

	# Status. A core at online-refueling equilibrium is CRITICAL (k_cold ~ 1), so the
	# strict k>1 test would flicker; treat within CRIT_BAND of 1 as self-regulating,
	# and reserve "shutting down" for a clearly subcritical core (the passive-safety demo).
	var status := ""
	if not _feedback_on:
		status = "UNCONTROLLED — no self-limiting"
	elif _k_cold < 1.0 - CRIT_BAND:
		status = "SUBCRITICAL — shutting down"
	elif _feedback_insufficient or _peak_temp >= OVER_TEMP_K:
		status = "OVER-TEMP — Doppler can't hold; needs control rods"
	else:
		status = "SELF-REGULATING (critical)"

	# Outflow composition of discharged (spent) fuel — the "inspect the spent fuel
	# flowing out the bottom" deliverable: running averages + the last discharge.
	var outflow := ""
	if _out_count > 0:
		outflow = "spent fuel out: %d   avg burnup %.0f  avg passes %.1f\n" \
				% [_out_count, _out_burnup_sum / _out_count, float(_out_passes_sum) / _out_count] \
			+ "  avg residual fissile %.1f%%   Pu-239 %.3f   poison %.4f\n" \
				% [(_out_fissile_sum / _out_count) * 100.0, _out_pu_sum / _out_count, _out_poison_sum / _out_count] \
			+ "  last out: burnup %.0f  passes %d  fissile %.1f%% (fresh in %.1f%%)\n" \
				% [_last_out_burnup, _last_out_passes, _last_out_fissile * 100.0, _enrichment * 100.0]
	else:
		outflow = "spent fuel out: 0   (fuel still below discharge burnup)\n"

	_label.text = "PEBBLE BED — M3 burnup & outflow\n" \
		+ "active: %d / %d   recirculated: %d\n" % [_pebbles.size(), TARGET_POPULATION, _total_recirculated] \
		+ "injected: %d   discharged: %d\n" % [_total_injected, _total_extracted] \
		+ "design enrichment: %.1f%%   ( [ / ] )   campaign: %.0f\n" % [_enrichment * 100.0, _clocks.campaign_elapsed] \
		+ "feedback: %s   (F)\n" % ("ON" if _feedback_on else "OFF") \
		+ "k-eff: %.4f   %s\n" % [_k_eff, status] \
		+ "  cold / uncontrolled k: %.4f\n" % _k_cold \
		+ "peak fuel temp: %.0f K  (ΔT %.0f)   [Doppler placeholder → M4]\n" % [_peak_temp, _peak_temp - Feedback.T_REF] \
		+ "fission rate: %.1f (rel.)   [thermal power → M4]\n" % _power \
		+ outflow \
		+ "field: %s   (V)\n" % field_name \
		+ "solve iters: %d   fps: %d" % [_solve_iters, Engine.get_frames_per_second()]
