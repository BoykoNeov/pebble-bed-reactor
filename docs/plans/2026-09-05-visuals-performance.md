# Visuals & performance — what was done, what is left, and how to do it

Status as of 2026-09-05. Part 1 is the work that landed in the commit this file ships
with. Part 2 is a step-by-step plan for the rest, written so it can be executed by
someone (or a smaller model) who has not read the codebase: every step names the exact
file, the exact function, how to measure before/after, and which gate must stay green.

Read `CLAUDE.md` first, in particular: the three clocks (never run everything on one
`delta`), "visualization is a pure consumer of sim state", and the testing rule that
anything touching a calibrated number gets **re-gated, never re-tuned silently**.

## The measuring tools (use them for every step below)

- **`tests/live_render_perf.gd`** — run with a window (NOT `--headless`):
  `godot --path . --script res://tests/live_render_perf.gd`. Runs the real scene 32 s,
  prints (a) engine monitors over a 20 s steady window, (b) main.gd's own per-section
  timing of the physics step, (c) a per-call micro-benchmark of every per-frame function.
  Add `-- --field=7` to measure under a per-pebble field (burnup). Takes ~40 s.
  How to read it: `render cpu/gpu ms` are the renderer's own timers for the main
  viewport; `phys script ms` is the script cost of one physics tick (from the HUD's
  readout); `process ms` INCLUDES the windowed present's wait for the display's next
  refresh, so on its own it cannot tell work from waiting. Ignore `physics ms` — in
  Godot 4.7 that monitor does not read as a per-frame wall time.
