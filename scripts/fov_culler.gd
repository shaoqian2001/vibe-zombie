extends Node

## Vision-shadow system.
##
## Casts a soft, world-space shadow over every fragment that falls
## outside the player's view sector — buildings, roads, sidewalks,
## enemies, pickups and mission markers all darken together. The shadow
## is rendered by `shaders/vision_shadow.gdshader`, applied as a
## material_overlay on every relevant MeshInstance3D, with uniforms
## driven by this script from the player's per-frame pose.
##
## Smoothness is built into the shader: the angular and distance edges
## of the sector use smoothstep bands, so an entity sliding from inside
## to outside the cone fades gradually rather than popping. As the
## player rotates, surfaces near the angular boundary cross through the
## same smoothstep, giving a temporal fade for free.
##
## The classifier still publishes a discrete IN / FADED / HIDDEN state
## per cullable node, because gameplay code reads it:
##   • enemy.gd uses State.IN to decide when to chase rather than wander.
##   • main.gd uses State.IN to suppress occlusion fading for buildings
##     that the shader is already darkening.
##
## A cullable node is currently considered:
##   • IN     — inside the sector (gameplay treats it as visible).
##   • FADED  — outside the sector but within memory range. Visually it's
##              just shadow; gameplay treats it as "not currently seen."
##   • HIDDEN — outside the sector and past memory range. Only applied
##              to entities tagged "moving" (enemies); these stop being
##              rendered entirely so an off-screen zombie cannot leak its
##              silhouette through the shadow.
##
## Per-entity metadata read from the `fov_cullable` group:
##   • fov_cull_radius          — bounding-sphere radius (default 0.5).
##   • fov_cull_center          — optional Vector2 XZ override for nodes
##                                whose own global_position isn't the
##                                logical culling centre (e.g. a Node3D
##                                container sitting at world origin).
##   • fov_cull_entity_type     — "static" (default) or "moving". Only
##                                "moving" entities can reach HIDDEN.
##   • fov_cull_memory_range    — world-unit cut-off past which moving
##                                entities are fully hidden. Defaults to
##                                roughly 1.6× view_distance.

const META_RADIUS          := &"fov_cull_radius"
const META_CENTER          := &"fov_cull_center"
const META_TYPE            := &"fov_cull_entity_type"
const META_MEMORY_RANGE    := &"fov_cull_memory_range"
const META_LAST_STATE      := &"fov_cull_last_state"
const GROUP                := &"fov_cullable"
## Tag a Node3D with this meta to skip the shadow overlay on its subtree
## (e.g. the local player's own body — it sits at the FOV apex and
## shouldn't darken itself).
const META_SHADOW_EXEMPT   := &"vision_shadow_exempt"

enum State { IN, FADED, HIDDEN }

# ---------------------------------------------------------------------
# Shader / overlay configuration
# ---------------------------------------------------------------------
#
# The angular / distance smoothstep bands set how soft the FOV edge is.
# Wider bands feel more cinematic and forgive fast camera turns, but
# also leak more light/zombie-silhouette across the boundary. These
# defaults give an obvious-but-not-jarring transition over roughly
# 10° of yaw and 4 m of depth.
const SHADER_PATH      := "res://shaders/vision_shadow.gdshader"
const ANGLE_BAND_RAD   := 0.18   # ~10° each side of the sector edge
const DIST_BAND        := 4.0    # 4 world-units around the far edge
const SHADOW_ALPHA     := 0.85   # peak darkness of out-of-vision shadow

var _player: Node3D = null
var _fov_overlay: Node = null

# A single ShaderMaterial shared by every mesh's material_overlay slot.
# Updating its uniforms once a frame is enough to drive the whole world.
static var _shadow_material: ShaderMaterial = null

func configure(player: Node3D, fov_overlay: Node) -> void:
	_player = player
	_fov_overlay = fov_overlay
	# Mark the player so apply_shader_to_subtree() called on parent nodes
	# later won't accidentally pull the player's own meshes into the shadow.
	if _player != null:
		_player.set_meta(META_SHADOW_EXEMPT, true)

## Convenience for other systems (e.g. building occlusion) that need to
## know the current state of a cullable node without re-computing it.
static func current_state(node: Node3D) -> int:
	return int(node.get_meta(META_LAST_STATE, State.IN))

## Lazily build the shared shadow material. Returns null if the shader
## resource is missing (e.g. during very early bootstrap), which lets
## callers no-op safely.
static func get_shadow_material() -> ShaderMaterial:
	if _shadow_material != null:
		return _shadow_material
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("FovCuller: missing %s; vision shadow disabled" % SHADER_PATH)
		return null
	_shadow_material = ShaderMaterial.new()
	_shadow_material.shader = shader
	_shadow_material.set_shader_parameter("angle_band", ANGLE_BAND_RAD)
	_shadow_material.set_shader_parameter("dist_band", DIST_BAND)
	_shadow_material.set_shader_parameter("shadow_alpha", SHADOW_ALPHA)
	return _shadow_material

