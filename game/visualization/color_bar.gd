# game/visualization/color_bar.gd
#
# The legend for whatever field is on screen (CLAUDE.md: "always show a
# colorbar/legend with units — a heatmap without a scale is unreadable"). A
# screen-fixed Control on the HUD, driven from the same FieldDescriptor as the
# heatmap so the scale can never drift out of sync with the colors.
class_name ColorBar
extends Control

const BAR_W := 22.0
const BAR_H := 200.0
const STEPS := 48   # discrete bands sampled up the gradient

var _desc: FieldDescriptor
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	custom_minimum_size = Vector2(120, BAR_H + 40)


func set_descriptor(desc: FieldDescriptor) -> void:
	_desc = desc
	queue_redraw()


func _draw() -> void:
	if _desc == null:
		return
	var x := 12.0
	var y := 24.0
	# Gradient bar, high value at the top (viridis yellow) down to low (purple).
	var band := BAR_H / STEPS
	for s in STEPS:
		var t := 1.0 - float(s) / (STEPS - 1)
		draw_rect(Rect2(x, y + s * band, BAR_W, band + 1.0), Colormap.viridis(t))
	draw_rect(Rect2(x, y, BAR_W, BAR_H), Color(1, 1, 1, 0.5), false, 1.0)

	var fs := 13
	var tx := x + BAR_W + 8.0
	var title := _desc.name if _desc.units == "" else "%s (%s)" % [_desc.name, _desc.units]
	draw_string(_font, Vector2(x, y - 8.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(_font, Vector2(tx, y + 10.0), "%.2f" % _desc.vmax, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(_font, Vector2(tx, y + BAR_H), "%.2f" % _desc.vmin, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
