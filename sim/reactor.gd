# sim/reactor.gd
#
# The coupling loop as an OBJECT — the engine-agnostic reactor core that main.gd drives.
#
# WHY this exists (structure, not physics): until this file, the two-worlds coupling —
# homogenize → solve → feedbacks → sample-back, plus the fast-clock thermal/kinetics
# integration and the campaign-clock depletion — lived as methods on the Godot scene
# node (main.gd), interleaved with the HUD, the fuel-handling machine, and the input
# handling. That had one serious consequence for a project whose whole method is
# "calibrate against gated tests": the pure test suite could not run the LIVE loop.
# tests/test_thermal.gd re-implements its own copy of the coupled loop, and the two
# copies drifted — which is exactly why the notes had to speak of a pure-harness fixed
# point (A_REF = 87) that differs from the live scene's (~32), and of "breathing" that
# the pure loop does not reproduce. Now there is ONE loop. main.gd calls it with the
# physics engine's positions; a test calls it with a lattice. Both run this code.
#
# CONTRACT (CLAUDE.md principle 5): no Godot, no scene tree, no physics engine. It takes
# dictionaries of Pebble objects and positions and mutates pebble state + its own
# readouts. Three clocks, kept apart exactly as before (principle 1):
#
#   solve(...)         — clockless. Quasi-static two-group eigenproblem at the current
#                        pebble temperatures/rods/xenon. Call on a cadence.
#   thermal_step(dt)   — the physics clock. Power amplitude + per-pebble energy balance.
#   deplete(dt)        — the campaign clock. dt is derived from the physics step by
#                        Clocks and reaches nothing but Depletion.step.
#
# Everything the HUD shows is a plain field here; main.gd forwards them.
class_name ReactorCore
extends RefCounted

# --- Player levers (operating; the DESIGN levers are stamped on pebbles, not held here)
var feedback_on := true
var rod_insertion := 0.0              # fraction of the grid height the rods span
var scrammed := false                 # emergency shutdown engaged (drives rods full in)
var pre_scram_insertion := 0.0        # rod position to restore on reset (see toggle_scram)
var coolant_flow := Thermal.FLOW_NOMINAL
var inlet_temp := Thermal.INLET_MIN

# --- Integrated state
var grid: Grid
var clocks := Clocks.new()
var amplitude := Thermal.A_NOMINAL    # power-amplitude state (scales the flux shape)
var thermal_seeded := false           # one-time near-equilibrium seed done?
var running := false                  # core producing power (display/status threshold)

# --- Readouts written by solve()
var k_eff := 0.0
var k_cold := 0.0                     # k with feedback OFF — the reactivity being suppressed
var xenon_worth := 0.0                # k_no_xe − k, Δk (>0: xenon suppressing reactivity)
var rod_worth := 0.0                  # k_norod − k, Δk (>0: rods holding k down)
var mean_xenon := 0.0                 # bed-average Xe-135 inventory (a.u.)
var solve_iters := 0
var flux := PackedFloat32Array()      # peak-normalized fission-rate density (the heat shape)
var flux_fast := PackedFloat32Array()
var flux_thermal := PackedFloat32Array()
var temp_field := PackedFloat32Array()      # homogenized pebble temperature (K)
var coolant_field := PackedFloat32Array()   # coolant transport field (K)
var moderation_field := PackedFloat32Array() # design per-cell M (pre-MTC)

# --- Readouts written by thermal_step()
var peak_temp := Feedback.T_REF
var mean_temp := Feedback.T_REF
var coolant_out := Thermal.INLET_MIN  # hottest coolant seen (bed outlet)
var extracted := 0.0                  # bed-total heat carried off by the coolant (a.u.)
var decay_heat := 0.0                 # bed-total delivered decay heat (a.u.)
var decay_frac := 0.0                 # decay heat as a fraction of total delivered heat

# Warm-start cache: the previous cadence's answer to each of the (up to four) eigen-
# problems solve() poses. The core barely changes between cadences, so seeding the
# power iteration from the last answer converges in a few outer iterations instead of
# ~45 (Neutronics.solve header) — a ~10× cut in the solve's frame cost. One slot per
# problem, because they are DIFFERENT problems (rods in vs out, xenon in vs out): a
# guess from the wrong one still converges, just more slowly.
var _sol_cold: Neutronics.Solution = null
var _sol_noxe: Neutronics.Solution = null
var _sol_norod: Neutronics.Solution = null
var _sol_warm: Neutronics.Solution = null


