extends Node

## Culls nodes outside the player's FOV sector.
##
## Every frame, iterates nodes in the `fov_cullable` group and toggles their
## `visible` property based on whether their world XZ position falls inside
## the sector defined by the matching `fov_overlay`'s apex, facing direction,
## FOV angle and view distance. This keeps the visible-set in sync with what
## the on-screen fog-of-war darkens, so hidden areas also stop issuing GPU
## draw calls (they are not just shaded black — their meshes skip rendering
## entirely, including shadows).
##
## Per-entity tuning via node metadata:
##   • fov_cull_radius          — bounding-sphere radius in world units. The
##                                entity is considered visible as long as any
##                                point of this sphere overlaps the sector.
##                                Default 0.5 (point-sized). For extended
##                                objects like buildings, set to the XZ half-
##                                extent + a small margin so the whole object
##                                pops in before its centre does.
##   • fov_cull_disable_process — if true, also sets process_mode to
##                                DISABLED while the node is outside the FOV
##                                so _process / _physics_process stop running.
##                                Good for purely visual animations (pickup
##                                bobbing) or AI that is safe to freeze while
##                                off-screen. Default false.
##
## All geometry is computed in world XZ at head height, matching the visual
## overlay's sector, so culling boundaries line up with the fog edge.

const META_RADIUS         := &"fov_cull_radius"
const META_DISABLE_PROCESS := &"fov_cull_disable_process"
## Optional Vector2 XZ override. Use when the entity's own global_position
## doesn't equal its culling centre — e.g. buildings are a container Node3D
## at world origin whose children carry the actual world positions, so the
## container itself needs to advertise its logical centre explicitly.
const META_CENTER          := &"fov_cull_center"
const GROUP               := &"fov_cullable"

var _player: Node3D = null
var _fov_overlay: Node = null  # reads fov_degrees / view_distance / head_height from here

func configure(player: Node3D, fov_overlay: Node) -> void:
	_player = player
	_fov_overlay = fov_overlay

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

		var p_xz: Vector2
		if n3.has_meta(META_CENTER):
			p_xz = n3.get_meta(META_CENTER)
		else:
			p_xz = Vector2(n3.global_position.x, n3.global_position.z)
		var inside := _point_in_fov(p_xz, radius, head_xz, facing, half_rad, view_dist)

		if n3.visible != inside:
			n3.visible = inside

		if disable_process:
			var want_mode: int = Node.PROCESS_MODE_INHERIT if inside else Node.PROCESS_MODE_DISABLED
			if n3.process_mode != want_mode:
				n3.process_mode = want_mode

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
