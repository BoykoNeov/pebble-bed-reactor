# 2D Pebble Bed Reactor Toy Simulator

A 2D, real-time, **educational** pebble bed reactor (PBR) simulator built in
Godot 4. You change the design of incoming pebbles (size, fuel loading,
enrichment) and the reactor's operating parameters, then watch how the core
responds and inspect the composition of the pebbles flowing out the bottom.

This is a **qualitative teaching toy**, not a benchmark-accurate physics code.
The goal is to reproduce the correct reactor *behaviors and trends* — passive
self-regulation, burnup gradients, flux peaking, moderation feedback — rather
than exact numbers. It models a civilian LEU power reactor throughout.

## The core idea — two coupled worlds

The simulation lives at the boundary between two representations and translates
between them every step:

- **Per-pebble world (Lagrangian):** each pebble is a discrete body with a
  position, size, temperature, burnup, and isotopic vector — what the physics
  engine gives us.
- **Continuum-field world (Eulerian):** neutron flux, cross-sections, and power
  density live on a coarse grid — what the neutronics solver operates on.

Pebble size, fuel loading, and enrichment enter the physics at the
homogenization step, which is what makes the player's design choices matter.
See [`CLAUDE.md`](CLAUDE.md) for the full architecture, design principles, and
physics reference.

## Status

Early development. Built in milestone order:

- **M0** — Granular flow (silo, falling pebbles, inject/extract)
- **M1** — Neutronics MVP (diffusion solve, k-eff, flux heatmap)
- **M2** — Doppler feedback (passive self-regulation)
- **M3** — Burnup, depletion, and outflow composition
- **M4** — Thermal and cooling loop
- **M5a** — Decay heat and scram (walk-away-safe demo)
- **M5b** — Two-group diffusion and the emergent-sign moderator coefficient
- **M5c** — Xenon transient and poisoning (Xe-135 worth, post-scram iodine pit)
- **M5d** — Control rods in the side reflector (emergent worth and S-curve)

## Tech stack

- **Engine:** Godot 4.x
- **Physics:** Godot's built-in 2D physics (behind a swappable interface)
- **Language:** GDScript, with the neutronics/depletion core kept as pure,
  engine-agnostic, unit-testable functions

## License

Licensed under the **Boyko Non-Commercial License v1.0 (BNCL-1.0)** — see
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Non-commercial use, modification,
and redistribution are permitted with attribution; commercial use requires a
separate license from the copyright holder.

This software was originally created by Boyko Neov.
