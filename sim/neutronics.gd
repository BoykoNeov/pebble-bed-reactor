# sim/neutronics.gd
#
# One-group steady-state neutron diffusion, solved fresh each call by power
# iteration (CLAUDE.md principles 1-2: the flux is CLOCKLESS — it equilibrates
# far faster than anything mechanical, so we solve it at steady state and NEVER
# time-march it).
#
# Equation (eigenvalue form):
#     -div(D grad phi) + Sigma_a * phi = (1/k) * nuSigma_f * phi
#
# Discretized cell-centered on grid.gd with a 5-point finite-volume stencil,
# harmonic-mean face diffusion, and a vacuum boundary condition (via an
# extrapolation length) at the OUTER edge of the reflector band. Inner fixed-
# source solves use Gauss-Seidel; the outer power iteration extracts k-eff and
# the flux shape.
#
# Pure and engine-agnostic: takes a Grid, returns flux + k-eff. No Godot, no
# feedback (M1 is strictly one-directional — the flux is consumed, never fed
# back into the cross-sections).
class_name Neutronics
extends RefCounted


## Result of one steady-state solve.
class Solution:
	var flux: PackedFloat32Array   # per-cell scalar flux (grid row-major)
	var k_eff: float               # multiplication factor incl. leakage
	var fission_rate: float        # total Sum(nuSigma_f * phi) at convergence.
	                               # Flux is peak-normalized, so this is a RELATIVE
	                               # power (arbitrary units). It is the fission heat
	                               # source M4 will feed into the energy balance.
	var iterations: int            # outer power iterations taken
	var converged: bool


## Solve the diffusion eigenproblem on `grid`. Coupling coefficients depend only
## on the (fixed) cross-sections, so they are built once; power iteration then
## alternates a fixed-source Gauss-Seidel solve with a k / flux update.
static func solve(grid: Grid, max_outer := 300, inner_sweeps := 6, tol := 1.0e-5) -> Solution:
	var n := grid.nx * grid.ny
	var nx := grid.nx
	var ny := grid.ny
	var h := grid.h
	var h2 := h * h
	var dd := grid.d
	var siga := grid.sigma_a
	var nsf := grid.nu_sigma_f

	# Precompute the 5-point stencil: four neighbor couplings (D_face / h^2) and
	# the diagonal (absorption + all outgoing couplings + boundary leakage).
	var cE := PackedFloat32Array(); cE.resize(n)
	var cW := PackedFloat32Array(); cW.resize(n)
	var cN := PackedFloat32Array(); cN.resize(n)
	var cS := PackedFloat32Array(); cS.resize(n)
	var diag := PackedFloat32Array(); diag.resize(n)

	for j in ny:
		for i in nx:
			var c := j * nx + i
			var dc := dd[c]
			var dsum := siga[c]
			# East / West / North / South
			var ce := _coupling(dc, dd, i + 1 < nx, c + 1, h2)
			var cw := _coupling(dc, dd, i - 1 >= 0, c - 1, h2)
			var cn := _coupling(dc, dd, j - 1 >= 0, c - nx, h2)
			var cs := _coupling(dc, dd, j + 1 < ny, c + nx, h2)
			cE[c] = ce.coup
			cW[c] = cw.coup
			cN[c] = cn.coup
			cS[c] = cs.coup
			# Interior couplings leave the diagonal via the neighbor; boundary
			# faces leak to a zero-flux extrapolated point (vacuum BC).
			dsum += ce.diag + cw.diag + cn.diag + cs.diag
			diag[c] = dsum

	var flux := PackedFloat32Array(); flux.resize(n); flux.fill(1.0)
	var src := PackedFloat32Array(); src.resize(n)
	var k := 1.0

	var sol := Solution.new()
	sol.converged = false
	for outer in range(max_outer):
		var fiss_old := 0.0
		for c in range(n):
			var f := nsf[c] * flux[c]
			fiss_old += f
			src[c] = f / k
		if fiss_old <= 0.0:
			break  # no fissile material — nothing to iterate

		# Fixed-source inner solve: M phi = src via Gauss-Seidel sweeps.
		for _s in range(inner_sweeps):
			for j in ny:
				for i in nx:
					var c := j * nx + i
					var acc := src[c]
					if i + 1 < nx: acc += cE[c] * flux[c + 1]
					if i - 1 >= 0: acc += cW[c] * flux[c - 1]
					if j - 1 >= 0: acc += cN[c] * flux[c - nx]
					if j + 1 < ny: acc += cS[c] * flux[c + nx]
					flux[c] = maxf(acc / diag[c], 0.0)  # clamp: no negative flux

		var fiss_new := 0.0
		for c in range(n):
			fiss_new += nsf[c] * flux[c]
		var k_new := k * fiss_new / fiss_old

		# Normalize the flux shape (peak = 1) so magnitudes don't drift over
		# iterations; only the SHAPE and k carry meaning in an eigenproblem.
		var peak := 0.0
		for c in range(n):
			peak = maxf(peak, flux[c])
		if peak > 0.0:
			var inv := 1.0 / peak
			for c in range(n):
				flux[c] *= inv

		var dk: float = absf(k_new - k)
		k = k_new
		if dk < tol:
			sol.converged = true
			sol.iterations = outer + 1
			break
		sol.iterations = outer + 1

	# Total fission rate on the converged, peak-normalized flux — the relative
	# power readout (M1 deliverable) and the M4 heat-source hook.
	var fr := 0.0
	for c in range(n):
		fr += nsf[c] * flux[c]
	sol.fission_rate = fr

	sol.flux = flux
	sol.k_eff = k
	return sol


## One face's contribution: harmonic-mean coupling to an interior neighbor, or a
## vacuum-boundary leakage term to a zero-flux point ~2D beyond the face.
## Returns {coup, diag}: `coup` multiplies the neighbor flux (0 at a boundary);
## `diag` is what this face adds to the cell's diagonal.
static func _coupling(dc: float, dd: PackedFloat32Array, interior: bool, nbr: int, h2: float) -> Dictionary:
	var h := sqrt(h2)
	if interior:
		var dn := dd[nbr]
		var d_face := 2.0 * dc * dn / (dc + dn)  # harmonic mean
		var coup := d_face / h2
		return {"coup": coup, "diag": coup}
	# Vacuum BC: current out = D * phi / (h/2 + d_ext), d_ext ~ 2D, per cell area.
	var leak := dc / ((0.5 * h + 2.0 * dc) * h)
	return {"coup": 0.0, "diag": leak}
