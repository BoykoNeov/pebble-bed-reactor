# CLAUDE.md — 2D Pebble Bed Reactor Toy Simulator

## Project overview

A 2D, real-time, **toy** pebble bed reactor (PBR) simulator built in Godot. The
player changes the design of incoming pebbles (size, fuel loading, enrichment)
and reactor operating parameters, then watches how the core responds and
inspects the composition of pebbles flowing out the bottom.

This is an **educational, qualitative** simulator. The goal is to reproduce the
correct reactor *behaviors and trends* — not benchmark-accurate numbers. It is a
civilian power-reactor teaching toy; keep everything LEU and realistic.

## Core mental model — the two worlds

The single most important architectural idea. The simulation lives at the
boundary between two representations and translates between them every step:

- **Per-pebble world (Lagrangian):** each pebble is a discrete object with a
  position, size, temperature, burnup, and isotopic vector. This is what Box2D /
  the physics engine gives us.
- **Continuum-field world (Eulerian):** the neutron flux, cross-sections, and
  power density live on a coarse grid over the core. This is what the neutronics
  solver operates on.

The coupling loop:

```
Box2D positions + per-pebble state
        │  (homogenize)
        ▼
Coarse grid: macroscopic cross-sections per cell
        │  (diffusion solve, power iteration)
        ▼
Flux field φ  +  k-effective
        │  (map flux back onto pebbles)
        ▼
Per-pebble local power + burnup rate
        │  (slow campaign clock: deplete isotopics)
        ▼
Pebbles age → back to Box2D
```

Pebble *size, fuel loading, and enrichment* enter the physics precisely at the
homogenization step (they change packing, moderation ratio, and cross-sections).
That is the causal chain that makes the player's design choices matter.

## Critical design principles — do not violate these

1. **Timescale decoupling (most important).** There are three clocks running at
   wildly different rates:
   - *Physics clock* — Box2D / mechanical step, real-time-ish.
   - *Campaign (burnup) clock* — accelerated; compresses months into minutes.
   - *Flux solve — clockless.* The neutron flux equilibrates essentially
     instantly relative to anything mechanical, so it is always solved at steady
     state, never time-integrated.
   Never run all subsystems on a single `delta`. Time acceleration for burnup
   must NOT accelerate the physics step or the flux solve.

2. **Quasi-static neutronics.** Solve the steady-state diffusion problem fresh
   each step (or every N steps) and get k-effective via power iteration. Do not
   time-march the flux.

3. **Parameterized cross-sections, not nuclear data libraries.** Express
   k-infinity (and the few-group cross-sections) as smooth functions of
   enrichment, moderation ratio, fuel temperature, and burnup with plausible
   functional forms. No ENDF / real data libraries — that is out of scope for a
   toy and unnecessary to get correct behavior.

4. **Qualitative, not quantitative.** Target correct signs, trends, and
   feedback directions. Do not chase accurate MWd/kgHM or exact k-eff digits.

5. **Engine-agnostic simulation core.** The neutronics, depletion, thermal, and
   feedback logic must not depend on Godot or on the specific physics engine.
   The physics backend is behind an interface and is swappable.

## Tech stack & key decisions

- **Engine:** Godot 4.x.
- **Physics backend:** Godot 4 ships its own 2D physics engine. *Start with the
  built-in 2D physics* for the granular flow — it comfortably handles the
  hundreds-to-few-thousand circles we need in a silo. Using *actual* Box2D
  requires a GDExtension; the main one (`appsinacup/godot-box2d`) wraps Box2D
  v2.4.1, is flagged unmaintained, and lacks cross-platform determinism, while
  the box2d.org docs are for Box2D **v3** (a version mismatch). **Decision:**
  keep the physics backend behind an abstraction and start with Godot's built-in
  physics; only revisit Box2D / Jolt / Rapier if flow quality or determinism
  demands it.
- **Language:** GDScript for glue, nodes, and UI. Keep the diffusion solver and
  depletion as pure, testable functions; if profiling shows the solver is a
  bottleneck, move *only that* to C# or a GDExtension. Do not optimize
  prematurely.
- **Scale:** Real HTR-PM cores have ~420,000 pebbles. Use hundreds to a few
  thousand. This is a 2D slice / silo abstraction of a 3D cylinder — that's fine.

