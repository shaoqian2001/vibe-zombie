extends CanvasLayer

## FOV fog-of-war overlay.
## Projects a world-space pie-slice (facing direction ± fov_degrees/2, radius
## view_distance) to screen space each frame and passes it to the shader as a
## polygon. Pixels outside the polygon are darkened; inside are transparent.
##
## Human-eyesight defaults: 145° horizontal FOV, ~50 world units (~200 m at
## the game's approximate 1 unit = 4 m scale).

@export var fov_degrees: float = 145.0
@export var view_distance: float = 50.0
## World-unit distance to move the cone apex behind the player so the
## character model is fully visible inside the sector. Keep this just large
## enough to cover the player's half-depth — any more looks unnatural.
@export var center_back_offset: float = 1.0

const ARC_SEGMENTS := 32
const N_VERTS := ARC_SEGMENTS + 2  # 1 center + (ARC_SEGMENTS + 1) arc pts = 34

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

	var half_rad   := deg_to_rad(fov_degrees * 0.5)
	var base_angle := atan2(facing.y, facing.x)

	# Shift the apex behind the player so the character model falls inside
	# the visible sector instead of sitting right at its sharp point.
	var apex_xz  := Vector2(ppos.x, ppos.z) - facing * center_back_offset
	var apex_3d  := Vector3(apex_xz.x, ppos.y, apex_xz.y)
	var apex_px  := _camera.unproject_position(apex_3d)  # still in pixel space

	var polygon := PackedVector2Array()
	polygon.resize(N_VERTS)

	# Vertex 0: shifted apex (pixel space; normalised at the end)
	polygon[0] = apex_px

	# Vertices 1 .. N_VERTS-1: arc swept ±half_rad, radius measured from ppos
	for i in range(ARC_SEGMENTS + 1):
		var t := float(i) / float(ARC_SEGMENTS)
		var angle := base_angle - half_rad + t * (half_rad * 2.0)
		var dir_xz := Vector2(cos(angle), sin(angle))
		var world_xz := Vector2(ppos.x, ppos.z) + dir_xz * view_distance
		var world3d := Vector3(world_xz.x, 0.0, world_xz.y)
		polygon[i + 1] = _safe_project(world3d, apex_px, dir_xz)

	# Normalise all vertices to UV [0,1] before uploading to the shader.
	for i in range(N_VERTS):
		polygon[i] = polygon[i] / vp_size

	_mat.set_shader_parameter("fov_polygon", polygon)

# Project a world point to screen. If the point is behind the camera, fall back
# to an off-screen position in the approximate screen direction so the polygon
# winding remains sensible.
func _safe_project(world3d: Vector3, player_screen: Vector2, world_dir_xz: Vector2) -> Vector2:
	var cam_fwd := -_camera.global_transform.basis.z
	var to_point := world3d - _camera.global_position
	if to_point.dot(cam_fwd) > 0.1:
		return _camera.unproject_position(world3d)

	# Point is behind the camera. Walk toward the player along the arc direction
	# until we find a point in front of the camera, then extend off screen.
	var ppos := _player.global_position
	var dir3 := Vector3(world_dir_xz.x, 0.0, world_dir_xz.y)
	var steps: Array[float] = [0.5, 0.25, 0.1]
	for step: float in steps:
		var probe: Vector3 = ppos + dir3 * (view_distance * step)
		if (probe - _camera.global_position).dot(cam_fwd) > 0.1:
			var probe_screen := _camera.unproject_position(probe)
			var screen_dir := (probe_screen - player_screen).normalized()
			return player_screen + screen_dir * 3000.0

	# Ultimate fallback: guess direction from world XZ to screen XY
	# (approximate: camera yaw ~45° means +X_world ≈ screen right+down,
	#  +Z_world ≈ screen right+up — heuristic only used when fully behind camera)
	var approx := Vector2(world_dir_xz.x - world_dir_xz.y,
	                      -world_dir_xz.x - world_dir_xz.y).normalized()
	return player_screen + approx * 3000.0
