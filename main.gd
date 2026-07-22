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

# The CALIBRATED operating population — the bed's fuel inventory is what A_REF and the
# whole M4/M5 operating point were tuned against. Phase 3c stopped pinning the LIVE bed
# count to this: it is now a "recommended" reference the HUD shows alongside the
# player's own `_population_setpoint`, which is what the fuel machine actually chases.
# Kept as the boot default and the number every subcriticality/overfill readout compares
# the live count against.
const RECOMMENDED_POPULATION := 380
# How far above RECOMMENDED_POPULATION the player may push the setpoint (the "overfill"
# lever). Bounded well inside CLAUDE.md's "hundreds to a few thousand" perf envelope —
# generous enough to make a genuinely taller, denser pile (and eventually jam the inlet,
# see `_admit_batch`), not so large it risks the granular solver.
const OVERFILL_MAX := 800

# Extra pebbles beyond the bed, circulating in the fuel-handling machine (FuelLoop).
#
# WHY the buffer is load-bearing, not decoration: once recirculation takes real time
# instead of being a teleport, pebbles are continuously in the pipe and OUT of the core,
# so a naive implementation would silently run the bed short of the player's setpoint
# (≈ ride_time / EXTRACT_INTERVAL ≈ 13 pebbles, ~3%) — and the headless suites would NOT
# catch it, since they drive sim/ directly and never see this mechanic. So the inventory
# is minted ahead of the setpoint by this buffer, and the bed is refilled from whatever is
# waiting at the inlet (`_admit_batch`) to keep the IN-CORE count tracking the setpoint.
# That decouples ride time from the physics entirely: the ride can be as slow and
# legible as we like at zero reactivity cost.
#
# SIZING: must comfortably exceed worst-case pebbles-in-flight, or the inlet starves
# and the bed runs short — the exact failure it exists to prevent. A back-of-envelope
# ride_time / EXTRACT_INTERVAL is NOT enough: the measured peak is ~25 in flight (the
# ride takes longer than nominal whenever the scene runs below real time, and
# extraction bursts), which starved a buffer of 24 and dropped the bed to 379.
# tests/live_fuel_loop.gd measures the real peak and fails if it reaches the buffer;
# this is sized ~2x it. Surplus is nearly free — the extra pebbles just pile up at the
# inlet, visibly — so prefer margin over a tight fit.
const LOOP_BUFFER := 48
const SPAWN_PER_TICK := 3
const SPAWN_INTERVAL := 0.12    # seconds between injection ticks
const PEBBLE_RADIUS := 8.0
# Design SIZE lever (the third of CLAUDE.md's three knobs, after enrichment and
# loading). Stamped at manufacture like the other two, so it reaches the bed only as
# fresh fuel cycles in — you watch the new size arrive one pebble at a time.
#
# WHAT SIZE ACTUALLY DOES HERE, stated plainly because it is easy to assume otherwise:
# radius reaches the physics through exactly one path — grid.gd sums PI*r^2 into each
# cell's packing. Packing fraction is SCALE-INVARIANT (bigger circles settle at the
# same ~0.61 areal packing), so a UNIFORM size change does not move any cross-section.
# What it does move is GEOMETRY: the bed holds a pinned COUNT, so bigger pebbles need
# more volume, the bed grows taller into more fuel cells, and leakage falls — k rises.
# That is a real lever, but it is a leakage lever, not the surface-to-volume /
# self-shielding one CLAUDE.md describes; no self-shielding term exists yet (see the
# corrected note in sim/pebble.gd). MIXING sizes is different and IS already modelled:
# small pebbles fill the gaps between big ones, packing genuinely rises, and the
# area-summing homogenization picks that up with no new physics.
#
# The ceiling is DERIVED from the transport bore, not picked: the fuel machine is a
# pipe of fixed width, and a pebble wider than its bore would be drawn outside the
# casing it is supposed to be travelling inside. Tying the two together means the pipe
# can never be retuned into a lie — widen BORE_W and the lever follows.
const RADIUS_DEFAULT := PEBBLE_RADIUS
const RADIUS_MIN := 5.0
const RADIUS_MAX := FuelLoop.BORE_W * 0.5   # the pebble must fit the pipe it rides in
const RADIUS_STEP := 0.25
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
# --- Fuel-cycle policy limits (the live recirculate-vs-discharge criteria; see
# _discharge_burnup / _max_passes for WHY the policy lives in main and the calibrated
# constants stay in sim/depletion.gd).
#
# The band brackets the HTR-PM ~90-100 MWd/kgHM reference (CLAUDE.md) generously on BOTH
# sides, because both directions teach something real and neither is a misuse:
#   * DOWN — discharge fuel long before it is spent. Wasteful (the outflow readout shows
#     fissile still on the table), and it drives the bed's mean burnup down, so the core
#     gets MORE reactive. Taken far enough it is the classic once-through-vs-multi-pass
#     tradeoff made visible. Lowering it below burnups already IN the bed starts a
#     discharge WAVE as the sorter works through the newly-spent backlog — correct
#     emergent behavior, not a bug, and metered at one per EXTRACT_INTERVAL rather than
#     an instant dump.
#   * UP — squeeze every last MWd out of each pebble. The bed ages, poisons accumulate,
#     and reactivity falls until the core cannot hold criticality. That is the real
#     ceiling on discharge burnup, and here the player finds it by hitting it.
# The floor is not 0: at 0 every pebble is born spent and the cycle degenerates into
# mint-and-discharge with no reactor in the middle.
const DISCHARGE_MIN := 10.0
const DISCHARGE_MAX := 160.0
const DISCHARGE_STEP := 2.5
# Passes is a BACKSTOP, not the primary criterion (a pebble parked in a cold spot must
# not recirculate forever). The floor is 1 — "one pass and out" is once-through fuelling,
# a real cycle worth being able to build, not a degenerate setting.
const PASSES_MIN := 1
const PASSES_MAX := 40
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
# Selection ring (inspector). Cyan on purpose: every field colormap in the registry is
# a warm or purple ramp (inferno / magma / viridis), so a cyan ring cannot be mistaken
# for a field value no matter which heatmap is up.
const SELECT_RING := Color(0.35, 0.95, 1.0, 0.95)
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
# The fuel-handling machine outside the vessel, and the places a pebble can be when it is
# not fuel in the bed. A pebble is in exactly one of six states: in the BED (a body the
# neutronics sees); in TRANSIT through the duct, a riser, or a merge run (a body, on a
# belt); PENDING at the shared drop's mouth waiting for room (no body — this one door
# still needs one, see `_feed_drop`); PENDING at REINJECT's OWN mouth, the same wait at a
# different door (no body, likewise); MANUFACTURED but not yet shown, waiting in
# `_mint_pending` for the top of the inlet pipe to clear (no body — see `_feed_inlet_top`;
# this is not the "no body, nothing draws it" staging Phase 3c otherwise retired, because
# nothing has ever shown this pebble existing to make disappear); WAITING at the shared
# INLET, piled against its closed floor (a body — no list of its own; found by position,
# see `_admit_batch`); or settled in the spent POOL (a body, in a real tray).
# `_out_of_core` is the id set for the five that are not the bed — main-side only, so
# Pebble stays a pure sim struct with no notion of the game's fuel handling.
#
# This list has grown and shrunk more than once, and the same line has held every time:
# `_out_of_core` means NOT FUEL, never "has no body". It used to mean both, back when the
# only way to leave the bed was to stop existing mechanically — the pool (Phase 3a), the
# pipes (3b), and the inlet (3c) all broke that coincidence, and every reader that had
# quietly come to depend on it had to be re-pointed. Losing or gaining a state is cheap;
# re-deriving which flag meant what is not.
var _loop: FuelLoop
var _out_of_core: Dictionary = {}   # id -> true for every pebble outside the bed
# Manufactured pebbles waiting for the top of the inlet pipe to clear, oldest first — see
# `_mint_pebble`/`_feed_inlet_top`. Bodiless like `_drop_pending`, and for the identical
# reason: LOOP_BUFFER lets minting run up to 48 pebbles ahead of the setpoint, several per
# tick, and the inlet pipe is short — it cannot be handed that many bodies at the same
# point in the same instant without the solver firing them apart.
var _mint_pending: Array = []
# Pebbles being carried through the pipes as REAL BODIES (Phase 3b) — id -> leg. A FIFTH
# state, and the first one that is out of the core while still holding a body. Not "down": the
# recirculation leg goes down the drop, out along the duct and then 880 px UP the riser.
#
# It exists because a belt-driven pebble has to be told apart from a settled one: both are
# bodies the engine is stepping, but this one still needs pushing and still needs watching
# for arrival, and the pooled one is done. Membership here is what the belt drives and
# nothing else — so a pebble that arrives simply leaves this set, and the physics keeps
# hold of the same body throughout. Nothing is destroyed or re-created at the hand-off.
#
# Note it does NOT replace `_out_of_core`, it rides alongside it: `_out_of_core` answers
# the NEUTRONICS question ("is this fuel in the bed"), which for a transiting pebble is no.
# That one flag is the whole reason this leg cannot shift k (see `_core_positions`).
#
# It carries the pebble's LEG, not just its membership, and that is the whole design of the
# belts since Phase 3b-ii put recirculation on one too. Both legs share the drop and share the
# duct, running opposite ways out of the sorter, so where a body IS cannot tell you which way
# to push it — only its leg can (see `_drive`). The sorter decides once and this remembers.
var _transit: Dictionary = {}
# Pebbles the sorter has taken but the drop has not accepted yet, oldest first — the pipe's
# feed queue, as [{peb, leg}]. A SIXTH state, and bodiless like the riders and the staging
# queue. See `_feed_drop` for why a physical pipe needs a door, and why both legs queue in
# this ONE list: the vessel has one outlet, so they are genuinely waiting for the same hole.
var _drop_pending: Array = []
# Pebbles pulled from the pool, waiting for REINJECT's own mouth to clear (Phase 3b-iii).
# A SEVENTH state, and a separate queue from `_drop_pending` because it is a separate door —
# the reinject riser does not share the outlet's drop, so it has no reason to share that
# drop's back-pressure.
var _reinject_pending: Array = []
# Pebbles that finished their last pass and settled in the spent-fuel pool, oldest
# first. A FOURTH state, and — since the pool became RE-INJECTABLE — one that lives
# INSIDE `_pebbles`, flagged out-of-core, like every other bodiless state.
#
# This inverts what this comment used to say ("deliberately OUTSIDE `_pebbles`"), so
# here is why that was right then and wrong now. A spent pebble was out of the fuel
# cycle FOR GOOD, so holding a slot against the mint gate would have starved the bed
# of fresh fuel forever. Once a pebble can come BACK, "for good" is false: the pool is
# a reservoir the player draws from, and a pebble in it is inventory that merely is
# not in the bed — exactly what `_out_of_core` already means for riders and staged
# pebbles. Keeping it out of `_pebbles` would mean re-injection has to hand-maintain
# a budget the registry is already keeping.
#
# The gate that cared now subtracts the pool explicitly (`_inventory()`), so the pool
# still holds no slot — the arithmetic is IDENTICAL, just stated instead of implied.
# See `_inventory()` for the neutrality proof, which is the whole reason this is safe
# to do without re-calibrating anything.
#
# `_spent` holds the Pebble objects (not ids) because it also carries the pool's
# ORDER — oldest first — which drives both the display window and the drop-oldest cap.
# It is the ONLY structure the pool needs: `_out_of_core` already answers "is it fuel"
# and `_spent.size()` already answers "how many are parked", so there is no second
# membership set to drift out of step with this one.
#
# It must ALSO never become FUEL. The spent pool sits at (480, ~1000), and the
# neutronics grid spans x ∈ [424, 1036], y ∈ [-16, 1072] (Grid.for_silo) — so a pool
# slot is a VALID cell, not outside the grid, and a pool pebble reaching homogenize()
# would blend the spent pile into the flux solve as if it were fuel in the core,
# silently shifting k.
#
# Note what that does and does NOT forbid. The guard is neutronic ("not fuel"), not
# physical ("no body"): the coupling reads `_core_positions()`, which filters on
# `_out_of_core`, so bed membership is DECLARED rather than inferred from whether the
# engine happens to hold a body. A pool pebble may therefore have a real body — it
# must, to collide and to be re-injectable — and still be invisible to the flux. This
# comment used to say the pile was bodiless "for that reason, not for cheapness";
# that was true of the mechanism but overstated the requirement, and the distinction
# is what lets the pool become a real pile of colliding pebbles.
var _spent: Array = []

