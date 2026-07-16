# tests/test_silo.gd
#
# Headless geometry gate for the vessel shell. Runs pure (no scene, no physics) via:
#   godot --headless --script res://tests/test_silo.gd
#
# WHY this test exists at all, for what is "only drawing": the shell was given real
# thickness, and the ONE way that change could do damage is by growing INWARD. The inner
# faces are the physics (Silo.wall_segments), and the bed volume they enclose is what
# TARGET_POPULATION, A_REF and the whole M4/M5 operating point were calibrated against —
# so a shell that ate even a few px of bed would shift k with no other test noticing. The
# existing suites all drive sim/ directly and never build a silo; they would stay green.
#
# So this pins the two properties the drawing must have:
#   1. wall_segments() — the physics — is EXACTLY the inner profile, still, unchanged.
#   2. No part of the shell intrudes into the bed. Not "looks fine": every shell vertex is
#      tested against the vessel interior polygon, and every outer vertex is proven to lie
#      the full wall thickness along the OUTWARD normal.
# Plus a clearance check tying WALL_T to the M5d rod channels it must not swallow, so a
# future retune of either one cannot silently hide the rods behind the vessel wall.
extends SceneTree

var _failures := 0


func _initialize() -> void:
	print("=== vessel shell geometry ===")
	_test_profile_matches_collision()
	_test_shell_never_intrudes_into_the_bed()
	_test_offset_is_outward_by_exactly_the_thickness()
	_test_shell_clears_the_rod_channels()
	if _failures > 0:
		print("\n%d CHECK(S) FAILED" % _failures)
		quit(1)
	else:
		print("\nALL CHECKS PASSED")
		quit(0)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  PASS  %s" % what)
	else:
		print("  FAIL  %s" % what)
		_failures += 1


## The drawn shell derives from inner_profile(); the physics collides on wall_segments().
## If those two ever describe different shapes, the wall the player sees is not the wall
## the pebbles hit. Pin them together by reconstructing one from the other.
func _test_profile_matches_collision() -> void:
	var profile := Silo.inner_profile()
	var segs := Silo.wall_segments()
	# Every consecutive pair of the profile must be a real collision segment (in either
	# orientation — wall_segments lists the right funnel top-down, the profile walks it
	# bottom-up, and a segment collides the same both ways).
	var matched := 0
	for i in range(profile.size() - 1):
		for s in segs:
			var fwd: bool = s[0].is_equal_approx(profile[i]) and s[1].is_equal_approx(profile[i + 1])
			var rev: bool = s[1].is_equal_approx(profile[i]) and s[0].is_equal_approx(profile[i + 1])
			if fwd or rev:
				matched += 1
				break
	_check(matched == profile.size() - 1 and matched == segs.size(),
			"inner profile is exactly the collision geometry (%d/%d segments)" % [matched, segs.size()])


## The load-bearing one: nothing the shell draws may sit inside the bed.
func _test_shell_never_intrudes_into_the_bed() -> void:
	var interior := _interior_polygon()
	var worst := ""
	var intrusions := 0
	for quad in Silo.shell_quads():
		# The outer pair (indices 2, 3) are the offset vertices — the ones that moved.
		for k in [2, 3]:
			var p: Vector2 = quad[k]
			if Geometry2D.is_point_in_polygon(p, interior):
				intrusions += 1
				worst = "%s" % p
	_check(intrusions == 0,
			"no shell vertex intrudes into the bed interior%s" % ("" if intrusions == 0
					else " — %d did, e.g. %s" % [intrusions, worst]))

	# Stronger than the vertex test: sample ALONG each outer edge, so a quad cannot pass by
	# having compliant corners and a bowed edge cutting the corner of the bed.
	var edge_hits := 0
	for quad in Silo.shell_quads():
		for s in 21:
			var p: Vector2 = quad[3].lerp(quad[2], float(s) / 20.0)
			if Geometry2D.is_point_in_polygon(p, interior):
				edge_hits += 1
	_check(edge_hits == 0, "no point along any outer wall face enters the bed (%d samples clear)"
			% (Silo.shell_quads().size() * 21))


## Prove the offset is the intended one: each outer vertex lies WALL_T along the outward
## normal of its face, i.e. the wall is uniformly thick and grew in the right direction.
func _test_offset_is_outward_by_exactly_the_thickness() -> void:
	var worst_err := 0.0
	var min_outward := INF
	for quad in Silo.shell_quads():
		var a: Vector2 = quad[0]
		var b: Vector2 = quad[1]
		var d := (b - a).normalized()
		var n := Vector2(-d.y, d.x)   # the outward normal, per Silo._outward
		for pair in [[a, quad[3]], [b, quad[2]]]:
			var inner: Vector2 = pair[0]
			var outer: Vector2 = pair[1]
			var off := outer - inner
			# Distance from the inner FACE (perpendicular component) must be the thickness;
			# the mitre is free to slide the vertex ALONG the face, which is why this
			# projects rather than comparing raw distance.
			var perp := off.dot(n)
			worst_err = maxf(worst_err, absf(perp - Silo.WALL_T))
			min_outward = minf(min_outward, perp)
	_check(worst_err < 0.001,
			"every wall face is exactly WALL_T (%.0f px) thick (worst error %.5f px)"
					% [Silo.WALL_T, worst_err])
	_check(min_outward > 0.0,
			"every offset is strictly OUTWARD — the bed cannot have shrunk (min %.2f px)"
					% min_outward)


## The shell must not grow into the M5d rod channels. The rods are in the side reflector
## precisely so the player can SEE them beside the bed; a wall thick enough to cover them
## would erase the geometry lesson. Derived from the grid + ControlRods themselves, so
## retuning WALL_T, the cell size, or the reflector band all get caught here.
func _test_shell_clears_the_rod_channels() -> void:
	var grid := Grid.for_silo()
	var cols := ControlRods.rod_columns(grid)
	_check(cols.size() == 2, "the reference grid has a symmetric rod bank to clear")
	if cols.size() != 2:
		return
	# Half-width of a drawn rod channel (main.gd ROD_W = 13).
	var rod_half := 6.5
	var gap := INF
	for i in cols:
		var cx: float = grid.ox + (float(i) + 0.5) * grid.h
		# Nearest vertical wall face to this column, grown outward by the shell.
		var wall_outer: float = (Silo.LEFT - Silo.WALL_T) if cx < Silo.CENTER_X else (Silo.RIGHT + Silo.WALL_T)
		gap = minf(gap, absf(wall_outer - cx) - rod_half)
	_check(gap > 2.0, "the shell leaves the rod channels visible (clearance %.1f px)" % gap)


## The vessel interior as a closed polygon: the inner profile, closed across the open top.
static func _interior_polygon() -> PackedVector2Array:
	var poly := Silo.inner_profile()
	# inner_profile runs top-left → around the funnel → top-right; closing the ring is
	# just the open top edge back to the start, which Geometry2D does implicitly.
	return poly