## Suggested module layout

Keep the pure simulation core separate from Godot so it is unit-testable.

```
sim/                     # engine-agnostic, deterministic, testable
  pebble.gd              # id, radius, isotopics vector, burnup, temp, pass count
  grid.gd                # coarse mesh + homogenization of pebbles → cells
  neutronics.gd          # diffusion solve, power iteration, k-eff, flux field
  depletion.gd           # per-pebble burnup / simplified Bateman chain
  feedback.gd            # Doppler / temperature coefficients → cross-sections
  thermal.gd             # (M4) heat source, pebble temp, coolant transport, exchanger
  clocks.gd              # the three-clock manager
game/                    # Godot nodes
  reactor_vessel/        # silo geometry, pebble spawn (top) + extract (bottom)
  pebble_body/           # RigidBody2D wrapper, syncs to a sim.pebble
  visualization/         # switchable field heatmaps (grid + per-pebble), colorbar, readouts
  controls/              # player-tunable pebble design + operating params
main.gd                  # orchestrates the coupling loop
```

## Physics reference — approximate, HTR-PM-flavored

For plausible defaults only. Do not treat as accurate.

- Pebble diameter ~6 cm (fuel zone ~5 cm + ~5 mm graphite outer shell).
- ~7 g heavy metal per pebble; ~11,000–15,000 TRISO particles per pebble.
- Enrichment ~8.5% (LEU). Keep player-adjustable enrichment **< 20%**.
- Random monodisperse sphere packing fraction ≈ 0.61. Note: changing all
  pebbles' size *uniformly* does NOT change packing fraction; *mixing* sizes
  does. Uniform size change instead affects surface-to-volume and self-shielding.
- Discharge burnup ~90–100 MWd/kgHM.
- Multi-pass fuel cycling (~6–15 passes) before a pebble is discharged.
- Graphite moderator; helium coolant.
- Minimal isotopic vector to track per pebble: U-235, U-238, Pu-239 (optionally
  Pu-240 / Pu-241), one lumped fission-product poison, and optionally Xe-135 /
  Sm-149 for transient poisoning.

## Roadmap / milestones — build in this order

- **M0 — Granular flow.** Silo, falling circles, extraction at the bottom,
  injection at the top, per-pebble state attached. This looks *done* almost
  immediately — do not be fooled (see Pitfalls).
- **M1 — Neutronics MVP.** Coarse grid, one-group diffusion, power iteration →
  k-eff, flux heatmap overlay (build it via the generic field-display system so
  later fields plug in — see Field visualization), power readout. Compelling on
  its own.
- **M2 — Feedback.** Negative fuel-temperature (Doppler) coefficient so the
  reactor self-regulates. This is the "it's alive" moment.
- **M3 — Burnup & outflow.** Per-pebble burnup from local flux, isotopic
  depletion, outflow composition readout, recirculate-vs-discharge decision.
- **M4 — Thermal & cooling.** Heat production, coolant flow, and heat exchange,
  built on a real energy balance that closes the feedback loop M2 stubs out.
  Depends on M1 (flux→power) and M2 (feedback). See the dedicated section below —
  **not a day-one build.**
- **M5+ — Stretch.** Two-group diffusion; xenon transient; control (rods /
  coolant flow / scram); decay-heat / loss-of-flow passive-safety demo; a
  demonstrable under- vs over-moderation instability. *(All of these now exist:
  coolant flow M4a, scram M5a, two-group + moderation instability M5b, xenon M5c,
  control rods M5d — see the control-rod note below.)*