# --- Inspector (read-only) ---
#
# The pebble the player has clicked, or null. Held as the Pebble itself rather than
# an id because a spent pebble HAS no id in `_pebbles` any more — it left the
# inventory — and the inspector's whole point is that it reaches every pebble,
# including the ones that have finished.
#
# Read-only BY CONSTRUCTION, and that is not timidity: visualization is a pure
# consumer of sim state and never writes back (CLAUDE.md). Editing is a separate,
# narrower thing — it is confined to pebbles OUTSIDE the core, where a change cannot
# perturb a running solve mid-step.
var _selected: Pebble = null
var _selected_where := ""
var _overlay: Node2D
var _inspector: RichTextLabel
var _rng := RandomNumberGenerator.new()
var _next_id := 0
var _spawn_accum := 0.0
var _extract_accum := 0.0
var _solve_accum := 0.0
var _fill_accum := 0.0

# Population/fill control (Phase 3c) — what the fuel machine chases and how fast it is
# allowed to chase it, both player levers now instead of the old hard-pinned
# TARGET_POPULATION. See `RECOMMENDED_POPULATION`/`OVERFILL_MAX` for the bounds.
var _population_setpoint := RECOMMENDED_POPULATION
# Pebbles/sec `_admit_batch` is allowed to cross from the inlet pile into the bed. Slow end
# is for watching a single pebble land (teaching an empty-start climb to criticality); the
# top end SATURATES on purpose rather than reaching an arbitrary large number — the real
# ceiling is the inlet's own physics (`FuelLoop.INLET_LANES` parallel columns, each
# gravity-limited to ~4.5/s by how fast a body clears `INLET_MOUTH_CLEAR`), so a max far
# above that would leave most of the slider doing nothing. MEASURED before widening the
# pipe: a single-lane inlet capped real fill at ~4.3/s regardless of this slider, with
# FILL_RATE_MAX=100 that left over 95% of the range dead. Three lanes raise the physical
# ceiling to ~13/s; FILL_RATE_MAX sits just above it so the top of the slider is an honest
# "as fast as the pipe goes", not a bigger dead zone at a bigger number. The very first
# boot skips this path entirely — see `_seed_initial_bed`.
var _fill_rate := 15.0
const FILL_RATE_MIN := 1.0
const FILL_RATE_MAX := 20.0
var _fill_paused := false

# The campaign (burnup) clock (M3). Its campaign_dt drives depletion and NOTHING
# else — never the physics step or the flux solve (CLAUDE.md principle 1).
var _clocks := Clocks.new()

# Neutronics / visualization (M1)
var _grid: Grid
var _field_display: FieldDisplay
var _color_bar: ColorBar

# Mouse-clickable controls panel (Phase 3c) — see `_build_controls_panel`.
# Sliders: [{label, text, get, slider, fmt}]; toggles: [{button, get}]. Kept as untyped
# dictionaries (not a resource) because they only ever round-trip within this one file,
# between build time and `_sync_controls_panel`.
var _control_specs: Array = []
var _toggle_specs: Array = []
var _pause_button: Button
var _feedback_button: Button
var _scram_button: Button
var _restamp_button: Button
var _reinject_button: Button
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
var _pebble_radius := RADIUS_DEFAULT   # design size lever; stamped on fresh fuel

# --- Fuel-cycle POLICY, live-editable (the recirculate-vs-discharge criteria).
#
# The rule the sorter applies to every pebble that reaches the bottom: below BOTH of
# these it goes back up for another pass; at or past EITHER it leaves for good. That
# decision was previously hard-wired to the Depletion constants, so the player could
# watch the fuel cycle but not operate it — the one part of the cycle with a genuine
# operating choice in it (how hard do you burn your fuel?) was the part they could not
# touch.
#
# WHY the knob lives HERE and the constants stay in sim/depletion.gd, rather than the
# constants simply becoming mutable: the constants have SEVERAL readers and only ONE of
# them wants the live value (see below). They are also calibration-linked — test_depletion
# pins the burn rates against DISCHARGE_BURNUP ("a pebble reaches discharge over ~6-15
# passes"), so making them mutable global state would let one test case leak its policy
# into the next, and would quietly redefine the constant that several calibrations are
# expressed in terms of. sim/ stays pure; the POLICY (an operating choice) lives with the
# operator, and the CONSTANT stays what it always was: the calibrated reference default.
#
# The split between who reads which — the rule is "what will happen to this pebble" vs
# "what fixed scale was calibrated":
#   LIVE (policy — the pebble's fate):  _extract_lowest's decision, and the inspector's
#       burnup/passes/(spent) rows. The inspector MUST track the live knob or it lies:
#       a sorter discharging at 40 while the panel reads "45 / 90, not spent" is the
#       two-worlds-disagree bug that commit 7b0be70 fixed for radius, in another costume.
#       (Safe by nature, too: the inspector is a pure render consumer that writes nothing
#       back, so pointing it live cannot perturb a solve.)
#   DEFAULT (calibrated reference — NOT policy):  the burnup FieldDescriptor's range
#       (CLAUDE.md demands STABLE normalization — rescaling the colormap because the
#       player nudged a policy knob would recolor every pebble and destroy exactly the
#       frame-to-frame comparability the rule exists to protect), and _seed_burned (a
#       one-time startup calibration; the knob is an operating lever, and moving it must
#       not rewrite the core's history).
#
# Accepted consequence of that split, which is honest rather than a defect: with a lowered
# threshold a pebble can sit at ~44% of the colormap's 0..90 range and still be tagged
# (spent). The color is absolute burnup; the tag is the policy verdict. Two real axes.
#
# Defaulted BY REFERENCE, never a re-typed 90.0/15 — so "neutral at the default setting"
# is true by construction (the M5d pattern) and cannot silently drift if anyone retunes
# the constants.
var _discharge_burnup := Depletion.DISCHARGE_BURNUP
var _max_passes := Depletion.MAX_PASSES
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
# Pebbles shipped from the full pool to a cask — gone from the sim for good. Counted, not
# silent: a capped view that quietly drops things reads as a stalled discharge leg, and
# the player must be able to tell "the tray is full" from "the plant stopped".
var _total_shipped := 0
# Pebbles the player pulled back out of the pool and sent round again. A SEPARATE counter
# rather than a decrement of `_total_extracted`: the discharge really happened, and
# un-counting it would falsify the pool's own accounting (held + casked == discharged).
var _total_reinjected := 0
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

	# The spent-fuel tray is a real vessel too: discharged pebbles are bodies that fall
	# into it and pile up. Its walls go in beside the silo's because they are the same
	# kind of thing — immovable steel the pebbles rest on — and the backend cannot tell
	# them apart. What keeps this pile out of the reactor physics is not the geometry
	# but `_out_of_core` (see `_core_positions`): the tray sits over valid grid cells.
	for seg in FuelLoop.pool_walls():
		_physics.add_static_segment(seg[0], seg[1])

	# The transport pipes are solid too (Phase 3b): an extracted pebble is a real body from
	# the outlet to wherever it is going — down to the pool if it is spent, out along the duct
	# and up the riser if it is not. So the pipes it travels need faces to travel down. Same
	# reasoning as the tray's walls above — immovable steel the backend cannot tell from the
	# silo's — and the same guard keeps them out of the reactor: a body in this pipework is
	# `_out_of_core`, so the pipes crossing valid grid cells cost nothing.
	for seg in FuelLoop.plant_walls():
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

	# The selection ring, above EVERYTHING: the pebble bodies draw after both the field
	# display and the plant, so the marker for a bed pebble has to outrank them or it is
	# painted over by the pebble it points at.
	_overlay = Node2D.new()
	_overlay.z_index = 50
	_overlay.draw.connect(_draw_selection)
	add_child(_overlay)

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

	# Boot "starts filled" by default (Phase 3c): commission the plant toward the
	# recommended population INSTANTLY, by placing already-settled bodies directly
	# (`_seed_initial_bed`) rather than playing the real admission physics back sped up.
	# A manual restart never does this — see `_restart_reactor`, which runs the real,
	# watchable fill at normal speed.
	_reset_population(RECOMMENDED_POPULATION)
	_seed_initial_bed(RECOMMENDED_POPULATION)


## Clear every piece of population/campaign state and start the plant toward `start`
## pebbles. Called once at boot (`_ready`) and by the player's "Restart Reactor" control
## (Phase 3c) — the same path both times, so a restart is not a special case of startup,
## it IS startup.
##
## Deliberately narrow: only simulation state that describes THE FUEL INVENTORY resets.
## The player's design/operating levers (enrichment, size, loading, flow, inlet temp,
## rods, feedback, discharge policy) are NOT touched — a restart is "empty the plant and
## refill it", not "undo my settings".
func _reset_population(start: int) -> void:
	# Every physics body the plant is holding, bed or otherwise — the bed, transit, the
	# inlet pile, and the pool are all real bodies now (Phase 3c), so one sweep over
	# `positions()` reaches all of them.
	for id in _physics.positions().keys():
		_physics.remove_pebble(id)

	_pebbles.clear()
	_out_of_core.clear()
	_transit.clear()
	_drop_pending.clear()
	_reinject_pending.clear()
	_mint_pending.clear()
	_spent.clear()
	if _selected != null:
		_select(null, "")

	_spawn_accum = 0.0
	_extract_accum = 0.0
	_solve_accum = 0.0
	_fill_accum = 0.0
	_thermal_seeded = false
	_clocks = Clocks.new()

	_total_injected = 0
	_total_recirculated = 0
	_total_extracted = 0
	_total_shipped = 0
	_total_reinjected = 0
	_out_count = 0
	_out_burnup_sum = 0.0
	_out_passes_sum = 0
	_out_fissile_sum = 0.0
	_out_pu_sum = 0.0
	_out_poison_sum = 0.0
	_last_out_burnup = 0.0
	_last_out_passes = 0
	_last_out_fissile = 0.0

	_refresh_pool()
	_population_setpoint = clampi(start, 0, OVERFILL_MAX)


## The player's "Restart Reactor" control (Phase 3c) — clears the plant and starts it
## refilling toward whatever the setpoint slider currently reads, through the REAL,
## watchable admission physics (`_admit_batch`, paced by `_fill_rate`/`_fill_paused`) —
## never `_seed_initial_bed`. Setting the setpoint to 0 first gives an empty-start
## commissioning fill; leaving it at the recommended population gives a fresh filled
## start, just a slower one than boot. No separate empty/filled buttons: the setpoint
## IS the target.
func _restart_reactor() -> void:
	_reset_population(_population_setpoint)


