# tests/live_render_perf.gd
#
# Measures where the frame time goes in the REAL running scene — renderer on.
#
#   godot --path . --script res://tests/live_render_perf.gd        # NOTE: no --headless
#   godot --path . --script res://tests/live_render_perf.gd -- --field=7   # a per-pebble field
#
# WHY THIS EXISTS: "it feels smooth" and "the fps counter says 60" both hide the cost that
# matters — the game is vsync-locked, so a frame that costs 12 ms and one that costs 2 ms
# both read 60 fps, and the difference is the headroom the next feature (or the player's
# OVERFILL_MAX bed) eats. This prints the ENGINE's own per-frame monitors (process time,
# physics-process time, draw calls, objects) as mean / p95 over a steady window, and then
# micro-times each per-frame function of main.gd in isolation so the number that moves
# when something is optimized is the number that says why.
#
# Not a gate — it asserts nothing (timings are machine-dependent). It is the tool for
# "is this faster, and by how much", the same way live_render_capture.gd is the tool for
# "does it look right". Runs headless too (the render columns just read 0), which is
# handy for measuring the pure-CPU cost of the sim side alone.
extends SceneTree

const SETTLE_AT := 12.0      # let the bed seed, solve, and settle before sampling
const SAMPLE_FOR := 20.0     # steady-state window
const BENCH_REPS := 20

var _main
var _t := 0.0
var _samples := {}           # monitor name -> Array[float]
var _reported := false
var _field := -1             # -1 = leave the default (grid flux) field
var _phys_frames_at_start := 0
var _frames := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--field="):
			_field = int(arg.trim_prefix("--field="))
	# Vsync OFF: with it on, the render present blocks inside the process step until the
	# next vblank, so TIME_PROCESS reads "the rest of the frame" whatever the real cost is.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	# The renderer's own timers for the main viewport: CPU = command recording for that
	# viewport, GPU = its measured GPU time. TIME_PROCESS alone cannot separate real work
	# from the windowed present blocking until the display's next refresh (it does, even
	# with vsync "off", under a compositing desktop) — which is why the display refresh
	# rate is printed too: an fps pinned near it is the present, not the CPU.
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	print("[perf] renderer: %s   physics ticks/s: %d   vsync: %d   display: %.0f Hz" % [
		RenderingServer.get_current_rendering_method(),
		Engine.physics_ticks_per_second,
		DisplayServer.window_get_vsync_mode(),
		DisplayServer.screen_get_refresh_rate()])


