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
# Extra pebbles beyond the bed, circulating in the fuel-handling machine (FuelLoop).
#
# WHY the buffer is load-bearing, not decoration: TARGET_POPULATION is a CALIBRATED
# quantity — the bed's fuel inventory is what A_REF and the whole M4/M5 operating
# point were tuned against. Once recirculation takes real time instead of being a
# teleport, pebbles are continuously in the pipe and OUT of the core, so a naive
# implementation would silently run the bed short (≈ ride_time / EXTRACT_INTERVAL
# ≈ 13 pebbles, ~3%), shifting k_cold in a core whose burn-in trough already grazes
# 1 — and the headless suites would NOT catch it, since they drive sim/ directly and
# never see this mechanic. So the inventory is topped up by the buffer and the bed is
# refilled from a staging queue to keep the IN-CORE count pinned at TARGET_POPULATION.
# That decouples ride time from the physics entirely: the ride can be as slow and
# legible as we like at zero reactivity cost.
#
# SIZING: must comfortably exceed worst-case pebbles-in-flight, or the queue starves
# and the bed runs short — the exact failure it exists to prevent. A back-of-envelope
# ride_time / EXTRACT_INTERVAL is NOT enough: the measured peak is ~25 in flight (the
# ride takes longer than nominal whenever the scene runs below real time, and
# extraction bursts), which starved a buffer of 24 and dropped the bed to 379.
# tests/live_fuel_loop.gd measures the real peak and fails if it reaches the buffer;
# this is sized ~2x it. Surplus is nearly free — the extra pebbles just stage at the
# top — so prefer margin over a tight fit.
const LOOP_BUFFER := 48
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
# point where Doppler alone stops being a safe hold. Real cores hold that excess with
# control rods — which, as of M5d, this one has too (N/M; sim/control_rods.gd), so the
# status naming this condition now names a lever the player actually holds.
# ~1800 K ≈ 1500 °C, near the TRISO integrity limit.
const OVER_TEMP_K := 1800.0
# Control-rod drawing (M5d). Amber deliberately matches the rod bar in the HUD, so the
# thing on screen and the thing in the readout are recognizably one control.
const ROD_W := 13.0
const ROD_COLOR := Color(1.0, 0.67, 0.27, 0.95)
# Vessel shell livery. Cool structural greys: the shell must frame the core without
# competing with the field heatmap it surrounds, so the steel is dark and only the two
# faces carry contrast (bright liner inside, dim edge outside).
const WALL_STEEL := Color(0.15, 0.17, 0.22, 1.0)
const WALL_EDGE := Color(0.32, 0.37, 0.46, 0.9)
const WALL_LINER := Color(0.82, 0.86, 0.93, 0.95)
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
var _pebbles: Dictionary = {}   # id -> Pebble (the FULL inventory: bed + machine)
# The fuel-handling machine outside the vessel, and the two places a pebble can be
# while it has no body. A pebble is in exactly one of three states: in the bed (has a
# physics body), riding the machine, or staged in `_queue` at the top waiting for a
# slot. `_out_of_core` is the id set for the latter two — main-side only, so Pebble
# stays a pure sim struct with no notion of the game's fuel handling.
var _loop: FuelLoop
var _queue: Array = []          # [{id, x}] arrived at the top, waiting to enter the bed
var _out_of_core: Dictionary = {}   # id -> true for every pebble with no body
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
# that collapses fission power WITHOUT freezing the thermal/decay loop — the
# walk-away-safe demo watches the decay-heat tail bound the temperature after the trip.
#
# Scram is now a FULL ROD INSERTION and nothing more (_toggle_scram): the trip acts
# through the control rods in the flux solve, not through a lumped kinetics constant.
# So _scrammed is a MODE flag, not a reactivity — it records that the bank was driven
# in by the trip rather than by the player, which is what lets reset put the rods back
# where the player had them.
var _scrammed := false                # emergency shutdown engaged (drives rods full in)
var _pre_scram_insertion := 0.0       # rod position to restore on reset (see _toggle_scram)
var _decay_power := 0.0               # bed-total delivered decay heat (readout, a.u.)
var _decay_frac := 0.0                # decay heat as a fraction of total delivered heat

# Xenon transient & poisoning (M5c). Xe-135 is a strong thermal absorber the pebbles
# accrue from fission (via I-135 decay) and shed by decay + neutron burnout — an
# intermediate-timescale poison whose reactivity worth is shown live, and whose
# post-scram "iodine pit" is the headline transient (pairs with scram + flow cut).
var _xenon_desc: FieldDescriptor      # per-pebble Xe-135 heatmap (Lagrangian)
var _xenon_worth := 0.0               # reactivity worth of current xenon (k_no_xe − k), Δk
var _mean_xenon := 0.0                # bed-average Xe-135 inventory (a.u.)

# Control rods (M5d) — the operator's DIRECT reactivity lever, and the answer to the
# "OVER-TEMP — Doppler can't hold" status this HUD has always been able to show
# without offering a way out. Unlike scram (a lumped kinetics term) these are real
# absorbers in the side-reflector cells (sim/control_rods.gd), so their worth is
# EMERGENT from the diffusion solve — including its S-curve in insertion depth.
# Default 0.0 = fully withdrawn = adds literally nothing to the solve, which is what
# keeps every pre-M5d calibration untouched.
var _rod_insertion := 0.0             # fraction of the grid height the rods span
var _rod_worth := 0.0                 # reactivity the rods are holding down (k_norod − k), Δk