func _init(p_grid: Grid = null) -> void:
	grid = p_grid if p_grid != null else Grid.for_silo()
	var n := grid.cell_count()
	temp_field = grid.temperature.duplicate()
	coolant_field = grid.coolant_temp.duplicate()
	moderation_field = PackedFloat32Array(); moderation_field.resize(n)


## Forget the campaign: amplitude, seed, clocks, warm-start cache. The LEVERS are
## deliberately untouched — a restart is "empty the plant and refill it", not "undo my
## settings" (main._reset_population).
func reset_campaign() -> void:
	amplitude = Thermal.A_NOMINAL
	thermal_seeded = false
	running = false
	clocks = Clocks.new()
	_sol_cold = null
	_sol_noxe = null
	_sol_norod = null
	_sol_warm = null
	_pending_diag.clear()


# --- Levers ------------------------------------------------------------------

## Drive the control rods (M5d). INERT WHILE SCRAMMED: the trip acts through these same
## rods, so a manual jog would otherwise walk a scrammed bank back out and quietly defeat
## the scram. Returns whether the rods moved.
func set_rods(x: float) -> bool:
	if scrammed:
		return false
	rod_insertion = clampf(x, ControlRods.INSERT_MIN, ControlRods.INSERT_MAX)
	return true


## Trip / reset the scram. Scram SLAMS THE CONTROL RODS FULLY IN — that is the whole
## mechanism (no lumped scram worth anywhere): the rods are real absorbers in the solve,
## so the trip's reactivity is emergent. Reset RESTORES THE PRE-SCRAM INSERTION rather
## than withdrawing to zero: withdrawing to zero would re-expose exactly the excess the
## player's rods were holding down, making the un-scram itself the cause of an over-temp.
## The caller should re-solve immediately — a trip must register now, not at the next
## cadence.
func toggle_scram() -> void:
	scrammed = not scrammed
	if scrammed:
		pre_scram_insertion = rod_insertion
		rod_insertion = ControlRods.INSERT_MAX
	else:
		rod_insertion = pre_scram_insertion


func set_flow(f: float) -> void:
	coolant_flow = clampf(f, Thermal.FLOW_MIN, Thermal.FLOW_MAX)


func set_inlet(t: float) -> void:
	inlet_temp = clampf(t, Thermal.INLET_MIN, Thermal.INLET_MAX)


# --- The clockless solve -----------------------------------------------------

# Diagnostic solves: the readouts that are NOT the driving solve. Each is a full
# eigenproblem, and a cadence used to pose all of them in the same physics frame as
# the warm solve — three or four ~3 ms solves back to back, a ~15 ms hitch five times a
# second (measured, tests/live_render_perf.gd). See `defer_diagnostics`.
const DIAG_COLD := 0     # k with no feedback — k_cold (also the seed's reference)
const DIAG_NOXE := 1     # k with the Xe-135 absorption stripped — xenon worth
const DIAG_NOROD := 2    # k with the rods stripped — rod worth

# Spread the diagnostic solves over the frames AFTER the cadence instead of doing them
# all in the cadence frame. OFF by default so every headless gate that calls solve()
# and reads k_cold / xenon_worth / rod_worth on the next line sees them fresh, exactly
# as before. main.gd turns it ON: the driving warm solve still lands in the cadence
# frame (the physics never waits), and the three readouts follow one per physics frame
# via `run_deferred_diagnostic` — fresh within ~50 ms, against the SAME homogenized
# grid, so a worth is still the difference of two solves of one core. Per-frame peak
# cost drops from ~4 solves to 1. `solve(..., immediate=true)` bypasses the deferral
# for the moments that must register at once (scram, feedback toggle).
var defer_diagnostics := false
var _pending_diag: Array = []
# The cadence's temperature-free bases (what homogenize + rods wrote) and its rod-free
# thermal absorption, kept so a deferred diagnostic can pose its problem against the
# cadence's core after the warm solve has overwritten the grid with the fed-back
# cross-sections — and restore those afterwards, so the grid a reader sees between
# frames is always the warm one the physics is running on.
var _base_sa1 := PackedFloat32Array()
var _base_sr := PackedFloat32Array()
var _base_sa2 := PackedFloat32Array()
var _sa2_norod := PackedFloat32Array()
var _cold_k_for_worths := 0.0   # the cold k the pending worths difference against
# The two diffusion stencils for the cadence's homogenization — built once here and
# shared by every solve posed against it (Neutronics.build_stencils).
var _stencils: Array = []