## Instantly commission the bed with `count` already-settled pebbles, for the ONE
## moment a real-time pour would be pure friction: the very first boot, before the
## player has done anything to watch (Phase 3c "starts filled" default).
##
## WHY NOT A SPED-UP REAL FILL — this replaced an `Engine.time_scale` warm-up that
## played the real admission physics back at 8x. MEASURED to be unsafe: a live probe
## (tests/live_inlet_probe.gd) held 0 escapes in 70s of the real fill at time_scale=1.0,
## then reliably tunnelled dozens of settled BED pebbles straight through the silo's
## closed hopper floor (`Silo.OUTLET_Y`) once time_scale was restored to 8.0 — the exact
## failure `3be4e7b` already fixed once for the old initial-fill path (a long, unbroken
## free-fall reaching enough velocity to cross a zero-thickness SegmentShape2D in one
## step) and CCD-on-by-default does not save it here: Godot scales the DELTA reported to
## `_physics_process` by `time_scale`, so an 8x warm-up does not just call physics 8x
## more often, it hands the SAME 60 Hz physics step 8x more simulated time to integrate
## in one go — an 8x bigger stride for every body, every step, everywhere at once, not
## just the one long first drop CCD was proven against. So this function does not run
## physics at all: it places bodies already resting where a settled pile would be.
##
## Bottom-up, funnel-aware, like a real pile builds — NOT `Silo.spawn_x`'s random top
## scatter, which is exactly the "pebbles appear from nothing, already falling" look
## this whole phase exists to remove. A pebble placed here is real, collidable, and
## indistinguishable from one that arrived through the inlet — same isotopic seeding
## (`_seed_burned`), same tint, same everything except HOW it got there.
func _seed_initial_bed(count: int) -> void:
	var r := _pebble_radius
	var spacing := 2.0 * r + 4.0
	var row_height := spacing * 0.87   # hex-ish vertical pitch, not a square grid
	var y := Silo.OUTLET_Y - r - 4.0
	var row := 0
	var placed := 0
	while placed < count and y > Silo.TOP + r:
		# The funnel narrows going DOWN, so a pebble's most constrained point is its own
		# lower edge (y + r), not its center — measured at y alone, rows in the steep taper
		# clipped the sloped wall and got popped free by the solver at a few hundred px/s
		# (harmless — never an escape — but a visibly jumpy "instant fill", the opposite of
		# what this function exists to look like).
		var half_w: float = _bed_half_width(y + r) - r - 2.0
		if half_w > 0.0:
			var x := Silo.CENTER_X - half_w + (spacing * 0.5 if row % 2 == 1 else 0.0)
			while x <= Silo.CENTER_X + half_w and placed < count:
				var id := _next_id
				_next_id += 1
				var peb := Pebble.new(id, r)
				_stamp_enrichment(peb, _enrichment)
				peb.fuel_loading = _fuel_loading
				_pebbles[id] = peb
				_total_injected += 1
				_seed_burned(peb)
				var jitter := Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
				_physics.spawn_pebble(id, Vector2(x, y) + jitter, r)
				_physics.set_pebble_tint(id, _pebble_tint(peb))
				placed += 1
				x += spacing
		y -= row_height
		row += 1


## Half-width of the bed's cross-section at height `y` — full vessel width above the
## funnel knee, tapering linearly to the closed floor's outlet gap below it. Mirrors
## the same geometry `Silo.wall_segments`/`inner_profile` draw the funnel from, so a
## seeded pebble is never placed outside the walls it will immediately be resting against.
func _bed_half_width(y: float) -> float:
	var full_half := (Silo.RIGHT - Silo.LEFT) * 0.5
	if y <= Silo.FUNNEL_TOP:
		return full_half
	var t := clampf((y - Silo.FUNNEL_TOP) / (Silo.OUTLET_Y - Silo.FUNNEL_TOP), 0.0, 1.0)
	return lerp(full_half, Silo.OUTLET_HALF, t)


# HUD text colors (BBCode). Dim for labels/keys, bright for values, semantic
# colors for the status line — the one thing that must be readable at a glance.
const HUD_DIM := "8a97ab"
const HUD_HEAD := "5c81c4"
# Top of the inspector panel — clear of the readout above it, which runs to y ≈ 440.
const INSPECTOR_Y := 460.0

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

	# Inspector panel — same left column, below the readout. That column is the only
	# large free area that is entirely OUTSIDE the neutronics grid (which starts at
	# x = 424): a panel any further right would cover the left reflector band, and flux
	# peaking at the reflector is one of the behaviors this toy exists to show.
	var ins := PanelContainer.new()
	ins.position = Vector2(12, INSPECTOR_Y)
	ins.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(ins)
	_inspector = RichTextLabel.new()
	_inspector.bbcode_enabled = true
	_inspector.fit_content = true
	_inspector.scroll_active = false
	_inspector.custom_minimum_size = Vector2(386, 0)
	_inspector.add_theme_font_size_override("normal_font_size", 13)
	_inspector.add_theme_font_size_override("bold_font_size", 13)
	_inspector.add_theme_color_override("default_color", Color(0.93, 0.95, 0.98))
	ins.add_child(_inspector)

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
		_key_hint("Z X", "pebble size"),
		_key_hint(", .", "coolant flow"),
		_key_hint("K L", "inlet temp"),
		_key_hint("; '", "fuel loading"),
		_key_hint("N M", "control rods"),
		_key_hint("G H", "discharge at"),
		_key_hint("O P", "max passes"),
		_key_hint("F", "feedback"),
		_key_hint("Space", "scram"),
		_key_hint("V", "field"),
		_key_hint("T R", "restamp / re-inject"),
	])
	help.add_child(keys)

	_build_controls_panel(root)


## Mouse-clickable controls for every hotkey-driven lever, plus the new fill controls
## (Phase 3c). Every widget calls the EXACT SAME setter the keyboard path calls — this is
## thin wiring, not a second copy of any rule — so the two input paths can never disagree
## and the key-hints bar above stays accurate.
##
## Placed in the one column with real free space: below the colorbar (which ends around
## y ≈ 452), in the same right-hand margin. `MOUSE_FILTER_STOP` on the panel (Godot's
## default for a Control with interactive children) is what lets it catch clicks while the
## HUD root above stays `MOUSE_FILTER_IGNORE` — so buttons work without breaking
## click-to-inspect anywhere else on screen.
func _build_controls_panel(root: Control) -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(1036, 452)
	panel.custom_minimum_size = Vector2(158, 0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(150, 510)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(140, 0)
	vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(vbox)

	_control_title(vbox, "FILL")
	_add_slider(vbox, "population", 0.0, float(OVERFILL_MAX), 1.0,
		func() -> float: return float(_population_setpoint),
		func(v: float) -> void: _population_setpoint = clampi(int(round(v)), 0, OVERFILL_MAX),
		"%d")
	_add_slider(vbox, "fill rate/s", FILL_RATE_MIN, FILL_RATE_MAX, 1.0,
		func() -> float: return _fill_rate,
		func(v: float) -> void: _fill_rate = clampf(v, FILL_RATE_MIN, FILL_RATE_MAX),
		"%.0f")
	_pause_button = _add_toggle(vbox, "pause fill", func() -> bool: return _fill_paused,
		func() -> void: _fill_paused = not _fill_paused)
	_add_button(vbox, "restart reactor", _restart_reactor)

	_control_title(vbox, "DESIGN")
	_add_slider(vbox, "enrichment", ENRICH_MIN, ENRICH_MAX, ENRICH_STEP,
		func() -> float: return _enrichment,
		func(v: float) -> void: _set_enrichment(v), "%.3f")
	_add_slider(vbox, "pebble size", RADIUS_MIN, RADIUS_MAX, RADIUS_STEP,
		func() -> float: return _pebble_radius,
		func(v: float) -> void: _set_radius(v), "%.2f")
	_add_slider(vbox, "fuel loading", LOADING_MIN, LOADING_MAX, LOADING_STEP,
		func() -> float: return _fuel_loading,
		func(v: float) -> void: _set_loading(v), "%.2f")

	_control_title(vbox, "OPERATING")
	_add_slider(vbox, "coolant flow", Thermal.FLOW_MIN, Thermal.FLOW_MAX, Thermal.FLOW_STEP,
		func() -> float: return _coolant_flow,
		func(v: float) -> void: _set_flow(v), "%.2f")
	_add_slider(vbox, "inlet temp", Thermal.INLET_MIN, Thermal.INLET_MAX, Thermal.INLET_STEP,
		func() -> float: return _inlet_temp,
		func(v: float) -> void: _set_inlet(v), "%.0f")
	_add_slider(vbox, "control rods", ControlRods.INSERT_MIN, ControlRods.INSERT_MAX,
		ControlRods.INSERT_STEP, func() -> float: return _rod_insertion,
		func(v: float) -> void: _set_rods(v), "%.2f")
	_add_slider(vbox, "discharge at", DISCHARGE_MIN, DISCHARGE_MAX, DISCHARGE_STEP,
		func() -> float: return _discharge_burnup,
		func(v: float) -> void: _set_discharge_burnup(v), "%.0f")
	_add_slider(vbox, "max passes", float(PASSES_MIN), float(PASSES_MAX), 1.0,
		func() -> float: return float(_max_passes),
		func(v: float) -> void: _set_max_passes(int(round(v))), "%d")

	_control_title(vbox, "CONTROL")
	_feedback_button = _add_toggle(vbox, "feedback", func() -> bool: return _feedback_on,
		func() -> void: _toggle_feedback())
	_scram_button = _add_toggle(vbox, "scram", func() -> bool: return _scrammed,
		func() -> void: _toggle_scram())
	_add_button(vbox, "cycle field", _cycle_field)

	_control_title(vbox, "SELECTED PEBBLE")
	_restamp_button = _add_button(vbox, "restamp", _restamp_selected)
	_reinject_button = _add_button(vbox, "re-inject", _reinject_selected)


func _control_title(vbox: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.42, 0.5, 0.63))
	vbox.add_child(lbl)


## One slider row: a label (rewritten with the live value every sync) above a compact
## HSlider. `get`/`set` are the SAME state the keyboard path reads/writes — this function
## only builds the widget and remembers it (`_control_specs`) so `_sync_controls_panel`
## can push live state back onto the slider without re-triggering `value_changed`
## (`set_value_no_signal`), the standard Godot pattern for a two-way-bound control.
func _add_slider(vbox: VBoxContainer, label: String, min_v: float, max_v: float, step_v: float,
		getter: Callable, setter: Callable, fmt: String) -> void:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.75, 0.8, 0.88))
	vbox.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step_v
	slider.value = getter.call()
	slider.custom_minimum_size = Vector2(136, 16)
	slider.value_changed.connect(setter)
	vbox.add_child(slider)
	_control_specs.append({"label": lbl, "text": label, "get": getter, "slider": slider, "fmt": fmt})


func _add_toggle(vbox: VBoxContainer, label: String, getter: Callable, on_press: Callable) -> Button:
	var btn := Button.new()
	btn.toggle_mode = true
	btn.text = label
	btn.custom_minimum_size = Vector2(136, 0)
	btn.add_theme_font_size_override("font_size", 11)
	btn.pressed.connect(on_press)
	vbox.add_child(btn)
	_toggle_specs.append({"button": btn, "get": getter})
	return btn


func _add_button(vbox: VBoxContainer, label: String, on_press: Callable) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(136, 0)
	btn.add_theme_font_size_override("font_size", 11)
	btn.pressed.connect(on_press)
	vbox.add_child(btn)
	return btn


## Push live sim state onto every slider/toggle (render clock, pure consumer — same
## discipline as `_update_hud`): keeps the panel honest when a value changes from the
## KEYBOARD side, or from the sim itself (e.g. a scram driving `_rod_insertion`).
## `set_value_no_signal` is what keeps this from re-firing `value_changed` and fighting
## the player's own drag.
func _sync_controls_panel() -> void:
	for spec in _control_specs:
		var slider: HSlider = spec["slider"]
		var v: float = spec["get"].call()
		if not slider.has_focus():   # don't yank the slider out from under an active drag
			slider.set_value_no_signal(v)
		var lbl: Label = spec["label"]
		lbl.text = spec["text"] + ": " + (spec["fmt"] as String) % v
	for spec in _toggle_specs:
		var btn: Button = spec["button"]
		btn.button_pressed = spec["get"].call()
	if _restamp_button != null:
		var sel := _pool_selected()
		_restamp_button.disabled = not sel
		_reinject_button.disabled = not sel


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
	_refresh_pool()
	_update_inspector()
	_sync_controls_panel()    # keep the mouse panel honest against keyboard/sim changes
	_overlay.queue_redraw()   # the ring tracks a moving pebble (bed flow, or a ride)


func _physics_process(delta: float) -> void:
	# Native self-steps; kept explicit so an external engine slots in cleanly.
	_physics.step(delta)

	# The belts: let the next extracted pebble into the drop if there is room for it, press on
	# every pebble the pipes are carrying, and hand over the ones that have arrived — into the
	# pool if they were spent, onto the chute if they are going back around. Real bodies, so
	# this is the one transport path that IS physics.
	_feed_drop()
	_feed_reinject()
	_feed_inlet_top()
	_belt_step()

	_spawn_accum += delta
	while _spawn_accum >= SPAWN_INTERVAL:
		_spawn_accum -= SPAWN_INTERVAL
		_inject_batch()

	# Admission into the BED from whatever is piled at the inlet — throttled by the
	# player's fill rate (Phase 3c), the way every other cadence in this loop is throttled
	# by its own accumulator. Paused means exactly what it says: the pile above the
	# closed floor keeps growing (minting above does not stop), nothing crosses into the
	# bed until resumed.
	if not _fill_paused:
		_fill_accum += delta
		var fill_interval: float = 1.0 / maxf(_fill_rate, 0.01)
		while _fill_accum >= fill_interval:
			_fill_accum -= fill_interval
			_admit_batch()

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


