# game/visualization/field_display.gd
#
# The generic GRID-field renderer (CLAUDE.md: Eulerian fields render as a small
# texture scaled up with interpolation — cheap). It is a pure CONSUMER of sim
# state: main.gd hands it a grid + a field array + a descriptor; it never writes
# back and never sits on the sim's critical path. Any grid field plugs in with
# zero new code here — only a new FieldDescriptor.
#
# Drawn in world space behind the pebbles (z = -1) so the heatmap is a background
# with pebbles on top — the two-worlds-at-once view CLAUDE.md calls for.
#
# Two-pass draw: the full grid rect (which includes the reflector band around the
# vessel) is drawn DIMMED, then the vessel interior is re-drawn at full
# brightness clipped to the silo polygon. The reflector-region field stays
# visible — thermal-flux peaking in the reflector is a validation target — but
# the eye reads the vessel as the subject, not a featureless colored rectangle.
class_name FieldDisplay
extends Node2D

# Multiplier for the field outside the vessel walls. Dim enough to recede,
# bright enough that the reflector thermal-flux bump still reads.
const OUTSIDE_DIM := Color(0.45, 0.45, 0.5)

var _tex: ImageTexture
var _rect: Rect2
var _has_field := false


func _ready() -> void:
	z_index = -1
	# Linear filtering turns the coarse nx*ny texture into a smooth field when
	# scaled up over the core (CLAUDE.md: interpolate the small grid texture).
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


## Rebuild the heatmap texture from a grid field. Cheap enough to call whenever a
## fresh flux solve lands; the render clock samples it independently.
func set_grid_field(grid: Grid, field: PackedFloat32Array, desc: FieldDescriptor) -> void:
	var img := Image.create(grid.nx, grid.ny, false, Image.FORMAT_RGB8)
	for j in grid.ny:
		for i in grid.nx:
			img.set_pixel(i, j, desc.color(field[j * grid.nx + i]))
	_tex = ImageTexture.create_from_image(img)
	_rect = Rect2(grid.ox, grid.oy, grid.nx * grid.h, grid.ny * grid.h)
	_has_field = true
	queue_redraw()


func _draw() -> void:
	if not _has_field:
		return
	# Pass 1: whole grid (vessel + reflector band), dimmed.
	draw_texture_rect(_tex, _rect, false, OUTSIDE_DIM)
	# Pass 2: vessel interior at full brightness, clipped to the silo polygon by
	# drawing the polygon itself UV-mapped into the same texture.
	var pts := _vessel_polygon()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	for p in pts:
		uvs.append(Vector2((p.x - _rect.position.x) / _rect.size.x,
				(p.y - _rect.position.y) / _rect.size.y))
		cols.append(Color.WHITE)
	draw_polygon(pts, cols, uvs, _tex)


## The silo interior outline (shell walls down through the funnel to the closed
## hopper bottom), clockwise.
static func _vessel_polygon() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(Silo.LEFT, Silo.TOP),
		Vector2(Silo.RIGHT, Silo.TOP),
		Vector2(Silo.RIGHT, Silo.FUNNEL_TOP),
		Vector2(Silo.CENTER_X + Silo.OUTLET_HALF, Silo.OUTLET_Y),
		Vector2(Silo.CENTER_X - Silo.OUTLET_HALF, Silo.OUTLET_Y),
		Vector2(Silo.LEFT, Silo.FUNNEL_TOP),
	])
