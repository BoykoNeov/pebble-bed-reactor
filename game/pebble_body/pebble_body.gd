# game/pebble_body/pebble_body.gd
#
# The Eulerian/physics half of a pebble: a RigidBody2D circle that Godot's
# native physics drives. It carries only what it needs to BE a body and draw
# itself — all reactor state lives in the paired sim/Pebble (looked up by id).
#
# WHY it draws itself via _draw for now: M0 just needs circles on screen. The
# generic field-visualization system (M1+, CLAUDE.md) will later recolor these
# per-pebble (burnup, temperature, xenon); exposing `tint` keeps that door open
# without pulling in a renderer today.
class_name PebbleBody
extends RigidBody2D

const DEFAULT_TINT := Color(0.75, 0.78, 0.82)  # graphite grey (no field selected)

var radius: float = 8.0
var tint: Color = DEFAULT_TINT  # recolored per-pebble by the field viz (M3+)

var _shape: CircleShape2D


func configure(p_radius: float) -> void:
	radius = p_radius
	var col := CollisionShape2D.new()
	_shape = CircleShape2D.new()
	_shape.radius = radius
	col.shape = _shape
	add_child(col)
	# Slight damping so granular stacking settles instead of jittering forever
	# (CLAUDE.md pitfall: stacking is spongy/jittery — favour quiet settling).
	linear_damp = 0.4
	angular_damp = 0.6


## Recolor for the per-pebble field heatmap. Only redraws on an actual change so
## the render clock isn't repainting hundreds of unchanged bodies every frame.
func set_tint(color: Color) -> void:
	if color == tint:
		return
	tint = color
	queue_redraw()


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, tint)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 20, Color(0, 0, 0, 0.25), 1.0, true)
