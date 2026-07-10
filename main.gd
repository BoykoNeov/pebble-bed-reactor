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
# Neutronics re-solve cadence (quasi-static flux). Tightened from M2's 0.5 s for
# M4: the flux (hence k) is stale between solves, but the power amplitude and
# pebble temperatures now integrate EVERY physics step against that k. The
# coupling decision (advisor): keep the flux quasi-static on a cadence AND tune
# the power response slow enough (Thermal.KINETICS_GAIN) that its e-folding time
# is comfortably ≫ this interval — so stale k is harmless — while still resolving
# often enough that a transient's k tracks the evolving temperature smoothly.
const SOLVE_INTERVAL := 0.20

# Player enrichment lever (M2). Kept LEU and well under 20% (CLAUDE.md: civilian
# teaching toy). Small step because enrichment is a steep reactivity lever and
# Doppler is a weak fine feedback — a few tenths of a percent already moves k ~1%.
const ENRICH_MIN := 0.050
const ENRICH_MAX := 0.120

# Fuel-loading design lever (M5b): the graphite-to-heavy-metal ratio of a fresh
# pebble, which sets its homogenized MODERATION ratio M = M_REF / loading
# (CrossSections.moderation). This is the knob that walks the core across the
# k_inf(M) peak: LESS loading (more graphite per gram of fuel) → MORE moderation →
# higher M. Nominal 1.0 gives M = 1.0, on the stable UNDER-moderated side; dialing
# loading DOWN toward LOADING_MIN pushes M over the peak into the OVER-moderated
# regime where the moderator-temperature coefficient turns POSITIVE and the core
# can run away — the "accidentally build an unstable core" demo (CLAUDE.md). Applied
# to freshly injected fuel only (like enrichment), so a change propagates as the bed
# refuels rather than resetting the core. Range straddles the peak (M≈1.2): MIN 0.5
# → M=2.0 (strongly over-moderated), MAX 1.5 → M≈0.67 (deep under-moderated).
const LOADING_DEFAULT := 1.0
const LOADING_MIN := 0.5
const LOADING_MAX := 1.5
const LOADING_STEP := 0.05
# Moderation ratio at the k_inf(M) peak (from the tests/test_neutronics.gd sweep,
# M ≈ 1.2). Display-only: the HUD labels the core UNDER-moderated (stable MTC) below
# it and OVER-moderated (unstable MTC) above it, so the player can see which side of
# the instability their fuel-loading choice has put the core on.
const MOD_PEAK_M := 1.2
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
# Toy display scale mapping the extracted coolant-enthalpy power (M4b: the heat the
# secondary side harvests) to a plausible headline figure (HTR-PM is ~250 MWth).
# Purely cosmetic — the physics is in arbitrary units — tuned so the nominal
# operating point (flow 1.0, cold inlet) reads ~300 MWth.
const THERMAL_MW_SCALE := 0.035

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
var _flux_fast_desc: FieldDescriptor   # M5b fast-group (φ1) heatmap
var _flux_thermal_desc: FieldDescriptor # M5b thermal-group (φ2) heatmap
var _moderation_desc: FieldDescriptor  # M5b per-cell design moderation ratio M
var _temp_desc: FieldDescriptor        # grid fuel-temperature heatmap (real at M4)
var _pebble_temp_desc: FieldDescriptor # M4 per-pebble temperature (Lagrangian)
var _k_eff := 0.0
var _power := 0.0        # headline extracted thermal power (real energy balance, M4)
var _solve_iters := 0

# Field switching: keep the latest solved arrays so the player can flip the
# heatmap between fields (V) without waiting for the next solve.
var _fields: Array = []   # [ {desc, get: Callable -> PackedFloat32Array}, ... ]
var _current_field := 0
var _last_flux: PackedFloat32Array = PackedFloat32Array()
var _last_flux_fast: PackedFloat32Array = PackedFloat32Array()
var _last_flux_thermal: PackedFloat32Array = PackedFloat32Array()
var _last_moderation: PackedFloat32Array = PackedFloat32Array()
var _last_temp: PackedFloat32Array = PackedFloat32Array()

# Doppler feedback (M2): closes the loop so the reactor self-regulates.
var _feedback_on := true
var _enrichment := ENRICH_DEFAULT
var _fuel_loading := LOADING_DEFAULT   # design moderation lever (M5b); stamped on fresh fuel
var _k_cold := 0.0            # k with feedback OFF — the reactivity being suppressed
var _peak_temp := Feedback.T_REF

