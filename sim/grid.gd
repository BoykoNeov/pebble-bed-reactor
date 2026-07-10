# sim/grid.gd
#
# The coarse Eulerian mesh and the homogenization step — the boundary between
# the two worlds (CLAUDE.md). This is where per-pebble Lagrangian state becomes
# continuum-field macroscopic cross-sections, and where a solved field is
# sampled back onto pebbles. CLAUDE.md flags this as where the real subtlety
# lives; keep it small and obvious.
#
# Coordinates are physics-backend pixels. The grid rect extends a reflector band
# BEYOND the silo walls: cells outside the vessel interior are graphite
# reflector, and the vacuum boundary condition (neutronics.gd) sits at the outer
# edge of that band — not at the bed edge. Gridding vacuum right at the fuel
# boundary would produce edge flux depression, the opposite of the real behavior.
class_name Grid
extends RefCounted

# Aim for >~10 pebbles per cell so homogenized cross-sections aren't noise
# (a few dozen fuel cells for a few hundred pebbles). Too fine → cells with 0-2
# pebbles → garbage field. A coarse flux field is the correct toy answer.
const DEFAULT_CELL := 68.0
const DEFAULT_BAND_CELLS := 2
const PACK_MAX := 0.65        # cap so a cell can't read as denser than physical
# Cold inlet / reflector reference temperature (K, = Feedback.T_REF = 20 C).
# Duplicated as a plain literal so this low-level module stays free of a
# dependency on the feedback layer; the two must agree (asserted in tests).
const T_INLET := 293.15

var nx: int
var ny: int
var h: float                  # square cell size (px)
var ox: float                 # grid origin (left/top edge), px
var oy: float

# Silo interior rect: inside → fuel-or-void, outside (within grid) → reflector.
var _in_left: float
var _in_right: float
var _in_top: float
var _in_bottom: float

# Per-cell homogenized fields, row-major (idx = j * nx + i), length nx*ny.
var material: PackedInt32Array
var packing: PackedFloat32Array
# TWO-GROUP macroscopic cross-sections (M5b). Group 1 = fast, group 2 = thermal;
# sigma_r is the fast→thermal down-scatter (removal). moderation is the per-cell
# ratio M homogenized from pebble fuel loading — the base (design, reference
# moderator temperature) value; the feedback layer rescales sigma_r / sigma_a2
# from it at solve time for the moderator-temperature coefficient. The *_base
# fields hold the temperature-FREE values homogenize writes; feedback (Doppler on
# sigma_a1, MTC on sigma_r/sigma_a2) layers temperature dependence on top.
var d1: PackedFloat32Array          # fast diffusion coefficient
var d2: PackedFloat32Array          # thermal diffusion coefficient
var sigma_a1: PackedFloat32Array    # fast absorption (Doppler target)
var sigma_a2: PackedFloat32Array    # thermal absorption (fuel + moderator-parasitic + poison)
var sigma_r: PackedFloat32Array     # fast → thermal removal (down-scatter)
var nu_sigma_f1: PackedFloat32Array # fast fission production
var nu_sigma_f2: PackedFloat32Array # thermal fission production
var moderation: PackedFloat32Array  # per-cell moderation ratio M (fuel cells; 0 elsewhere)
# Derived total fission production νΣf1+νΣf2. Kept because downstream consumers
# (thermal coolant field, viz) use "nu_sigma_f > 0" purely as a FUEL-CELL FLAG,
# and it is a convenient displayable total. Not read by the two-group solver.
var nu_sigma_f: PackedFloat32Array
# Area-weighted mean pebble temperature per cell (K), from the per-pebble
# Lagrangian state (M4). This is how the REAL, time-lagged fuel temperature
# reaches the Eulerian Doppler solve — replacing M2's instant critical-power
# search (which invented a temperature) with the temperature the pebbles
# actually have. Cells with no pebbles stay at the cold inlet reference.
var temperature: PackedFloat32Array
# Per-cell coolant (helium) temperature (K), the M4b downstream transport field.
# Filled by Thermal.solve_coolant_field via a top-down per-column energy balance:
# coolant enters cold at the inlet and warms as it descends through the fuel,
# co-current with the falling pebbles. Cells above/beside the bed pass the coolant
# through unchanged. This is an Eulerian (grid) field, rendered like flux/temp.
var coolant_temp: PackedFloat32Array


