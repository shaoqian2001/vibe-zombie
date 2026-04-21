extends CanvasLayer

## FOV fog-of-war overlay.
## Projects a world-space lens (the intersection of two circles) to screen
## space each frame and passes it to the shader as a polygon. Pixels outside
## the polygon are darkened; inside are transparent.
##
## The lens is defined by an apex at the character's head and a tip one
## view_distance ahead along the facing direction. Two circular arcs, bulging
## symmetrically to the left and right, connect them — so both lateral
## boundaries of the vision area are curved instead of the straight edges of
## a pie-slice. Placing the apex at the head (instead of between the feet)
## keeps the character's model fully inside the unshaded region regardless of
## facing direction, while the lens shape avoids the unnatural sharp point a
## sector has at its vertex.
##
## Human-eyesight defaults: 145° opening angle at the apex, ~50 world units
## (~200 m at the game's approximate 1 unit = 4 m scale).

@export var fov_degrees: float = 145.0
@export var view_distance: float = 50.0
## World-unit height of the character's eyes above the player's root position.
## The lens apex is anchored at this height so it aligns with where the head
## is rendered on screen.
@export var head_height: float = 1.6

const ARC_SEGMENTS := 16                      # samples per arc
const N_VERTS := (ARC_SEGMENTS + 1) * 2       # 34: two arcs, endpoints duplicated

var _player: Node3D = null
var _camera: Camera3D = null
var _mat: ShaderMaterial = null

func configure(player: Node3D, camera: Camera3D) -> void:
	_player = player
	_camera = camera

func _ready() -> void:
	layer = 1  # same layer as HUD; added to tree first so it renders below HUD

	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/fov.gdshader") as Shader
	rect.material = _mat
	add_child(rect)

