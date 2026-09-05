# sim/neutronics.gd
#
# TWO-GROUP steady-state neutron diffusion (M5b), solved fresh each call by power
# iteration (CLAUDE.md principles 1-2: the flux is CLOCKLESS — it equilibrates
# far faster than anything mechanical, so we solve it at steady state and NEVER
# time-march it).
#
# Group 1 = FAST (neutrons born from fission), group 2 = THERMAL (slowed by the
# graphite moderator). Fission is born entirely fast (chi_1 = 1, chi_2 = 0); the
# thermal group has NO fission source of its own — it is fed only by down-scatter
# (removal Sigma_r) out of the fast group. Eigenvalue form:
#
#   Fast:    -div(D1 grad phi1) + (Sigma_a1 + Sigma_r)*phi1 = (1/k)(nuSigf1*phi1 + nuSigf2*phi2)
#   Thermal: -div(D2 grad phi2) +  Sigma_a2         *phi2 =        Sigma_r*phi1
#
# Sigma_r appears twice: as a LOSS on the fast diagonal (neutrons leaving group 1)
# and as the SOURCE driving the thermal group. Each group is discretized with the
# same cell-centered 5-point finite-volume stencil, harmonic-mean face diffusion,
# and a per-group vacuum boundary condition (each uses its OWN D for the
# extrapolation length). Two stencils are built (D1 != D2). Inner fixed-source
# solves are Gauss-Seidel; the outer power iteration alternates fast then thermal
# and extracts k-eff from the fission source.
#
# Pure and engine-agnostic: takes a Grid, returns flux + k-eff. No Godot, no
# feedback (the flux is consumed, never fed back into the cross-sections here —
# feedback.gd / thermal.gd layer temperature dependence onto the grid BEFORE the
# solve).
class_name Neutronics
extends RefCounted


## Result of one steady-state solve.
class Solution:
	var flux: PackedFloat32Array         # per-cell FISSION-RATE density (nuSigf1*phi1 +
	                                     # nuSigf2*phi2), PEAK-NORMALIZED to 1 — the local
	                                     # power/heat source. Same normalization convention as
	                                     # the old one-group scalar flux, so the thermal
	                                     # map-back (thermal.gd) and its tuned constants survive.
	var flux_fast: PackedFloat32Array    # fast scalar flux phi1 (same scale factor as `flux`)
	var flux_thermal: PackedFloat32Array # thermal scalar flux phi2 (same scale factor)
	var k_eff: float                     # multiplication factor incl. leakage
	var fission_rate: float              # total Sum(nuSigf1*phi1 + nuSigf2*phi2) at
	                                     # convergence, on the peak-normalized flux — the
	                                     # relative power readout and the M4 heat-source hook.
	var iterations: int                  # outer power iterations taken
	var converged: bool


## Per-group 5-point stencil coefficients.
class Stencil:
	var cE: PackedFloat32Array
	var cW: PackedFloat32Array
	var cN: PackedFloat32Array
	var cS: PackedFloat32Array
	var diag: PackedFloat32Array   # leakage + face terms; the caller adds removal/absorption