## Build a grid sized to the silo plus a reflector band around it.
static func for_silo(cell := DEFAULT_CELL, band_cells := DEFAULT_BAND_CELLS) -> Grid:
	var g := Grid.new()
	g.h = cell
	var band := band_cells * cell
	g.ox = Silo.LEFT - band
	g.oy = Silo.TOP - band
	var width := (Silo.RIGHT - Silo.LEFT) + 2.0 * band
	var height := (Silo.OUTLET_Y - Silo.TOP) + 2.0 * band
	g.nx = int(ceil(width / cell))
	g.ny = int(ceil(height / cell))
	g._in_left = Silo.LEFT
	g._in_right = Silo.RIGHT
	g._in_top = Silo.TOP
	g._in_bottom = Silo.OUTLET_Y
	g._alloc()
	return g


func _alloc() -> void:
	var n := nx * ny
	material = PackedInt32Array(); material.resize(n)
	packing = PackedFloat32Array(); packing.resize(n)
	d1 = PackedFloat32Array(); d1.resize(n)
	d2 = PackedFloat32Array(); d2.resize(n)
	sigma_a1 = PackedFloat32Array(); sigma_a1.resize(n)
	sigma_a2 = PackedFloat32Array(); sigma_a2.resize(n)
	sigma_r = PackedFloat32Array(); sigma_r.resize(n)
	nu_sigma_f1 = PackedFloat32Array(); nu_sigma_f1.resize(n)
	nu_sigma_f2 = PackedFloat32Array(); nu_sigma_f2.resize(n)
	nu_sigma_f = PackedFloat32Array(); nu_sigma_f.resize(n)
	moderation = PackedFloat32Array(); moderation.resize(n)
	temperature = PackedFloat32Array(); temperature.resize(n)
	temperature.fill(T_INLET)
	coolant_temp = PackedFloat32Array(); coolant_temp.resize(n)
	coolant_temp.fill(T_INLET)


func cell_count() -> int:
	return nx * ny


func idx(i: int, j: int) -> int:
	return j * nx + i


## Column/row of a world position, or -1 if outside the grid rect.
func cell_of(pos: Vector2) -> int:
	var i := int((pos.x - ox) / h)
	var j := int((pos.y - oy) / h)
	if i < 0 or i >= nx or j < 0 or j >= ny:
		return -1
	return j * nx + i


## World-space center of cell (i, j).
func cell_center(i: int, j: int) -> Vector2:
	return Vector2(ox + (i + 0.5) * h, oy + (j + 0.5) * h)