## The coupling step: homogenize the in-core pebbles (`positions` holds ONLY pebbles in
## the bed; ids index `pebbles`) — including each pebble's real, lagged temperature —
## onto the grid, solve the quasi-static flux against that temperature, measure the
## absorber worths, then push results outward only (sample flux/coolant/fission share
## back onto the pebbles). Temperature is a STATE the pebbles carry (thermal_step), so
## Doppler just reads grid.temperature and we solve the eigenproblem ONCE — no search.
##
## `allow_seed`: the one-time near-equilibrium seed may fire this call (the caller gates
## it on the bed being FULL — a partly-filled bed reads k_cold just above 1, giving a
## tiny equilibrium ΔT: under-seeding, and the climb to the packed operating point IS the
## overshoot the seed exists to avoid).
##
## `immediate`: run the diagnostic solves in this call even when `defer_diagnostics` is
## on — for a change that must show up in every readout NOW (a scram trip).
func solve(pebbles: Dictionary, positions: Dictionary, allow_seed: bool, immediate := false) -> void:
	if positions.is_empty():
		return
	grid.homogenize(pebbles, positions)

	# CONTROL RODS (M5d) go in HERE — after homogenize, BEFORE the bases are snapshot. A
	# rod is not feedback, it is part of the core's physical CONFIGURATION, like
	# enrichment or burnup: applying it to the base means every downstream solve — cold,
	# xenon-worth, warm, AND the feedback-OFF branch — sees the rods for free. It cannot
	# stack across frames because homogenize unconditionally REWRITES sigma_a2 first.
	_sa2_norod = grid.sigma_a2.duplicate() if rod_insertion > 0.0 else PackedFloat32Array()
	ControlRods.apply_rods(grid, rod_insertion)

	# Snapshot the temperature-FREE bases homogenize just wrote (Neutronics only reads
	# the grid). Doppler perturbs sigma_a1; the moderator-temperature coefficient perturbs
	# sigma_r / sigma_a2.
	_base_sa1 = grid.sigma_a1.duplicate()
	_base_sr = grid.sigma_r.duplicate()
	_base_sa2 = grid.sigma_a2.duplicate()
	_stencils = Neutronics.build_stencils(grid)

	# The diagnostics run here, in the cadence frame, unless deferred. Before the seed
	# they always run here: the seed needs the cold flux and a fresh cold k this call.
	# With feedback OFF the cold solve IS the driving solve, so it too stays here.
	var deferred := defer_diagnostics and not immediate and thermal_seeded
	_pending_diag.clear()

	var cold: Neutronics.Solution = null
	if not deferred or not feedback_on:
		# Cold (temperature-free) reference solve — the honest UNCONTROLLED reactivity,
		# the k the core WOULD run at with no feedback (design M, no Doppler, no MTC).
		cold = Neutronics.solve(grid, 300, 8, 1.0e-5, _sol_cold, 1.0e-4, _stencils)
		_sol_cold = cold
		k_cold = cold.k_eff
		_cold_k_for_worths = k_cold
	else:
		_pending_diag.append(DIAG_COLD)

	if not deferred:
		_diag_noxe()
		if rod_insertion > 0.0:
			_diag_norod()
		else:
			rod_worth = 0.0
	else:
		_pending_diag.append(DIAG_NOXE)
		if rod_insertion > 0.0:
			_pending_diag.append(DIAG_NOROD)
		else:
			rod_worth = 0.0

	if not thermal_seeded and allow_seed and cold != null and cold.k_eff > 1.0:
		seed_equilibrium(pebbles, positions, cold.flux)

	var sol: Neutronics.Solution
	if feedback_on:
		# Warm solve: temperature-free base + Doppler (fuel T → sigma_a1) + moderator-
		# temperature feedback (graphite T → sigma_r / sigma_a2) at the CURRENT per-cell
		# state. Both feedbacks read the SAME driver — grid.temperature, the pebble/graphite
		# temperature (Thermal.apply_field_moderator). Restore all three bases first so
		# neither feedback stacks across frames.
		grid.sigma_a1 = _base_sa1.duplicate()
		grid.sigma_r = _base_sr.duplicate()
		grid.sigma_a2 = _base_sa2.duplicate()
		Thermal.apply_field_doppler(grid)
		Thermal.apply_field_moderator(grid)
		sol = Neutronics.solve(grid, 300, 8, 1.0e-5, _sol_warm, 1.0e-4, _stencils)
		_sol_warm = sol
	else:
		# Feedback OFF: the uncontrolled state — no Doppler, no MTC, so k is the raw cold
		# k and nothing self-limits power. Restore the bases so the heatmaps show the design
		# cross-sections, not a stale warm field.
		grid.sigma_a1 = _base_sa1.duplicate()
		grid.sigma_r = _base_sr.duplicate()
		grid.sigma_a2 = _base_sa2.duplicate()
		sol = cold
	k_eff = sol.k_eff
	flux = sol.flux
	flux_fast = sol.flux_fast
	flux_thermal = sol.flux_thermal
	solve_iters = sol.iterations

	# M4b coolant transport: with the fuel temperature freshly homogenized, march the
	# downstream coolant energy balance (top-down, co-current with the falling pebbles).
	# Quasi-steady on the solve cadence; the pebbles sample it as their cooling sink.
	Thermal.solve_coolant_field(grid, coolant_flow, inlet_temp)

	temp_field = grid.temperature.duplicate()
	coolant_field = grid.coolant_temp.duplicate()
	moderation_field = grid.moderation.duplicate()

	# SAMPLE-BACK: flux drives each pebble's fission heat (thermal_step) and burnup
	# (deplete); coolant is its Newton-cooling sink; the fission weight is its own share
	# of the cell's fission rate (Pebble.fission_weight). Fuel temperature is NOT sampled
	# back — it is the pebble's own integrated state; that map runs pebble → grid.
	var xe_sum := 0.0
	var xe_n := 0
	for id in positions:
		var peb: Pebble = pebbles.get(id)
		if peb != null:
			var pos: Vector2 = positions[id]
			peb.local_flux = grid.sample(flux, pos)
			peb.local_coolant = grid.sample(coolant_field, pos)
			peb.fission_weight = fission_weight_of(peb, pos)
			xe_sum += peb.xe135
			xe_n += 1
	mean_xenon = xe_sum / xe_n if xe_n > 0 else 0.0