## Solve the two-group diffusion eigenproblem on `grid`. Coupling coefficients
## depend only on the (fixed) cross-sections, so the two stencils are built once;
## power iteration then alternates fast/thermal fixed-source solves with a k update.
##
## CONVERGENCE is judged on BOTH the eigenvalue and the fission-source SHAPE. A k-only
## test is the classic false-convergence trap of power iteration: k is a Rayleigh-like
## quotient and settles to second order while the shape is still first-order off, so
## |Δk| < tol can trigger while the flux is visibly wrong. Measured on the calibrated
## lattice with the rods half in: the k-only test stopped at 12 outer iterations with
## the peak-normalized fission-rate density still 2.8e-3 off its converged value —
## and every worth the HUD shows (rods, xenon) is a DIFFERENCE of two such solves, so
## shape error goes straight into the readout. `tol_src` bounds the max change of the
## peak-normalized fission-rate density between outer iterations.
##
## `guess` WARM-STARTS the iteration from a previous solution (its phi1/phi2 and k).
## The live loop re-solves a nearly-unchanged core every 0.2 s (and 3-4 variants of
## it per cadence: cold / xenon-free / rod-free / warm), so starting from a flat flux
## each time wastes ~40 outer iterations per solve; from the last answer it converges
## in a handful. The result is IDENTICAL up to the tolerance — the eigenproblem has one
## fundamental mode — so a warm start changes cost, never physics. A guess whose size
## does not match the grid is ignored.
##
## `stencils` optionally supplies the two pre-built stencils (`build_stencils(grid)`).
## The stencils depend on the diffusion coefficients only — on PACKING, which homogenize
## sets — never on temperature, xenon or rods, so every solve posed against one
## homogenization (cold, xenon-free, rod-free, warm: up to four per cadence) shares the
## same pair. Building them once per cadence instead of once per solve is a pure cost
## saving with bit-identical results; omitted, they are built here as before.
static func solve(grid: Grid, max_outer := 300, inner_sweeps := 8, tol := 1.0e-5,
		guess: Solution = null, tol_src := 1.0e-4, stencils: Array = []) -> Solution:
	var n := grid.nx * grid.ny
	var nx := grid.nx
	var ny := grid.ny

	var sa1 := grid.sigma_a1
	var sa2 := grid.sigma_a2
	var sr := grid.sigma_r
	var f1 := grid.nu_sigma_f1
	var f2 := grid.nu_sigma_f2

	# Two stencils (fast/thermal) share geometry but differ in D, hence in face
	# couplings and vacuum-BC leakage. Removal adds to the fast diagonal (a loss
	# from group 1); thermal absorption is the thermal diagonal's reaction term.
	if stencils.size() != 2:
		stencils = build_stencils(grid)
	var st1: Stencil = stencils[0]
	var st2: Stencil = stencils[1]
	var diag1 := PackedFloat32Array(); diag1.resize(n)
	var diag2 := PackedFloat32Array(); diag2.resize(n)
	for c in range(n):
		diag1[c] = st1.diag[c] + sa1[c] + sr[c]
		diag2[c] = st2.diag[c] + sa2[c]

	var phi1 := PackedFloat32Array(); phi1.resize(n); phi1.fill(1.0)
	var phi2 := PackedFloat32Array(); phi2.resize(n); phi2.fill(1.0)
	var fsrc := PackedFloat32Array(); fsrc.resize(n)   # fission-rate density (per cell)
	var fprev := PackedFloat32Array(); fprev.resize(n) # ... from the previous outer iteration
	var src := PackedFloat32Array(); src.resize(n)     # per-group fixed source
	var k := 1.0
	var have_prev := false
	# A guess from a fuel-less solve (zero flux) would make the very first fission
	# integral zero and end the iteration before it starts — so it is only used when
	# it actually carries a fission source.
	if guess != null and guess.flux_fast.size() == n and guess.flux_thermal.size() == n \
			and guess.k_eff > 0.0 and guess.fission_rate > 0.0:
		phi1 = guess.flux_fast.duplicate()
		phi2 = guess.flux_thermal.duplicate()
		k = guess.k_eff

	var sol := Solution.new()
	sol.converged = false
	for outer in range(max_outer):
		# Fission source F = nuSigf1*phi1 + nuSigf2*phi2 (born fast). fiss_old is its
		# spatial integral — the numerator of the k update.
		var fiss_old := 0.0
		var dsrc := 0.0
		for c in range(n):
			var fc := f1[c] * phi1[c] + f2[c] * phi2[c]
			if have_prev:
				dsrc = maxf(dsrc, absf(fc - fprev[c]))
			fprev[c] = fc
			fsrc[c] = fc
			fiss_old += fc
		if fiss_old <= 0.0:
			break  # no fissile material — nothing to iterate

		# Fast fixed-source solve: (leak + Sigma_a1 + Sigma_r) phi1 = F / k.
		for c in range(n):
			src[c] = fsrc[c] / k
		_gs_sweeps(phi1, src, st1, diag1, nx, ny, inner_sweeps)

		# Thermal fixed-source solve: (leak + Sigma_a2) phi2 = Sigma_r * phi1.
		for c in range(n):
			src[c] = sr[c] * phi1[c]
		_gs_sweeps(phi2, src, st2, diag2, nx, ny, inner_sweeps)

		# New fission integral and k update.
		var fiss_new := 0.0
		for c in range(n):
			fiss_new += f1[c] * phi1[c] + f2[c] * phi2[c]
		var k_new := k * fiss_new / fiss_old

		# Normalize BOTH groups by the peak fission-rate density so magnitudes don't
		# drift over iterations while the phi1:phi2 ratio (the spectrum) is preserved.
		var peak := 0.0
		for c in range(n):
			peak = maxf(peak, f1[c] * phi1[c] + f2[c] * phi2[c])
		if peak > 0.0:
			var inv := 1.0 / peak
			for c in range(n):
				phi1[c] *= inv
				phi2[c] *= inv

		var dk: float = absf(k_new - k)
		k = k_new
		sol.iterations = outer + 1
		# Both the eigenvalue AND the shape must have settled (see the header). The shape
		# test compares the peak-normalized fission source entering this iteration with the
		# one entering the last, so it needs one prior iteration before it can pass.
		if dk < tol and have_prev and dsrc < tol_src:
			sol.converged = true
			break
		have_prev = true

	# Peak-normalized fission-rate density (peak = 1) — the derived `flux` the rest
	# of the sim samples; and its total (relative power). phi1/phi2 already carry the
	# same scale factor from the last normalization.
	var rr := PackedFloat32Array(); rr.resize(n)
	var fr := 0.0
	var rpeak := 0.0
	for c in range(n):
		var v := f1[c] * phi1[c] + f2[c] * phi2[c]
		rr[c] = v
		rpeak = maxf(rpeak, v)
	if rpeak > 0.0:
		var rinv := 1.0 / rpeak
		for c in range(n):
			rr[c] *= rinv
	for c in range(n):
		fr += rr[c]

	sol.flux = rr
	sol.flux_fast = phi1
	sol.flux_thermal = phi2
	sol.fission_rate = fr
	sol.k_eff = k
	return sol