## HOMOGENIZE: per-pebble state -> per-cell macroscopic cross-sections.
##
## Bins each pebble by its center into a cell, accumulates covered area →
## packing, and area-weights enrichment/burnup/poison so a cell's cross-sections
## reflect the fuel actually in it. Cells with no pebbles are classified as
## reflector (outside the vessel) or void (empty interior above the bed).
func homogenize(pebbles: Dictionary, positions: Dictionary) -> void:
	var n := nx * ny
	var area := PackedFloat32Array(); area.resize(n)   # summed pebble area per cell
	var e_acc := PackedFloat32Array(); e_acc.resize(n) # area-weighted enrichment
	var b_acc := PackedFloat32Array(); b_acc.resize(n) # area-weighted burnup
	var p_acc := PackedFloat32Array(); p_acc.resize(n) # area-weighted poison
	var t_acc := PackedFloat32Array(); t_acc.resize(n) # area-weighted temperature (M4)
	var l_acc := PackedFloat32Array(); l_acc.resize(n) # area-weighted fuel loading (M5b)

	for id in positions:
		var c := cell_of(positions[id])
		if c == -1:
			continue
		var peb: Pebble = pebbles.get(id)
		if peb == null:
			continue
		var a := PI * peb.radius * peb.radius
		area[c] += a
		# Enrichment proxy from the isotopic vector: fissile fraction of heavy
		# metal. At M1 pebbles carry no isotopics yet, so fall back to E_REF.
		var e := _enrichment_of(peb)
		e_acc[c] += a * e
		b_acc[c] += a * peb.burnup
		p_acc[c] += a * peb.poison
		t_acc[c] += a * peb.temperature   # M4: real lumped pebble temperature
		l_acc[c] += a * peb.fuel_loading  # M5b: sets the cell moderation ratio

	var cell_area := h * h
	for j in ny:
		for i in nx:
			var c := j * nx + i
			var pack: float = min(area[c] / cell_area, PACK_MAX)
			packing[c] = pack
			if pack > 0.03:
				material[c] = CrossSections.FUEL
				var inv := 1.0 / area[c]
				var e: float = e_acc[c] * inv
				var b: float = b_acc[c] * inv
				var poison: float = p_acc[c] * inv
				var loading: float = l_acc[c] * inv
				var m := CrossSections.moderation(loading)
				moderation[c] = m
				d1[c] = CrossSections.diffusion_fast(pack)
				d2[c] = CrossSections.diffusion_thermal(pack)
				sigma_a1[c] = CrossSections.sigma_a1_fuel(pack)
				sigma_a2[c] = CrossSections.sigma_a2_fuel(pack, poison, m)
				sigma_r[c] = CrossSections.sigma_r_fuel(pack, m)
				var f1 := CrossSections.nu_sigma_f1(pack, e, b)
				var f2 := CrossSections.nu_sigma_f2(pack, e, b)
				nu_sigma_f1[c] = f1
				nu_sigma_f2[c] = f2
				nu_sigma_f[c] = f1 + f2   # derived total / fuel-cell flag
				temperature[c] = t_acc[c] * inv   # mean of the pebbles actually here
			elif _inside_vessel(i, j):
				material[c] = CrossSections.VOID
				moderation[c] = 0.0
				d1[c] = CrossSections.VOID_D1
				d2[c] = CrossSections.VOID_D2
				sigma_a1[c] = CrossSections.VOID_SIGA1
				sigma_a2[c] = CrossSections.VOID_SIGA2
				sigma_r[c] = CrossSections.VOID_SIGR
				nu_sigma_f1[c] = 0.0
				nu_sigma_f2[c] = 0.0
				nu_sigma_f[c] = 0.0
				temperature[c] = T_INLET
			else:
				material[c] = CrossSections.REFLECTOR
				moderation[c] = 0.0
				d1[c] = CrossSections.REFL_D1
				d2[c] = CrossSections.REFL_D2
				sigma_a1[c] = CrossSections.REFL_SIGA1
				sigma_a2[c] = CrossSections.REFL_SIGA2
				sigma_r[c] = CrossSections.REFL_SIGR
				nu_sigma_f1[c] = 0.0
				nu_sigma_f2[c] = 0.0
				nu_sigma_f[c] = 0.0
				temperature[c] = T_INLET


## SAMPLE-BACK: bilinear read of a per-cell field at a world position, so a
## pebble can pick up its local flux (M3 burnup, per-pebble viz). Uses cell
## centers as sample points; clamps to the domain edges.
func sample(field: PackedFloat32Array, pos: Vector2) -> float:
	var fx := (pos.x - ox) / h - 0.5
	var fy := (pos.y - oy) / h - 0.5
	var i0 := int(floor(fx))
	var j0 := int(floor(fy))
	var tx := fx - i0
	var ty := fy - j0
	var i0c: int = clampi(i0, 0, nx - 1)
	var i1c: int = clampi(i0 + 1, 0, nx - 1)
	var j0c: int = clampi(j0, 0, ny - 1)
	var j1c: int = clampi(j0 + 1, 0, ny - 1)
	var v00 := field[j0c * nx + i0c]
	var v10 := field[j0c * nx + i1c]
	var v01 := field[j1c * nx + i0c]
	var v11 := field[j1c * nx + i1c]
	var top: float = lerp(v00, v10, tx)
	var bot: float = lerp(v01, v11, tx)
	return lerp(top, bot, ty)


## Cell center inside the rectangular vessel interior (fuel/void vs reflector).
## The funnel is approximated by the bounding rect — fine for a toy grid.
func _inside_vessel(i: int, j: int) -> bool:
	var cx := ox + (i + 0.5) * h
	var cy := oy + (j + 0.5) * h
	return cx >= _in_left and cx <= _in_right and cy >= _in_top and cy <= _in_bottom


## Fissile fraction of a pebble's heavy metal, defaulting to E_REF before any
## isotopics are tracked (M1). Kept here so M3 only fills the pebble vector.
func _enrichment_of(peb: Pebble) -> float:
	var hm := peb.u235 + peb.u238 + peb.pu239
	if hm <= 0.0:
		return CrossSections.E_REF
	return (peb.u235 + peb.pu239) / hm