func _process(_delta: float) -> void:
	if _player == null or _camera == null or _mat == null:
		return

	# Viewport size used to normalise pixel coords → UV [0,1], matching the
	# shader which uses UV rather than FRAGCOORD to avoid physical-vs-logical
	# pixel mismatches under canvas_items stretch mode.
	var vp_size := get_viewport().get_visible_rect().size

	var ppos := _player.global_position
	var fwd3 := _player.global_transform.basis.z
	var facing := Vector2(fwd3.x, fwd3.z)
	if facing.length_squared() < 0.0001:
		facing = Vector2(0.0, 1.0)
	facing = facing.normalized()

	# Lens geometry in world XZ.
	#   A = apex (at the character's head, projected to XZ)
	#   T = tip  (view_distance ahead of A along facing)
	#   2α = opening angle between the two arcs at A (and by symmetry at T),
	#        which is what fov_degrees parameterises.
	# Each arc is part of a circle whose chord is AT and whose inscribed
	# central angle is 2α; the arc's tangent at the chord endpoints makes
	# angle α with the chord.
	var head_xz := Vector2(ppos.x, ppos.z)

	var alpha := deg_to_rad(fov_degrees * 0.5)
	# Guard against degenerate angles (near 0° or 180°).
	alpha = clamp(alpha, deg_to_rad(5.0), deg_to_rad(88.0))
	var sin_a := sin(alpha)
	var cos_a := cos(alpha)

	var chord_len := view_distance
	var radius := chord_len / (2.0 * sin_a)
	var half_chord := chord_len * 0.5
	var center_offset := radius * cos_a   # distance from chord midpoint to arc center

	var mid_xz := head_xz + facing * half_chord
	# Perpendicular to facing, rotated 90° CCW in XZ.
	var perp := Vector2(-facing.y, facing.x)

	# Right-bulge arc: centre on the opposite (left) side of AT.
	var center_right := mid_xz - perp * center_offset
	# Left-bulge arc: centre on the opposite (right) side of AT.
	var center_left  := mid_xz + perp * center_offset

	# Angles (in the XZ polar frame the shader doesn't see — we only use them
	# to sample points on each circle) that correspond to A and T as seen
	# from each arc's centre.
	var base_angle := atan2(facing.y, facing.x)
	# From center_right, A lies at (base_angle + 90° + α) and T at
	# (base_angle + 90° - α). We sweep the short arc between them, which
	# passes through the outward (right-side) bulge point at (base_angle + 90°).
	var right_a_ang := base_angle + PI * 0.5 + alpha
	var right_t_ang := base_angle + PI * 0.5 - alpha
	# From center_left, the same but mirrored through the chord.
	var left_a_ang  := base_angle - PI * 0.5 - alpha
	var left_t_ang  := base_angle - PI * 0.5 + alpha

	# Anchor the lens at head height so the apex projects to where the head
	# is actually rendered on screen. Using a constant Y for every vertex
	# keeps the polygon a planar horizontal slice, which is what the
	# isometric-style camera expects.
	var y_lens := ppos.y + head_height
	var head3d := Vector3(head_xz.x, y_lens, head_xz.y)

	# Pre-computed head screen position used as the fallback anchor when an
	# arc vertex happens to lie behind the camera.
	var cam_fwd := -_camera.global_transform.basis.z
	var head_screen: Vector2
	if (head3d - _camera.global_position).dot(cam_fwd) > 0.1:
		head_screen = _camera.unproject_position(head3d)
	else:
		head_screen = vp_size * 0.5

	var polygon := PackedVector2Array()
	polygon.resize(N_VERTS)

	# Arc 1: right-bulge, A → T.
	for i in range(ARC_SEGMENTS + 1):
		var t := float(i) / float(ARC_SEGMENTS)
		var ang: float = lerp(right_a_ang, right_t_ang, t)
		var pt_xz := center_right + Vector2(cos(ang), sin(ang)) * radius
		var pt3d  := Vector3(pt_xz.x, y_lens, pt_xz.y)
		var dir_xz := pt_xz - head_xz
		if dir_xz.length_squared() < 0.0001:
			dir_xz = facing
		polygon[i] = _safe_project(pt3d, dir_xz.normalized(), head_screen, y_lens)

	# Arc 2: left-bulge, T → A (so the polygon winds continuously).
	for i in range(ARC_SEGMENTS + 1):
		var t := float(i) / float(ARC_SEGMENTS)
		var ang: float = lerp(left_t_ang, left_a_ang, t)
		var pt_xz := center_left + Vector2(cos(ang), sin(ang)) * radius
		var pt3d  := Vector3(pt_xz.x, y_lens, pt_xz.y)
		var dir_xz := pt_xz - head_xz
		if dir_xz.length_squared() < 0.0001:
			dir_xz = -facing
		polygon[ARC_SEGMENTS + 1 + i] = _safe_project(pt3d, dir_xz.normalized(), head_screen, y_lens)

	# Normalise all vertices to UV [0,1] before uploading to the shader.
	for i in range(N_VERTS):
		polygon[i] = polygon[i] / vp_size

	_mat.set_shader_parameter("fov_polygon", polygon)

# Project a world point to screen. If the point is behind the camera, fall back
# to an off-screen position in the approximate screen direction so the polygon
# winding remains sensible.
func _safe_project(world3d: Vector3, world_dir_xz: Vector2, head_screen: Vector2, y_lens: float) -> Vector2:
	var cam_fwd := -_camera.global_transform.basis.z
	var to_point := world3d - _camera.global_position
	if to_point.dot(cam_fwd) > 0.1:
		return _camera.unproject_position(world3d)

	# Point is behind the camera. Walk toward the head along the arc direction
	# until we find a probe point in front of the camera, then extend off screen.
	var ppos := _player.global_position
	var head_xz := Vector2(ppos.x, ppos.z)
	var steps: Array[float] = [0.5, 0.25, 0.1]
	for step: float in steps:
		var probe_xz: Vector2 = head_xz + world_dir_xz * (view_distance * step)
		var probe := Vector3(probe_xz.x, y_lens, probe_xz.y)
		if (probe - _camera.global_position).dot(cam_fwd) > 0.1:
			var probe_screen := _camera.unproject_position(probe)
			var screen_dir := (probe_screen - head_screen).normalized()
			return head_screen + screen_dir * 3000.0

	var approx := Vector2(world_dir_xz.x - world_dir_xz.y,
	                      -world_dir_xz.x - world_dir_xz.y).normalized()
	return head_screen + approx * 3000.0
