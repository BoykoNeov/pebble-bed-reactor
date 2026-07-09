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
class_name FieldDisplay
extends Node2D

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
			var t := desc.normalize(field[j * grid.nx + i])
			img.set_pixel(i, j, Colormap.viridis(t))
	_tex = ImageTexture.create_from_image(img)
	_rect = Rect2(grid.ox, grid.oy, grid.nx * grid.h, grid.ny * grid.h)
	_has_field = true
	queue_redraw()


func _draw() -> void:
	if _has_field:
		draw_texture_rect(_tex, _rect, false)
