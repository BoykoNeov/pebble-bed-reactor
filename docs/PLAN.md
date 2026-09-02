# Scientific hurdles and roadmap

This is the working plan for the simulator's *science* and *structure*: what the
model gets wrong or leaves out, what has been fixed, and in what order the rest
should be done. `CLAUDE.md` stays the statement of principles and the record of
decisions already taken; this file is the list of open problems and the plan.

Everything here was measured on the calibrated lattice (`tests/`) with headless
Godot 4.7. Numbers are toy units unless a unit is given.

## 1. Where the project stands

M0–M5d are built and gated. The two-world coupling, two-group diffusion, Doppler
and moderator feedbacks, depletion with online refueling, the thermal loop with
decay heat, xenon, control rods and scram all exist and pass their suites.

The remaining hurdles are not "features missing" but places where the model is
**internally inconsistent** (the two worlds disagree), **structurally untestable**
(the live loop was not the loop the tests ran), or **physically hollow** (a tuned
constant standing in for a mechanism whose sign and scale the toy could actually
earn). They are listed below in the order they were attacked.

## 2. Fixed in this pass

### 2.1 The live coupling loop was not the loop the tests ran (structure)

The homogenize → solve → feedback → sample-back loop, the thermal/kinetics
integration, and the campaign-clock depletion lived as methods on the Godot scene
node (`main.gd`, ~3000 lines), interleaved with the HUD and the fuel machine. The
pure suite could not run them, so `tests/test_thermal.gd` carried its *own*
re-implementation of the coupled loop. The two copies had already drifted: the
notes speak of a pure-harness fixed point (`A_REF = 87`) that differs from the
live scene's settled amplitude (~32), and of "breathing" the pure loop does not
reproduce.

**Done:** the loop is now one object, `sim/reactor.gd` (`ReactorCore`), with the
three clocks as three methods (`solve`, `thermal_step`, `deplete`) and every
readout as a plain field. `main.gd` feeds it the physics engine's positions and
forwards its fields under the old `_name`s (read-through properties), so the HUD,
the drawing code and every live harness are unchanged. `tests/test_reactor.gd`
drives the *same* object on a lattice and gates the things only the live loop can
answer: seed → settle → scram → bounded, plus the consistency checks below.

`main.gd` shrank by ~240 lines. It is still large (fuel machine, HUD, controls,
inspector); see §4 for the next extractions.

### 2.2 The diffusion solver stopped early and started cold (numerics)

Power iteration converged on `|Δk| < 1e-5` only. k is a Rayleigh-like quotient
and settles to second order while the flux shape is first-order off, so the test
can fire with the shape still wrong. Measured with the rods half in: the k-only
test stopped at 12 outer iterations with the peak-normalized fission-rate density
still **2.8e-3** off its converged value. Every worth the HUD shows (rods, xenon)
is a *difference* of two such solves, so that error went straight into the readout.

Separately, each solve cost ~30 ms in GDScript (144 cells × 8 Gauss–Seidel sweeps
× ~45 outer iterations) and the live loop runs three or four of them per 0.2 s
cadence, all from a flat initial flux — roughly 100 ms of solver per cadence
against a 16 ms frame.

**Done:** `Neutronics.solve` now also requires the peak-normalized fission source
to change by less than `tol_src = 1e-4` between outer iterations (shape error in
the rodded case drops to 9e-5), and accepts a previous `Solution` as a warm start.
`ReactorCore` keeps one cached solution per eigenproblem it poses (cold, xenon-free,
rod-free, warm) and re-solves from it: a same-core re-solve converges in 2–3
outer iterations at ~2.5 ms instead of ~45 at ~30 ms. k values agree with cold
starts to better than 2e-4 (gated). Every calibration number in the suites is
unchanged to four decimals.

### 2.3 The two worlds disagreed on heat for any pebble size but 8 px (physics)