> **M5d — control rods live in the SIDE REFLECTOR, and their worth is emergent.**
> Two decisions worth not re-litigating. **(1) Placement.** Rods are in the reflector
> columns against the vessel wall, never in the bed — you cannot drive a rod into a
> packed pebble bed without crushing pebbles, which is why real HTR-PMs use borings in
> the side reflector. This also means the rods touch the Lagrangian/pebble world not at
> all: they are pure Eulerian grid state. It is not a compromise, either — the reflector
> is where the THERMAL flux peaks in the two-group model (measured: 37.4 in the rod
> column vs 33.5 in the best fuel column), so a thermal absorber parked there is a
> strong rod. That is *why* reflector rods work in a PBR, and one-group M1 could not
> have shown it. **(2) Emergent worth.** A rod adds real thermal absorption
> (`ROD_SIGMA_A2` on `sigma_a2`) and everything else falls out of the eigenvalue solve —
> nothing names a "rod worth". The S-shaped integral worth curve is a *consequence* of
> the flux profile the rod tip travels through (differential worth peaks at tip row 10.4;
> the thermal flux peaks at row 10), not a shape anyone coded. Worth is measured for the
> HUD the same way xenon's is: re-solve with the rods stripped and difference.
> **Calibration-neutral at zero insertion** — a withdrawn rod adds *exactly* nothing, so
> every pre-M5d calibration is untouched bit-for-bit (gated by `test_control_rods.gd`).
> **Scram is deliberately NOT unified with the rods**: `Thermal.SCRAM_WORTH` remains an
> independent lumped kinetics term with its own calibration and gate. Unifying them
> ("scram = slam the rods in") is a real, user-facing calibration change, not a side
> effect — leave it opt-in. See `sim/control_rods.gd`.

## Validation targets — "is it actually working"

The sim should be able to demonstrate these behaviors:

- Negative fuel-temperature coefficient → passive self-regulation / stability.
- Online refueling → roughly flat reactivity over time (vs. a batch sawtooth).
- Burnup gradient down the bed.
- Flux peaking near the reflector, depression toward the center.
- Under- vs over-moderation flips the sign of the moderator coefficient — a
  player should be able to accidentally build an unstable core and see why.
- Xenon poisoning transient (if implemented).
- Control rods hold a core Doppler alone cannot: a fresh, over-reactive LEU core
  saturates the Doppler feedback (over-temp / `feedback_insufficient`), and
  inserting rods restores a critical equilibrium at a sane temperature — with rod
  worth following the classic S-curve in insertion depth.
  *Scope, deliberately: this rescue is verified QUASI-STATICALLY, through
  `Feedback.solve_equilibrium` (the M2 critical-power search, which is NOT wired
  into the live loop — the game runs dynamic point-kinetics). So what is proven is
  that a critical equilibrium EXISTS at 40–45% insertion, not that the live loop
  settles there. Dynamic settling is inferred, not measured: the rod-trimmed core
  sits at k_cold ~1.007 / peak ~543 K — cooler and lower power than the nominal
  operating point whose dynamic stability IS verified (~1100 K), and this project's
  limit-cycle failures were all HIGH-power_frac ones, so a rod-trimmed core is
  further inside the safe regime, not nearer the edge. Treat as plausible, not
  confirmed. The live loop's rod wiring is separately proven end-to-end by
  `tests/live_rods.gd` (k_cold drop = reported worth; full insertion shuts the
  running scene down; withdrawal restarts it).*

## Thermal & cooling model — planned extension (M4)

**Not part of the day-one build.** Add this only after M1 (flux→power) and M2
(feedback) exist, because it reuses both. When it lands it upgrades the
placeholder temperature used for feedback into a real energy balance and turns
the reactor into a genuinely self-regulating thermal system with its own
dynamics.

### Why it couples cleanly

The heat source is already computed. The same flux→pebble map that drives burnup
(M1/M3) gives each pebble its local fission power — that *is* the heat-generation
term. Thermal needs no new neutronics; it layers an energy balance on top of the
power we already have.

### What to model (toy scope)

- **Heat source:** per-pebble fission power from the flux map. Optionally add
  decay heat (a fraction that persists after fission stops — basis of the
  passive-safety demo).
- **Pebble temperature:** lumped single-node temperature per pebble (intra-pebble
  centerline-vs-surface profile can wait). Its heat capacity gives thermal
  *inertia* — the source of lag and transients. This lumped temperature is what
  feeds Doppler feedback.
- **Pebble → coolant heat transfer:** Newton cooling,
  `q = h · A · (T_pebble − T_coolant)`, with the transfer coefficient `h`
  parameterized by coolant mass flow rate. Do NOT implement real packed-bed
  Nusselt correlations for the toy — fit a plausible curve.