# Thermal & cooling (M4). Temperature is no longer M2's instant search output —
# it is a real, time-lagged STATE the pebbles carry, integrated on the physics
# clock (Thermal). The power amplitude and coolant flow are the new dynamics/
# controls; the loop closes as power → heat → pebble T (inertia) → Doppler → power.
var _amplitude := Thermal.A_NOMINAL   # power-amplitude state (scales the flux shape)
var _coolant_flow := Thermal.FLOW_NOMINAL  # primary operating lever (mass flow)
var _mean_temp := Feedback.T_REF      # bed-average fuel temperature (readout)
var _thermal_seeded := false          # one-time near-equilibrium seed done?
var _running := false                 # core producing power (gates depletion)

# Decay heat & scram (M5). Decay heat is the fraction of the fuel heat that comes
# from decaying fission products — it PERSISTS after fission stops, so it must still
# be cooled (CLAUDE.md decay-heat / passive-safety). SCRAM is an emergency shutdown
# (large negative reactivity into the kinetics) that collapses fission power WITHOUT
# freezing the thermal/decay loop — the walk-away-safe demo watches the decay-heat
# tail bound the temperature after the reactor trips.
var _scrammed := false                # emergency shutdown engaged (kinetics only)
var _decay_power := 0.0               # bed-total delivered decay heat (readout, a.u.)
var _decay_frac := 0.0                # decay heat as a fraction of total delivered heat

# Coolant transport & loop closure (M4b). The coolant is no longer a uniform inlet:
# it enters cold at the top and warms as it flows down the bed, so each pebble sees a
# LOCAL sink temperature. The heat exchanger closes the loop — extracted power = the
# coolant enthalpy rise (the headline reactor / electrical proxy). Inlet temperature
# is the load-following lever (hotter return → smaller convective gap → lower power).
var _inlet_temp := Thermal.INLET_MIN   # coolant inlet temperature (K), player lever
var _coolant_out := Thermal.INLET_MIN  # hottest coolant seen (bed outlet, readout)
var _coolant_desc: FieldDescriptor     # grid coolant-temperature heatmap
var _last_coolant: PackedFloat32Array = PackedFloat32Array()