## Run ONE queued diagnostic solve (see `defer_diagnostics`), or nothing if none is
## pending. Called by main every physics frame. Poses the problem against the cadence's
## temperature-free bases, then puts the grid back exactly as it found it (the warm,
## fed-back cross-sections the physics is running on).
func run_deferred_diagnostic() -> void:
	if _pending_diag.is_empty():
		return
	var which: int = _pending_diag.pop_front()
	var live_sa1 := grid.sigma_a1
	var live_sr := grid.sigma_r
	var live_sa2 := grid.sigma_a2
	grid.sigma_a1 = _base_sa1
	grid.sigma_r = _base_sr
	grid.sigma_a2 = _base_sa2
	match which:
		DIAG_COLD:
			var cold := Neutronics.solve(grid, 300, 8, 1.0e-5, _sol_cold, 1.0e-4, _stencils)
			_sol_cold = cold
			k_cold = cold.k_eff
			_cold_k_for_worths = k_cold
		DIAG_NOXE:
			_diag_noxe()
		DIAG_NOROD:
			_diag_norod()
	grid.sigma_a1 = live_sa1
	grid.sigma_r = live_sr
	grid.sigma_a2 = live_sa2


## Xenon reactivity worth (M5c): re-solve with the Xe-135 absorption stripped out of
## the thermal group. XENON_A2*xenon is exactly what homogenize folded into sigma_a2.
## Expects the grid to hold the temperature-free bases; leaves it holding them.
func _diag_noxe() -> void:
	var sa2_xe := grid.sigma_a2
	var stripped := sa2_xe.duplicate()
	for c in range(grid.cell_count()):
		stripped[c] = sa2_xe[c] - CrossSections.XENON_A2 * grid.xenon[c]
	grid.sigma_a2 = stripped
	var cold_noxe := Neutronics.solve(grid, 300, 8, 1.0e-5, _sol_noxe, 1.0e-4, _stencils)
	_sol_noxe = cold_noxe
	grid.sigma_a2 = sa2_xe
	xenon_worth = cold_noxe.k_eff - _cold_k_for_worths