The Eulerian coolant march (`Thermal.solve_coolant_field`) converted a cell's
packing into a total conductance with a hardcoded "23 pebbles per cell", which is
only true at the nominal radius. The Lagrangian thermal step, meanwhile, gave every
pebble the same heat, conductance and heat capacity regardless of size. So with
the size lever at r = 5 the coolant picked up ~40% of the heat the pebbles shed; at
r = 13 it picked up ~260%. Energy was not conserved between the worlds, and the
size knob did no thermal physics at all — it reached the neutronics only through
bed height (leakage), as `sim/pebble.gd` already admitted.

**Done, 2D-consistently:** `Grid.homogenize` now records a per-cell conductance
weight `Σ r_i / R_REF` alongside packing, and the coolant march uses it — so the
cell picks up exactly what its pebbles shed for *any* size mix (gated to 0.1%;
measured 0.00–0.02%). Per pebble, with `s = r / R_REF`: heat source ∝ s² (fuel
area), conductance ∝ s (perimeter), capacity ∝ s². Consequences, all gated:
cell heat is size-invariant at fixed packing (matches the Eulerian fission-rate
density, which knows only packing); a bigger pebble at the same power density
runs **hotter** (ΔT ∝ s) and responds **slower** (τ ∝ s) — the surface-to-volume
effect `CLAUDE.md` names for uniform size change, now closing the loop through the
existing Doppler feedback with no new coefficient. A nominal pebble is scaled by
exactly 1.0, so every r = 8 calibration is untouched.

### 2.4 A spent pebble made as much heat as a fresh one (physics)

`local_flux` is the *cell's* peak-normalized fission-rate density, and it was the
only thing a pebble's heat depended on. Two pebbles in the same cell — one fresh,
one at discharge burnup — produced identical heat, contradicting the cell's own
cross-sections (built from the area-weighted fissile fraction) and undercutting
the project's headline goal of watching individual pebbles age.

**Done:** `Grid.homogenize` keeps the per-cell homogenized fissile fraction, and
the sample-back sets `Pebble.fission_weight = own fissile fraction / cell's`. The
heat source is scaled by it. The area-weighted mean of the weights over a cell is
exactly 1 (gated to 1e-4), so cell heat and the calibrated operating point are
unchanged; only its distribution among pebbles is. On a burnup-spread bed the
weights span ~0.83–1.19 and the freshest pebble runs hotter than the most spent
one in 26 of 27 cells (the one exception sits in a cell straddling a steep flux
gradient, i.e. position, not weighting). A "Pebble power" per-pebble heatmap
shows it. Depletion is *not* weighted — a pebble's own inventory already sets its
absorption rates.

### 2.5 No way to run the suite (structure)

Tests were run one file at a time by hand. `tests/run_tests.sh` runs the pure
suite (`--live` adds the curated scene harnesses, `--all` every headless one) and
`.github/workflows/tests.yml` runs both on push. Note the first run after a
checkout must import the project (the script does it) — new `class_name`s are
not visible until then.

## 3. Open scientific hurdles, with proposed fixes

Ordered by how much they distort the *teaching* behaviors, not by effort.

### 3.1 Power kinetics has no delayed neutrons

`dA/dt = A·(k−1)·KINETICS_GAIN` with `GAIN = 4` tuned so the power e-fold is no
faster than the pebble thermal time constant (~18 s), because faster kinetics
drove a burnup-coupled limit cycle. That tuning *substitutes* for physics: in a
real reactor the small-reactivity period is long *because of delayed neutrons*,
and the transition to prompt criticality at ρ = β is the single most important
kinetics fact a teaching toy could show.

One-delayed-group point kinetics in the prompt-jump approximation gives, for
ρ < β, `dA/dt = A·λρ/(β−ρ)` with β ≈ 0.0065, λ ≈ 0.08/s (ρ = (k−1)/k). Compared to
the current model:

| ρ      | current e-fold (GAIN 4) | delayed-neutron e-fold |
|--------|-------------------------|------------------------|
| 0.002  | 125 s                   | 28 s                   |
| 0.005  | 50 s                    | 3.7 s                  |
| 0.0065 | 38 s                    | → 0 (prompt critical)  |