func _process(delta: float) -> bool:
	_t += delta
	if _t < SETTLE_AT:
		if _field >= 0 and _main._current_field != _field:
			_main._cycle_field()
		return false
	if _t < SETTLE_AT + SAMPLE_FOR:
		if _frames == 0:
			_phys_frames_at_start = Engine.get_physics_frames()
		_frames += 1
		_sample("process ms", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		_sample("render cpu ms", RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
		_sample("render gpu ms", RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
		_sample("phys script ms", _main._perf_physics_ms)
		_sample("physics ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		_sample("fps", Performance.get_monitor(Performance.TIME_FPS))
		_sample("draw calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		_sample("render objects", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		_sample("primitives", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		_sample("active bodies", Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS))
		_sample("collision pairs", Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS))
		_sample("nodes", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		return false
	if not _reported:
		_reported = true
		_report()
		_sections()
		_bench()
		quit(0)
	return false


func _sample(name: String, v: float) -> void:
	if not _samples.has(name):
		_samples[name] = []
	_samples[name].append(v)


func _report() -> void:
	print("[perf] steady window %.0f s, %d frames, field '%s', %d pebbles (%d in core)" % [
		SAMPLE_FOR, _samples["fps"].size(), _main._fields[_main._current_field]["desc"].name,
		_main._pebbles.size(), _main._core_count()])
	# Physics ticks that actually ran vs the 60/s the clock asked for: below ~100% the
	# physics clock is falling behind real time (the engine caps catch-up steps per frame).
	var ticks := Engine.get_physics_frames() - _phys_frames_at_start
	print("  physics ticks: %d in %.0f s = %.0f%% of real time" % [
		ticks, SAMPLE_FOR, 100.0 * ticks / (SAMPLE_FOR * Engine.physics_ticks_per_second)])
	print("  %-16s %10s %10s %10s" % ["monitor", "mean", "p95", "max"])
	for name in _samples:
		var arr: Array = _samples[name].duplicate()
		arr.sort()
		var sum := 0.0
		for v in arr:
			sum += v
		var n := arr.size()
		print("  %-16s %10.2f %10.2f %10.2f" % [name, sum / n, arr[int(0.95 * (n - 1))], arr[n - 1]])


## main.gd's own per-section accounting of the physics step (smoothed ms per tick).
func _sections() -> void:
	print("[perf] physics-step sections (smoothed ms per tick, in situ):")
	var total := 0.0
	for name in _main._perf_sections:
		var v: float = _main._perf_sections[name]
		total += v
		print("  %-16s %8.3f" % [name, v])
	print("  %-16s %8.3f   (step readout %.3f, peak %.3f)" % ["total", total,
		_main._perf_physics_ms, _main._perf_physics_peak_ms])


## Time each per-frame function of main.gd on its own. Each one is either a pure render
## consumer (safe to call again) or a sim step whose extra invocations only nudge state
## the run is about to throw away.
func _bench() -> void:
	print("[perf] per-call cost (mean of %d reps, ms):" % BENCH_REPS)
	_time("_process(1/60) [all render-clock work]", func(): _main._process(1.0 / 60.0))
	_time("_physics.positions()", func(): _main._physics.positions())
	_time("_core_positions()", func(): _main._core_positions())
	_time("_update_hud()", func(): _main._update_hud())
	_time("_update_inspector()", func(): _main._update_inspector())
	_time("_sync_controls_panel()", func(): _main._sync_controls_panel())
	_time("_update_pebble_colors()", func(): _main._update_pebble_colors())
	_time("_refresh_pool()", func(): _main._refresh_pool())
	_time("_inlet_top_clear(0)", func(): _main._inlet_top_clear(0))
	_time("_admit_mouth_clear(0)", func(): _main._admit_mouth_clear(0))
	_time("_lowest_at_inlet(0)", func(): _main._lowest_at_inlet(0))
	_time("_belt_step()", func(): _main._belt_step())
	_time("thermal_step(1/60)", func(): _main._core.thermal_step(_main._pebbles, _main._out_of_core, 1.0 / 60.0))
	_time("deplete(1/60)", func(): _main._core.deplete(_main._pebbles, _main._out_of_core, 1.0 / 60.0))
	var positions: Dictionary = _main._core_positions()
	_time("grid.homogenize()", func(): _main._grid.homogenize(_main._pebbles, positions))
	_time("_solve_flux() [warm]", func(): _main._solve_flux())
	_time("_refresh_field_display()", func(): _main._refresh_field_display())
	# The flux solve itself, warm-started from the cached previous answer as the live loop does.
	_main._grid.homogenize(_main._pebbles, positions)
	var sol = Neutronics.solve(_main._grid, 300, 8, 1.0e-5, null)
	_time("Neutronics.solve [cold start]", func(): Neutronics.solve(_main._grid, 300, 8, 1.0e-5, null))
	_time("Neutronics.solve [warm start]", func(): Neutronics.solve(_main._grid, 300, 8, 1.0e-5, sol))
	# One pebble-field tint pass under a per-pebble field, whatever field is current.
	var saved: int = _main._current_field
	while _main._fields[_main._current_field]["desc"].world != FieldDescriptor.PEBBLE:
		_main._cycle_field()
	_time("_update_pebble_colors() [pebble field]", func(): _main._update_pebble_colors())
	while _main._current_field != saved:
		_main._cycle_field()


func _time(label: String, f: Callable) -> void:
	var t0 := Time.get_ticks_usec()
	for _i in BENCH_REPS:
		f.call()
	var dt := (Time.get_ticks_usec() - t0) / 1000.0 / BENCH_REPS
	print("  %-40s %8.3f" % [label, dt])
