# main.gd
#
# M0 orchestrator: inject pebbles at the top, let them flow through the silo,
# extract them at the bottom, and keep a per-pebble sim/Pebble bound to each
# body by id. This is the skeleton of the two-world coupling loop (CLAUDE.md):
# for now only the mechanical world runs; homogenization + neutronics plug in
# here at M1, reading positions() and the Pebble registry.
extends Node2D

const TARGET_POPULATION := 380  # keep the silo full enough to show bed flow
const SPAWN_PER_TICK := 3
const SPAWN_INTERVAL := 0.12    # seconds between injection ticks
const PEBBLE_RADIUS := 8.0
const EXTRACT_INTERVAL := 0.30  # metered discharge cadence (lowest pebble out)

var _physics: PhysicsBackend
var _pebbles: Dictionary = {}   # id -> Pebble (the Lagrangian registry)
var _rng := RandomNumberGenerator.new()
var _next_id := 0
var _spawn_accum := 0.0
var _extract_accum := 0.0

# M0 readouts
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

	_build_hud()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(12, 10)
	_label.add_theme_font_size_override("font_size", 16)
	layer.add_child(_label)


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


func _update_hud() -> void:
	_label.text = "PEBBLE BED — M0 granular flow\n" \
		+ "active: %d / %d\n" % [_pebbles.size(), TARGET_POPULATION] \
		+ "injected: %d   discharged: %d\n" % [_total_injected, _total_extracted] \
		+ "fps: %d" % Engine.get_frames_per_second()