So real kinetics is 5–10× *faster* in the operating band, and the toy's fresh
cores (k_cold up to 1.10) would be prompt-supercritical — physically a Doppler-
terminated pulse in milliseconds, not representable at 60 Hz. That tension is
the honest reason the constant exists. Proposal:

1. Add `sim/kinetics.gd`: one-group delayed precursors integrated semi-implicitly
   (`C' = (C + dt·β/Λ·A)/(1+dt·λ)`), prompt-jump for `A` while ρ < β, and above
   β a *saturated* prompt growth rate (a stated ceiling, e.g. 5/s) so the toy
   shows a "prompt jump" and a Doppler turnover instead of an overflow.
2. Gate the inhour behavior in a pure test (period vs ρ, the divergence at β, a
   negative-reactivity asymptote at −λ).
3. Wire it live *behind a flag* and re-run the full live set. The known risk is
   the burnup-coupled limit cycle (§3.4): the campaign clock is compressed ~1000×
   while the thermal clock is real-time, so faster kinetics makes burnup respond
   inside the thermal lag. The fix is to slow the *campaign* coupling
   (`TIME_ACCEL`) relative to the kinetics, not to slow the kinetics — which is
   also what §3.4 needs.

### 3.2 Burnup accrues by fluence, not by fissions

`burnup += BURN_RATE · flux · dt` — a pebble at discharge accrues burnup as fast
as a fresh one, and a 5%-enriched pebble as fast as a 12% one. Burnup is energy
per heavy metal, i.e. ∝ fissions; the depletion step already computes the
pebble's own fissions (`FF5·burn5 + FF9·burn9`) and uses them for poison and
xenon, so this is a one-line change in physics and a real change in calibration:

- `burnup += K · fissions`, with K set so the nominal 11.3% pebble still reaches
  90 at the same fluence as today (~1800 in current units; integrated fissions
  to fluence 90 are ~0.05).
- Consequences to re-gate: `test_depletion` passes-to-discharge (6–15), the
  `FLUENCE_PER_PASS` semantics, `_seed_burned` (loop to a burnup *target*, not a
  fluence), and the xenon mixed-grid builders that use burnup as fluence.
- It interacts with §3.4: at the live core's power_frac ~0.37 pebbles already
  bump the `MAX_PASSES` backstop; making the rate fall with depletion makes that
  worse unless the campaign clock is re-pinned at the same time. Do them together.

### 3.3 Doppler absorption ignores how much fuel is in the cell