# Coolant transport & loop closure (M4b). The coolant is no longer a uniform inlet:
# it enters cold at the top and warms as it flows down the bed, so each pebble sees a
# LOCAL sink temperature. The heat exchanger closes the loop — extracted power = the
# coolant enthalpy rise (the headline reactor / electrical proxy). Inlet temperature
# is the load-following lever (hotter return → smaller convective gap → lower power).
var _inlet_temp := Thermal.INLET_MIN   # coolant inlet temperature (K), player lever
var _coolant_out := Thermal.INLET_MIN  # hottest coolant seen (bed outlet, readout)
var _coolant_desc: FieldDescriptor     # grid coolant-temperature heatmap
# Height of the coolant heatmap's window above the current inlet. Covers the largest bed
# rise the player can produce (~143 K, at FLOW_MIN — measured in test_thermal's coolant
# transport check) with a little headroom, so the gradient fills the colormap without the
# hot end clamping. This is a LEGIBILITY constant, not physics: nothing reads it but the
# display, and the coolant field itself is unaffected.
const COOLANT_SPAN_K := 160.0
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
var _readout: RichTextLabel


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

	# The fuel-handling machine (conveyor / sorter / spent bin / fresh hopper). Added
	# after the field display so it draws on top of the background heatmap, and it
	# sits outside the vessel walls so it never occludes the bed.
	_loop = FuelLoop.new()
	add_child(_loop)

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
	# DIVERGING colormap pivoted on the peak itself: blue = under-moderated (stable
	# MTC), red = over-moderated (unstable) — the field shows the SIGN of the regime,
	# not just a magnitude (CLAUDE.md: diverging map for signed quantities).
	_moderation_desc = FieldDescriptor.new("Moderation M", "ratio", FieldDescriptor.GRID,
		CrossSections.M_REF / LOADING_MAX, CrossSections.M_REF / LOADING_MIN, false,
		Colormap.COOLWARM, MOD_PEAK_M)
	# Fuel temperature (M2 heatmap; M4 makes it the REAL homogenized field). Fixed
	# range from inlet to the over-temp line so the scale is stable across transients
	# (CLAUDE.md); hotter cells clamp to the top. All temperature/heat fields share
	# inferno so "hot" has one visual language across grid and pebble views.
	_temp_desc = FieldDescriptor.new("Fuel temperature", "K", FieldDescriptor.GRID, Feedback.T_REF, OVER_TEMP_K, false, Colormap.INFERNO)
	# Coolant (helium) temperature (M4b) — a GRID field like flux/fuel-temp, showing the
	# cold inlet at the top warming to a hot outlet at the bottom of the bed.
	#
	# The range TRACKS THE INLET LEVER instead of being a fixed span (see _sync_coolant_range).
	# WHY: what this field exists to show is the downstream RISE, and the rise is ~83 K at
	# nominal flow (~143 K at low flow) wherever the inlet happens to sit. A fixed span wide
	# enough for every reachable state needs to reach INLET_MAX(700) + ~143 ≈ 843 K — and then
	# the DEFAULT view, the one every player sees first, packs the whole rise into the bottom
	# ~17% of the colormap and reads as flat black. That was the shipped behavior; it was only
	# ever visible on screen, never headless (a dummy renderer draws no pixels).
	_coolant_desc = FieldDescriptor.new("Coolant temperature", "K", FieldDescriptor.GRID, Feedback.T_REF, Feedback.T_REF + COOLANT_SPAN_K, false, Colormap.INFERNO)
	# Per-pebble temperature (M4) — the Lagrangian view of the SAME real energy
	# balance: watch one hot pebble travel down the bed. Same fixed range as the grid
	# field so the two views are directly comparable.
	_pebble_temp_desc = FieldDescriptor.new("Pebble temperature", "K", FieldDescriptor.PEBBLE, Feedback.T_REF, OVER_TEMP_K, false, Colormap.INFERNO)
	# Burnup (M3) — the FIRST per-pebble (Lagrangian) field: each pebble colored by
	# its own burnup, so you can literally watch a burned pebble descend the bed
	# (CLAUDE.md two render modes). Fixed range [0, discharge] keeps the scale stable.
	_burnup_desc = FieldDescriptor.new("Burnup", "MWd/kgHM", FieldDescriptor.PEBBLE, 0.0, Depletion.DISCHARGE_BURNUP, false)
	# Decay heat (M5) — a per-pebble (Lagrangian) field: each pebble colored by the heat
	# its decaying fission products are currently releasing. Barely varies during normal
	# operation, but after a SCRAM it is the ONLY heat source, so this view shows the
	# decay-heat tail lingering (and draining) once fission has stopped. Fixed range up to
	# ~γ·S at the peak-flux operating pebble keeps the scale stable.
	_decay_desc = FieldDescriptor.new("Decay heat", "a.u.", FieldDescriptor.PEBBLE, 0.0, 2.0, false, Colormap.INFERNO)
	# Xe-135 (M5c) — a per-pebble (Lagrangian) field: each pebble colored by its transient
	# xenon inventory. During normal operation the bed sits near a uniform equilibrium
	# xenon; after a SCRAM (or flow cut) the pebbles' trapped I-135 keeps decaying into Xe
	# with no flux to burn it out, so this view shows xenon SURGING up (the pit) then
	# draining. Fixed range spans equilibrium up past the pit peak so it reads on a stable
	# scale (single-pebble equilibrium ~2.9e-5, pit crest ~5e-5; range to 8e-5 leaves headroom).
	# Magma: visually distinct from the inferno heat fields it is watched alongside.
	_xenon_desc = FieldDescriptor.new("Xenon-135", "a.u.", FieldDescriptor.PEBBLE, 0.0, 8.0e-5, false, Colormap.MAGMA)

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
		{"desc": _xenon_desc, "get_peb": func(peb: Pebble) -> float: return peb.xe135},
	]

	_build_hud()