- **Coolant transport:** helium gains enthalpy as it flows through the bed;
  coolant temperature rises downstream via a per-cell energy balance
  (`ṁ · cp · ΔT = heat picked up`). Pick a flow direction (e.g. top-down,
  co-current with the pebbles) and document it.
- **Heat exchanger (loop closure):** a lumped secondary side removes heat from
  the hot outlet with some effectiveness and returns cold helium to the inlet,
  closing the coolant loop. Extracted thermal power is the headline "reactor
  power" / electrical-output proxy the player watches.

### The feedback loop it closes

M2 introduces the negative fuel-temperature (Doppler) coefficient using a
*placeholder* temperature (e.g. instantaneously proportional to local power). The
thermal model replaces that placeholder with a real, time-lagged energy balance,
giving the honest loop:

```
power → heat → pebble temperature (with inertia) → Doppler reactivity → power
```

The reactor now responds with genuine dynamics — thermal lag, overshoot,
settling — instead of instant regulation.

> **M5b correction — the moderator coefficient is driven by pebble/graphite
> temperature, not coolant temperature.** This section originally said "coolant
> temperature similarly feeds the moderator temperature coefficient." That is
> physically weak for a *gas-cooled* pebble bed: helium moderates negligibly, and
> the graphite moderator actually sits **inside the pebble at pebble temperature**.
> So the implemented moderator-temperature coefficient (MTC) rides `grid.temperature`
> (the pebble/fuel field — the same driver Doppler reads), giving both the correct
> physics and a driver strong enough (~hundreds of K of pebble swing vs ~tens of K
> of coolant bed rise) to make an over-moderated core visibly destabilize. See
> `sim/feedback.gd` (`moderator_m_eff`) and `sim/thermal.gd` (`apply_field_moderator`).

### Where it sits in the clock model

Thermal is the one field that genuinely needs *time integration on the fast
(physics) clock* — unlike the flux (clockless / quasi-static) and unlike burnup
(campaign clock). Pebble thermal time constants are ~tens of seconds; coolant
transit is seconds. So:

- **At normal speed:** integrate the thermal ODEs on the physics clock to show
  transients.
- **When the campaign (burnup) clock is fast-forwarded:** thermal transients
  become sub-step — collapse thermal to quasi-steady (solve the steady energy
  balance) rather than trying to resolve second-scale dynamics inside a
  month-per-frame step.

### New player controls

- **Coolant mass flow rate** — the primary operating lever. Lower flow → hotter
  pebbles → stronger negative Doppler → power self-limits and outlet runs hotter;
  higher flow → cooler, more reactive.
- Inlet temperature; secondary-side demand (for load-following).

### New behaviors it unlocks (validation targets)

- **Loss-of-flow transient:** cut coolant flow, watch temperature rise drive
  Doppler and passively shut the reactor down — the defining PBR "walk-away safe"
  story.
- Thermal lag and power overshoot during transients.
- **Load following:** change secondary demand and watch the coolant loop and
  reactivity re-settle.
- **Decay heat after scram** (stretch): fission stops but heat continues, and
  passive feedback keeps the core bounded.

### Stretch within thermal

Intra-pebble radial temperature profile; bed pressure drop (Ergun) tying flow
rate to pumping cost; thermal radiation; realistic packed-bed heat-transfer
correlations.

## Field visualization / heatmaps

The player can display any tracked field as a heatmap and switch between them
(neutron flux, power/heat, coolant temperature, burnup, xenon, pebble
temperature, pass count, …). Build this as one generic, field-agnostic system —
not a bespoke renderer per parameter — from M1 onward, so each new field plugs in
as it comes online (flux at M1, burnup/isotopics at M3, heat/coolant temp at M4,
xenon at M5).

### Two render modes — one per world

The fields split along the same Lagrangian/Eulerian line as the rest of the sim,
and each mode is the honest representation for its world:

- **Grid field (Eulerian):** flux, power density, coolant temperature,
  cross-sections. Render the coarse grid as a small texture and scale it up with
  interpolation. Cheap.
- **Per-pebble (Lagrangian):** burnup, pebble/fuel temperature, Xe-135 (and other
  isotopics), pass count, enrichment. Color each pebble circle by its scalar
  (per-instance modulate / shader color). This lets you literally watch one
  burned or hot pebble travel down the bed — directly serving the "see the
  composition of outflowing pebbles" goal.