## Walk a Node3D subtree and attach the shared shadow material to every
## MeshInstance3D's material_overlay slot. Skips subtrees rooted at any
## node tagged META_SHADOW_EXEMPT so the local player can opt out.
static func apply_shader_to_subtree(root: Node) -> void:
	var mat := get_shadow_material()
	if mat == null:
		return
	_apply_shader_recursive(root, mat)

static func _apply_shader_recursive(node: Node, mat: ShaderMaterial) -> void:
	if node is Node3D and node.has_meta(META_SHADOW_EXEMPT):
		return
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		# Don't trample an existing overlay — some assets (HP bars, glow
		# discs) deliberately use their own. Only fill the slot when it's
		# untouched, so a single recursive sweep stays idempotent.
		if mi.material_overlay == null:
			mi.material_overlay = mat
	for child in node.get_children():
		_apply_shader_recursive(child, mat)

func _process(_delta: float) -> void:
	if _player == null or _fov_overlay == null:
		return

	var fov_deg: float = _fov_overlay.fov_degrees
	var view_dist: float = _fov_overlay.view_distance

	var ppos := _player.global_position
	var head_xz := Vector2(ppos.x, ppos.z)

	var fwd3 := _player.global_transform.basis.z
	var facing := Vector2(fwd3.x, fwd3.z)
	if facing.length_squared() < 0.0001:
		facing = Vector2(0.0, 1.0)
	facing = facing.normalized()

	var half_rad := deg_to_rad(fov_deg * 0.5)
	var default_memory_range := view_dist * 1.6

	# Push the live sector into the shared shadow material so every mesh
	# in the world re-derives its per-fragment shadow this frame.
	var mat := get_shadow_material()
	if mat != null:
		mat.set_shader_parameter("player_pos", ppos)
		mat.set_shader_parameter("facing", facing)
		mat.set_shader_parameter("half_angle", half_rad)
		mat.set_shader_parameter("view_distance", view_dist)

	var tree := get_tree()
	if tree == null:
		return

	# Classifier: still publishes IN/FADED/HIDDEN for gameplay queries
	# (zombie chase mode, building-occlusion suppression). Visual fading
	# is owned by the shader, so we no longer touch material alpha here.
	for node in tree.get_nodes_in_group(GROUP):
		if not is_instance_valid(node):
			continue
		var n3 := node as Node3D
		if n3 == null:
			continue

		var radius: float = float(n3.get_meta(META_RADIUS, 0.5))
		var entity_type: String = str(n3.get_meta(META_TYPE, "static"))
		var memory_range: float = float(n3.get_meta(META_MEMORY_RANGE, default_memory_range))

		var p_xz: Vector2
		if n3.has_meta(META_CENTER):
			p_xz = n3.get_meta(META_CENTER)
		else:
			p_xz = Vector2(n3.global_position.x, n3.global_position.z)

		var state := _classify(p_xz, radius, head_xz, facing, half_rad,
		                       view_dist, entity_type, memory_range)

		var last_state: int = int(n3.get_meta(META_LAST_STATE, -1))
		if state != last_state:
			_apply_state(n3, state)
			n3.set_meta(META_LAST_STATE, state)

static func _classify(p_xz: Vector2, radius: float, head_xz: Vector2,
                      facing: Vector2, half_rad: float, view_dist: float,
                      entity_type: String, memory_range: float) -> int:
	if _point_in_fov(p_xz, radius, head_xz, facing, half_rad, view_dist):
		return State.IN
	if entity_type == "moving":
		var dist := (p_xz - head_xz).length()
		if dist > memory_range + radius:
			return State.HIDDEN
	return State.FADED

static func _apply_state(node: Node3D, state: int) -> void:
	# Visual darkening is the shader's job — the only thing we still own
	# here is hard-hiding moving entities that drift past memory range,
	# so an off-screen zombie can't leak a silhouette through the shadow.
	node.visible = state != State.HIDDEN

# Returns true if any part of a bounding-sphere of `radius` at `p_xz`
# falls inside the player's view sector. Passing radius=0 degenerates to
# a pure point test.
static func _point_in_fov(p_xz: Vector2, radius: float, head_xz: Vector2,
                          facing: Vector2, half_rad: float, view_dist: float) -> bool:
	var delta := p_xz - head_xz
	var dist_sq := delta.length_squared()
	var max_dist := view_dist + radius
	if dist_sq > max_dist * max_dist:
		return false

	# If the head is inside the bounding sphere, the object straddles the
	# apex and is always visible (otherwise the player would be standing in
	# a hidden object).
	if dist_sq <= radius * radius:
		return true

	var dist := sqrt(dist_sq)
	var dir := delta / dist
	var ang := absf(facing.angle_to(dir))
	# Widen the angular window by the half-angle subtended by the sphere at
	# this distance, so objects whose centre is just outside the sector but
	# whose body crosses the edge still count as visible.
	var ang_tolerance := half_rad + asin(clampf(radius / dist, 0.0, 1.0))
	return ang <= ang_tolerance