# HUD text colors (BBCode). Dim for labels/keys, bright for values, semantic
# colors for the status line — the one thing that must be readable at a glance.
const HUD_DIM := "8a97ab"
const HUD_HEAD := "5c81c4"

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	# Readout panel — the dedicated left column (the vessel + reflector band
	# start at x ≈ 424, see Silo), so the instrument panel never covers the core.
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(panel)
	_readout = RichTextLabel.new()
	_readout.bbcode_enabled = true
	_readout.fit_content = true
	_readout.scroll_active = false
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readout.custom_minimum_size = Vector2(386, 0)
	_readout.add_theme_font_size_override("normal_font_size", 13)
	_readout.add_theme_font_size_override("bold_font_size", 13)
	_readout.add_theme_color_override("default_color", Color(0.93, 0.95, 0.98))
	panel.add_child(_readout)

	# Colorbar — the dedicated right column, beside the reflector band.
	_color_bar = ColorBar.new()
	_color_bar.position = Vector2(1036, 120)
	root.add_child(_color_bar)

	# Key-hints bar along the bottom, out of the way of everything.
	var help := PanelContainer.new()
	help.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	help.offset_left = 12
	help.offset_right = -12
	help.offset_top = -54
	help.offset_bottom = -12
	help.add_theme_stylebox_override("panel", _panel_style(true))
	root.add_child(help)
	var keys := RichTextLabel.new()
	keys.bbcode_enabled = true
	keys.fit_content = true
	keys.scroll_active = false
	keys.add_theme_font_size_override("normal_font_size", 13)
	keys.add_theme_color_override("default_color", Color(0.75, 0.8, 0.88))
	keys.text = "[center]%s[/center]" % "   ".join([
		_key_hint("[ ]", "enrichment"),
		_key_hint(", .", "coolant flow"),
		_key_hint("K L", "inlet temp"),
		_key_hint("; '", "fuel loading"),
		_key_hint("N M", "control rods"),
		_key_hint("F", "feedback"),
		_key_hint("Space", "scram"),
		_key_hint("V", "field"),
	])
	help.add_child(keys)


static func _key_hint(key: String, what: String) -> String:
	return "[b]%s[/b] [color=#%s]%s[/color]" % [key, HUD_DIM, what]