## Pebbles currently in the BED (i.e. homogenized, fissioning).
## Derived rather than counted so it cannot drift out of step with the registry.
##
## Needs no pool term: a pooled pebble is in `_pebbles` AND in `_out_of_core`, so it
## adds one to each side and cancels itself out. The pool is invisible here for free.
func _core_count() -> int:
	return _pebbles.size() - _out_of_core.size()


## The fuel CYCLE's population: everything the plant is still circulating — in the bed,
## riding the machine, rolling down a pipe on a belt, waiting at the pipe's mouth for room,
## or staged at the top — but NOT the spent pool.
##
## This is the quantity the mint gate and the thermal seed have always measured; it
## simply had no name while the pool lived outside the registry and `_pebbles.size()`
## happened to equal it. Now that a pool pebble is a registry member (it must be, to be
## re-injectable — see `_spent`), the two have diverged and the distinction has to be
## said out loud. A pebble parked in the pool is NOT being circulated: it must not hold
## a slot against the mint gate, or the plant would stop making fresh fuel as the pool
## filled and the bed would starve.
##
## NEUTRALITY, and it is exact rather than approximate. `_spent` was disjoint from
## `_pebbles` before, so the old `_pebbles.size()` counted precisely the non-pool
## pebbles; now `_pebbles` contains the pool and we subtract it back off. Same set,
## same number, every frame — the pool moved across the boundary and the arithmetic
## did not notice. That is what let this land without re-calibrating anything.
##
## It also makes re-injection self-accounting: dropping a pebble out of `_spent` and
## into the queue raises `_inventory()` by one, so the gate mints one fewer fresh
## pebble on its own. Nothing has to remember to debit a budget — the only way to get
## that wrong is to keep a hand-maintained counter, which is exactly what this avoids.
func _inventory() -> int:
	return _pebbles.size() - _spent.size()


## Materialize a pebble directly into the tray and pool it — for a caller that has a spent
## pebble but no body for it, which since Phase 3b-i means the drip-feed in
## tests/live_spent_pool.gd and nothing on the live path. The plant's own discharges arrive
## as bodies down a real pipe and go through `_pool_admit` below.
##
## The cap and the `_spent` invariant live in `_pool_admit`, which is what BOTH paths reach:
## that is what keeps "`_spent.size()` never exceeds the tray" an INVARIANT rather than a
## hope — and that invariant is load-bearing well beyond tidiness (see `_refresh_pool`).
##
## WHY THE POOL IS CAPPED AT WHAT THE TRAY CAN DRAW, and why that is not an arbitrary
## number. The pool exists to be REACHED: the player clicks a spent pebble to inspect it,
## edit it and send it back. Reachable means drawn — a pebble with no slot has no pixels
## to click. So a cap larger than the tray would manufacture inventory the player cannot
## touch, which serves nothing and quietly contradicts the feature's whole premise. The
## cap therefore IS the displayable count, and it reads that count from the tray rather
## than restating it: a second constant that "must agree" with `pool_capacity()` is the
## drift bug this project keeps paying for (commit 7b0be70). Shrink the tray and the pool
## ships sooner — the correct semantics, not a leak, because a smaller tray really can
## hold fewer.
##
## Before this cap, `_spent` grew WITHOUT BOUND: nothing was ever discarded, and the tray
## silently showed a rolling window of the newest arrivals while everything older became
## unreachable-but-retained. Phase 2a made that worse by moving the pool inside
## `_pebbles`, where five per-frame walks would carry it forever. Shipping is the honest
## end of the fuel cycle and it is the answer to "what happens when the pool fills":
## the OLDEST goes to a cask, and what remains is exactly what you can see.
func _pool_push(peb: Pebble) -> void:
	# Somewhere across the pipe's bore, not dead-centre — see FuelLoop.pool_drop, where
	# that randomness is the difference between a pile and a balanced column.
	_physics.spawn_pebble(peb.id, FuelLoop.pool_drop(_rng.randf_range(-1.0, 1.0)),
			peb.radius)
	_pool_admit(peb)


## Take ownership of a pebble that has ARRIVED in the tray under its own steam — it already
## has a body, it rode a belt in, and it is somewhere in the pile. This is the live path
## since Phase 3b-i; `_pool_push` above is the same thing for a pebble that needs
## materializing first (the drip-feed in tests/live_spent_pool.gd, which fills the tray far
## faster than the plant discharges).
##
## The split is the belt-body↔pool-body seam, and putting it here rather than inside the
## belt keeps the pool the thing that decides what a pooled pebble IS. Note what is NOT in
## this function any more: the spawn. The arriving pebble has held the same body since the
## outlet, so there is nothing to create — which is precisely what "the two body-worlds
## join" means, and why nothing here can put a pebble somewhere the physics did not.
##
## GIVING IT A BODY AND DECLARING IT OUT OF CORE ARE STILL ONE OPERATION, which is why the
## flag is set here and not left to the caller. Both of today's callers have it set already
## (the pebble has been out of core since the sorter took it), so this line is redundant on
## both live paths and is here for what it prevents: the tray overlays VALID grid cells, so
## a body parked in it without that flag is homogenized as core fuel and shifts k with
## nothing on screen to say so (see `_core_positions`). A caller that forgot would not
## crash, it would quietly re-calibrate the reactor. That is exactly the pairing discipline
## `_ship_to_cask` keeps at the other end of the pool's life.
## Joining `_spent` is ALSO what opens a fresh-fuel slot, by the same arithmetic as ever:
## the pebble STAYS in `_pebbles` (it has to, to be re-injectable), but leaving
## `_inventory()` is what the mint gate reads.
##
## `_total_extracted` is deliberately NOT bumped here, even though this looks like the
## obvious home for it. It counts DISCHARGES THE PLANT MADE, and this function has a second
## caller that did not make one: `_pool_push`, the drip-feed that stages dummy pebbles
## straight into the tray. Counting those would inflate the HUD's spent total with pebbles
## the sorter never saw and shift the accounting live_fuel_policy checks. The counter
## therefore stays at the real arrival site, in `_belt_step`, which is reached only by a
## pebble that actually rode the pipe.
func _pool_admit(peb: Pebble) -> void:
	_spent.push_back(peb)
	_out_of_core[peb.id] = true
	# Ordering note, now moot but worth keeping straight: the cap check runs last because
	# shipping ERASES a body, so a tray at exactly cap must push-then-ship. It used to
	# matter that the spawn came first; today the arriving pebble is bodied before it ever
	# reaches this function, which removes the hazard rather than relying on the order.
	while _spent.size() > FuelLoop.pool_capacity():
		_ship_to_cask()


## Drive every belt-carried pebble one step, and pool the ones that have landed.
##
## Takes no delta, and that is not an oversight: a belt applies a FORCE, and Godot
## accumulates forces per physics step and consumes them on the next one. Scaling by delta
## would be integrating twice. The step it belongs to is the physics step, which is why
## this is called from `_physics_process` and nowhere else.
func _belt_step() -> void:
	if _transit.is_empty():
		return
	var landed: Array = []
	for id in _transit:
		var at := _physics.get_position(id)
		if _delivered(at, _transit[id]):
			landed.append(id)
			continue
		_drive(id, at, _transit[id])
	# Collected first, mutated after: `_pool_admit` can ship a pebble to a cask, which
	# erases from `_pebbles` — and erasing anything mid-walk over `_transit` is how a
	# harmless arrival turns into a corrupted iteration.
	for id in landed:
		var leg: int = _transit[id]
		_transit.erase(id)
		if leg == FuelLoop.RECIRC or leg == FuelLoop.REINJECT:
			# Phase 3c: nothing left to do. The pebble is already a body, already
			# `_out_of_core`, and has just crossed into the shared inlet bore — it simply
			# rests there now, piled against the closed floor like any other pebble
			# waiting for `_admit_batch` to let it into the bed. No hand-off, no rider.
			continue
		_pool_admit(_pebbles[id])
		# THE discharge counter, and it lives here rather than in `_pool_admit` because this
		# is the site only a real pebble off a real pipe reaches (see there).
		_total_extracted += 1


## Has this pebble reached the end of ITS leg? DISCHARGE tips off a conveyor into an open
## tray; RECIRC and REINJECT both end the same way now (Phase 3c) — by crossing into the
## shared inlet bore, whichever merge run they arrived on.
func _delivered(at: Vector2, leg: int) -> bool:
	if leg == FuelLoop.RECIRC or leg == FuelLoop.REINJECT:
		return FuelLoop.in_inlet_bore(at)
	return FuelLoop.pool_contains(at)


## Press one pebble along whichever belt its leg puts it on.
##
## ⚠️ THE DIRECTION COMES FROM THE LEG, NEVER FROM THE POSITION, and that is the load-bearing
## line in this function. Both belts run in the SAME duct, in opposite directions, so a drive
## that asked "which side of the hub am I on" instead of "where am I going" would turn a spent
## pebble around and send it up the riser the first time one drifted past the sorter. Reading
## it from `_transit` means a pebble's destination is decided once, at the sorter, by policy —
## which is where the fuel cycle's one decision belongs (see `_extract_lowest`).
##
## It is also what replaced the discharge conveyor's end cap. That wall had to be cut to let
## recirculating fuel out of the drop at all (`FuelLoop.plant_walls`), so a discharge pebble
## bouncing rightward off the corner is no longer stopped by geometry — it is simply still on
## the leftward belt wherever it lands, and gets pushed back.
##
## The velocity test IS the belt: push only while the pebble is still slower than the belt, so
## it is dragged UP TO belt speed and no further. A pebble already at speed is coasting on a
## surface moving with it, which is what riding a conveyor is, and it leaves at belt speed no
## matter how hard the belt pressed to get it there. Reversed — force with no speed limit —
## this same drive throws pebbles out of the world (measured, 3 in 10).
func _drive(id: int, at: Vector2, leg: int) -> void:
	if leg == FuelLoop.DISCHARGE:
		# Out along the duct to the pool's mouth. Slow, because it ends by tipping into an
		# open, lidless tray (see FuelLoop.BELT_DISCHARGE).
		if FuelLoop.in_duct(at):
			_belt(id, Vector2.LEFT, FuelLoop.BELT_DISCHARGE)
		return
	if leg == FuelLoop.REINJECT:
		# Its own riser, its own straight climb — no duct leg to cross first, unlike RECIRC's.
		if FuelLoop.in_reinject_riser(at):
			_belt(id, Vector2.UP, FuelLoop.BELT_RISER)
		# Phase 3c: past the bend, the belt pushes RIGHT along REINJECT's own merge run
		# toward the shared inlet (REINJECT_X sits left of INLET_X) instead of lifting the
		# body off onto a rider — see `FuelLoop.in_reinject_merge`.
		if FuelLoop.in_reinject_merge(at):
			_belt(id, Vector2.RIGHT, FuelLoop.BELT_RISER)
		return
	# RECIRC: out the other way and then up. BOTH pushes are applied, and the zones overlap at
	# the foot of the riser on purpose — a pebble in the corner is dragged right AND lifted at
	# once, so it rounds the elbow on a diagonal instead of being driven into the far wall and
	# then asked to climb from a standstill (see FuelLoop.in_riser).
	if FuelLoop.in_duct(at):
		_belt(id, Vector2.RIGHT, FuelLoop.BELT_RISER)
	if FuelLoop.in_riser(at):
		_belt(id, Vector2.UP, FuelLoop.BELT_RISER)
	# Phase 3c: past the bend, the belt pushes LEFT along the merge run toward the shared
	# inlet (RISER_X sits right of INLET_X) instead of lifting the body off onto a rider —
	# see `FuelLoop.in_recirc_merge`.
	if FuelLoop.in_recirc_merge(at):
		_belt(id, Vector2.LEFT, FuelLoop.BELT_RISER)


## The belt itself: drag a body up to `speed` along `dir`, and no further.
##
## `dot(dir)` generalizes the old `velocity.x > -BELT_DISCHARGE` to a belt that can run in any
## direction — including straight up, where the force must also beat gravity all the way (2500
## against ~980, so the climb is comfortable rather than marginal).
func _belt(id: int, dir: Vector2, speed: float) -> void:
	if _physics.get_velocity(id).dot(dir) < speed:
		_physics.apply_force(id, dir * FuelLoop.BELT_FORCE)