## Control-rod worth (M5d), measured the same honest way: re-solve against the rod-FREE
## snapshot and difference. Measured COLD (like xenon) so it is the rod's OWN
## reactivity, not tangled with the feedback's response to it. Costs a solve ONLY while
## the rods are in; fully withdrawn, worth is exactly zero by definition (the caller
## sets it). Expects the grid to hold the temperature-free bases; leaves it holding them.
func _diag_norod() -> void:
	var sa2_rod := grid.sigma_a2
	grid.sigma_a2 = _sa2_norod
	var cold_norod := Neutronics.solve(grid, 300, 8, 1.0e-5, _sol_norod, 1.0e-4, _stencils)
	_sol_norod = cold_norod
	grid.sigma_a2 = sa2_rod
	rod_worth = cold_norod.k_eff - _cold_k_for_worths


## A pebble's share of its cell's fission rate: its fissile fraction over the cell's
## area-weighted one (the `e` the cell's nu_sigma_f was built from). Uses the pebble's
## OWN cell (not a bilinear blend) so that, summed over the cell's pebbles, the shares
## reproduce the cell's total exactly — energy is conserved per cell by construction.
## 1.0 outside the grid or in a non-fuel cell.
func fission_weight_of(peb: Pebble, pos: Vector2) -> float:
	var c := grid.cell_of(pos)
	if c < 0 or grid.nu_sigma_f[c] <= 0.0:
		return 1.0
	var e_cell := grid.enrichment[c]
	if e_cell <= 0.0:
		return 1.0
	return Grid.fissile_fraction(peb) / e_cell


## One-time near-equilibrium seed: open the core AT its operating point so it just
## settles rather than igniting from cold with a big overshoot. Amplitude → A_REF and
## each pebble's temperature → the steady value that same amplitude sustains at the
## current flow (power and temperature mutually consistent, so k_eff starts ≈ 1), decay
## reservoirs and Xe-135 at their operating inventories (no spurious build-up
## transients). WHY A_REF rather than Feedback.solve_equilibrium: the frozen-shape search
## under-estimates ΔT for a reactive fresh bed and saturates at high enrichment.
func seed_equilibrium(pebbles: Dictionary, positions: Dictionary, cold_flux: PackedFloat32Array) -> void:
	var h := Thermal.h_of_flow(coolant_flow)
	for id in positions:
		var peb: Pebble = pebbles.get(id)
		if peb != null:
			var pos: Vector2 = positions[id]
			var lf := grid.sample(cold_flux, pos)
			var size := Thermal.size_of(peb)
			peb.fission_weight = fission_weight_of(peb, pos)
			var s := Thermal.pebble_power(Thermal.A_REF, lf, size, peb.fission_weight)
			# Seed against the inlet coolant (the field's downstream rise is a modest
			# correction the bed settles out over its first seconds). steady_temp takes
			# the TOTAL fuel heat S: at steady state prompt + decay = S.
			peb.temperature = Thermal.steady_temp(s, inlet_temp, h, size)
			Thermal.seed_decay_heat(peb.decay_e, s)
			# Xe-135 at its equilibrium for the pebble's OPERATING flux (A_REF ⇒ power_frac
			# ≈ 1, so the operating fluence is just its local peak-normalized flux).
			Depletion.seed_xenon(peb, lf)
	amplitude = Thermal.A_REF
	thermal_seeded = true


# --- The physics clock -------------------------------------------------------