## Gauss-Seidel sweeps of a fixed-source problem (leak+reaction) phi = src, in
## place on `phi`. `diag` already includes the reaction term; `st` holds the
## neighbor couplings. Flux is clamped non-negative (an unstable solve must never
## emit negative flux — CLAUDE.md pitfall).
static func _gs_sweeps(phi: PackedFloat32Array, src: PackedFloat32Array, st: Stencil, diag: PackedFloat32Array, nx: int, ny: int, sweeps: int) -> void:
	var cE := st.cE
	var cW := st.cW
	var cN := st.cN
	var cS := st.cS
	for _s in range(sweeps):
		for j in ny:
			for i in nx:
				var c := j * nx + i
				var acc := src[c]
				if i + 1 < nx: acc += cE[c] * phi[c + 1]
				if i - 1 >= 0: acc += cW[c] * phi[c - 1]
				if j - 1 >= 0: acc += cN[c] * phi[c - nx]
				if j + 1 < ny: acc += cS[c] * phi[c + nx]
				phi[c] = maxf(acc / diag[c], 0.0)


## The fast and thermal stencils for `grid`, as [fast, thermal]. See `solve` for why a
## caller posing several solves against one homogenization should build these once.
static func build_stencils(grid: Grid) -> Array:
	var h2 := grid.h * grid.h
	return [_build_stencil(grid.d1, grid.nx, grid.ny, h2), _build_stencil(grid.d2, grid.nx, grid.ny, h2)]


## Build one group's 5-point stencil from its diffusion field `dd`. `diag` holds
## only the leakage part (face couplings + vacuum-BC boundary leakage); the caller
## adds the reaction term (absorption, plus removal for the fast group).
##
## Each face is either a harmonic-mean coupling to an interior neighbour (which adds the
## same amount to the diagonal) or, at the grid edge, a vacuum-boundary leakage term to a
## zero-flux point ~2D beyond the face (current out = D*phi / (h/2 + d_ext), d_ext ~ 2D,
## per cell area) that adds to the diagonal only. Written inline rather than through a
## per-face helper returning a Dictionary: this ran 4 allocations per cell per stencil,
## twice per solve, several solves per cadence — measurable in GDScript for no gain.
static func _build_stencil(dd: PackedFloat32Array, nx: int, ny: int, h2: float) -> Stencil:
	var n := nx * ny
	var h := sqrt(h2)
	var st := Stencil.new()
	st.cE = PackedFloat32Array(); st.cE.resize(n)
	st.cW = PackedFloat32Array(); st.cW.resize(n)
	st.cN = PackedFloat32Array(); st.cN.resize(n)
	st.cS = PackedFloat32Array(); st.cS.resize(n)
	st.diag = PackedFloat32Array(); st.diag.resize(n)
	for j in ny:
		for i in nx:
			var c := j * nx + i
			var dc := dd[c]
			var leak := dc / ((0.5 * h + 2.0 * dc) * h)
			var diag := 0.0
			var coup: float
			if i + 1 < nx:
				coup = 2.0 * dc * dd[c + 1] / (dc + dd[c + 1]) / h2
				st.cE[c] = coup
				diag += coup
			else:
				diag += leak
			if i - 1 >= 0:
				coup = 2.0 * dc * dd[c - 1] / (dc + dd[c - 1]) / h2
				st.cW[c] = coup
				diag += coup
			else:
				diag += leak
			if j - 1 >= 0:
				coup = 2.0 * dc * dd[c - nx] / (dc + dd[c - nx]) / h2
				st.cN[c] = coup
				diag += coup
			else:
				diag += leak
			if j + 1 < ny:
				coup = 2.0 * dc * dd[c + nx] / (dc + dd[c + nx]) / h2
				st.cS[c] = coup
				diag += coup
			else:
				diag += leak
			st.diag[c] = diag
	return st