`Feedback.doppler_sigma_a(T)` is added to `sigma_a1` per cell with no packing
factor, so a sparse cell at the bed surface (packing 0.05) gets the same resonance
absorption as a packed one. It should scale with the U-238 content, i.e. with
packing (and, at §3.2, with the pebble's U-238 fraction). Proposal: multiply by
`packing / PACK_REF` with `PACK_REF` the calibration lattice's ~0.62, so packed
cells are unchanged and only sparse edge cells lose Doppler they never earned.
Small effect on k (edge cells are leaky and cool); re-gate `test_feedback` and
the thermal operating points.

### 3.4 The campaign clock and the design-point amplitude do not agree live

`Thermal.A_REF` (87) is "the only validated fixed point" of the *pure* coupled
loop, while the live scene settles at ~32, so live burnup runs at ~37% of the
calibrated rate and pebbles can hit `MAX_PASSES` under-burned. That was partly an
artifact of two loops; with one loop (§2.1) it becomes measurable: run
`ReactorCore` on a funnel-shaped lattice with position-based refueling, read the
settled A, and pin `A_REF` and `TIME_ACCEL` from *that*. Also note the seed:
decay-heat reservoirs are seeded for `A_REF`, so a core that then settles far
below it carries an oversized slow-group decay inventory for ~2 minutes — visible
as post-scram heating under loss-of-flow early in a session (see §5).

### 3.5 Self-shielding is absent

Uniform size change now affects thermal physics (§2.3) but still not resonance
self-shielding. A toy Dancoff-like factor on `FAST_SIGA` — `(R_REF/r)^p` with
p ~ 0.3–0.5, 1.0 at nominal — would make bigger pebbles slightly *more* reactive
(less resonance capture) while §2.3 makes them hotter (more Doppler), a genuine
competing-effects lesson. Cheap; calibration-neutral at r = 8. Lower priority
than the above because the sign of the lever's net effect is not a teaching
target anywhere in `CLAUDE.md`.

### 3.6 No fast-forward, so the quasi-steady thermal branch is dead code

The clock model in `CLAUDE.md` says thermal transients collapse to quasi-steady
when the campaign clock is fast-forwarded, and `Thermal.steady_temp` exists for
it — but there is no time-skip control. Add a campaign multiplier lever (×1, ×5,
×20); above ×1, `ReactorCore.thermal_step` sets each pebble to `steady_temp`
instead of integrating and re-solves every step. That turns a 15-pass fuel life
from minutes into seconds and makes the burnup-gradient / flat-reactivity targets
watchable.

### 3.7 The xenon cold-start bistability is avoided, not gated

`test_thermal` notes that a cold start now lands in a relaxation limit cycle
that coexists with the operating point, and seeds past it. `CLAUDE.md` lists the
xenon transient as a validation target; the bistability deserves its own test
(does the cycle exist, what is its basin, does the delayed-neutron model of §3.1
change it) rather than being a comment in another test.

### 3.8 Radial (intra-pebble) temperature, pressure drop, real correlations

Listed in `CLAUDE.md` as stretch and still stretch. None blocks a teaching target.

## 4. Structure — remaining

- `main.gd` (~2750 lines) still holds the fuel-handling machine's queues and
  belts (~900 lines), the HUD/inspector/controls (~700), input, drawing and the
  field registry. Next extractions, in order of value: (a) `game/controls/hud.gd`
  — the readout, inspector and controls panel, reading `ReactorCore` fields; (b)
  `game/reactor_vessel/fuel_machine.gd` — mint/admit/extract/drop/reinject queues
  and belt driving, which already talk to `FuelLoop`; leaving `main.gd` as the
  orchestrator `CLAUDE.md` describes. The live harnesses reach into `_main.*`,
  so keep read-through forwards as was done here.
- `tests/test_thermal.gd`'s private coupled loops (`_run_coupled`,
  `_run_burnup_loop`) should migrate onto `ReactorCore` so the calibration
  sweeps and the live loop are literally the same code. Do it one test at a time
  and keep the gates.
- The scene's physics (positions from Godot) is the one thing the pure suite
  cannot reproduce; a funnel-shaped lattice builder with position-based
  refueling in `tests/` would let `test_reactor` reproduce the "breathing".

## 5. Validation record for this pass

Pure suite (`tests/run_tests.sh`): all gates pass — `test_neutronics`,
`test_feedback`, `test_depletion`, `test_xenon`, `test_control_rods`,
`test_silo`, `test_thermal`, and the new `test_reactor`. Calibration numbers are
unchanged to the printed precision (e.g. nominal k 1.0091, full-bank worth
0.3845, operating peak 1293 K).

Live (`tests/run_tests.sh --live`): `live_m4`, `live_scram`, `live_rods`,
`live_xenon`, `live_radius`. One pre-existing failure was found and fixed in the
harness, not the sim: `live_m4` scrammed the core and cut coolant flow in the
same instant, then asserted the fuel had *cooled* 27 s later. On the untouched
scene it had not (734 → 987 K; with these changes 750 → 1075 K) — and it should
not: with the flow cut, decay heat has only the small ambient leak to go to, so
warming before settling is the loss-of-flow story itself. The gate now restores
flow after the bounded-temperature check and asserts the cooldown then. The
magnitude of the warming is the §3.4 artifact: the decay reservoirs are seeded
for `A_REF` while the live core runs at ~8% of it by the time the harness trips,
so the slow decay group is still draining an inventory ~10× the running power's.