## Integrate the power + thermal dynamics one physics step — the only fast-clock time
## integration (CLAUDE.md clock model). Power amplitude follows toy point-kinetics
## against the latest k (exact exponential); each in-core pebble's temperature relaxes
## under its fission heat and the coolant/ambient losses (semi-implicit). Pebbles whose
## id is in `out_of_core` (riding the fuel machine, staged, pooled) are skipped: no
## fission heat in the pipe, no place in the coolant loop — their state is frozen.
##
## Feedback OFF FREEZES the loop. WHY this is mandatory, not cosmetic: with no Doppler,
## k = raw cold k > 1, so the exponential kinetics would drive the amplitude to A_MAX
## every frame; burnup ∝ A/A_REF would then deplete the whole core to spent in a step
## or two — silent, irreversible state corruption from a couple of seconds of the
## F-toggle demo. OFF holds A, temperatures, and burnup fixed and displays the
## uncontrolled k as the contrast.
func thermal_step(pebbles: Dictionary, out_of_core: Dictionary, dt: float) -> void:
	if dt <= 0.0 or not feedback_on:
		return
	# NO scram term: scram is a full rod insertion and the rods are REAL absorbers in
	# the grid before the solve, so k_eff ALREADY carries the trip (~0.62 scrammed).
	amplitude = Thermal.step_power(amplitude, k_eff, dt)
	var h := Thermal.h_of_flow(coolant_flow)
	var peak := Feedback.T_REF
	var sum_t := 0.0
	var shed := 0.0
	var out_t := inlet_temp
	var sum_decay := 0.0
	var sum_delivered := 0.0
	var count := 0
	for id in pebbles:
		if out_of_core.has(id):
			continue
		var peb: Pebble = pebbles[id]
		var size := Thermal.size_of(peb)
		# M4b: cooled by its LOCAL coolant temperature (downstream transport field).
		var t_cool := peb.local_coolant
		# M5 energy-conserving split of the fission power S: a prompt part deposited now,
		# plus the decay-heat reservoirs. Size and fission share scale S (Thermal header).
		var s := Thermal.pebble_power(amplitude, peb.local_flux, size, peb.fission_weight)
		var decay := Thermal.step_decay_heat(peb.decay_e, s, dt)
		var p := Thermal.prompt_power(s) + decay
		peb.temperature = Thermal.step_pebble_temp(peb.temperature, p, t_cool, h, dt, size)
		# Heat carried off by the coolant — what the heat exchanger harvests (the headline
		# power). The ambient loss is a passive structural leak, not harvested.
		shed += Thermal.conv_power(peb.temperature, t_cool, h, size)
		sum_decay += decay
		sum_delivered += p
		peak = maxf(peak, peb.temperature)
		sum_t += peb.temperature
		out_t = maxf(out_t, t_cool)
		count += 1
	peak_temp = peak
	mean_temp = sum_t / count if count > 0 else Feedback.T_REF
	coolant_out = out_t
	extracted = shed
	decay_heat = sum_decay
	decay_frac = sum_decay / sum_delivered if sum_delivered > 0.0 else 0.0
	running = amplitude > Thermal.A_RUNNING


# --- The campaign clock ------------------------------------------------------

## Deplete every in-core pebble by one campaign step derived from `physics_dt` (the
## ONLY place the two rates meet — Clocks). Frozen when feedback is OFF (no valid
## dynamic power level exists without Doppler). Real fluence scales with ABSOLUTE flux
## = amplitude × normalized shape, so burnup ∝ A/A_REF: at the design point the
## M3-calibrated rate; an idling core barely burns. Out-of-core pebbles must not burn
## (their last local_flux is stale and non-zero).
func deplete(pebbles: Dictionary, out_of_core: Dictionary, physics_dt: float) -> void:
	var campaign_dt := clocks.campaign_dt(physics_dt)
	if not feedback_on or campaign_dt <= 0.0 or amplitude <= 0.0:
		return
	var power_frac := amplitude / Thermal.A_REF
	for id in pebbles:
		if out_of_core.has(id):
			continue
		var peb: Pebble = pebbles[id]
		Depletion.step(peb, peb.local_flux * power_frac, campaign_dt)