Reuse the existing homogenization (`grid.gd`) to convert between modes: bin
per-pebble values onto the grid for a smooth field view of a Lagrangian quantity,
or sample a grid field at a pebble's position. The two modes also compose — e.g.
flux as a background field with pebbles colored by burnup on top — showing both
worlds at once.

### Field registry

Each displayable field declares: name + units, world (grid vs per-pebble), value
range + normalization, scale (linear/log), and colormap. The UI selector is
generated from the registry; adding a field is a registration, not new render
code.

### Rules that keep it readable

- **Perceptually-uniform, colorblind-safe colormaps** (viridis / inferno /
  magma). Avoid rainbow/jet — it invents false gradients and fails for colorblind
  users. Sequential map for magnitudes; diverging map for signed quantities
  (e.g. reactivity/feedback contribution, deviation from critical).
- **Always show a colorbar/legend with units.** A heatmap without a scale is
  unreadable.
- **Stable normalization by default.** Auto-ranging every frame makes transients
  impossible to compare because the scale keeps moving — prefer a fixed or
  slowly-adapting range with the legend visible. Use a log scale for flux (spans
  orders of magnitude).

### Decoupling

Visualization is a pure *consumer* of sim state — it never writes back. Render it
on the render clock, sampling the latest sim state; it may lag the sim without any
correctness impact and must never sit on the sim's critical path. This keeps the
engine-agnostic sim core clean.

## Known pitfalls / gotchas

- **The granular flow lulls you.** It looks finished in a weekend. The
  homogenization + coupling translation between the two worlds is where nearly
  all the subtlety and debugging time actually lives. Design it carefully first.
- **Do not run everything on one clock.** See principle 1.
- **Granular stacking can be jittery/spongy.** Raise solver iterations and
  accept slow quasi-static settling; don't chase perfect rigid packing.
- **Diffusion needs proper boundary conditions** (vacuum / albedo at the
  reflector). An unstable solve can produce garbage or negative flux — validate
  and clamp.
- **Keep enrichment LEU and realistic.** This is a civilian teaching toy.

## Conventions

- Sim core: pure functions where possible, deterministic given inputs,
  unit-testable without launching Godot.
- Physics backend behind an interface so it stays swappable.
- Comment the *why* (the physics reasoning), not the *what*.
- Clarity over premature optimization; profile before moving anything to
  C# / GDExtension.

## Glossary

- **k-effective (k-eff):** neutron multiplication factor including leakage;
  =1 critical, <1 subcritical, >1 supercritical.
- **k-infinity (k∞):** multiplication factor for an infinite medium (no leakage).
- **Moderation:** slowing neutrons (via graphite) to increase fission
  probability. Under-moderated vs over-moderated changes feedback sign.
- **Doppler broadening / temperature coefficient:** as fuel heats, resonance
  absorption broadens; a negative coefficient is the key passive-safety feature.
- **Burnup (MWd/kgHM):** energy extracted per unit heavy metal; a proxy for how
  "spent" a pebble is.
- **TRISO:** coated fuel particle; thousands are embedded in each pebble.
- **HTR-PM:** the Chinese commercial pebble bed reactor; source of our reference
  numbers.
- **Diffusion approximation:** cheap approximation to neutron transport, solved
  on a grid; the workhorse of this toy.
- **Power iteration:** iterative method used to extract k-eff and the flux shape
  from the diffusion problem.
- **Quasi-static:** solved at steady state each step because the flux
  equilibrates far faster than anything mechanical.
- **Xenon poisoning:** Xe-135 buildup absorbs neutrons on an hours timescale,
  causing transients.
- **Decay heat:** heat that continues after fission stops (from decaying fission
  products); the reason a reactor must still be cooled post-scram, and the basis
  of the passive-safety demo.
- **Thermal time constant:** how fast a pebble's temperature responds to a change
  in power — its heat capacity gives the core inertia, hence lag and overshoot.
- **Packing fraction:** volume fraction occupied by pebbles (~0.61 random
  monodisperse spheres).
- **Lagrangian vs Eulerian:** per-object tracking vs fixed-grid field — the two
  worlds this sim couples.
