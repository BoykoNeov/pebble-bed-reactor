# game/pebble_body/pebble_body.gd
#
# The Eulerian/physics half of a pebble: a RigidBody2D circle that Godot's
# native physics drives. It carries only what it needs to BE a body and draw
# itself — all reactor state lives in the paired sim/Pebble (looked up by id).
#
# HOW IT DRAWS, and why not with _draw any more. It used to paint itself with three
# draw_circle calls and a draw_arc. Each of those is a polygon the 2D renderer cannot
# merge with the next body's, so a 428-pebble plant issued ~2,750 draw calls and
# ~150,000 primitives a frame — about 8 ms of a ~12 ms frame, measured with
# tests/live_render_perf.gd, and the reason the game could not hold its display's
# refresh rate. Now every pebble is ONE textured quad (a child Sprite2D) sharing ONE
# material and ONE texture, which is exactly the shape the renderer batches: all the
# pebbles on screen collapse into a handful of draw calls, and nothing per-frame runs in
# script to make that happen — the engine moves the sprite with the body.
#
# The ball itself is drawn by the shader from the quad's UV, not from pixels: an
# anti-aliased disc lit as a sphere by a light fixed in SCREEN space (up-left), so the
# highlight does not spin when the body rolls, plus a faint mark that DOES rotate with
# the body — which is what makes the granular flow legible as pebbles rolling over each
# other rather than discs sliding. The shading multiplies the tint, so the dominant colour
# on screen stays the FIELD colour the per-pebble heatmaps assign (the shading is a depth
# cue, not information).
class_name PebbleBody
extends RigidBody2D

const DEFAULT_TINT := Color(0.75, 0.78, 0.82)  # graphite grey (no field selected)
# Side of the shared placeholder texture the quad is sized from (the shader never
# samples it; it only gives the sprite a rect to scale).
const QUAD_PX := 16.0

const BALL_SHADER := """
shader_type canvas_item;

// Light direction in SCREEN space (up-left, out of the screen). Fixed here on purpose:
// a highlight that rotated with the body would read as the body wobbling, not rolling.
const vec3 LIGHT_DIR = vec3(-0.45, -0.45, 0.78);

varying float rot;   // the body's world rotation, so the lighting can be un-rotated

void vertex() {
	rot = atan(MODEL_MATRIX[0].y, MODEL_MATRIX[0].x);
}

void fragment() {
	// -1..1 across the quad, in the BODY frame (rotates with it).
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	// Anti-aliased disc edge, one screen pixel wide, kept inside the quad.
	float aa = max(fwidth(r), 1e-4);
	float cover = 1.0 - smoothstep(1.0 - 2.0 * aa, 1.0, r);
	// The same point in SCREEN orientation, for the fake sphere normal.
	float c = cos(rot);
	float s = sin(rot);
	vec2 q = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
	float nz = sqrt(max(1.0 - dot(q, q), 0.0));
	vec3 n = vec3(q, nz);
	vec3 l = normalize(LIGHT_DIR);
	float diff = max(dot(n, l), 0.0);
	// Ambient + diffuse, with a darker rim so neighbouring pebbles separate.
	float shade = 0.55 + 0.45 * diff;
	// A small, soft specular; additive so it reads as a highlight on any tint.
	vec3 h = normalize(l + vec3(0.0, 0.0, 1.0));
	float spec = pow(max(dot(n, h), 0.0), 28.0) * 0.22;
	// The rolling mark: a faint darker spot off-centre in the body frame.
	float mark = 1.0 - 0.12 * (1.0 - smoothstep(0.16, 0.24, length(p - vec2(0.42, 0.0))));
	vec3 col = COLOR.rgb * shade * mark + vec3(spec);
	COLOR = vec4(col, COLOR.a * cover);
}
"""

static var _shared_tex: ImageTexture
static var _shared_mat: ShaderMaterial

var radius: float = 8.0
var tint: Color = DEFAULT_TINT  # recolored per-pebble by the field viz (M3+)

var _shape: CircleShape2D
var _sprite: Sprite2D


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

	# One texture and one material for EVERY pebble — sharing them is what lets the
	# renderer draw all the bodies in one batch (see the header).
	if _shared_tex == null:
		var img := Image.create(int(QUAD_PX), int(QUAD_PX), false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_shared_tex = ImageTexture.create_from_image(img)
		var sh := Shader.new()
		sh.code = BALL_SHADER
		_shared_mat = ShaderMaterial.new()
		_shared_mat.shader = sh
	_sprite = Sprite2D.new()
	_sprite.texture = _shared_tex
	_sprite.material = _shared_mat
	_sprite.scale = Vector2.ONE * (2.0 * radius / QUAD_PX)
	_sprite.self_modulate = tint
	add_child(_sprite)


## Recolor for the per-pebble field heatmap. Only touches the sprite on an actual
## change so the render clock isn't re-modulating hundreds of unchanged bodies.
func set_tint(color: Color) -> void:
	if color == tint:
		return
	tint = color
	_sprite.self_modulate = color