# Burnup / outflow (M3)
var _burnup_desc: FieldDescriptor      # first PEBBLE-world (Lagrangian) field
var _decay_desc: FieldDescriptor       # M5 per-pebble decay-heat power (Lagrangian)
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
	# Two-group flux components (M5b): the fast (φ1) and thermal (φ2) fields the solver
	# produces. Each is peak-normalized to its own max, so [0,1] linear ranges are stable.
	# Viewed together they SHOW the two-group story: the fast flux peaks in the fuel where
	# fission is born, the thermal flux peaks out in the reflector where leaked neutrons
	# thermalize and pile up (the reflector-peaking a one-group model can only fake).
	_flux_fast_desc = FieldDescriptor.new("Fast flux (φ1)", "norm", FieldDescriptor.GRID, 0.0, 1.0, false)
	_flux_thermal_desc = FieldDescriptor.new("Thermal flux (φ2)", "norm", FieldDescriptor.GRID, 0.0, 1.0, false)
	# Design moderation ratio M per cell (M5b): the homogenized fuel-loading knob. Shows
	# WHERE the core sits relative to the k_inf(M) peak (~1.2) — the field the player
	# reshapes with the loading lever to build (or avoid) the over-moderated instability.
	# Fixed range spanning the lever's reach (M_REF/LOADING_MAX … M_REF/LOADING_MIN).
	_moderation_desc = FieldDescriptor.new("Moderation M", "ratio", FieldDescriptor.GRID,
		CrossSections.M_REF / LOADING_MAX, CrossSections.M_REF / LOADING_MIN, false)
	# Fuel temperature (M2 heatmap; M4 makes it the REAL homogenized field). Fixed
	# range from inlet to the over-temp line so the scale is stable across transients
	# (CLAUDE.md); hotter cells clamp to the top.
	_temp_desc = FieldDescriptor.new("Fuel temperature", "K", FieldDescriptor.GRID, Feedback.T_REF, OVER_TEMP_K, false)
	# Coolant (helium) temperature (M4b) — a GRID field like flux/fuel-temp, showing
	# the cold inlet at the top warming to a hot outlet at the bottom of the bed. A
	# tighter fixed range than fuel temp (coolant stays well below the fuel) keeps the
	# downstream gradient legible; hotter cells clamp to the top of the scale.
	_coolant_desc = FieldDescriptor.new("Coolant temperature", "K", FieldDescriptor.GRID, Feedback.T_REF, 900.0, false)
	# Per-pebble temperature (M4) — the Lagrangian view of the SAME real energy
	# balance: watch one hot pebble travel down the bed. Same fixed range as the grid
	# field so the two views are directly comparable.
	_pebble_temp_desc = FieldDescriptor.new("Pebble temperature", "K", FieldDescriptor.PEBBLE, Feedback.T_REF, OVER_TEMP_K, false)
	# Burnup (M3) — the FIRST per-pebble (Lagrangian) field: each pebble colored by
	# its own burnup, so you can literally watch a burned pebble descend the bed
	# (CLAUDE.md two render modes). Fixed range [0, discharge] keeps the scale stable.
	_burnup_desc = FieldDescriptor.new("Burnup", "MWd/kgHM", FieldDescriptor.PEBBLE, 0.0, Depletion.DISCHARGE_BURNUP, false)
	# Decay heat (M5) — a per-pebble (Lagrangian) field: each pebble colored by the heat
	# its decaying fission products are currently releasing. Barely varies during normal
	# operation, but after a SCRAM it is the ONLY heat source, so this view shows the
	# decay-heat tail lingering (and draining) once fission has stopped. Fixed range up to
	# ~γ·S at the peak-flux operating pebble keeps the scale stable.
	_decay_desc = FieldDescriptor.new("Decay heat", "a.u.", FieldDescriptor.PEBBLE, 0.0, 2.0, false)

	# Field registry: each entry pairs a descriptor with a getter for its latest
	# values. GRID fields expose `get` → a per-cell array; PEBBLE fields expose
	# `get_peb` → a scalar per pebble. Adding a field (coolant temp at M4) is one
	# more entry, not new render code.
	_fields = [
		{"desc": _flux_desc, "get": func() -> PackedFloat32Array: return _last_flux},
		{"desc": _flux_fast_desc, "get": func() -> PackedFloat32Array: return _last_flux_fast},
		{"desc": _flux_thermal_desc, "get": func() -> PackedFloat32Array: return _last_flux_thermal},
		{"desc": _moderation_desc, "get": func() -> PackedFloat32Array: return _last_moderation},
		{"desc": _temp_desc, "get": func() -> PackedFloat32Array: return _last_temp},
		{"desc": _coolant_desc, "get": func() -> PackedFloat32Array: return _last_coolant},
		{"desc": _pebble_temp_desc, "get_peb": func(peb: Pebble) -> float: return peb.temperature},
		{"desc": _burnup_desc, "get_peb": func(peb: Pebble) -> float: return peb.burnup},
		{"desc": _decay_desc, "get_peb": func(peb: Pebble) -> float: return Thermal.decay_power(peb.decay_e)},
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

	# Thermal & power dynamics (M4) — the ONE subsystem that time-integrates on the
	# fast physics clock (CLAUDE.md clock model): the flux is quasi-static above and
	# burnup is on the campaign clock below, but pebble temperature has real inertia,
	# so it steps every frame against the latest k. This is what makes the loop lag,
	# overshoot, and settle instead of regulating instantly.
	_thermal_step(delta)

	# Deplete on the CAMPAIGN clock (CLAUDE.md principle 1): campaign_dt is derived
	# from the physics step here and reaches ONLY Depletion.step. Gated on a RUNNING
	# core (power above threshold) — a shut-down core has a flux SHAPE but no fission,
	# so it must not burn fuel (advisor). Uses each pebble's local_flux from last solve.
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
		peb.fuel_loading = _fuel_loading   # M5b design moderation, stamped at manufacture
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
	# Frozen when feedback is OFF (see _thermal_step): no valid dynamic power level
	# exists without Doppler, so burnup pauses with the rest of the loop.
	if not _feedback_on or campaign_dt <= 0.0 or _amplitude <= 0.0:
		return
	# Real fluence scales with ABSOLUTE flux = amplitude × normalized shape, so burnup
	# ∝ A/A_REF (advisor). At the design point A ≈ A_REF → the M3-calibrated rate
	# (TIME_ACCEL preserved); an idling core (A ≪ A_REF) barely burns. This replaces
	# M3's on/off gate — WITHOUT it, a core collapsing toward idle keeps burning at
	# full rate and over-depletes k_cold below 1, forcing a spurious shutdown.
	var power_frac := _amplitude / Thermal.A_REF
	for id in _pebbles:
		var peb: Pebble = _pebbles[id]
		Depletion.step(peb, peb.local_flux * power_frac, campaign_dt)


func _solve_flux() -> void:
	# The coupling step (M4 dynamic form): homogenize the current pebble field —
	# now INCLUDING each pebble's real, lagged temperature — onto the grid, solve
	# the quasi-static flux against that temperature, then push results outward only.
	#
	# M4 replaces M2's critical-power SEARCH with a measured feedback. Temperature is
	# a STATE the pebbles carry (integrated in _thermal_step), so Doppler just reads
	# grid.temperature (Thermal.apply_field_doppler) and we solve the eigenproblem
	# ONCE at the current temperature — no search. The retained M2 search survives
	# only as the one-time equilibrium SEED below (and, later, fast-forward collapse).
	var positions := _physics.positions()
	if positions.is_empty():
		return
	_grid.homogenize(_pebbles, positions)

	# Snapshot the temperature-FREE base FAST absorption homogenize just wrote
	# (Neutronics only reads the grid, never mutates it, so this stays clean across
	# the cold solve). M5b: Doppler perturbs sigma_a1; the moderator-temperature
	# coefficient perturbs sigma_r / sigma_a2, so those are snapshot too.
	var base_sa1 := _grid.sigma_a1.duplicate()
	var base_sr := _grid.sigma_r.duplicate()
	var base_sa2 := _grid.sigma_a2.duplicate()

	# Cold (temperature-free) reference solve — the honest UNCONTROLLED reactivity,
	# kept as the HUD contrast: the k the core WOULD run at with no feedback. Runs on
	# the base cross-sections homogenize just wrote (design M, no Doppler), so k_cold
	# excludes BOTH temperature feedbacks — Doppler and the moderator coefficient. Cheap.
	var cold := Neutronics.solve(_grid)
	_k_cold = cold.k_eff

	# One-time thermal seed: start the bed near its Doppler equilibrium temperature so
	# the sim opens close to steady state and merely settles, instead of a violent
	# cold-start transient every launch (advisor). Gate on a FULL bed (not a partial
	# one): a partly-filled bed reads k_cold just above 1, giving a tiny equilibrium
	# ΔT — under-seeding, and the subsequent climb to the packed operating point IS
	# the overshoot. Waiting for the full pack lands the seed on the real operating k.
	if not _thermal_seeded and cold.k_eff > 1.0 and _pebbles.size() >= TARGET_POPULATION:
		_seed_thermal_equilibrium(positions, cold.flux)

	if _feedback_on:
		# Warm solve: temperature-free base + Doppler (fuel T → sigma_a1) + moderator-
		# temperature feedback (graphite T → sigma_r / sigma_a2) at the CURRENT per-cell
		# state. Restore all three bases first so neither feedback stacks across frames.
		# BOTH feedbacks read the SAME driver — grid.temperature, the pebble/graphite
		# temperature — because in a gas-cooled bed the graphite moderator sits inside the
		# pebble at pebble temperature (see Thermal.apply_field_moderator). That temperature
		# is a genuine time-integrated state (thermal inertia), so the power→temp→feedback→
		# power loop is closed honestly through the lag, with no one-solve hack. At cold
		# start temperature = inlet everywhere → M_eff = M_base → the MTC is simply a no-op.
		_grid.sigma_a1 = base_sa1.duplicate()
		_grid.sigma_r = base_sr.duplicate()
		_grid.sigma_a2 = base_sa2.duplicate()
		Thermal.apply_field_doppler(_grid)
		Thermal.apply_field_moderator(_grid)
		var sol := Neutronics.solve(_grid)
		_k_eff = sol.k_eff
		_last_flux = sol.flux
		_last_flux_fast = sol.flux_fast
		_last_flux_thermal = sol.flux_thermal
		_solve_iters = sol.iterations
	else:
		# Feedback OFF: the uncontrolled state — no Doppler, no MTC, so k is the raw cold
		# k and nothing self-limits power (it runs away, capped for display). Restore the
		# bases so the heatmaps show the design cross-sections, not a stale warm field.
		_grid.sigma_a1 = base_sa1.duplicate()
		_grid.sigma_r = base_sr.duplicate()
		_grid.sigma_a2 = base_sa2.duplicate()
		_k_eff = cold.k_eff
		_last_flux = cold.flux
		_last_flux_fast = cold.flux_fast
		_last_flux_thermal = cold.flux_thermal
		_solve_iters = cold.iterations

	# M4b coolant transport: with the fuel temperature freshly homogenized onto the
	# grid, march the downstream coolant energy balance (top-down, co-current with the
	# falling pebbles) so each cell carries its LOCAL coolant temperature — cold at the
	# inlet, warming through the bed. Quasi-steady on the solve cadence (coolant transit
	# is seconds); the pebbles sample it as their cooling sink in _thermal_step. Computed
	# from grid.temperature, which is the held state when feedback is OFF, so the field
	# freezes with the rest of the loop rather than drifting.
	Thermal.solve_coolant_field(_grid, _coolant_flow, _inlet_temp)

	# The homogenized grid temperature IS the fuel-temperature heatmap now — a real,
	# measured field, not M2's invented equilibrium. (_peak_temp / _mean_temp are
	# computed from the pebbles themselves in _thermal_step.)
	_last_temp = _grid.temperature.duplicate()
	_last_coolant = _grid.coolant_temp.duplicate()
	# Design moderation field (M5b) — the base per-cell M homogenize wrote (pre-MTC), so
	# the heatmap shows the fuel-loading design the player set, not the transient warm M_eff.
	_last_moderation = _grid.moderation.duplicate()

	# Update the heatmap for whichever field is selected (consumer; never writes back).
	_refresh_field_display()

	# Sample the flux AND the coolant temperature back onto each pebble: flux drives its
	# fission heat (_thermal_step) and burnup (_deplete); coolant is its Newton-cooling
	# sink (_thermal_step). Fuel temperature is NOT sampled back — it is the pebble's own
	# integrated state, and the two-worlds map runs pebble T → grid via homogenize.
	for id in positions:
		var peb: Pebble = _pebbles.get(id)
		if peb != null:
			peb.local_flux = _grid.sample(_last_flux, positions[id])
			peb.local_coolant = _grid.sample(_last_coolant, positions[id])


## Integrate the M4 power + thermal dynamics one physics step — the only fast-clock
## time integration (CLAUDE.md clock model). Power amplitude follows toy point-
## kinetics against the latest k (exact exponential, stable); each pebble's
## temperature relaxes under its fission heat and the coolant/ambient losses
## (semi-implicit, stable). Accumulates the headline extracted thermal power and
## the peak/mean fuel temperature for the HUD, and sets the depletion gate.
func _thermal_step(delta: float) -> void:
	# Feedback OFF FREEZES the dynamic loop (advisor). WHY this is mandatory, not
	# cosmetic: with no Doppler, _k_eff = raw cold k > 1, so the exponential kinetics
	# would drive _amplitude to A_MAX every frame; burnup ∝ A/A_REF would then hit
	# ~1e6/30 ≈ 3e4× and deplete the whole core to spent in a step or two — silent,
	# irreversible state corruption from a couple seconds of the F-toggle demo. So OFF
	# holds A, temperatures, and burnup fixed and simply displays the uncontrolled k as
	# the contrast (M2's "no self-limiting"). Toggling back ON resumes from the held state.
	if delta <= 0.0 or not _feedback_on:
		return
	# Power amplitude: exact exponential update at the frozen-between-solves k. SCRAM
	# (M5) subtracts a large negative reactivity here ONLY — the effective kinetics k
	# goes far subcritical so fission power collapses, while the thermal/decay loop
	# below keeps integrating (that is the whole point: heat continues after trip).
	var k_kin := _k_eff - (Thermal.SCRAM_WORTH if _scrammed else 0.0)
	_amplitude = Thermal.step_power(_amplitude, k_kin, delta)
	var h := Thermal.h_of_flow(_coolant_flow)
	var peak := Feedback.T_REF
	var sum_t := 0.0
	var extracted := 0.0
	var out_t := _inlet_temp
	var sum_decay := 0.0        # bed-total delivered decay heat this step
	var sum_delivered := 0.0    # bed-total delivered fuel heat (prompt + decay)
	var count := 0
	for id in _pebbles:
		var peb: Pebble = _pebbles[id]
		# M4b: each pebble is cooled by its LOCAL coolant temperature (from the
		# downstream transport field), not a uniform inlet — a deep pebble sheds heat
		# into hotter helium than a shallow one.
		var t_cool := peb.local_coolant
		# M5 energy-conserving split of the fission power S: a prompt part deposited now,
		# plus the decay-heat reservoirs (fed by S, drained at their own rate). At steady
		# state prompt + decay = S exactly, so this does NOT move the M4 operating point;
		# only after a scram (S→0) do the reservoirs keep delivering the decay-heat tail.
		var s := Thermal.pebble_power(_amplitude, peb.local_flux)
		var decay := Thermal.step_decay_heat(peb.decay_e, s, delta)
		var p := Thermal.prompt_power(s) + decay
		peb.temperature = Thermal.step_pebble_temp(peb.temperature, p, t_cool, h, delta)
		# Heat carried off by the coolant — the enthalpy the heat exchanger harvests on
		# the secondary side (M4b loop closure). Summed over the bed this IS the headline
		# extracted "reactor power" (the electrical-output proxy); at steady state it
		# equals the fission power. The always-on ambient loss is a passive structural
		# leak, NOT harvested, so it is excluded from the headline.
		extracted += h * (peb.temperature - t_cool)
		sum_decay += decay
		sum_delivered += p
		peak = maxf(peak, peb.temperature)
		sum_t += peb.temperature
		out_t = maxf(out_t, t_cool)
		count += 1
	_peak_temp = peak
	_mean_temp = sum_t / count if count > 0 else Feedback.T_REF
	_coolant_out = out_t
	_power = extracted * THERMAL_MW_SCALE
	_decay_power = sum_decay * THERMAL_MW_SCALE
	_decay_frac = sum_decay / sum_delivered if sum_delivered > 0.0 else 0.0
	_running = _amplitude > Thermal.A_RUNNING


## One-time near-equilibrium seed (advisor): open the core AT its operating point so
## it just settles rather than igniting from cold with a big overshoot. We seed the
## amplitude to the design value A_REF and each pebble's temperature to the steady
## value that SAME amplitude sustains at the current flow — power and temperature
## mutually consistent, so k_eff starts ≈ 1 and barely moves. WHY A_REF and the
## steady-temp balance instead of Feedback.solve_equilibrium: the frozen-shape search
## under-estimates ΔT for the reactive fresh bed (and saturates at high enrichment),
## so it under-seeds; A_REF is by definition the settled operating amplitude, giving
## a self-consistent seed directly. (solve_equilibrium stays for M4b fast-forward.)
func _seed_thermal_equilibrium(positions: Dictionary, cold_flux: PackedFloat32Array) -> void:
	var h := Thermal.h_of_flow(_coolant_flow)
	for id in positions:
		var peb: Pebble = _pebbles.get(id)
		if peb != null:
			var lf := _grid.sample(cold_flux, positions[id])
			var s := Thermal.pebble_power(Thermal.A_REF, lf)
			# Seed against the inlet coolant (the coolant field's downstream rise is a
			# modest correction the bed settles out over its first few seconds). steady_temp
			# takes the TOTAL fuel heat S: at steady state prompt + decay = S, so the M5
			# split does not change the seed temperature — but the decay reservoirs must be
			# seeded to that same steady inventory (γ·S) so the core opens at operating decay
			# heat instead of building it up (a spurious startup transient otherwise).
			peb.temperature = Thermal.steady_temp(s, _inlet_temp, h)
			Thermal.seed_decay_heat(peb.decay_e, s)
	_amplitude = Thermal.A_REF
	_thermal_seeded = true


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


## Stamp FRESH fuel at injection: the toy heavy-metal split grid._enrichment_of()
## reads back as the fissile fraction. From here Depletion.step evolves this vector
## over the pebble's life (U-235 burns, Pu-239 breeds, poison builds).
func _stamp_enrichment(peb: Pebble, e: float) -> void:
	peb.u235 = e
	peb.u238 = 1.0 - e


func _toggle_feedback() -> void:
	_feedback_on = not _feedback_on
	_solve_flux()   # re-solve immediately so the contrast is instant


## Trip / reset the scram (M5). Scram inserts a large negative reactivity into the
## power kinetics (Thermal.SCRAM_WORTH) so fission power collapses over ~2 s, but —
## unlike the feedback-OFF freeze — the thermal and decay-heat loop keeps running, so
## the player watches the decay-heat tail keep the core hot and bounded after the trip
## (the walk-away-safe demo — pair it with a flow cut). Toggling off lets the core
## restart from its held state if it is still cold-supercritical.
func _toggle_scram() -> void:
	_scrammed = not _scrammed


func _cycle_field() -> void:
	_current_field = (_current_field + 1) % _fields.size()
	_refresh_field_display()


func _input(event: InputEvent) -> void:
	# Ignore key releases and auto-repeat. Non-key events (InputEventAction, which
	# is what the gdai MCP's simulate_input synthesizes) fall through to the action
	# checks below so the sim is drivable headlessly / from tooling, not just the
	# physical keyboard.
	if event is InputEventKey and (not event.pressed or event.echo):
		return
	# InputMap actions take priority: a real key mapped to one of these arrives as
	# an action-matching key event, so it is handled here — the raw-keycode branch
	# is only a fallback for when the [input] actions aren't defined (e.g. a clone
	# without them). The elif chain guarantees a single key press toggles once.
	if event.is_action_pressed("toggle_feedback"):
		_toggle_feedback()
	elif event.is_action_pressed("cycle_field"):
		_cycle_field()
	elif event.is_action_pressed("enrich_up"):
		_set_enrichment(_enrichment + ENRICH_STEP)
	elif event.is_action_pressed("enrich_down"):
		_set_enrichment(_enrichment - ENRICH_STEP)
	elif event.is_action_pressed("flow_up"):
		_set_flow(_coolant_flow + Thermal.FLOW_STEP)
	elif event.is_action_pressed("flow_down"):
		_set_flow(_coolant_flow - Thermal.FLOW_STEP)
	elif event.is_action_pressed("inlet_up"):
		_set_inlet(_inlet_temp + Thermal.INLET_STEP)
	elif event.is_action_pressed("inlet_down"):
		_set_inlet(_inlet_temp - Thermal.INLET_STEP)
	elif event.is_action_pressed("loading_up"):
		_set_loading(_fuel_loading + LOADING_STEP)
	elif event.is_action_pressed("loading_down"):
		_set_loading(_fuel_loading - LOADING_STEP)
	elif event.is_action_pressed("scram"):
		_toggle_scram()
	elif event is InputEventKey:
		match event.keycode:
			KEY_F:
				_toggle_feedback()
			KEY_BRACKETRIGHT, KEY_EQUAL:
				_set_enrichment(_enrichment + ENRICH_STEP)
			KEY_BRACKETLEFT, KEY_MINUS:
				_set_enrichment(_enrichment - ENRICH_STEP)
			# Coolant mass flow — the PRIMARY M4 operating lever. Down (,) drives the
			# loss-of-flow / walk-away-safe demo; up (.) cools and re-reactivates.
			KEY_PERIOD:
				_set_flow(_coolant_flow + Thermal.FLOW_STEP)
			KEY_COMMA:
				_set_flow(_coolant_flow - Thermal.FLOW_STEP)
			# Coolant INLET temperature — the M4b load-following lever. Up (L) raises the
			# returning coolant temp → smaller convective gap → core self-limits to lower
			# power at the same Doppler-pinned fuel temperature; down (K) cools it back.
			KEY_L:
				_set_inlet(_inlet_temp + Thermal.INLET_STEP)
			KEY_K:
				_set_inlet(_inlet_temp - Thermal.INLET_STEP)
			# Fuel LOADING — the M5b moderation design lever. Down (;) removes heavy metal
			# (more graphite → MORE moderation → M up, toward the over-moderated instability);
			# up (') adds it (less moderation → M down, deeper under-moderated / stable).
			KEY_SEMICOLON:
				_set_loading(_fuel_loading - LOADING_STEP)
			KEY_APOSTROPHE:
				_set_loading(_fuel_loading + LOADING_STEP)
			# SCRAM (M5) — emergency shutdown. Space trips / resets it; pair with a flow
			# cut (,) to watch the decay-heat tail bound the temperature (walk-away safe).
			KEY_SPACE:
				_toggle_scram()
			KEY_V, KEY_TAB:
				_cycle_field()


## Change the DESIGN enrichment: applied to freshly injected pebbles only (see
## _inject_batch). It does NOT restamp pebbles already in the core — doing so would
## also wipe their burned isotopics back to fresh (the very state M3 tracks). So a
## new enrichment propagates gradually as fresh fuel refuels the bed — the honest
## online-refueling behavior, not an instant core-wide reset.
func _set_enrichment(e: float) -> void:
	_enrichment = clampf(e, ENRICH_MIN, ENRICH_MAX)


## Change the coolant mass flow — the primary M4 operating lever (CLAUDE.md). Lower
## flow → weaker convection → hotter pebbles → the loss-of-flow transient; higher
## flow → cooler, more power at the same Doppler-pinned temperature. Takes effect on
## the next physics step (it only changes the convective conductance in _thermal_step).
func _set_flow(f: float) -> void:
	_coolant_flow = clampf(f, Thermal.FLOW_MIN, Thermal.FLOW_MAX)


## Change the coolant INLET temperature — the M4b load-following lever (advisor).
## Doppler pins the fuel temperature that burns the cold excess, so raising the inlet
## does not change that target; it shrinks the convective gap (T_fuel − T_inlet), so
## each pebble sheds less and the core settles at LOWER power. This delivers the
## CLAUDE.md "coolant temp feeds reactivity, power re-settles" behavior through the
## existing loop — no separate moderator coefficient (that stays M5). Takes effect on
## the next coolant solve (it only re-seeds the top-of-bed march temperature).
func _set_inlet(t: float) -> void:
	_inlet_temp = clampf(t, Thermal.INLET_MIN, Thermal.INLET_MAX)


## Change the DESIGN fuel loading — the M5b moderation lever. Like enrichment it is
## applied to freshly injected pebbles ONLY (not restamped onto the burned bed), so a
## new loading propagates as fresh fuel refuels the core: the moderation ratio, and
## with it the sign of the moderator-temperature coefficient, shifts gradually rather
## than flipping the whole core at once. The player watches the core walk from the
## stable under-moderated regime toward the over-moderated instability as it refuels.
func _set_loading(v: float) -> void:
	_fuel_loading = clampf(v, LOADING_MIN, LOADING_MAX)


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
	elif _scrammed:
		status = "SCRAMMED — subcritical, decay-heat cooling"
	elif _k_cold < 1.0 - CRIT_BAND:
		status = "SUBCRITICAL — shutting down"
	elif _peak_temp >= OVER_TEMP_K:
		status = "OVER-TEMP — Doppler can't hold; needs control rods"
	else:
		status = "SELF-REGULATING (critical)"

	# When scrammed, the multiplication the kinetics actually sees is k_eff − SCRAM_WORTH
	# (far subcritical). Show THAT, not the Doppler-regulated ~1.0, so "SCRAMMED" doesn't
	# sit next to a critical-looking k and read like a bug (advisor).
	var k_show := _k_eff - (Thermal.SCRAM_WORTH if _scrammed else 0.0)

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

	# Moderation regime from the DESIGN fuel loading: M = M_REF / loading, labeled by
	# which side of the k_inf(M) peak it sits on — the sign of the moderator coefficient.
	var m_design := CrossSections.moderation(_fuel_loading)
	var mod_regime := "OVER-moderated (MTC +, unstable)" if m_design > MOD_PEAK_M else "under-moderated (MTC −, stable)"

	_label.text = "PEBBLE BED — M5b two-group & moderation\n" \
		+ "active: %d / %d   recirculated: %d\n" % [_pebbles.size(), TARGET_POPULATION, _total_recirculated] \
		+ "injected: %d   discharged: %d\n" % [_total_injected, _total_extracted] \
		+ "design enrichment: %.1f%%  ( [ / ] )    coolant flow: %.2f  ( , / . )\n" % [_enrichment * 100.0, _coolant_flow] \
		+ "fuel loading: %.2f → M %.2f  %s  ( ; / ' )\n" % [_fuel_loading, m_design, mod_regime] \
		+ "coolant inlet: %.0f K  ( K / L )\n" % _inlet_temp \
		+ "feedback: %s  (F)   scram: %s  (Space)   campaign: %.0f\n" % [("ON" if _feedback_on else "OFF"), ("TRIPPED" if _scrammed else "off"), _clocks.campaign_elapsed] \
		+ "k-eff: %.4f   %s\n" % [k_show, status] \
		+ "  cold / uncontrolled k: %.4f\n" % _k_cold \
		+ "fuel temp:  peak %.0f K (ΔT %.0f)   mean %.0f K\n" % [_peak_temp, _peak_temp - Feedback.T_REF, _mean_temp] \
		+ "coolant: inlet %.0f K → outlet %.0f K  (bed ΔT %.0f)\n" % [_inlet_temp, _coolant_out, _coolant_out - _inlet_temp] \
		+ "extracted power: %.0f MWth (toy, secondary side)\n" % _power \
		+ "decay heat: %.0f MWth  (%.0f%% of fuel heat)\n" % [_decay_power, _decay_frac * 100.0] \
		+ outflow \
		+ "field: %s   (V)\n" % field_name \
		+ "solve iters: %d   fps: %d" % [_solve_iters, Engine.get_frames_per_second()]
