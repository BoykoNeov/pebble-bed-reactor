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
# Fine step: enrichment is a steep reactivity lever, so a coarse step would jump
# straight from self-regulating to over-temp and hide the "flat reactivity, rising
# power" behavior (a CLAUDE.md validation target). Small steps show the core climb
# through several regulating states — power/temperature up, k pinned ~1 — first.
const ENRICH_STEP := 0.0005
# Above this equilibrium fuel temperature the toy calls the core "over-temp": the
# point where Doppler alone stops being a safe hold (real cores use control rods
# for that excess — M5). ~1800 K ≈ 1500 °C, near the TRISO integrity limit.
const OVER_TEMP_K := 1800.0

var _physics: PhysicsBackend
var _pebbles: Dictionary = {}   # id -> Pebble (the Lagrangian registry)
var _rng := RandomNumberGenerator.new()
var _next_id := 0
var _spawn_accum := 0.0
var _extract_accum := 0.0
var _solve_accum := 0.0

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
var _enrichment := CrossSections.E_REF
var _k_cold := 0.0            # k with feedback OFF — the reactivity being suppressed
var _peak_temp := Feedback.T_REF
var _regulated := false
var _feedback_insufficient := false

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

	# Field registry: each entry pairs a descriptor with a getter for its latest
	# array. Adding a field (burnup at M3, coolant temp at M4) is one more entry.
	_fields = [
		{"desc": _flux_desc, "get": func() -> PackedFloat32Array: return _last_flux},
		{"desc": _temp_desc, "get": func() -> PackedFloat32Array: return _last_temp},
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
		_pebbles[id] = peb
		var pos := Vector2(Silo.spawn_x(_rng, PEBBLE_RADIUS + 2.0), Silo.spawn_y())
		_physics.spawn_pebble(id, pos, PEBBLE_RADIUS)
		_total_injected += 1


func _extract_lowest() -> void:
	# Metered discharge: pull the single lowest (most-descended) pebble out of
	# the closed hopper. Only once the bed is actually settled at the bottom, so
	# we don't yank pebbles still in free-fall near the top. The vacated space
	# lets the bed creep down and top injection refills it — steady circulation.
	# (M3 will read this pebble's burnup/pass count to decide discharge vs
	# recirculate instead of always discharging.)
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
	_physics.remove_pebble(lowest_id)
	_pebbles.erase(lowest_id)
	_total_extracted += 1


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
		# power_scale keeps the relative-power readout numerically distinct from the
		# raw ΔT (in the instant placeholder the two are proportional — T ∝ power).
		var eq := Feedback.solve_equilibrium(_grid, 0.1)
		_k_eff = eq.k_eff
		_k_cold = eq.k_cold
		_regulated = eq.regulated
		_feedback_insufficient = eq.feedback_insufficient
		_peak_temp = Feedback.T_REF + eq.peak_dt
		_power = eq.power if eq.regulated else 0.0
		_solve_iters = eq.iterations
		_last_flux = eq.flux
		_last_temp = eq.temperature
	else:
		# Feedback off: the honest uncontrolled state. No Doppler, so fuel sits at
		# inlet temperature and there is no self-limited power level to report.
		var sol := Neutronics.solve(_grid)
		_k_eff = sol.k_eff
		_k_cold = sol.k_eff
		_regulated = false
		_feedback_insufficient = false
		_peak_temp = Feedback.T_REF
		_power = -1.0            # undefined without feedback (would run away / decay)
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


## Push the currently selected field into the heatmap + colorbar.
func _refresh_field_display() -> void:
	if _fields.is_empty():
		return
	var entry: Dictionary = _fields[_current_field]
	var desc: FieldDescriptor = entry["desc"]
	var field: PackedFloat32Array = entry["get"].call()
	if field.is_empty():
		return
	_field_display.set_grid_field(_grid, field, desc)
	_color_bar.set_descriptor(desc)


## An all-inlet-temperature field (feedback off / no fission heating yet).
func _flat_temp_field() -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize(_grid.cell_count())
	t.fill(Feedback.T_REF)
	return t


## Toy heavy-metal split so grid._enrichment_of() reads back `e` as the fissile
## fraction. (M3's depletion will grow this into a real evolving isotopic vector.)
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


## Change the design enrichment and re-solve. Restamps ALL current pebbles (not
## just incoming) so the reactivity response is immediate — a toy design knob, not
## the realistic gradual-refueling propagation (that arrives with M3 recirculation).
func _set_enrichment(e: float) -> void:
	_enrichment = clampf(e, ENRICH_MIN, ENRICH_MAX)
	for id in _pebbles:
		_stamp_enrichment(_pebbles[id], _enrichment)
	_solve_flux()


func _draw() -> void:
	# Silo shell, drawn in the parent's pass so it sits above the background
	# heatmap but below the pebbles.
	for seg in Silo.wall_segments():
		draw_line(seg[0], seg[1], Color(0.9, 0.9, 0.95, 0.9), 3.0)


func _update_hud() -> void:
	var field_name: String = _fields[_current_field]["desc"].name if not _fields.is_empty() else "-"
	var power_str := "%.0f a.u." % _power if _power >= 0.0 else "— (uncontrolled)"

	var status := ""
	if not _feedback_on:
		status = "UNCONTROLLED — no self-limiting"
	elif not _regulated:
		status = "SUBCRITICAL — shutting down"
	elif _feedback_insufficient or _peak_temp >= OVER_TEMP_K:
		status = "OVER-TEMP — Doppler can't hold; needs control rods"
	else:
		status = "SELF-REGULATING"

	_label.text = "PEBBLE BED — M2 Doppler feedback\n" \
		+ "active: %d / %d\n" % [_pebbles.size(), TARGET_POPULATION] \
		+ "injected: %d   discharged: %d\n" % [_total_injected, _total_extracted] \
		+ "enrichment: %.1f%%   ( [ / ] )\n" % (_enrichment * 100.0) \
		+ "feedback: %s   (F)\n" % ("ON" if _feedback_on else "OFF") \
		+ "k-eff: %.4f   %s\n" % [_k_eff, status] \
		+ "  cold / uncontrolled k: %.4f\n" % _k_cold \
		+ "peak fuel temp: %.0f K  (ΔT %.0f)\n" % [_peak_temp, _peak_temp - Feedback.T_REF] \
		+ "power: %s\n" % power_str \
		+ "field: %s   (V)\n" % field_name \
		+ "solve iters: %d   fps: %d" % [_solve_iters, Engine.get_frames_per_second()]