- **`tests/live_render_capture.gd`** — saves PNG frames of the running scene to
  `user://shots/` (on Windows: `%APPDATA%\Godot\app_userdata\Pebble Bed\shots\`). A
  green headless suite proves nothing about pixels (project memory); look at the PNGs.
- **`tests/run_tests.sh`** (pure gates, ~5 min) and `tests/run_tests.sh --live` (the
  curated live set, ~8 min). Live suites are real-time-locked: run them ONE AT A TIME,
  never two Godot instances at once.
- The HUD's `perf` row now shows `physics step X ms (peak Y)`: the smoothed / decaying-peak
  script cost of a physics tick. Watch it while playing; it is the number that has to
  stay under ~6 ms for the game to hold a 144 Hz display.

## Part 1 — landed (measured on an RTX 5090 / 144 Hz display, 428 pebbles)

| metric | before | after |
|---|---|---|
| draw calls per frame | 2,750 | 183 |
| primitives per frame | 149,500 | 9,150 |
| renderer CPU per frame | (not separable) | 0.6 ms |
| neutronics cadence frame (`_solve_flux`) | 15.5 ms every 0.2 s | 5.5 ms, + ≤1.6 ms on each of the next 3 ticks |
| single warm flux solve | 2.8 ms | 1.6 ms |
| render-clock script (`_process`) | ~1.4 ms/frame | 0.2 ms/frame |
| sim script per physics tick (in situ, smoothed) | ~5 ms | 2.4 ms (solve 0.53, diagnostics 0.71, thermal 0.69, deplete 0.40, belts+fuel machine 0.10) |
| uncapped fps (vsync off) | 85 | 109 (physics ticks at 100% of real time) |

What changed, and why:

1. **Pebbles are one batched quad each** (`game/pebble_body/pebble_body.gd`). Each body
   used to paint 3 `draw_circle` + 1 `draw_arc` — polygons the 2D renderer cannot batch
   across bodies. Now each body has a child `Sprite2D` sharing one texture and one
   `ShaderMaterial`; the shader draws an anti-aliased sphere-shaded disc from the UV
   (light fixed in screen space so the highlight does not spin; a faint mark that rotates
   with the body so rolling is visible). Tint = `self_modulate`, so per-pebble fields
   colour exactly as before. Zero per-frame script.
2. **Physics interpolation ON** (`project.godot`, `physics/common/physics_interpolation`).
   Bodies are rendered interpolated between 60 Hz ticks: smooth motion on a 144 Hz display.
   The sim is untouched (scripts read the physics transform).
3. **Diagnostic solves deferred** (`sim/reactor.gd`, `ReactorCore.defer_diagnostics`,
   `run_deferred_diagnostic`). A cadence used to run 3–4 eigen-solves in one physics frame
   (warm + cold + no-xenon (+ no-rod)) — a 15 ms hitch 5×/s. Now the cadence frame runs
   only the physics-driving warm solve; k_cold / xenon worth / rod worth follow one per
   tick over the next ≤3 ticks, against the same homogenized grid. OFF by default in
   `ReactorCore` so every headless gate still reads all numbers fresh from one `solve()`;
   `main.gd` turns it on. `_toggle_scram` / `_toggle_feedback` pass `immediate=true` so
   those still register every readout on the same frame (tests/live_scram.gd and
   live_xenon.gd check exactly that).
4. **Diffusion stencils built once per cadence** (`Neutronics.build_stencils`, the new
   `stencils` argument of `Neutronics.solve`). They depend on packing only, so all solves
   of one cadence share them; the build itself no longer allocates a Dictionary per face.
   Bit-identical results.
5. **Render-clock waste removed** (`main.gd::_process`): the two BBCode panels rebuild at
   10 Hz instead of 60 (a click still refreshes the inspector at once); the per-pebble
   tint walk runs at 20 Hz; the plant (`FuelLoop.set_pool`) only redraws when a caption
   count actually changed — it had been redrawing every pipe every frame; the field
   heatmap updates its GPU texture in place.
6. **Always-on perf readout**: a `perf` row at the bottom of the HUD (the inspector panel
   moved down one row to make room), and `tests/live_render_perf.gd`.

Verification: pure suite green (7/7 — one run reported `test_thermal.gd (127)` while a
second Godot instance was running; alone it exits 0 with 55 PASS, so a 127 is a
rerun-before-believing artifact); live set (`--live`) run one suite at a time — see the
commit message for the exact results.

## Part 2 — remaining work, in priority order

Where the remaining frame goes (measured alone, vsync off, 428 pebbles): the renderer is
0.35 ms CPU / 0.03 ms GPU; the sim script is ~2.4 ms per 60 Hz tick (~1.5 ms per frame
at 109 fps); yet a frame takes ~9 ms. The unaccounted ~5 ms is the engine's own 2D
physics step (428 always-awake bodies, ~1,350 collision pairs; `TIME_PHYSICS_PROCESS`
cannot measure it in 4.7 — it reads 26 ms) plus the windowed present. So the biggest
single lever is **P2.1.e (let the settled bed sleep)** — do it FIRST and re-measure;
P2.1.a–d trim the script side and are worth ~1 ms/tick together. P2.2 is visual
polish. P2.3 is bigger, optional architecture.

### P2.1 Physics-tick script cost

Measure first: run `live_render_perf.gd`, read the "physics-step sections" table
(`belts`, `fuel machine`, `solve`, `diagnostics`, `thermal`, `deplete`). Do the items in
the order of that table's biggest numbers; the order below is the expected one.

**P2.1.a Deplete every 4th tick with 4× the campaign step.**
- Where: `sim/reactor.gd::deplete`. Today it walks all in-core pebbles every physics
  tick (~0.7 ms). `Depletion.step` uses closed-form exponentials per isotope and
  backward Euler for xenon (see the header of `sim/depletion.gd`), so it is stable for
  any step; only the U-238→Pu-239→burn chain is integrated across steps, and at
  4 × (1/60 s × campaign rate) the step is still tiny.
- How: add `var deplete_every := 1` and an accumulator `_deplete_dt := 0.0` to
  `ReactorCore`; in `deplete()` add `physics_dt` to the accumulator and a tick counter;
  only when the counter reaches `deplete_every` run the existing loop with the
  accumulated dt (then zero both). Default 1 (tests unchanged); `main.gd` sets 4 next to
  where it sets `defer_diagnostics`.
- Gate: `tests/test_reactor.gd` and `test_depletion.gd` unchanged and green; run
  `tests/live_long_session.gd` alone (10 min, real-time) and compare its printed
  second-half mean burnup / k_cold to a run before the change — they must agree within
  the run-to-run noise it already prints. If they drift, do NOT retune; reduce to 2.
- Expect: ~0.5 ms/tick saved.

**P2.1.b Thermal step at 30 Hz (every 2nd tick, 2× dt).**
- Where: `sim/reactor.gd::thermal_step`. Backward-Euler pebble temperature
  (`Thermal.step_pebble_temp`), exact-exponential power (`Thermal.step_power`),
  backward-Euler decay reservoirs: all unconditionally stable. Pebble time constants are
  tens of seconds; the fastest thing here is the post-scram power e-fold (~0.7 s), still
  40 steps at 30 Hz.
- How: same accumulator pattern as P2.1.a (`thermal_every`, default 1, main sets 2).
  Keep `thermal_step`'s readouts (peak/mean temp, extracted power) as they are — they
  are just refreshed at 30 Hz.
- Gate: THIS ONE TOUCHES CALIBRATED DYNAMICS. Run `tests/run_tests.sh --live` (all five)
  before and after; every printed number they gate (settling temperature, scram decay,
  rod worth match, xenon pit peak) must stay inside the existing tolerances. If
  `live_m4.gd`'s overshoot/settle numbers move, stop and report — do not loosen a gate.
- Expect: ~0.5 ms/tick saved.

**P2.1.c Fuel-machine helpers should fetch positions once.**
- Where: `main.gd::_admit_batch` calls, per lane, `_lowest_at_inlet(lane)` and
  `_admit_mouth_clear(lane)`; `_feed_inlet_top` calls `_inlet_top_clear(lane)` per lane.
  Each of those calls `_physics.positions()`, which builds a fresh 428-entry Dictionary
  (0.2 ms) — so an admit tick costs ~1.5 ms and a fill at 15/s spends ~25 ms/s here.
- How: give each helper an optional `positions: Dictionary = {}` parameter; when empty,
  fetch as today (keeps every existing caller and test valid); in `_admit_batch` and
  `_feed_inlet_top` fetch once at the top and pass it down. Note `_admit_batch` removes
  and respawns a body inside the loop — the cached dictionary is then stale for that one
  id only, which the next lane's mouth check should treat as "occupied": after a spawn,
  write the new position into the cached dictionary before continuing.
- Gate: `tests/live_inlet_fill.gd`, `live_inlet_max_radius.gd`, `live_fill_escape.gd`
  (each alone).
- Expect: only matters during fills / restarts, but those are exactly the moments the
  player watches.

**P2.1.d `positions()` itself.** `GodotPhysicsBackend.positions()` rebuilds a Dictionary
from every `PebbleBody.position` on every call (0.2 ms). Options, cheapest first:
cache it per physics tick (a `_positions_tick` stamp compared against
`Engine.get_physics_frames()`; invalidate on spawn/remove) — every caller inside one
tick then shares one build. Gate: `tests/test_silo.gd` and any live suite; behaviour
must be identical because positions only change when the engine steps.

**P2.1.e Let the settled bed sleep — DO THIS FIRST.** All ~428 bodies are always
active (`active bodies` in the harness) with ~1,350 collision pairs re-solved every
tick. The engine's own step is the largest unaccounted slice of the frame (see the
Part 2 intro), and sleeping bodies also stop the residual jitter of a packed bed
(CLAUDE.md pitfall: "granular stacking can be jittery"). Measure it honestly first:
in `live_render_perf.gd`, time one engine tick by subtracting the script cost from
the wall time between two consecutive `_physics_process` entries (add a
`Time.get_ticks_usec()` stamp at the top of `main._physics_process` and print the
gap minus `_perf_physics_ms`), or simply compare `fps` before/after. Then raise
`physics/2d/sleep_threshold_linear` (default 2 px/s) to ~6 and
`physics/2d/time_before_sleep` to ~1 s in `project.godot`, then VERIFY the one thing
that can go wrong: when `_extract_lowest` removes the lowest body, the pebbles resting
on it must wake and fall. Run `tests/live_render_capture.gd` and look at the bed above
the outlet; run `live_long_session.gd` and confirm the discharge count over 10 min is
unchanged. If pebbles hang in the air after a removal, wake the neighbours explicitly
in `GodotPhysicsBackend.remove_pebble` (query the removed body's contacts before
freeing it and call `sleeping = false` on each) — or drop the idea.

### P2.2 Visual polish (each is small and independent)

**P2.2.a Look at the new pebble shader on screen.** Run `live_render_capture.gd`, open
`field_5.png` and `spent_bin_1.png`. Check: the discs are round and anti-aliased; the
highlight is up-left on every pebble regardless of rotation; the field tints (switch to
field 7 = burnup with `-- --field=7` in the perf harness, or press V in the game) read
clearly — if the shading fights the colour, raise the ambient term (`0.55`) in
`BALL_SHADER` in `game/pebble_body/pebble_body.gd`; the rolling mark (`0.12`) should be
barely visible on a still frame and obvious in motion.

**P2.2.b Heatmap and vessel.** `game/visualization/field_display.gd` draws the coarse
9×16 grid texture with bilinear filtering — honest for a coarse model, but the vessel's
funnel is a straight-edged polygon over it. Options: draw the field only inside
`Silo.inner_profile()` (it already does) and add a 2–3 px soft inner shadow along the
liner (`main.gd::_draw`, `WALL_LINER`) so the bed reads as sitting inside a vessel.
Purely `_draw` code, no sim contact.

**P2.2.c Selection ring.** `main.gd::_draw_selection` — with interpolation on, the ring
reads `positions()` (the physics transform) while the sprite is drawn interpolated, so
the ring can trail a moving pebble by up to one tick (~1–2 px). If visible, read
`body.get_global_transform_interpolated().origin` through a new backend method
`get_render_position(id)` instead. Cosmetic.

**P2.2.d HUD.** The readout is one large BBCode panel. A quick legibility win is a
fixed-width number font for the readout only (`add_theme_font_override` with a
monospace `SystemFont`), so values stop jumping as digits change. No logic.

### P2.3 Bigger, optional

**P2.3.a Flux solve on a worker thread.** The solve is pure (reads `grid` arrays, writes
`Solution`s). Design: in `_solve_flux`, homogenize on the main thread as now, then hand
the grid's arrays (duplicated) to a `Thread`/`WorkerThreadPool` task that runs the warm
solve and the diagnostics; on the next cadence (or when done) apply results and
sample back on the main thread. Everything the HUD reads is already a duplicate. Risks:
GDScript `RefCounted` objects across threads, and the one-frame staleness of `k_eff`
seen by `thermal_step` (harmless — CLAUDE.md already accepts a stale k between
cadences). Only worth it if P2.1 does not get the tick under ~4 ms. Gate: whole live set.

**P2.3.b Solver in C#.** CLAUDE.md allows moving *only the solver* out of GDScript once
profiling shows it — it now does (1.6 ms warm / 28 ms cold for a 144-cell grid is pure
interpreter overhead). It changes the distribution (needs the .NET Godot build) so treat
as a decision for the owner, not a default.

**P2.3.c Renderer method.** `project.godot` uses Forward+; for a 2D game `mobile` or
`gl_compatibility` has lower fixed per-frame cost. Try each, run `live_render_perf.gd`,
keep the one with the lowest `render cpu ms` if the frames look identical in
`live_render_capture.gd`. One-line change, fully reversible.