## Send the oldest pooled pebble away for good — it leaves the plant entirely.
##
## The three removals are ONE operation and must stay together. Dropping the
## `_out_of_core` erase would leave a flag with no pebble behind it, and `_core_count()`
## (`_pebbles.size() - _out_of_core.size()`) would drift DOWN by one per shipment —
## a phantom bed shortfall that walks k off calibration with nothing on screen to show
## it. That is the same pairing discipline the transport bodies will need in Phase 3.
##
## Shipping is INVENTORY-NEUTRAL and deliberately so: `_pebbles` and `_spent` each lose
## the same pebble, so `_inventory()` does not move and the mint gate does not react. It
## should not — the fresh-fuel slot was already opened when this pebble first discharged
## into the pool. Freeing it again here would mint a second replacement for one pebble.
## Stamp the CURRENT design onto a pooled pebble — the player's edit before sending it
## back. Deliberately only what a pebble is BUILT with, never what it has BECOME.
##
## WHY ENRICHMENT IS NOT HERE, though it is one of CLAUDE.md's three design knobs and it
## is editable for FRESH fuel one function away (`_mint_pebble`). There is no stored
## enrichment field: enrichment IS the isotopic vector (`_stamp_enrichment` writes
## `u235 = e`, `u238 = 1 - e`). For fresh fuel those are the same statement. For a burned
## pebble they are not — u235 is now a RESULT, the fissile that survived the last pass,
## so "re-enriching" would mean writing fresh fissile back into a pebble that has already
## spent it. That is not an edit, it is un-burning, and it would hand the player a pebble
## with a spent pebble's burnup and fresh fuel's reactivity — a lie homogenize would then
## faithfully propagate into k.
##
## Radius and fuel_loading carry no such double meaning: they are pure design, read by
## the geometry (packing → leakage) and the moderation ratio respectively, and nothing in
## the depletion chain writes them. So they can be re-designed on a spent pebble without
## contradicting anything the pebble has lived through. Re-enrichment would be
## reprocessing — a real thing, but a different feature, and one that needs its own answer
## for what happens to burnup.
func _restamp_design(peb: Pebble) -> void:
	peb.radius = _pebble_radius
	peb.fuel_loading = _fuel_loading


## Is the selection a pebble sitting in the pool — i.e. one the player may edit?
##
## The pool is the ONLY editable place, and the restriction is physical rather than
## fussy. A pebble in the bed or riding the machine is mid-cycle: resizing it would
## resize a live body and shift the packing the flux solve just homogenized. A pooled
## pebble is parked, bodiless and out of core, so a redesign touches nothing until the
## player sends it back — at which point it is built fresh from these fields anyway.
func _pool_selected() -> bool:
	return _selected != null and _spent.has(_selected)


func _restamp_selected() -> void:
	if _pool_selected():
		_restamp_design(_selected)
		_refresh_pool()   # its tint may have moved with the design


func _reinject_selected() -> void:
	if _pool_selected():
		_reinject(_selected)


## Send a pooled pebble back into the fuel cycle — the player's "burn it down, tweak it,
## put it back" move.
##
## SELF-ACCOUNTING, and that is the whole reason Phase 2a put the pool inside `_pebbles`.
## Leaving `_spent` raises `_inventory()` by one, so the mint gate makes one fewer fresh
## pebble WITHOUT being told: the returning pebble takes the slot the replacement would
## have. Nothing decrements a budget by hand, so nothing can forget to.
##
## `_total_extracted` is NOT decremented. It counts an event that really happened — this
## pebble WAS discharged — and rewriting history to keep a HUD tidy would break the
## accounting live_fuel_policy checks (`_spent + shipped == extracted`). The return is a
## new event with its own counter.
##
## It climbs its OWN riser (Phase 3b-iii) rather than materializing at the top, so the
## pebble the player just edited is the one they watch climb back in — a real body for the
## whole trip, same as RECIRC. `_out_of_core` is already true (it has been since it
## discharged) and stays true for the ride — the pebble is not fuel again until
## `_admit_batch` lets it out of the inlet pile it lands in at the top of the climb
## (Phase 3c: the shared `_belt_step`/`_drive` machinery already handles a REINJECT leg the
## same way it handles RECIRC, so there is no new arrival code here at all).
func _reinject(peb: Pebble) -> void:
	var idx := _spent.find(peb)
	if idx == -1:
		return
	# The body must go: the pebble is leaving the pool to ride the machine, and while it
	# is in transit it holds no body of its own (see `_pool_admit`'s pairing discipline —
	# a pebble may hold a body in the pool or be in flight, never both, or it would be
	# drawn twice and picked twice). It does NOT get a new body here — it gets in line for
	# one, at REINJECT's own mouth (Phase 3b-iii), exactly as a discharge or recirculating
	# pebble queues for the shared drop's. `_out_of_core` deliberately does NOT move: it
	# was true as a pooled body and stays true for the ride, because neither is fuel in
	# the core. The exact spot it was lying in the pile is not carried forward — it
	# reappears at the mouth like every other transiting pebble does, not at its pool
	# position, the same seam `FuelLoop.drop_mouth` already accepts for the other legs.
	_physics.remove_pebble(peb.id)
	_spent.remove_at(idx)
	_total_reinjected += 1
	_reinject_pending.push_back(peb)
	_refresh_pool()


func _ship_to_cask() -> void:
	var peb: Pebble = _spent.pop_front()
	# The inspector may be holding the very pebble leaving. Clear it rather than let the
	# selection dangle on a pebble that no longer exists anywhere in the sim.
	if _selected == peb:
		_select(null, "")
	# The body goes with it — a fourth removal joining the three the comment above pairs.
	# The oldest pebble is generally NOT on top of the pile, so this pulls a body out from
	# under the others and the pile resettles into the gap. That is the correct picture:
	# emptying a transfer pool to a cask really does disturb what is left.
	_physics.remove_pebble(peb.id)
	_pebbles.erase(peb.id)
	_out_of_core.erase(peb.id)
	_total_shipped += 1


## The BED's positions — every pebble the neutronics is allowed to see.
##
## WHY this exists at all, when _physics.positions() looks like the same thing: today
## it IS the same thing, because nothing outside the bed holds a body. That equality is
## a COINCIDENCE of the current transport model, not an invariant — and two different
## meanings are riding on it. "Has a physics body" is a rendering/engine fact;
## "is in the core" is a NEUTRONICS fact. The flux solve wants the second and has been
## reading the first, which is correct only for as long as no pebble outside the bed is
## ever given a body.
##
## The spent pool is what proves the stakes are real rather than theoretical: its slots
## land in VALID grid cells (tests/live_spent_pool.gd asserts exactly this), so a body
## parked there would be homogenized into the flux solve as if it were fuel in the core,
## silently shifting k. That hazard is currently held off by a CONVENTION — "we just
## don't give those pebbles bodies" — enforced by a comment. Routing the coupling through
## `_out_of_core` moves the guard from convention into code: membership is now declared,
## not inferred from an engine side-effect, and a pebble can hold a body anywhere in the
## machine without ever reaching the neutronics.
##
## Byte-identical today BY CONSTRUCTION: every id in `_out_of_core` is exactly an id with
## no body, so this filter removes nothing that positions() would have returned. That is
## the point — it is the M5d calibration-neutral pattern (a new mechanism that does
## precisely nothing at its current setting), so every existing calibration survives and
## the suites prove it rather than a claim doing so.
##
## NOT for the inspector (_select_at / _selected_pos): clicking is an INTERACTION concern
## and must reach every pebble that is drawn, in the bed or not. Those deliberately keep
## reading _physics.positions() directly.
func _core_positions() -> Dictionary:
	# Bind the backend's dictionary ONCE: positions() BUILDS a fresh dictionary per call
	# (see godot_physics_backend.gd), so calling it inside the loop would rebuild the whole
	# thing per pebble — O(n^2) on the solve's critical path.
	var all := _physics.positions()
	var out := {}
	for id in all:
		if not _out_of_core.has(id):
			out[id] = all[id]
	return out


## One job per tick: mint inventory until it covers the player's population setpoint plus
## the in-flight buffer. Admission into the bed is no longer done here — Phase 3c moved it
## to its own throttled loop in `_physics_process` (`_admit_batch`, paced by `_fill_rate`),
## since minting and admitting are now two genuinely different rates: minting only needs to
## keep the inlet fed, admitting is the player-watchable one.
func _inject_batch() -> void:
	for i in SPAWN_PER_TICK:
		# Gate on the CIRCULATING population, not the raw registry: the pool is inventory
		# too, and counting it would let a filling pool throttle fresh fuel until the bed
		# starved. `_inventory()` is exactly what `_pebbles.size()` used to mean here.
		if _inventory() < _population_setpoint + LOOP_BUFFER:
			_mint_pebble()


## Manufacture one pebble at the CURRENT design settings and put it in line for the inlet.
##
## MANUFACTURED, NOT MATERIALIZED — the distinction that keeps LOOP_BUFFER safe. Minting
## runs up to 48 pebbles ahead of the setpoint (see LOOP_BUFFER) so the bed is never
## starved while pebbles are in flight, and `SPAWN_PER_TICK` (3) mints several in the same
## tick. Giving every one of those a real body at the SAME point (`inlet_top`) in the SAME
## instant is exactly the "never materialize a body into space that may be occupied"
## failure `FuelLoop.MOUTH_CLEAR` exists to prevent at the OTHER end of the plant — and the
## inlet pipe is short (it has to fit above the vessel), so it physically cannot hold 48
## pebbles even one at a time. So minting stages the pebble bodiless in `_mint_pending`,
## same as a discharge stages in `_drop_pending`: manufactured inventory that has not yet
## been given a body is not a pebble that disappeared, because nothing ever showed it
## existing. `_feed_inlet_top` is the door onto the visible pipe.
func _mint_pebble() -> void:
	var id := _next_id
	_next_id += 1
	var peb := Pebble.new(id, _pebble_radius)
	_stamp_enrichment(peb, _enrichment)
	peb.fuel_loading = _fuel_loading   # M5b design moderation, stamped at manufacture
	_pebbles[id] = peb
	_out_of_core[id] = true
	_total_injected += 1
	# The INITIAL load is seeded to online-refueling equilibrium (a spread of burnups),
	# not all-fresh — including the buffer, since those pebbles cycle into the bed too
	# and a slug of fresh fuel entering early would be a reactivity bump the equilibrium
	# does not have.
	if _total_injected <= _population_setpoint + LOOP_BUFFER:
		_seed_burned(peb)
	_mint_pending.push_back(id)


## Put the next manufactured pebble(s) at the top of the visible inlet pipe, one per LANE
## that is currently clear (Phase 3c widening — up to `FuelLoop.INLET_LANES` per tick, not
## just one). Mirrors `_feed_drop` exactly — same door, same reason (`FuelLoop.INLET_MOUTH_CLEAR`
## is `FuelLoop.MOUTH_CLEAR`'s bore-width margin, reused): a body spawned on top of another
## is a collision the solver resolves violently, not a queue.
func _feed_inlet_top() -> void:
	for lane in FuelLoop.INLET_LANES:
		if _mint_pending.is_empty():
			return
		if not _inlet_top_clear(lane):
			continue
		var id: int = _mint_pending.pop_front()
		var peb: Pebble = _pebbles[id]
		# Wall margin comes from THIS pebble's radius, not the nominal: a bigger pebble
		# spawned at the nominal margin would be born overlapping the pipe wall and get
		# kicked out by the solver.
		_physics.spawn_pebble(id, FuelLoop.inlet_top(lane), peb.radius)
		_physics.set_pebble_tint(id, _pebble_tint(peb))


## Is the top of inlet LANE `lane` clear for one more pebble? Same reasoning as
## `_admit_mouth_clear`/`_drop_mouth_clear`, checked against the point every waiting pebble
## in THIS lane is spawned at.
##
## AXIS-ALIGNED, not a Euclidean radius — a circular check big enough to protect one lane
## reaches into its neighbour at `FuelLoop.INLET_LANES` pitch, which would make every lane
## block the next one and defeat the entire point of widening the pipe (see
## `FuelLoop.INLET_MOUTH_CLEAR`/`INLET_LANE_HALF_WIDTH`). Splitting into a narrow X band and
## a Y distance keeps lanes independently gated.
func _inlet_top_clear(lane: int) -> bool:
	var top := FuelLoop.inlet_top(lane)
	var positions := _physics.positions()
	for id in positions:
		var at: Vector2 = positions[id]
		if absf(at.x - top.x) < FuelLoop.INLET_LANE_HALF_WIDTH \
				and absf(at.y - top.y) < FuelLoop.INLET_MOUTH_CLEAR:
			return false
	return true


