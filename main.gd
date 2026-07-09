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
var _k_eff := 0.0
var _power := 0.0        # relative fission power (a.u.); becomes real MW at M4
var _solve_iters := 0
var _solved_once := false

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
	# the steady-state diffusion eigenproblem, then push results outward only.
	var positions := _physics.positions()
	if positions.is_empty():
		return
	_grid.homogenize(_pebbles, positions)
	var sol := Neutronics.solve(_grid)
	_k_eff = sol.k_eff
	_power = sol.fission_rate
	_solve_iters = sol.iterations

	# Update the heatmap (consumer of sim state; never writes back).
	_field_display.set_grid_field(_grid, sol.flux, _flux_desc)
	if not _solved_once:
		_color_bar.set_descriptor(_flux_desc)
		_solved_once = true

	# Sample the flux back onto each pebble — read-only at M1, the input M3 will
	# turn into a per-pebble burnup rate.
	for id in positions:
		var peb: Pebble = _pebbles.get(id)
		if peb != null:
			peb.local_flux = _grid.sample(sol.flux, positions[id])


func _draw() -> void:
	# Silo shell, drawn in the parent's pass so it sits above the background
	# heatmap but below the pebbles.
	for seg in Silo.wall_segments():
		draw_line(seg[0], seg[1], Color(0.9, 0.9, 0.95, 0.9), 3.0)


func _update_hud() -> void:
	var crit := "subcritical" if _k_eff < 1.0 else "supercritical"
	_label.text = "PEBBLE BED — M1 neutronics\n" \
		+ "active: %d / %d\n" % [_pebbles.size(), TARGET_POPULATION] \
		+ "injected: %d   discharged: %d\n" % [_total_injected, _total_extracted] \
		+ "k-eff: %.4f  (%s)\n" % [_k_eff, crit] \
		+ "power: %.1f a.u.\n" % _power \
		+ "solve iters: %d\n" % _solve_iters \
		+ "fps: %d" % Engine.get_frames_per_second()
