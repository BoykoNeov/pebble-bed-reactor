# game/visualization/color_bar.gd
#
# The legend for whatever field is on screen (CLAUDE.md: "always show a
# colorbar/legend with units — a heatmap without a scale is unreadable"). A
# screen-fixed Control on the HUD, driven from the same FieldDescriptor as the
# heatmap so the scale can never drift out of sync with the colors: the gradient
# samples desc.color and the tick labels go through desc.value_at — the exact
# mappings the renderer uses.
class_name ColorBar
extends Control

const BAR_W := 24.0
const BAR_H := 240.0
const STEPS := 64        # discrete bands sampled up the gradient
const TICKS := 5         # labeled ticks from vmin to vmax
const PAD := 12.0
const TITLE_H := 40.0    # room above the bar for a two-line title
const PANEL_W := 158.0

var _desc: FieldDescriptor
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	custom_minimum_size = Vector2(PANEL_W, TITLE_H + BAR_H + 2.0 * PAD)


func set_descriptor(desc: FieldDescriptor) -> void:
	_desc = desc
	queue_redraw()


func _draw() -> void:
	if _desc == null:
		return
	# Translucent panel so the legend reads over whatever the field shows.
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.04, 0.05, 0.08, 0.82)
	panel.border_color = Color(0.35, 0.42, 0.55, 0.5)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(6)
	draw_style_box(panel, Rect2(Vector2.ZERO, custom_minimum_size))

	var x := PAD
	var y := PAD + TITLE_H
	var fs := 13

	# Title: field name, units on their own line under it.
	draw_string(_font, Vector2(x, PAD + 14.0), _desc.name,
			HORIZONTAL_ALIGNMENT_LEFT, PANEL_W - 2.0 * PAD, fs, Color(0.91, 0.94, 0.98))
	if _desc.units != "":
		draw_string(_font, Vector2(x, PAD + 30.0), "[%s]" % _desc.units,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color(0.55, 0.62, 0.72))

	# Gradient bar, high value at the top down to low — through the SAME
	# descriptor mapping as the heatmap (value_at then color).
	var band := BAR_H / STEPS
	for s in STEPS:
		var t := 1.0 - float(s) / (STEPS - 1)
		draw_rect(Rect2(x, y + s * band, BAR_W, band + 1.0), _desc.color(_desc.value_at(t)))
	draw_rect(Rect2(x, y, BAR_W, BAR_H), Color(1, 1, 1, 0.4), false, 1.0)

	# Ticks: evenly spaced in NORMALIZED position, labeled with the raw value at
	# that position — so log / pivot mappings label honestly.
	for k in TICKS:
		var t := 1.0 - float(k) / (TICKS - 1)
		var ty := y + (float(k) / (TICKS - 1)) * BAR_H
		draw_line(Vector2(x + BAR_W, ty), Vector2(x + BAR_W + 5.0, ty), Color(1, 1, 1, 0.55), 1.0)
		draw_string(_font, Vector2(x + BAR_W + 9.0, ty + 4.0), _fmt(_desc.value_at(t)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color(0.78, 0.83, 0.9))

	# Diverging pivot marker: the physically meaningful center (colormap midpoint).
	if not is_nan(_desc.pivot):
		var py := y + 0.5 * BAR_H
		draw_line(Vector2(x - 4.0, py), Vector2(x + BAR_W + 4.0, py), Color(1, 1, 1, 0.9), 2.0)


## Compact number formatting across the fields' very different magnitudes
## (xenon ~1e-5, flux ~1, temperature ~1e3) — "%.2f" alone renders the xenon
## scale as an unreadable column of 0.00.
static func _fmt(v: float) -> String:
	var a := absf(v)
	if a < 1.0e-12:
		return "0"
	if a >= 100.0:
		return "%.0f" % v
	if a >= 1.0:
		return "%.2f" % v
	if a >= 0.01:
		return "%.3f" % v
	return "%.1e" % v