## Let the pebble resting lowest at the inlet — the one closest to actually being admitted
## — into the bed, IF the admit point below the closed floor has room. Mirrors `_feed_drop`
## exactly, for exactly the same door reason (see `FuelLoop.INLET_MOUTH_CLEAR`): a body
## spawned on top of another is a collision, not a queue.
##
## Called on its own throttled cadence (`_fill_rate`, see `_physics_process`) rather than
## unconditionally — that throttle IS the player's fill-speed control, and pausing it is
## what "stop the process" means: pebbles keep minting and piling at the inlet, genuinely
## queued as real bodies, and simply stop crossing into the bed.
##
## The body is rebuilt at the PEBBLE'S OWN radius, never the nominal. This is the only
## place in the game a body is created, so it is the single point where the two worlds
## could silently disagree: peb.radius is what grid.gd homogenizes (PI*r^2 → packing),
## while the radius passed here is what collides and what is drawn. Passing the nominal
## constant would mean an edited pebble is neutronically large and physically small —
## the bed would pack one way and the flux solve would see another, with nothing on
## screen to show it. Reading it off the pebble keeps the Lagrangian and Eulerian views
## of the same object in agreement by construction.
## Admits up to one pebble per LANE that has both a waiting pebble and a clear mouth
## (Phase 3c widening) — not just one per throttled tick. This is the actual throughput
## multiplier: the per-lane physics (gravity-limited clearance) is unchanged from the
## original single lane, but up to `FuelLoop.INLET_LANES` of them now run in parallel.
func _admit_batch() -> void:
	for lane in FuelLoop.INLET_LANES:
		if _core_count() >= _population_setpoint:
			return
		var id := _lowest_at_inlet(lane)
		if id == -1:
			continue
		if not _admit_mouth_clear(lane):
			continue
		var peb: Pebble = _pebbles[id]
		_out_of_core.erase(id)
		_physics.remove_pebble(id)
		_physics.spawn_pebble(id,
				FuelLoop.inlet_admit_point(lane, _rng.randf_range(-1.0, 1.0), peb.radius), peb.radius)
		_physics.set_pebble_tint(id, _pebble_tint(peb))


## Is there room just below inlet LANE `lane`'s closed floor for one more pebble? Mirrors
## `_drop_mouth_clear` exactly (see there for the measured failure this guards against), and
## `_inlet_top_clear`'s axis-aligned reasoning exactly (a Euclidean radius here would let
## adjacent lanes block each other).
func _admit_mouth_clear(lane: int) -> bool:
	var mouth := FuelLoop.inlet_admit_point(lane)
	var positions := _physics.positions()
	for id in positions:
		if _out_of_core.has(id):
			continue   # still piled above the floor, or elsewhere in the plant
		var at: Vector2 = positions[id]
		if absf(at.x - mouth.x) < FuelLoop.INLET_LANE_HALF_WIDTH \
				and absf(at.y - mouth.y) < FuelLoop.INLET_MOUTH_CLEAR:
			return false
	return true


## The id of the pebble resting lowest (closest to admission) within inlet LANE `lane`, or
## -1 if nothing is waiting there. Deliberately excludes `_transit` bodies — those are still
## being actively driven along a merge run and have not arrived yet (`_delivered`/
## `in_inlet_bore` is what marks arrival) — and anything not `_out_of_core`, which the inlet
## zone should never contain but a defensive filter costs nothing here. Narrowed to THIS
## lane's own X band so each lane admits its own pebbles rather than racing every other lane
## for whichever is lowest across the whole wide bore.
func _lowest_at_inlet(lane: int) -> int:
	var lane_x := FuelLoop.inlet_lane_x(lane)
	var positions := _physics.positions()
	var best_id := -1
	var best_y := -INF
	for id in positions:
		if not _out_of_core.has(id) or _transit.has(id):
			continue
		var at: Vector2 = positions[id]
		if not FuelLoop.in_inlet_bore(at):
			continue
		if absf(at.x - lane_x) >= FuelLoop.INLET_LANE_HALF_WIDTH:
			continue
		if at.y > best_y:
			best_y = at.y
			best_id = id
	return best_id


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


## Is this pebble finished — does the CURRENT policy send it to the pool rather than
## back around for another pass?
##
## THE fuel-cycle rule, in one place. Both the sorter (_extract_lowest) and the inspector
## panel call this, and that sharing is the point rather than tidiness: the panel's job is
## to tell the player what will happen to a pebble, so if it carried its own copy of the
## predicate the two could disagree — the panel would say "not spent" about a pebble the
## sorter was in the act of discharging. They cannot drift now, because there is only one
## rule to drift from. (This is the same failure commit 7b0be70 fixed for radius: two
## worlds each holding their own copy of one fact.)
##
## Spent on EITHER criterion: burnup is the real one (the fuel is used up), passes is the
## backstop (a pebble in a cold spot burns slowly and must not cycle forever).
func _is_spent(peb: Pebble) -> bool:
	return peb.burnup >= _discharge_burnup or peb.pass_count >= _max_passes


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
	# fire while the bed was still filling. It also means a starved inlet stalls
	# extraction rather than quietly draining the bed — a safe failure.
	if _core_count() < _population_setpoint:
		return  # let the bed fill first
	var lowest_id := -1
	var lowest_y := -INF
	var positions := _core_positions()
	for id in positions:
		var y: float = positions[id].y
		if y > lowest_y:
			lowest_y = y
			lowest_id = id
	if lowest_id == -1 or lowest_y < Silo.FUNNEL_TOP:
		return  # nothing has reached the discharge region yet
	var peb: Pebble = _pebbles[lowest_id]
	# THE decision, and the only place fuel-cycle POLICY is applied. Reads the live knobs
	# (_discharge_burnup / _max_passes), not the Depletion constants, so the player can
	# re-govern the cycle while it runs; every other reader of those constants is either a
	# calibrated reference or a readout of this same rule (see _discharge_burnup).
	if _is_spent(peb):
		_discharge(lowest_id, peb)
	else:
		_recirculate(lowest_id, peb)
	# No same-step top-up any more (Phase 3c): admission is the player's own throttled
	# `_fill_rate`, not an invariant the sorter has to protect. A vacancy can sit open
	# for a moment between the sorter's step and the next admission tick — that lag is
	# now a visible, honest part of how fast the player told the plant to fill.


## Send a not-yet-spent pebble back to the top for another pass, keeping ALL its
## burned state (isotopics, burnup, poison). Population is unchanged, so minting
## does not add a fresh pebble for it — only a true discharge opens a slot.
##
## PHASE 3b-ii: it CLIMBS OUT as a real body instead of gliding out as a drawing. A
## recirculating pebble now goes down the same drop a spent one does, is dragged out along the
## duct by its own belt — the opposite way to the discharge belt sharing that duct, which is
## the sorter's decision made mechanical — and is lifted 880 px up the riser, colliding with
## the pipe and with the pebbles ahead of it the whole way. At the head of the climb it bends
## onto the merge run toward the shared inlet and stays a body the rest of the way in
## (Phase 3c: see `_drive`), piling up there until `_admit_batch` lets it into the bed.
##
## THE STATE IT KEEPS is untouched by any of that: isotopics, burnup and poison all ride
## along, because a pass ends at the sorter and not at the pipe. What it does NOT do is burn
## while travelling — it is `_out_of_core` from here until it lands back in the bed, so it is
## outside the flux solve and main freezes it. That is what makes the whole leg free: however
## long the journey takes, the reactor cannot tell, and LOOP_BUFFER covers the pebbles it
## leaves in the pipe meanwhile.
##
## Population is unchanged, so minting does not add a fresh pebble for it — only a true
## discharge opens a slot.
func _recirculate(id: int, peb: Pebble) -> void:
	peb.pass_count += 1
	# The body goes here and is rebuilt in the drop mouth, exactly as a discharge's is: the
	# hopper is CLOSED and must stay closed (a real hole would drain the calibrated bed), so a
	# metered extraction is a removal at the outlet and a reappearance in the pipe it was
	# metered into. See `FuelLoop.drop_mouth` for the full argument — this is the same seam,
	# and it is now the ONLY one on this leg: from the mouth to the top of the riser the pebble
	# is one continuous body.
	_physics.remove_pebble(id)
	_out_of_core[id] = true
	# It does NOT get a body here — it gets in line for one, in the SAME queue spent fuel uses.
	# One outlet, one drop, one door (see `_feed_drop`).
	_drop_pending.push_back({"peb": peb, "leg": FuelLoop.RECIRC})
	_total_recirculated += 1


## Retire a spent pebble: it goes down the discharge pipe as a REAL BODY and settles into
## the pool, and the slot the next mint fills is opened when it gets there (`_pool_admit`).
## The outflow readout is recorded HERE, at the sorter's decision, so its semantics are
## unchanged by however long the journey takes.
##
## PHASE 3b-i: this used to hand the pebble to `_loop` as a rider — a drawn dot sliding
## along a polyline, passing through the pipe walls, the tray and anything already in it.
## Now the pebble is a body for the whole trip and the pipe is solid, so where it ends up
## is the solver's answer rather than the path's. That is the same move Phase 3a made on
## the pool itself, applied to the leg that feeds it: the two body-worlds now JOIN, and a
## discharged pebble is one continuous object from the bed to the pile.
##
## The body is DESTROYED AND RE-CREATED at the outlet rather than carried through, and the
## seam is real — see `FuelLoop.drop_mouth` for why the closed hopper leaves no alternative
## (a hole in the floor would drain the bed uncontrollably). What is NOT re-created is
## anything after this point: from the drop mouth to the pile it is one body, one
## continuous trajectory.
func _discharge(id: int, peb: Pebble) -> void:
	_record_outflow(peb)
	_physics.remove_pebble(id)
	# Out of the core the instant the sorter takes it, and it stays out for good — through
	# the pipe, into the tray, and (unless the player re-injects it) forever. This is THE
	# line that makes the whole leg calibration-safe: the body about to appear in the pipe
	# crosses valid grid cells, and this flag is what stops the flux solve from seeing it.
	_out_of_core[id] = true
	# It does NOT get a body here — it gets in line for one. See `_feed_drop`.
	_drop_pending.push_back({"peb": peb, "leg": FuelLoop.DISCHARGE})