## `opaque` for panels the SCENE can run underneath. The default 0.82 alpha is fine
## over empty background, but the grid — and so the control rods drawn along it (M5d) —
## extends to the bottom of the viewport, and a fully-inserted rod bled through the
## key-hint bar as a bright amber stripe across the text. A HUD panel should occlude the
## scene, not compete with it.
static func _panel_style(opaque := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.08, 1.0 if opaque else 0.82)
	sb.border_color = Color(0.35, 0.42, 0.55, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	return sb


func _process(_delta: float) -> void:
	_update_hud()
	_update_pebble_colors()   # render-clock consumer of sim state (never writes back)


func _physics_process(delta: float) -> void:
	# Native self-steps; kept explicit so an external engine slots in cleanly.
	_physics.step(delta)

	# The fuel-handling machine: advance every pebble riding between the outlet and
	# the top, then act on the ones that arrived. Riders carry no body and no flux,
	# so this is transport bookkeeping only — it touches no physics.
	for arrival in _loop.advance(delta):
		var aid: int = arrival["id"]
		if arrival["kind"] == FuelLoop.DISCHARGE:
			# Reached the bin: gone for good. This is the ONLY thing that shrinks the
			# inventory, and so the only thing that opens a fresh-fuel slot.
			_pebbles.erase(aid)
			_out_of_core.erase(aid)
			_total_extracted += 1
		else:
			# Recirculated or fresh: stage at the top for the next free bed slot.
			_queue.push_back({"id": aid, "x": arrival["x"]})

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


## Pebbles currently in the BED (i.e. holding a physics body, homogenized, fissioning).
## Derived rather than counted so it cannot drift out of step with the registry.
func _core_count() -> int:
	return _pebbles.size() - _out_of_core.size()


## Two jobs per tick, in priority order: mint inventory until the design load exists,
## then top the BED back up to TARGET_POPULATION from the staging queue. Keeping the
## bed pinned at its calibrated count — regardless of how many pebbles are riding the
## machine — is what makes the visible fuel loop free of physics consequences
## (see LOOP_BUFFER).
func _inject_batch() -> void:
	for i in SPAWN_PER_TICK:
		if _pebbles.size() < TARGET_POPULATION + LOOP_BUFFER:
			_mint_pebble()
		if _core_count() < TARGET_POPULATION and not _queue.is_empty():
			_spawn_from_queue()


## Manufacture one pebble at the CURRENT design settings and hand it to the loop.
func _mint_pebble() -> void:
	var id := _next_id
	_next_id += 1
	var peb := Pebble.new(id, PEBBLE_RADIUS)
	_stamp_enrichment(peb, _enrichment)
	peb.fuel_loading = _fuel_loading   # M5b design moderation, stamped at manufacture
	_pebbles[id] = peb
	_out_of_core[id] = true
	_total_injected += 1
	# The INITIAL load is seeded to online-refueling equilibrium (a spread of burnups),
	# not all-fresh — including the buffer, since those pebbles cycle into the bed too
	# and a slug of fresh fuel entering early would be a reactivity bump the equilibrium
	# does not have. It is staged straight to the queue: making the opening load ride in
	# from the hopper one at a time would take minutes of real time.
	if _total_injected <= TARGET_POPULATION + LOOP_BUFFER:
		_seed_burned(peb)
		_queue.push_back({"id": id, "x": Silo.spawn_x(_rng, PEBBLE_RADIUS + 2.0)})
		return
	# Steady state: this is a genuinely fresh replacement for a pebble that just
	# discharged (1:1), so it rides in from the fresh-fuel hopper.
	_loop.add(id, FuelLoop.FRESH, FuelLoop.HOPPER, Silo.spawn_x(_rng, PEBBLE_RADIUS + 2.0),
			PebbleBody.DEFAULT_TINT)


## Move a staged pebble from the top of the machine into the bed, at exactly the x its
## ride ended on, so the hand-off from conveyor to physics body has no visible jump.
func _spawn_from_queue() -> void:
	var slot: Dictionary = _queue.pop_front()
	var id: int = slot["id"]
	_out_of_core.erase(id)
	_physics.spawn_pebble(id, Vector2(slot["x"], Silo.spawn_y()), PEBBLE_RADIUS)


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
	# Gate on the BED being full, not on total inventory: the machine holds pebbles
	# that are in `_pebbles` but not in the core, so the old total-based test would
	# fire while the bed was still filling. It also means a starved staging queue
	# stalls extraction rather than quietly draining the bed — a safe failure.
	if _core_count() < TARGET_POPULATION:
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
	# Close the vacancy in the SAME step the sorter opened it, rather than waiting for
	# the next injection tick: otherwise the bed sits one pebble short for up to
	# SPAWN_INTERVAL, and the flux solve (a shorter cadence still) would sample a core
	# that is momentarily under-fuelled. Tiny, but the whole point of the staging queue
	# is that the bed count is EXACTLY invariant — an almost-invariant would leave a
	# real, if small, mechanism-shaped wobble in k for someone to chase later.
	if not _queue.is_empty():
		_spawn_from_queue()


## Send a not-yet-spent pebble back to the top for another pass, keeping ALL its
## burned state (isotopics, burnup, poison). Population is unchanged, so minting
## does not add a fresh pebble for it — only a true discharge opens a slot.
##
## It now RIDES the machine to get there instead of teleporting: the body is
## destroyed here and rebuilt when the ride ends (_spawn_from_queue). In between the
## pebble has no body, so it is invisible to homogenization, and main freezes its
## state — a pebble in the transport pipe is out of the flux, so it neither fissions
## nor burns. That makes this behavior-identical to the old instant hop apart from
## the delay, which the LOOP_BUFFER absorbs.
func _recirculate(id: int, peb: Pebble) -> void:
	peb.pass_count += 1
	var from := _physics.get_position(id)
	_physics.remove_pebble(id)
	_out_of_core[id] = true
	_loop.add(id, FuelLoop.RECIRC, from, Silo.spawn_x(_rng, PEBBLE_RADIUS + 2.0),
			PebbleBody.DEFAULT_TINT)
	_total_recirculated += 1


## Retire a spent pebble: it rides out to the spent-fuel bin and is erased from the
## inventory on arrival (see _physics_process), which is what opens the slot the next
## mint fills with fresh fuel. The outflow readout is recorded HERE, at the sorter's
## decision, so its semantics are unchanged by the ride.
func _discharge(id: int, peb: Pebble) -> void:
	_record_outflow(peb)
	var from := _physics.get_position(id)
	_physics.remove_pebble(id)
	_out_of_core[id] = true
	_loop.add(id, FuelLoop.DISCHARGE, from, 0.0, PebbleBody.DEFAULT_TINT)


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
		# A pebble riding the fuel machine (or staged at the top) is OUT of the core
		# and out of the flux, so it must not burn. Its last local_flux is stale and
		# non-zero, so without this skip it would keep depleting inside the pipe.
		if _out_of_core.has(id):
			continue
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

	# CONTROL RODS (M5d) go in HERE — after homogenize, BEFORE the bases are snapshot.
	# WHY here and not alongside the feedbacks below: a rod is not feedback, it is part
	# of the core's physical CONFIGURATION, exactly like enrichment or burnup. Applying
	# it to the base means every downstream solve — cold, xenon-worth, warm, AND the
	# feedback-OFF branch — sees the rods for free, with no chance of one path silently
	# forgetting them (withdrawing a rod during the F-toggle demo must still do something).
	# It cannot stack across frames because homogenize unconditionally REWRITES sigma_a2
	# in every cell (fuel/void/reflector branches are exhaustive) before this runs.
	# Snapshot the rod-FREE absorption first, but only when rods are actually in — it is
	# the reference the worth measurement below re-solves against.
	var sa2_norod := _grid.sigma_a2.duplicate() if _rod_insertion > 0.0 else PackedFloat32Array()
	ControlRods.apply_rods(_grid, _rod_insertion)

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

	# Xenon reactivity worth (M5c): re-solve with the Xe-135 absorption stripped out of
	# the thermal group, so the HUD can show how much reactivity the transient poison is
	# eating right now. The post-scram pit reads as THIS number swinging up. grid.xenon
	# holds the per-cell homogenized Xe density; XENON_A2*xenon is exactly what homogenize
	# folded into sigma_a2, so subtracting it and re-solving gives the xenon-free k. One
	# extra cold-style solve per cadence (cheap on this grid); sigma_a2 is restored below
	# by the branch (both restore base_sa2, which KEEPS xenon for the real solve).
	var sa2_xe := _grid.sigma_a2.duplicate()
	for c in range(_grid.cell_count()):
		_grid.sigma_a2[c] = sa2_xe[c] - CrossSections.XENON_A2 * _grid.xenon[c]
	var cold_noxe := Neutronics.solve(_grid)
	_grid.sigma_a2 = sa2_xe   # restore xenon-in absorption before the feedback branch
	_xenon_worth = cold_noxe.k_eff - cold.k_eff   # >0: xenon is suppressing reactivity

	# Control-rod worth (M5d), measured the same honest way as xenon's: re-solve against
	# the rod-FREE absorption snapshot and difference the two. Nothing here knows a rod
	# "worth" number — it is whatever the eigenproblem says the absorbers are costing,
	# which is why it varies with insertion depth (the S-curve), with where the fuel
	# actually sits, and with the rest of the core state.
	#
	# Measured COLD (like xenon worth) so it is the rod's OWN reactivity, not tangled with
	# the feedback's response to it — inserting a rod drops power, which cools the fuel,
	# which releases Doppler and gives some k back; that is the core answering the rod, not
	# the rod's worth. Costs an extra solve ONLY while the rods are in: fully withdrawn,
	# worth is exactly zero by definition and no solve is needed.
	if _rod_insertion > 0.0:
		var sa2_rod := _grid.sigma_a2
		_grid.sigma_a2 = sa2_norod
		var cold_norod := Neutronics.solve(_grid)
		_grid.sigma_a2 = sa2_rod
		_rod_worth = cold_norod.k_eff - cold.k_eff   # >0: the rods are holding k down
	else:
		_rod_worth = 0.0

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
	var xe_sum := 0.0
	var xe_n := 0
	for id in positions:
		var peb: Pebble = _pebbles.get(id)
		if peb != null:
			peb.local_flux = _grid.sample(_last_flux, positions[id])
			peb.local_coolant = _grid.sample(_last_coolant, positions[id])
			xe_sum += peb.xe135
			xe_n += 1
	_mean_xenon = xe_sum / xe_n if xe_n > 0 else 0.0


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
	# Power amplitude: exact exponential update at the frozen-between-solves k.
	#
	# NO scram term here any more, and its absence is load-bearing: scram is now a full
	# rod insertion (_toggle_scram), and the rods are REAL absorbers folded into the grid
	# before the solve (_solve_flux), so _k_eff ALREADY carries the trip — it reads ~0.62
	# on a scrammed core. Subtracting a scram worth on top would double-count it.
	# The thermal/decay loop below keeps integrating either way: heat continues after trip.
	_amplitude = Thermal.step_power(_amplitude, _k_eff, delta)
	var h := Thermal.h_of_flow(_coolant_flow)
	var peak := Feedback.T_REF
	var sum_t := 0.0
	var extracted := 0.0
	var out_t := _inlet_temp
	var sum_decay := 0.0        # bed-total delivered decay heat this step
	var sum_delivered := 0.0    # bed-total delivered fuel heat (prompt + decay)
	var count := 0
	for id in _pebbles:
		# Riding / staged pebbles are outside the core: no fission heat (their stale
		# local_flux would otherwise keep making power in the pipe), and no place in
		# the coolant loop — including them would inflate the headline extracted power
		# and the peak/mean bed temperatures with pebbles that are not in the bed.
		# Their state is FROZEN for the ride, exactly as the old instant hop preserved
		# it; cooling in the pipe is a physics refinement for later.
		if _out_of_core.has(id):
			continue
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
			# Seed Xe-135 to its equilibrium at the pebble's operating flux (A_REF ⇒
			# power_frac ≈ 1, so the operating fluence is just its local peak-normalized
			# flux `lf`). WHY overwrite the xenon _seed_burned already built: that build ran
			# at flux 1.0, which OVER-seeds relative to the operating flux (~0.5 mid-bed), so
			# the bed would open xenon-heavy and droop as it decayed toward operating. Seeding
			# the real operating equilibrium here opens the core at its true xenon load — the
			# same reason temperature and decay heat are seeded (advisor: no startup transient).
			Depletion.seed_xenon(peb, lf)
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
		# desc.color = the field's own colormap through the same normalization as
		# the colorbar, so pebble tints and legend can never disagree.
		var c := desc.color(getter.call(_pebbles[id]))
		# The Lagrangian view should not stop at the vessel wall: a pebble riding the
		# machine keeps its field color, so you can follow one spent (or hot) pebble
		# all the way out to the bin. set_pebble_tint no-ops for a body-less pebble.
		if _out_of_core.has(id):
			_loop.set_rider_tint(id, c)
		else:
			_physics.set_pebble_tint(id, c)


## Restore graphite grey (used when switching from a PEBBLE field back to a GRID one).
func _reset_pebble_tints() -> void:
	for id in _pebbles:
		_physics.set_pebble_tint(id, PebbleBody.DEFAULT_TINT)
		_loop.set_rider_tint(id, PebbleBody.DEFAULT_TINT)


## Stamp FRESH fuel at injection: the toy heavy-metal split grid._enrichment_of()
## reads back as the fissile fraction. From here Depletion.step evolves this vector
## over the pebble's life (U-235 burns, Pu-239 breeds, poison builds).
func _stamp_enrichment(peb: Pebble, e: float) -> void:
	peb.u235 = e
	peb.u238 = 1.0 - e


func _toggle_feedback() -> void:
	_feedback_on = not _feedback_on
	_solve_flux()   # re-solve immediately so the contrast is instant


## Trip / reset the scram. Scram SLAMS THE CONTROL RODS FULLY IN — that is the whole
## mechanism, and there is no longer any lumped "scram worth" anywhere (M5a's
## Thermal.SCRAM_WORTH is deleted). The rods are real absorbers in the solve, so the
## trip's reactivity is EMERGENT: fully in, the bank is worth ~0.38 Δk and drives
## k ~1.01 → ~0.62, collapsing fission power over a ~0.7 s e-fold. That is both deeper
## and faster than the 0.15 constant it replaces, and — unlike the constant — it depresses
## the flux shape, interacts with xenon, and answers to core state.
##
## Unchanged, and still the point: unlike the feedback-OFF freeze, the thermal and
## decay-heat loop keeps running, so the player watches the decay-heat tail keep the core
## hot and bounded after the trip (the walk-away-safe demo — pair it with a flow cut).
##
## RESTORES THE PRE-SCRAM INSERTION on reset rather than withdrawing to zero. Withdrawing
## to zero would re-expose exactly the excess reactivity the player's rods were holding
## down — a core trimmed to critical at 40% would come back supercritical and over-temp,
## with the un-scram itself as the cause. Reset means "undo the trip", not "pull every rod".
##
## Re-solves immediately (like _toggle_feedback, and unlike a manual rod jog): a trip must
## register NOW, not whenever the solve cadence next comes around.
func _toggle_scram() -> void:
	_scrammed = not _scrammed
	if _scrammed:
		_pre_scram_insertion = _rod_insertion
		_rod_insertion = ControlRods.INSERT_MAX
	else:
		_rod_insertion = _pre_scram_insertion
	queue_redraw()   # the rods are drawn from _rod_insertion; the shell only repaints on request
	_solve_flux()


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
	elif event.is_action_pressed("rod_in"):
		_set_rods(_rod_insertion + ControlRods.INSERT_STEP)
	elif event.is_action_pressed("rod_out"):
		_set_rods(_rod_insertion - ControlRods.INSERT_STEP)
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
			# CONTROL RODS (M5d) — the direct reactivity lever. M drives them IN (down,
			# more absorber → k falls), N pulls them OUT. Worth per step is small near the
			# top of the stroke and large mid-bed: that is the S-curve, not a bug.
			KEY_M:
				_set_rods(_rod_insertion + ControlRods.INSERT_STEP)
			KEY_N:
				_set_rods(_rod_insertion - ControlRods.INSERT_STEP)
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


## Drive the control rods (M5d) to a new insertion depth — the operator's direct
## reactivity lever, and the one control that acts on the core's REACTIVITY rather than
## on its heat removal (flow/inlet) or its fuel design (enrichment/loading).
##
## Takes effect on the next flux solve, where the rods' absorption is folded into the
## grid before anything is solved. Re-solving here immediately would fight the solve
## cadence for no gain: unlike the F-toggle (which shows an instant contrast), rod motion
## is a physical change the core answers over its own thermal timescale, so letting the
## next scheduled solve pick it up is both cheaper and honest. (A SCRAM is the exception
## and does re-solve — see _toggle_scram: a trip must register immediately.)
##
## INERT WHILE SCRAMMED. Now that the trip acts through these same rods, a manual jog
## would otherwise walk a scrammed bank back out and quietly defeat the scram — the
## player could "un-trip" the reactor with the rod keys while the HUD still said SCRAMMED.
## Space (reset) is the only way out of a trip, which also keeps the restore-to-pre-scram
## contract intact: nothing can edit _rod_insertion out from under it mid-trip.
func _set_rods(x: float) -> void:
	if _scrammed:
		return
	_rod_insertion = clampf(x, ControlRods.INSERT_MIN, ControlRods.INSERT_MAX)
	queue_redraw()   # the shell is static and only repaints on request; the rods move


## Change the coolant INLET temperature — the M4b load-following lever (advisor).
## Doppler pins the fuel temperature that burns the cold excess, so raising the inlet
## does not change that target; it shrinks the convective gap (T_fuel − T_inlet), so
## each pebble sheds less and the core settles at LOWER power. This delivers the
## CLAUDE.md "coolant temp feeds reactivity, power re-settles" behavior through the
## existing loop — no separate moderator coefficient (that stays M5). Takes effect on
## the next coolant solve (it only re-seeds the top-of-bed march temperature).
func _set_inlet(t: float) -> void:
	_inlet_temp = clampf(t, Thermal.INLET_MIN, Thermal.INLET_MAX)
	_sync_coolant_range()


## Slide the coolant heatmap's window to sit on the current inlet, so the bed's downstream
## rise always fills the colormap instead of being squashed into the bottom of an
## inlet-independent scale.
##
## This is NOT the per-frame auto-ranging CLAUDE.md forbids — that is banned because a scale
## that moves every frame makes transients incomparable. This window moves ONLY when the
## player moves the inlet lever (K/L), so within any run at a fixed inlet the normalization is
## as stable as a constant; it is the "slowly-adapting range with the legend visible" the same
## section allows. The colorbar labels via FieldDescriptor.value_at, i.e. through this exact
## mapping, so the legend re-labels itself and cannot disagree with the colors.
func _sync_coolant_range() -> void:
	if _coolant_desc == null:
		return
	_coolant_desc.vmin = _inlet_temp
	_coolant_desc.vmax = _inlet_temp + COOLANT_SPAN_K


## Change the DESIGN fuel loading — the M5b moderation lever. Like enrichment it is
## applied to freshly injected pebbles ONLY (not restamped onto the burned bed), so a
## new loading propagates as fresh fuel refuels the core: the moderation ratio, and
## with it the sign of the moderator-temperature coefficient, shifts gradually rather
## than flipping the whole core at once. The player watches the core walk from the
## stable under-moderated regime toward the over-moderated instability as it refuels.
func _set_loading(v: float) -> void:
	_fuel_loading = clampf(v, LOADING_MIN, LOADING_MAX)


func _draw() -> void:
	# Silo shell as STRUCTURAL WALLS, not lines. Drawn in the parent's pass so it sits
	# above the background heatmap but below the pebbles.
	#
	# The steel is a filled band per wall segment, offset OUTWARD from the collision face
	# (Silo.shell_quads) — so the vessel gained thickness without the bed losing a single
	# pixel of volume, and every pre-existing calibration is untouched by construction
	# (see Silo.WALL_T). Opaque on purpose: a wall should occlude the field behind it.
	# The bright INNER liner is drawn last and lies exactly on the collision face, so what
	# the eye reads as "the wall" is precisely where a pebble actually stops.
	for quad in Silo.shell_quads():
		draw_colored_polygon(quad, WALL_STEEL)
		draw_line(quad[3], quad[2], WALL_EDGE, 1.5)    # outer face of the steel
		draw_line(quad[0], quad[1], WALL_LINER, 2.5)   # inner face = the collision face

	# The discharge chute mark that used to be here is gone: the fuel machine now draws a
	# real pipe out of the hopper bottom (FuelLoop), which pierces this floor and says the
	# same thing literally instead of by suggestion.

	# CONTROL RODS (M5d), drawn OUTSIDE the vessel walls — which is the point of them:
	# they ride in borings in the side reflector because a rod cannot be pushed into a
	# packed pebble bed. Seeing them alongside the bed rather than in it is the geometry
	# lesson, so it is worth drawing them literally where the solve absorbs.
	#
	# Geometry comes from ControlRods.rod_columns(_grid) and the grid's own origin/cell
	# size — never from re-derived constants — so the picture cannot drift out of sync
	# with the cells actually being absorbed in. If it looks wrong, the physics IS wrong.
	if _grid != null:
		var col_h := float(_grid.ny) * _grid.h
		var depth := _rod_insertion * col_h
		for i in ControlRods.rod_columns(_grid):
			var cx := _grid.ox + (float(i) + 0.5) * _grid.h
			# The empty channel: always visible, so the rods have a legible home to slide
			# down and a withdrawn rod doesn't look like a missing feature.
			draw_line(Vector2(cx, _grid.oy), Vector2(cx, _grid.oy + col_h), Color(1, 1, 1, 0.07), ROD_W)
			if depth > 0.0:
				var tip := Vector2(cx, _grid.oy + depth)
				draw_line(Vector2(cx, _grid.oy), tip, Color(0.10, 0.07, 0.03, 0.95), ROD_W)
				draw_line(Vector2(cx, _grid.oy), tip, ROD_COLOR, ROD_W * 0.45)
				# Mark the tip: the tip's depth is what the worth curve is all about.
				draw_line(tip - Vector2(ROD_W * 0.5, 0), tip + Vector2(ROD_W * 0.5, 0), ROD_COLOR, 2.5)


func _update_hud() -> void:
	var field_name: String = _fields[_current_field]["desc"].name if not _fields.is_empty() else "-"

	# Status. A core at online-refueling equilibrium is CRITICAL (k_cold ~ 1), so the
	# strict k>1 test would flicker; treat within CRIT_BAND of 1 as self-regulating,
	# and reserve "shutting down" for a clearly subcritical core (the passive-safety demo).
	# Each status carries its own color — the status line is the one glanceable thing.
	var status := ""
	var status_col := "6ecf7a"
	if not _feedback_on:
		status = "UNCONTROLLED — no self-limiting"
		status_col = "ff5555"
	elif _scrammed:
		status = "SCRAMMED — subcritical, decay-heat cooling"
		status_col = "ffaa44"
	elif _k_cold < 1.0 - CRIT_BAND:
		# Distinguish a genuine xenon "dead time" from an ordinary subcritical core. The
		# dead-time condition is PRECISE: subcritical NOW, but the core WOULD be critical if
		# the xenon cleared (k_cold + xenon_worth > 1) — so Xe-135 alone is holding it down
		# and it cannot restart until the xenon decays. A low-enrichment shutdown (k_cold far
		# below 1, xenon a minor contributor) correctly reads as an ordinary shutdown, NOT a
		# pit. NOTE this is a REACHABLE state, not the default: at the nominal operating point
		# k_cold sits ~1.01–1.02 and the ~0.2% pit swing stays well above the 0.99 gate, so
		# the pit is a visible reactivity transient there, not a restart-blocker. It becomes a
		# true dead time only if the core is run near-critical (e.g. enrichment dialed down)
		# and then scrammed while carrying its xenon load.
		var xenon_pit := _xenon_worth > 0.005 and _k_cold + _xenon_worth > 1.0
		# The rod analogue of the pit test, and PRECISE in the same way (M5d): subcritical
		# now, but the core WOULD be critical if the rods came out — so the operator's rods,
		# not spent fuel or poison, are what is holding it down. Checked FIRST because it is
		# the one cause here that is a deliberate human action: if the player just drove the
		# rods in, "held down by control rods" is the true explanation and "shutting down"
		# would read as though the core had failed. A core that is subcritical for other
		# reasons while rods happen to be part-in still falls through to the real cause.
		var rod_held := _rod_worth > 0.005 and _k_cold + _rod_worth > 1.0
		if rod_held:
			status = "SUBCRITICAL — held down by control rods (N to withdraw)"
			status_col = "ffaa44"
		elif xenon_pit:
			status = "SUBCRITICAL — XENON PIT (dead time; wait for Xe decay)"
			status_col = "c792ea"
		else:
			status = "SUBCRITICAL — shutting down"
			status_col = "7aa2f7"
	elif _peak_temp >= OVER_TEMP_K:
		# The rods are the answer to this one (M5d). Before they existed this status named a
		# control the player did not have; now it names the key that fixes it.
		status = "OVER-TEMP — Doppler can't hold alone; insert rods (M)"
		status_col = "ff7043"
	else:
		status = "SELF-REGULATING (critical)"
		status_col = "6ecf7a"

	# Outflow composition of discharged (spent) fuel — the "inspect the spent fuel
	# flowing out the bottom" deliverable: running averages + the last discharge.
	var outflow := ""
	if _out_count > 0:
		outflow = _row("discharged %d" % _out_count,
				"avg burnup %.0f   passes %.1f" % [_out_burnup_sum / _out_count, float(_out_passes_sum) / _out_count]) \
			+ _row("composition", "fissile %.1f%%   Pu-239 %.3f   poison %.4f"
				% [(_out_fissile_sum / _out_count) * 100.0, _out_pu_sum / _out_count, _out_poison_sum / _out_count]) \
			+ _row("last out", "burnup %.0f   passes %d   fissile %.1f%%"
				% [_last_out_burnup, _last_out_passes, _last_out_fissile * 100.0])
	else:
		outflow = _row("discharged 0", "fuel still below discharge burnup")

	# Moderation regime from the DESIGN fuel loading: M = M_REF / loading, labeled by
	# which side of the k_inf(M) peak it sits on — the sign of the moderator coefficient.
	var m_design := CrossSections.moderation(_fuel_loading)
	var mod_regime := "[color=#ff7043]OVER-moderated (MTC +, unstable)[/color]" if m_design > MOD_PEAK_M \
			else "[color=#7aa2f7]under-moderated (MTC −, stable)[/color]"

	# Xenon readout: worth = how much reactivity Xe-135 is eating now (Δk). After a scram
	# or flow cut, fission stops but trapped I-135 keeps decaying into Xe, so this climbs
	# — the iodine pit. Flag that state so the player can watch the pit build and drain.
	#
	# The threshold HALVED (0.006 -> 0.003) when scram was unified with the rods, and the
	# reason is absorber SHADOWING, not a xenon change: a scrammed core has the rod bank
	# fully in, and rods and xenon compete for the same thermal neutrons, so the SAME Xe
	# inventory that is worth ~1.05% unrodded measures only ~0.54% once the trip lands
	# (gated in tests/live_xenon.gd). Against the old 0.006 the post-trip pit range of
	# ~0.5-0.7% straddled the bar and the note would flicker mid-transient.
	# This is well-defined rather than a fudge BECAUSE the note is gated on _scrammed: a
	# scrammed core is always at EXACTLY full insertion, so there is only ever one rod
	# configuration in which this threshold is read, and one scale to tune it against.
	var xe_note := "  [color=#c792ea]pit building[/color]" if (_scrammed and _xenon_worth > 0.003) else ""

	# Control-rod readout (M5d): the bar shows WHERE in the stroke the rods are, the worth
	# beside it shows what that position is actually buying. Showing the pair together is
	# what makes the S-curve legible — the bar moves in equal steps while the worth does
	# not, which is the whole lesson of a rod-worth curve.
	var rod_pips := int(round(_rod_insertion * 10.0))
	var rod_bar := "[color=#ffaa44]%s[/color][color=#%s]%s[/color] %.0f%% in" \
		% ["█".repeat(rod_pips), HUD_DIM, "·".repeat(10 - rod_pips), _rod_insertion * 100.0]
	# Name the SCRAM as the reason the bank is buried, and say the keys are dead — otherwise
	# a tripped core just shows rods pinned at 100% and the player is left pressing N at a
	# bank that (correctly) refuses to move, with nothing on screen explaining why.
	var rod_note := ""
	if _scrammed:
		rod_note = "  [color=#ffaa44]SCRAM — driven in (Space to reset)[/color]"
	elif _rod_insertion <= 0.0:
		rod_note = "  [color=#%s]withdrawn[/color]" % HUD_DIM

	_readout.text = "[b]PEBBLE BED REACTOR[/b]  [color=#%s]toy sim — M5d[/color]\n" % HUD_DIM \
		+ "[color=#%s]● %s[/color]\n" % [status_col, status] \
		+ _section("CORE") \
		# k-eff needs no scram special case any more: a scrammed core has the rods IN the
		# solve, so this reads an honestly subcritical ~0.62 on its own. The old lumped term
		# needed a display hack here to avoid printing a critical-looking ~1.0 next to
		# "SCRAMMED" — don't reintroduce one; the physics covers it.
		+ _row("k-eff", "[b]%.4f[/b]    cold / uncontrolled %.4f" % [_k_eff, _k_cold]) \
		+ _row("xenon", "worth %.2f%% Δk   mean Xe %.1f ×1e-5%s" % [_xenon_worth * 100.0, _mean_xenon * 1e5, xe_note]) \
		+ _row("rods", "%s   worth %.2f%% Δk%s" % [rod_bar, _rod_worth * 100.0, rod_note]) \
		+ _section("POWER & HEAT") \
		+ _row("power", "[b]%.0f MWth[/b] extracted   decay heat %.0f MWth (%.0f%%)" % [_power, _decay_power, _decay_frac * 100.0]) \
		+ _row("fuel temp", "peak %.0f K (ΔT %.0f)   mean %.0f K" % [_peak_temp, _peak_temp - Feedback.T_REF, _mean_temp]) \
		+ _row("coolant", "%.0f → %.0f K (bed ΔT %.0f)" % [_inlet_temp, _coolant_out, _coolant_out - _inlet_temp]) \
		+ _section("FUEL CYCLE") \
		+ _row("in core", "%d / %d   (%d riding the loop)" % [_core_count(), TARGET_POPULATION, _loop.count()]) \
		+ _row("cycle", "recirculated %d   discharged %d   made %d" % [_total_recirculated, _total_extracted, _total_injected]) \
		+ _section("SPENT FUEL OUT") \
		+ outflow \
		+ _section("DESIGN & CONTROLS") \
		+ _row("enrichment", "%.1f%% fresh fuel   flow %.2f   inlet %.0f K" % [_enrichment * 100.0, _coolant_flow, _inlet_temp]) \
		+ _row("loading", "%.2f → M %.2f  %s" % [_fuel_loading, m_design, mod_regime]) \
		+ _row("feedback", "%s   scram %s   campaign %.0f" % [("[color=#6ecf7a]ON[/color]" if _feedback_on else "[color=#ff5555]OFF[/color]"), ("[color=#ffaa44]TRIPPED[/color]" if _scrammed else "off"), _clocks.campaign_elapsed]) \
		+ _section("FIELD") \
		+ _row(field_name, "solve iters %d   fps %d" % [_solve_iters, Engine.get_frames_per_second()])


## One dim section header line of the readout panel.
static func _section(title: String) -> String:
	return "[color=#%s][b]%s[/b][/color]\n" % [HUD_HEAD, title]


## One "label value…" line of the readout panel: dim label, bright value.
static func _row(label: String, value: String) -> String:
	return "[color=#%s]%s[/color]  %s\n" % [HUD_DIM, label, value]
