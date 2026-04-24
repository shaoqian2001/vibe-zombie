extends Node

## Project-Zomboid-style vision fade.
##
## Every frame, iterates nodes in the `fov_cullable` group and classifies
## each into one of three states based on whether its XZ position falls
## inside the player's view sector and how far away it is from the head:
##
##   • IN      — inside the sector. Rendered at full opacity.
##   • FADED   — outside the sector but still within memory range.
##               Rendered at a dimmed alpha so the player can see where
##               static scenery and recently-seen zombies were, like the
##               "ghosted" memory tiles in Project Zomboid.
##   • HIDDEN  — outside the sector and past memory range. Skipped by the
##               renderer entirely. Only applied to entities tagged as
##               "moving" (enemies); static scenery never fully hides
##               because the player remembers where buildings stand.
##
## Material alpha is applied recursively across each node's subtree —
## buildings have their body, roof ledge, windows, trim, awning and door
## meshes all fade together — and is only written on state transitions,
## not every frame, so the per-frame cost is a cheap classification pass.
## When process-pausing is enabled, entities freeze in their last FOV
## position the moment they fall out of the sector, so a FADED zombie is
## a genuine snapshot of where it was last seen.
##
## Per-entity metadata:
##   • fov_cull_radius          — bounding-sphere radius (default 0.5).
##   • fov_cull_disable_process — if true, set process_mode to DISABLED
##                                while outside the FOV. Default false.
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
const META_DISABLE_PROCESS := &"fov_cull_disable_process"
const META_CENTER          := &"fov_cull_center"
const META_TYPE            := &"fov_cull_entity_type"
const META_MEMORY_RANGE    := &"fov_cull_memory_range"
const META_LAST_STATE      := &"fov_cull_last_state"
const GROUP                := &"fov_cullable"

enum State { IN, FADED, HIDDEN }

## Alpha applied to FADED entities. Tuned to read as "remembered but
## not currently visible" — low enough to feel ghosted, high enough to
## let the player still parse outlines.
const FADE_ALPHA := 0.35

var _player: Node3D = null
var _fov_overlay: Node = null

func configure(player: Node3D, fov_overlay: Node) -> void:
	_player = player
	_fov_overlay = fov_overlay

## Convenience for other systems (e.g. building occlusion) that need to
## know the current state of a cullable node without re-computing it.
static func current_state(node: Node3D) -> int:
	return int(node.get_meta(META_LAST_STATE, State.IN))

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

	var tree := get_tree()
	if tree == null:
		return

	for node in tree.get_nodes_in_group(GROUP):
		if not is_instance_valid(node):
			continue
		var n3 := node as Node3D
		if n3 == null:
			continue

		var radius: float = float(n3.get_meta(META_RADIUS, 0.5))
		var disable_process: bool = bool(n3.get_meta(META_DISABLE_PROCESS, false))
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

		if disable_process:
			var want_mode: int = Node.PROCESS_MODE_INHERIT if state == State.IN else Node.PROCESS_MODE_DISABLED
			if n3.process_mode != want_mode:
				n3.process_mode = want_mode

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
	match state:
		State.IN:
			node.visible = true
			_set_alpha_tree(node, 1.0, false)
		State.FADED:
			node.visible = true
			_set_alpha_tree(node, FADE_ALPHA, true)
		State.HIDDEN:
			node.visible = false

# Recursively set every descendant MeshInstance3D's material alpha.
# `transparent` toggles between TRANSPARENCY_ALPHA (for the FADED ghost
# look) and TRANSPARENCY_DISABLED (restoring opaque rendering).
static func _set_alpha_tree(node: Node, alpha: float, transparent: bool) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var prim := mi.mesh as PrimitiveMesh
		if prim != null:
			var mat := prim.material as StandardMaterial3D
			if mat != null:
				if transparent:
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					mat.albedo_color.a = alpha
				else:
					mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
					mat.albedo_color.a = 1.0
	for child in node.get_children():
		_set_alpha_tree(child, alpha, transparent)

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