## Put the next spent pebble into the discharge pipe, IF the pipe's mouth is empty.
##
## WHY THIS QUEUE EXISTS, and why "just spawn it" is not an option. The sorter's rate is set
## by the player (the discharge-burnup knob, G/H) and the pipe's rate is set by the belt;
## nothing makes those two agree. Lower the knob and a burnup wave floods this leg — the bed
## is seeded to a spread, so a third of it can come due at once — and the mouth is asked to
## accept a pebble every few frames while the last one is still sitting in it.
##
## Spawning anyway does not queue them, it OVERLAPS them, and the solver's answer to two
## bodies in one place is to fire them apart. Measured, before this existed: pebbles forced
## UP through the silo's hopper floor into the bed — where they are `_out_of_core`, so they
## displace fuel while being invisible to the flux, which is the exact silent-k-shift this
## whole phase is supposed to avoid — and others thrown clear of the bore to fall out of the
## world. 38 wedged, 4 escaped, and the bed ran short as the jam ate LOOP_BUFFER.
##
## So the pipe gets a door. A pebble waits its turn holding no body, exactly as a RIDER or a
## `_queue`-staged pebble does, and the accounting does not notice: it is in `_pebbles` and
## in `_out_of_core`, so it counts as inventory (the mint gate must NOT replace it yet — its
## slot opens when it reaches the pool) and not as core. This is the same shape as the
## staging queue at the top of the loop, for the same reason: a physical pipe cannot be fed
## faster than it accepts, so the feed waits rather than the pipe breaking.
##
## The back-pressure is honest and self-limiting: if the belt ever stops, this grows, the
## mint gate sees no freed slots, and the plant slows down — which is what a blocked
## discharge line should do. It does not silently drop fuel on the floor.
## ONE DOOR FOR BOTH LEGS, because there is one outlet. The sorter's choice is recorded on the
## pebble (`leg`) and settled by the BELT that picks it up at the bottom of the drop, not by
## giving each destination its own hole in the hopper. That is what the plant has always drawn
## — the pipe leaves the vessel, falls to the SORT hub, and only there parts left or right —
## and it is now what the physics does.
##
## THE HEAD-ON THIS COULD HAVE BEEN, and why it is not: two pebbles driven at each other with
## BELT_FORCE apiece would stand there forever. It cannot arise, and not by luck. Every pebble
## enters at the drop's x and is driven AWAY from it — discharge left, recirc right — so
## `discharge_x <= drop_x <= recirc_x` holds structurally and the two legs can only ever be
## pushed apart. MEASURED anyway, because that argument is exactly the kind that is right until
## it is not: a spike fed this drop 150 pebbles ALTERNATING leg every single one (the worst
## case there is — real traffic is ~90% recirc, and the middle of a discharge wave is ~all
## discharge, both of which are one-directional) and saw 0 stuck, 0 lost, and the mouth queue
## never back up at the full 1-per-EXTRACT_INTERVAL feed.
func _feed_drop() -> void:
	if _drop_pending.is_empty() or not _drop_mouth_clear():
		return
	var next: Dictionary = _drop_pending.pop_front()
	var peb: Pebble = next["peb"]
	# Somewhere across the bore, not dead-centre — the pipe is built with BORE_CLEARANCE of
	# play and a pebble does not enter one perfectly aligned. Same honest disorder source as
	# `pool_drop`'s, and it matters for the same reason: symmetric contacts stack.
	_physics.spawn_pebble(peb.id,
			FuelLoop.drop_mouth(_rng.randf_range(-1.0, 1.0), peb.radius), peb.radius)
	# The riser belt runs at 380 px/s and radius is a PLAYER LEVER: a pebble designed at
	# RADIUS_MIN is only 10 px across while a step at belt speed carries it ~6.3 px, and
	# that margin is thin enough that the corner impact punches it clean through the
	# riser's wall. Measured before CCD defaulted on at spawn (`GodotPhysicsBackend.
	# spawn_pebble`): 12, 26 and 14 recirculating pebbles lost in three runs of ~70, every
	# one of them a pebble the calibrated bed never gets back.
	# Tint it NOW rather than letting the per-frame walk catch it a frame later in graphite
	# grey: under a per-pebble field the pebble the player is following must not blink.
	_physics.set_pebble_tint(peb.id, _pebble_tint(peb))
	_transit[peb.id] = next["leg"]


## Is there room at the mouth for one more pebble?
##
## Searches `_transit` WITHOUT asking which leg, and that is the point rather than an oversight:
## the mouth is shared, so what matters is whether anything is standing in it, not what that
## thing is going to do next. A per-leg check would happily drop a recirculating pebble onto a
## spent one still clearing the drop.
##
## And `_transit` alone is sufficient: the mouth sits below the hopper floor, inside the drop's
## bore, and the only bodies that can ever be in there are the ones the drop put there. Bed
## pebbles are the other side of a closed floor; pooled ones are at the far end of the duct.
func _drop_mouth_clear() -> bool:
	var mouth := FuelLoop.drop_mouth()
	for id in _transit:
		if _physics.get_position(id).distance_to(mouth) < FuelLoop.MOUTH_CLEAR:
			return false
	return true


## Put the next pulled-from-the-pool pebble into REINJECT's own riser, IF its mouth is empty
## (Phase 3b-iii). The mirror of `_feed_drop`/`_drop_mouth_clear`, at REINJECT's own door —
## it does not share the outlet's drop, so it does not share that drop's back-pressure either.
## Congestion here is not a real risk (re-injection is rare and player-triggered, never a
## steady 3.33/s like the shared drop), but the door exists anyway rather than special-cased
## away: "never spawn into space that may be occupied" (`FuelLoop.MOUTH_CLEAR`'s reasoning)
## does not stop being true just because the traffic is light.
func _feed_reinject() -> void:
	if _reinject_pending.is_empty() or not _reinject_mouth_clear():
		return
	var peb: Pebble = _reinject_pending.pop_front()
	_physics.spawn_pebble(peb.id,
			FuelLoop.reinject_mouth(_rng.randf_range(-1.0, 1.0), peb.radius), peb.radius)
	# Same CCD reasoning as `_feed_drop`, now handled the same way: radius is a player
	# lever, and a pebble built at RADIUS_MIN moves nearly a diameter per physics step at
	# belt speed — enough to tunnel through the riser's own wall on a backend that did not
	# default it on.
	_physics.set_pebble_tint(peb.id, _pebble_tint(peb))
	_transit[peb.id] = FuelLoop.REINJECT


func _reinject_mouth_clear() -> bool:
	var mouth := FuelLoop.reinject_mouth()
	for id in _transit:
		if _physics.get_position(id).distance_to(mouth) < FuelLoop.MOUTH_CLEAR:
			return false
	return true


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
	var positions := _core_positions()
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
	#
	# `_inventory()`, not `_pebbles.size()`: the pool must not count toward "the plant has
	# made its load". It cannot at startup — nothing has discharged yet, so the pool is
	# empty and this reads exactly as it always did — but a raw registry count would let a
	# stocked pool satisfy the gate with a half-empty bed, which is the under-seeded
	# cold start this line exists to prevent.
	if not _thermal_seeded and cold.k_eff > 1.0 and _inventory() >= _population_setpoint:
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
		# The Lagrangian view should not stop at the vessel wall: a pebble keeps its field
		# color in the bed, riding the machine, and settled in the pool, so you can follow
		# one spent (or hot) pebble all the way to the end of its life.
		#
		# set_pebble_tint is no-op-safe (skips a pebble with no body), which matters for the
		# handful of frames a pebble genuinely has none (mid-removal/respawn at a mouth).
		# Every pebble that has a body — bed, transit, inlet pile, or pool — is reached by
		# this one call now (Phase 3c retired the separate rider tint path: there are no
		# riders left to color).
		_physics.set_pebble_tint(id, c)


## Restore graphite grey (used when switching from a PEBBLE field back to a GRID one).
func _reset_pebble_tints() -> void:
	for id in _pebbles:
		_physics.set_pebble_tint(id, PebbleBody.DEFAULT_TINT)


## The selected PEBBLE field's color for one pebble, or graphite grey when the
## selected field is a GRID one (then the heatmap carries it, not the pebbles).
##
## Split out of _update_pebble_colors so a pebble can be colored at the moment it
## changes hands, before the per-frame walk gets to it: a pebble entering a pipe or
## boarding a rider needs its tint right then, and the plant wants it at spawn/`add`
## time rather than a frame later in graphite grey.
func _pebble_tint(peb: Pebble) -> Color:
	if _fields.is_empty():
		return PebbleBody.DEFAULT_TINT
	var entry: Dictionary = _fields[_current_field]
	var desc: FieldDescriptor = entry["desc"]
	if desc.world != FieldDescriptor.PEBBLE:
		return PebbleBody.DEFAULT_TINT
	return desc.color(entry["get_peb"].call(peb))


## Push the spent pool's CAPTION state to the machine (render clock, pure consumer).
##
## Only counts cross this seam now. The tray used to be handed a color per settled
## pebble because it drew them; they are bodies that draw themselves, so what is left
## is the caption — and the caption is the part that keeps a capped tray honest.
##
## The Lagrangian view still follows a pebble all the way to the END of its life: it
## keeps its field color in the bed, keeps it riding the machine, and keeps it settled
## in the pool (`_update_pebble_colors` tints the pool's bodies like any other). So the
## pool is a readable slice of the outflow — switch to Burnup and every pebble in it is
## at discharge burnup; switch to Xenon and you watch the settled ones drain. That is
## the "inspect the composition of outflowing pebbles" goal (CLAUDE.md) finally having
## something to inspect.
func _refresh_pool() -> void:
	_loop.set_pool(_spent.size(), _total_extracted, _total_shipped)


## Select whatever pebble is under `at`, or clear the selection if that is nothing.
##
## The pool no longer needs a branch of its own. It used to have one — a hit-test
## against the lattice slots, ordered ahead of the bed so a click landed on the layer
## drawn on top — but a settled pebble is a body now, so it falls out of the SAME
## nearest-body search the bed uses, and the two searches were the same search all
## along. What distinguishes a pool hit is not where it was found, it is what the
## pebble IS (`_spent.has`), which is a fact about the sim rather than about draw order.
##
## No separate rider branch any more (Phase 3c retired the last of them) — every pebble
## the plant is holding, wherever it is, is a body the physics knows about.
func _pick_at(at: Vector2) -> void:
	# Every body: the bed AND the settled pool. Nearest hit wins rather than first —
	# pebbles overlap slightly in a packed bed (and in a pile), so "first within radius"
	# would depend on dictionary order and feel arbitrary.
	#
	# Reads `positions()` raw, NOT `_core_positions()`, and that is deliberate: picking is
	# an INTERACTION concern and must reach every pebble that is drawn. `_core_positions`
	# answers a neutronics question ("what is fuel") and would filter the whole pool out
	# of the inspector — the one part of the plant the inspector most needs to reach.
	var positions: Dictionary = _physics.positions()
	var best_id := -1
	var best_d := INF
	for id in positions:
		var peb: Pebble = _pebbles.get(id)
		if peb == null:
			continue
		var d: float = positions[id].distance_to(at)
		if d <= peb.radius and d < best_d:
			best_d = d
			best_id = id
	if best_id == -1:
		_select(null, "")
		return
	var hit: Pebble = _pebbles[best_id]
	# Three kinds of body reach this point now, and WHERE a pebble is is a fact about the
	# sim, not about which list found it — so ask, rather than infer from the search that
	# happened to hit. A transiting pebble is a body like the other two but is neither in
	# the bed nor parked: labelling it "core bed" (which is what a two-way test does) would
	# tell the player a pebble halfway down the discharge pipe is fuel in the reactor.
	_select(hit, _where_is(hit))


## What to call the place a BODIED pebble is sitting — every pebble now (Phase 3c).
## Naming the LEG, not just the pipe: `_transit` carries three since Phase 3b-iii, and they
## mean different things to the player — one pebble is on its way out of the reactor for
## good, the other two are both going back in (by different climbs). A bare membership test
## would tell someone watching a pebble climb either riser that it had been thrown away.
func _where_is(peb: Pebble) -> String:
	if _spent.has(peb):
		return "spent pool"
	if _transit.has(peb.id):
		match _transit[peb.id]:
			FuelLoop.RECIRC: return "recirc riser"
			FuelLoop.REINJECT: return "reinject riser"
			_: return "discharge pipe"
	if _out_of_core.has(peb.id):
		return "waiting at inlet"
	return "core bed"


func _select(peb: Pebble, where: String) -> void:
	_selected = peb
	_selected_where = where
	_overlay.queue_redraw()


## Where the selected pebble is on screen, or Vector2.INF if it has no position.
##
## One lookup answers for every state now (Phase 3c): bed, transit, waiting at the inlet,
## and the pool are all real bodies, so this is just the physics position lookup. Only a
## pebble genuinely between removal and respawn at a mouth — a single physics step, at
## most — reads INF, the same as it always briefly could.
func _selected_pos() -> Vector2:
	if _selected == null:
		return Vector2.INF
	var positions: Dictionary = _physics.positions()
	return positions.get(_selected.id, Vector2.INF)


## Ring the selected pebble. Drawn by a dedicated overlay node with a high z_index
## rather than in main._draw, because main draws BENEATH the field display, the plant
## and the pebble bodies — a ring there would be painted over by the very pebble it
## marks.
func _draw_selection() -> void:
	if _selected == null:
		return
	var at := _selected_pos()
	if at == Vector2.INF:
		return
	_overlay.draw_arc(at, _selected.radius + 4.0, 0.0, TAU, 24, SELECT_RING, 2.0)
	_overlay.draw_arc(at, _selected.radius + 7.0, 0.0, TAU, 24,
		Color(SELECT_RING.r, SELECT_RING.g, SELECT_RING.b, 0.35), 1.0)


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
	# Click to inspect. Handled before the key chain because a mouse event is never a
	# key event — an early return here keeps the two input paths from tangling.
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_pick_at(event.position)
		return

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
			# Design SIZE. Adjacent-pair convention like every other lever here.
			KEY_X:
				_set_radius(_pebble_radius + RADIUS_STEP)
			KEY_Z:
				_set_radius(_pebble_radius - RADIUS_STEP)
			# --- The spent pool, on the SELECTED pebble (click one first) ---
			#
			# These two deliberately add no design UI of their own. The player already has
			# levers for all three design knobs (M/N size, [ ] enrichment, ; ' loading) and
			# they already mean "the design of pebbles from here on"; T just applies that
			# same design to the pebble in hand. A parallel per-pebble editor would be six
			# more keys teaching the same three ideas twice.
			KEY_T:
				_restamp_selected()
			KEY_R:
				_reinject_selected()
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
			# FUEL-CYCLE POLICY — the recirculate-vs-discharge criteria. G/H move the
			# discharge burnup (down = throw fuel away early → younger bed → MORE reactive,
			# and a discharge wave while the sorter clears the newly-spent backlog; up =
			# burn it harder → aged, poisoned bed → reactivity falls until criticality
			# cannot be held). O/P move the pass backstop; P down to 1 makes the core
			# once-through. Unlike the design levers these govern the fuel ALREADY in the
			# bed, not just fresh mints — the rule is the sorter's, not the pebble's.
			KEY_G:
				_set_discharge_burnup(_discharge_burnup - DISCHARGE_STEP)
			KEY_H:
				_set_discharge_burnup(_discharge_burnup + DISCHARGE_STEP)
			KEY_O:
				_set_max_passes(_max_passes - 1)
			KEY_P:
				_set_max_passes(_max_passes + 1)
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


## Change the design SIZE — stamped on fresh fuel at mint, and on a pooled pebble by a
## restamp. CLAUDE.md's third design knob, and until now the only one with no way for the
## player to reach it: `RADIUS_STEP`/`RADIUS_MIN`/`RADIUS_MAX` were all sitting here
## unused and `_pebble_radius` moved only when a test assigned it. Wiring it is what lets
## "edit the design and send it back" actually include size.
##
## Takes effect on the NEXT pebble built — the bed's existing pebbles keep the size they
## were made at, exactly as with enrichment and loading. Nothing resizes a live body.
##
## RADIUS_MAX is the pipe bore, not a taste call: a pebble wider than the bore it rides
## would be drawn outside the pipe carrying it (see FuelLoop.BORE_W).
func _set_radius(r: float) -> void:
	_pebble_radius = clampf(r, RADIUS_MIN, RADIUS_MAX)


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


## Change the DISCHARGE BURNUP criterion — how hard the player burns their fuel before
## throwing it away. Unlike enrichment/loading/size (design levers that are STAMPED on
## fresh fuel and reach the core only as new pebbles cycle in), this is an OPERATING
## lever: it is not a property of a pebble at all, it is the rule the sorter applies, so
## it re-governs every pebble already in the bed the instant it moves.
##
## That immediacy is the interesting part, and it is physics rather than a shortcut.
## Lowering it below burnups the bed already holds does NOT retroactively burn anything —
## it reclassifies pebbles that were "still good" as "spent", and the sorter then works
## through that backlog one pebble per EXTRACT_INTERVAL. So the core sheds aged fuel and
## takes fresh in its place faster than the equilibrium replaces it, mean burnup falls,
## and reactivity RISES. A discharge wave, emergent from the same metered sorter that
## runs the normal cycle — nothing special-cases it, and nothing should.
func _set_discharge_burnup(v: float) -> void:
	_discharge_burnup = clampf(v, DISCHARGE_MIN, DISCHARGE_MAX)


## Change the max-passes BACKSTOP — the criterion that catches a pebble the burnup
## threshold never will (one parked in a cold spot, burning too slowly to ever reach
## discharge). Drive it to 1 and the core is once-through: every pebble gets exactly one
## trip through the bed and leaves, however little it burned.
func _set_max_passes(v: int) -> void:
	_max_passes = clampi(v, PASSES_MIN, PASSES_MAX)


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
		var fuel_short := _core_count() < _population_setpoint
		if rod_held:
			status = "SUBCRITICAL — held down by control rods (N to withdraw)"
			status_col = "ffaa44"
		elif xenon_pit:
			status = "SUBCRITICAL — XENON PIT (dead time; wait for Xe decay)"
			status_col = "c792ea"
		elif fuel_short:
			status = "SUBCRITICAL — not enough fuel in the bed yet (%d / %d)" \
				% [_core_count(), _population_setpoint]
			status_col = "7aa2f7"
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

	# The sorter's BACKLOG: pebbles in the bed that the current policy already calls spent
	# and which are still riding down to the outlet, since only the lowest pebble can be
	# extracted (one per EXTRACT_INTERVAL). This is the number that makes the discharge
	# wave visible instead of mysterious: in equilibrium it sits at a small steady value
	# (a pebble crosses the threshold mid-bed and takes a while to reach the bottom), but
	# the instant the player lowers the threshold it JUMPS — a slug of fuel reclassified
	# as spent in one keystroke — and then drains at the metered rate while fresh fuel
	# replaces it and reactivity climbs. Without this row the player sees power rise for
	# no visible reason; with it, they watch the cause drain away.
	var spent_in_bed := 0
	for pid in _pebbles:
		if not _out_of_core.has(pid) and _is_spent(_pebbles[pid]):
			spent_in_bed += 1
	var policy_note := ""
	if spent_in_bed > 0:
		policy_note = "   [color=#ff7043]%d spent in bed, awaiting the sorter[/color]" % spent_in_bed

	# Overfill note (Phase 3c): once the bed is genuinely denser than the calibrated
	# reference, say so — the honest physical consequence (a taller pile, and eventually
	# a jammed inlet once it reaches the feed) is already what the physics does; this is
	# only the readout that names it. Pure comparison against RECOMMENDED_POPULATION, not
	# a new penalty.
	var overfill_note := ""
	if _core_count() > RECOMMENDED_POPULATION:
		overfill_note = "   [color=#ffaa44]OVERFILLED — pile crowding the feed[/color]"

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
		+ _row("in core", "%d / %d setpoint (recommended %d)   %d in the machine%s" % [
			_core_count(), _population_setpoint, RECOMMENDED_POPULATION, _transit.size(), overfill_note]) \
		+ _row("cycle", "recirculated %d   discharged %d   made %d%s" % [
			_total_recirculated, _total_extracted, _total_injected,
			# Only once it has happened: these two are player-driven, so a permanent
			# "casked 0  re-injected 0" would be two dead rows on every default run.
			("   casked %d   re-injected %d" % [_total_shipped, _total_reinjected]) \
				if _total_shipped + _total_reinjected > 0 else ""]) \
		+ _row("policy", "discharge at %.0f MWd/kgHM (G/H)   or %d passes (O/P)%s"
			% [_discharge_burnup, _max_passes, policy_note]) \
		+ _section("SPENT FUEL OUT") \
		+ outflow \
		+ _section("DESIGN & CONTROLS") \
		+ _row("enrichment", "%.1f%% fresh fuel   flow %.2f   inlet %.0f K" % [_enrichment * 100.0, _coolant_flow, _inlet_temp]) \
		+ _row("loading", "%.2f → M %.2f  %s" % [_fuel_loading, m_design, mod_regime]) \
		+ _row("feedback", "%s   scram %s   campaign %.0f" % [("[color=#6ecf7a]ON[/color]" if _feedback_on else "[color=#ff5555]OFF[/color]"), ("[color=#ffaa44]TRIPPED[/color]" if _scrammed else "off"), _clocks.campaign_elapsed]) \
		+ _section("FIELD") \
		+ _row(field_name, "solve iters %d   fps %d" % [_solve_iters, Engine.get_frames_per_second()])


## The inspector panel: everything this toy tracks about ONE pebble.
##
## The Lagrangian half of the two-worlds model, made legible. The heatmaps show a
## pebble's field value as a color; this shows the actual vector behind that color —
## which is what "inspect the composition of outflowing pebbles" (CLAUDE.md) has
## always meant, and what the burnup gradient down the bed looks like one pebble at a
## time. Reads sim state and writes nothing back.
func _update_inspector() -> void:
	if _selected == null:
		_inspector.text = _section("INSPECTOR") \
			+ "[color=#%s]click any pebble — in the bed, riding the machine, or settled\nin the spent pool[/color]" % HUD_DIM
		return

	var p := _selected
	# Fissile fraction of heavy metal — the same proxy the homogenizer feeds the
	# cross-sections (grid._enrichment_of), so this row is what the physics actually
	# sees, not a separate bookkeeping number that could drift from it.
	var hm: float = p.u235 + p.u238 + p.pu239
	var fissile: float = (p.u235 + p.pu239) / hm if hm > 0.0 else 0.0
	# The LIVE policy, not the Depletion constants: these three rows answer "what happens
	# to THIS pebble", so they must be judged by the rule the sorter will actually apply.
	# The verdict goes through _is_spent — the sorter's own predicate — so the panel cannot
	# tell the player a pebble is live while the sorter discharges it.
	var passes := "%d / %d" % [p.pass_count, _max_passes]
	var spent_note := ""
	if _is_spent(p):
		spent_note = "  [color=#ff7043](spent)[/color]"

	_inspector.text = _section("INSPECTOR") \
		+ _row("pebble", "#%d   [color=#%s]%s[/color]%s" % [p.id, HUD_DIM, _selected_where, spent_note]) \
		+ _row("size", "r = %.2f px   (area weight %.2f x)"
			% [p.radius, (p.radius * p.radius) / (PEBBLE_RADIUS * PEBBLE_RADIUS)]) \
		+ _row("loading", "%.2f  →  M %.2f" % [p.fuel_loading, CrossSections.moderation(p.fuel_loading)]) \
		+ _section("COMPOSITION") \
		+ _row("fissile", "%.2f%% of heavy metal" % (fissile * 100.0)) \
		+ _row("U-235", "%.4f" % p.u235) \
		+ _row("U-238", "%.4f" % p.u238) \
		+ _row("Pu-239", "%.4f" % p.pu239) \
		+ _row("poison", "%.5f   Xe-135 %.2f ×1e-5" % [p.poison, p.xe135 * 1e5]) \
		+ _section("LIFE") \
		+ _row("burnup", "%.1f / %.0f MWd/kgHM" % [p.burnup, _discharge_burnup]) \
		+ _row("passes", passes) \
		+ _row("temperature", "%.0f K" % p.temperature) \
		+ _row("local flux", "%.3f" % p.local_flux) \
		+ _pool_actions(p)


## The edit/re-inject offer, shown ONLY for a pebble in the pool — the one place a pebble
## is parked and bodiless enough to redesign (see `_pool_selected`). Naming the keys on
## the panel is what makes the pool's whole point discoverable: without this the player
## has a tray of pebbles they can click and no reason to think they can do anything else.
##
## It states what the restamp will DO, in the design the pebble would get, so pressing T
## is a confirmed action rather than a guess. And it says the pebble stays spent, because
## that is the surprise otherwise: re-injecting a burned pebble sends it round once and
## the sorter discharges it right back — correct, and baffling if unannounced. Raising the
## discharge knob (G/H) is what actually keeps it, which is the Phase 1 lever composing
## with this one.
func _pool_actions(p: Pebble) -> String:
	if not _spent.has(p):
		return ""
	var out := _section("SPENT POOL")
	out += _row("[T] restamp", "r %.2f → %.2f   loading %.2f → %.2f"
		% [p.radius, _pebble_radius, p.fuel_loading, _fuel_loading])
	out += _row("[R] re-inject", "send it round again")
	if _is_spent(p):
		out += _row("", "[color=#%s]still spent — the sorter will discharge it again\nunless you raise the burnup limit (G/H)[/color]"
			% HUD_DIM)
	return out


## One dim section header line of the readout panel.
static func _section(title: String) -> String:
	return "[color=#%s][b]%s[/b][/color]\n" % [HUD_HEAD, title]


## One "label value…" line of the readout panel: dim label, bright value.
static func _row(label: String, value: String) -> String:
	return "[color=#%s]%s[/color]  %s\n" % [HUD_DIM, label, value]
