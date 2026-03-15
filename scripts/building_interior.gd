extends Node3D

## Generates a procedural interior for a building when the player enters.
##
## The interior is spawned at the building's world position and rotated so
## its entrance aligns with the exterior entrance direction.
## No ceiling is generated so the isometric camera can see inside.

enum BuildingType { CONVENIENCE_STORE, APARTMENT, OFFICE, WAREHOUSE, DINER }

const WALL_COLOR     := Color(0.85, 0.83, 0.78)
const FLOOR_COLOR    := Color(0.45, 0.40, 0.35)
const DOOR_COLOR     := Color(0.35, 0.22, 0.12)

# Furniture palettes per building type
const SHELF_COLOR    := Color(0.55, 0.40, 0.25)
const COUNTER_COLOR  := Color(0.60, 0.58, 0.55)
const DESK_COLOR     := Color(0.50, 0.38, 0.28)
const CRATE_COLOR    := Color(0.62, 0.50, 0.30)
const BOOTH_COLOR    := Color(0.65, 0.18, 0.15)
const FRIDGE_COLOR   := Color(0.80, 0.82, 0.85)
const TABLE_COLOR    := Color(0.48, 0.35, 0.22)

var building_type: BuildingType
var interior_width: float
var interior_depth: float
var interior_height: float
var wall_color: Color = WALL_COLOR

# The exit door Area3D for detecting when player walks out
var exit_area: Area3D

# Wall tracking for camera-based transparency.
# Each entry: { meshes: Array, normal: Vector3 }
# normal is the outward-facing direction in local space.
var wall_sides: Array = []

## Set up and generate the interior.
## building_center: world position of the building centre (at ground level).
## entrance_facing: unit vector pointing outward from the entrance face.
## exterior_color: the building's exterior colour, used for walls so the
##                 interior matches the outside appearance.
func setup(type: BuildingType, w: float, d: float, h: float,
		building_center: Vector3, entrance_facing: Vector3,
		exterior_color: Color = WALL_COLOR) -> void:
	building_type = type
	interior_width = w
	interior_depth = d
	interior_height = h
	wall_color = exterior_color

	# Position at building centre (ground level)
	global_position = building_center

	# Rotate so the interior's +Z exit aligns with entrance_facing
	rotation.y = atan2(entrance_facing.x, entrance_facing.z)

	_generate_interior()

func _generate_interior() -> void:
	_create_floor()
	_create_walls()
	_create_exit_door()
	_create_interior_light()

	match building_type:
		BuildingType.CONVENIENCE_STORE:
			_furnish_convenience_store()
		BuildingType.APARTMENT:
			_furnish_apartment()
		BuildingType.OFFICE:
			_furnish_office()
		BuildingType.WAREHOUSE:
			_furnish_warehouse()
		BuildingType.DINER:
			_furnish_diner()

# ------------------------------------------------------------------
# Structural elements
# ------------------------------------------------------------------

func _create_floor() -> void:
	_add_box(
		Vector3(0.0, 0.0, 0.0),
		Vector3(interior_width, 0.05, interior_depth),
		FLOOR_COLOR, true
	)

func _create_walls() -> void:
	var h := interior_height
	var w := interior_width
	var d := interior_depth
	var thickness := 0.15

	# Back wall (-Z side)
	var back := _add_wall(Vector3(0.0, h * 0.5, -d * 0.5), Vector3(w, h, thickness), wall_color)
	wall_sides.append({ meshes = [back], normal = Vector3(0.0, 0.0, -1.0) })

	# Left wall (-X side)
	var left := _add_wall(Vector3(-w * 0.5, h * 0.5, 0.0), Vector3(thickness, h, d), wall_color)
	wall_sides.append({ meshes = [left], normal = Vector3(-1.0, 0.0, 0.0) })

	# Right wall (+X side)
	var right := _add_wall(Vector3(w * 0.5, h * 0.5, 0.0), Vector3(thickness, h, d), wall_color)
	wall_sides.append({ meshes = [right], normal = Vector3(1.0, 0.0, 0.0) })

	# Front wall with gap for exit door (+Z side)
	var front_meshes: Array = []
	var door_width := 1.2
	var door_height := 2.2
	var left_w := (w - door_width) * 0.5
	if left_w > 0.1:
		front_meshes.append(_add_wall(
			Vector3(-door_width * 0.5 - left_w * 0.5, h * 0.5, d * 0.5),
			Vector3(left_w, h, thickness), wall_color
		))
		front_meshes.append(_add_wall(
			Vector3(door_width * 0.5 + left_w * 0.5, h * 0.5, d * 0.5),
			Vector3(left_w, h, thickness), wall_color
		))
	# Section above door
	var above_h := h - door_height
	if above_h > 0.1:
		front_meshes.append(_add_wall(
			Vector3(0.0, door_height + above_h * 0.5, d * 0.5),
			Vector3(door_width, above_h, thickness), wall_color
		))
	wall_sides.append({ meshes = front_meshes, normal = Vector3(0.0, 0.0, 1.0) })

func _create_exit_door() -> void:
	var d := interior_depth
	# Visual door frame
	_add_box(
		Vector3(0.0, 1.1, d * 0.5 + 0.1),
		Vector3(1.2, 2.2, 0.08),
		DOOR_COLOR, false
	)

	# Exit trigger area — player walks into this to leave
	exit_area = Area3D.new()
	exit_area.name = "ExitArea"
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(1.4, 2.4, 1.2)
	cs.shape = shp
	exit_area.add_child(cs)
	exit_area.position = Vector3(0.0, 1.2, d * 0.5 + 0.8)
	add_child(exit_area)

func _create_interior_light() -> void:
	var light := OmniLight3D.new()
	light.position = Vector3(0.0, interior_height - 0.3, 0.0)
	light.light_energy = 2.5
	light.omni_range = maxf(interior_width, interior_depth) * 1.2
	light.shadow_enabled = true
	add_child(light)

	if interior_width > 5.0 or interior_depth > 5.0:
		var fill := OmniLight3D.new()
		fill.position = Vector3(interior_width * 0.25, interior_height - 0.3, -interior_depth * 0.25)
		fill.light_energy = 1.5
		fill.omni_range = maxf(interior_width, interior_depth) * 0.8
		add_child(fill)

# ------------------------------------------------------------------
# Furniture: Convenience Store
# ------------------------------------------------------------------

func _furnish_convenience_store() -> void:
	var w := interior_width
	var d := interior_depth

	_add_box(Vector3(w * 0.3, 0.5, d * 0.25), Vector3(1.8, 1.0, 0.6), COUNTER_COLOR, true)
	_add_box(Vector3(w * 0.3, 1.05, d * 0.25), Vector3(0.4, 0.3, 0.35), Color(0.15, 0.15, 0.15), false)

	var shelf_rows := int(maxf(2, floorf(d / 2.5)))
	for i in range(shelf_rows):
		var z_pos := -d * 0.35 + i * (d * 0.5 / shelf_rows)
		_add_box(Vector3(-w * 0.25, 0.75, z_pos), Vector3(0.5, 1.5, 1.6), SHELF_COLOR, true)
		if i > 0:
			_add_box(Vector3(w * 0.05, 0.75, z_pos), Vector3(0.5, 1.5, 1.6), SHELF_COLOR, true)

	_add_box(Vector3(0.0, 1.0, -d * 0.45), Vector3(w * 0.7, 2.0, 0.5), FRIDGE_COLOR, true)
	_add_box(Vector3(0.0, 2.5, d * 0.45), Vector3(1.5, 0.3, 0.05), Color(0.9, 0.2, 0.15), false)

# ------------------------------------------------------------------
# Furniture: Apartment
# ------------------------------------------------------------------

func _furnish_apartment() -> void:
	var w := interior_width
	var d := interior_depth

	_add_box(Vector3(-w * 0.25, 0.3, -d * 0.35), Vector3(1.6, 0.6, 2.0), Color(0.45, 0.35, 0.55), true)
	_add_box(Vector3(-w * 0.25, 0.65, -d * 0.42), Vector3(0.6, 0.15, 0.4), Color(0.85, 0.85, 0.85), false)
	_add_box(Vector3(w * 0.2, 0.4, -d * 0.1), Vector3(0.8, 0.8, 0.8), TABLE_COLOR, true)
	_add_box(Vector3(w * 0.2, 0.25, d * 0.1), Vector3(0.5, 0.5, 0.5), Color(0.50, 0.30, 0.20), true)
	_add_box(Vector3(-w * 0.42, 0.9, d * 0.1), Vector3(0.35, 1.8, 1.0), SHELF_COLOR, true)
	_add_box(Vector3(w * 0.42, 0.45, -d * 0.2), Vector3(0.4, 0.9, 1.5), COUNTER_COLOR, true)
	_add_box(Vector3(0.0, 0.03, 0.0), Vector3(1.8, 0.02, 1.4), Color(0.55, 0.20, 0.18), false)

# ------------------------------------------------------------------
# Furniture: Office
# ------------------------------------------------------------------

func _furnish_office() -> void:
	var w := interior_width
	var d := interior_depth

	var desk_count := int(maxf(2, floorf(w / 2.0)))
	for i in range(desk_count):
		var x_pos := -w * 0.35 + i * (w * 0.7 / maxf(desk_count - 1, 1))
		_add_box(Vector3(x_pos, 0.4, -d * 0.15), Vector3(1.2, 0.8, 0.7), DESK_COLOR, true)
		_add_box(Vector3(x_pos, 0.9, -d * 0.18), Vector3(0.4, 0.35, 0.05), Color(0.1, 0.1, 0.12), false)

	for i in range(desk_count):
		var x_pos := -w * 0.35 + i * (w * 0.7 / maxf(desk_count - 1, 1))
		_add_box(Vector3(x_pos, 0.25, d * 0.05), Vector3(0.45, 0.5, 0.45), Color(0.15, 0.15, 0.18), true)

	_add_box(Vector3(w * 0.35, 0.6, -d * 0.42), Vector3(0.5, 1.2, 0.4), Color(0.50, 0.50, 0.50), true)
	_add_box(Vector3(-w * 0.35, 0.6, -d * 0.42), Vector3(0.5, 1.2, 0.4), Color(0.50, 0.50, 0.50), true)
	_add_box(Vector3(w * 0.4, 0.55, d * 0.3), Vector3(0.3, 1.1, 0.3), Color(0.7, 0.85, 0.9), true)

# ------------------------------------------------------------------
# Furniture: Warehouse
# ------------------------------------------------------------------

func _furnish_warehouse() -> void:
	var w := interior_width
	var d := interior_depth

	for i in range(3):
		var x := -w * 0.3 + i * w * 0.3
		_add_box(Vector3(x, 0.5, -d * 0.3), Vector3(1.0, 1.0, 1.0), CRATE_COLOR, true)
		if i % 2 == 0:
			_add_box(Vector3(x, 1.5, -d * 0.3), Vector3(1.0, 1.0, 1.0), CRATE_COLOR, true)

	_add_box(Vector3(-w * 0.42, 1.2, 0.0), Vector3(0.4, 2.4, d * 0.7), SHELF_COLOR, true)
	_add_box(Vector3(w * 0.2, 0.08, d * 0.2), Vector3(1.2, 0.16, 1.2), Color(0.6, 0.5, 0.3), true)
	_add_box(Vector3(w * 0.35, 0.45, -d * 0.05), Vector3(0.6, 0.9, 0.6), Color(0.40, 0.30, 0.20), true)
	_add_box(Vector3(w * 0.15, 0.45, d * 0.3), Vector3(0.6, 0.9, 0.6), Color(0.40, 0.30, 0.20), true)

# ------------------------------------------------------------------
# Furniture: Diner
# ------------------------------------------------------------------

func _furnish_diner() -> void:
	var w := interior_width
	var d := interior_depth

	_add_box(Vector3(0.0, 0.55, -d * 0.25), Vector3(w * 0.7, 1.1, 0.5), COUNTER_COLOR, true)

	var stool_count := int(maxf(2, floorf(w * 0.7 / 0.7)))
	for i in range(stool_count):
		var x := -w * 0.3 + i * (w * 0.6 / maxf(stool_count - 1, 1))
		_add_box(Vector3(x, 0.35, -d * 0.05), Vector3(0.35, 0.05, 0.35), BOOTH_COLOR, true)
		_add_box(Vector3(x, 0.17, -d * 0.05), Vector3(0.08, 0.34, 0.08), Color(0.6, 0.6, 0.6), false)

	_add_box(Vector3(-w * 0.42, 0.4, d * 0.15), Vector3(0.4, 0.8, 1.2), BOOTH_COLOR, true)
	_add_box(Vector3(-w * 0.25, 0.4, d * 0.15), Vector3(0.6, 0.8, 0.9), TABLE_COLOR, true)
	_add_box(Vector3(w * 0.42, 0.4, d * 0.15), Vector3(0.4, 0.8, 1.2), BOOTH_COLOR, true)
	_add_box(Vector3(w * 0.25, 0.4, d * 0.15), Vector3(0.6, 0.8, 0.9), TABLE_COLOR, true)
	_add_box(Vector3(0.0, 1.5, -d * 0.48), Vector3(1.5, 0.8, 0.1), Color(0.15, 0.15, 0.18), false)

# ------------------------------------------------------------------
# Wall visibility (called by main.gd each frame while inside)
# ------------------------------------------------------------------

## Update wall transparency based on camera direction in local space.
## Walls whose outward normal faces toward the camera become transparent.
func update_wall_visibility(camera_dir_local: Vector3) -> void:
	for side in wall_sides:
		var dot: float = side.normal.dot(camera_dir_local)
		# Wall faces toward camera → make transparent so player is visible
		var alpha := 0.2 if dot > 0.0 else 1.0
		for mi in side.meshes:
			var mat: StandardMaterial3D = mi.mesh.material as StandardMaterial3D
			if mat == null:
				continue
			if alpha >= 1.0:
				mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
				mat.albedo_color.a = 1.0
			else:
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.albedo_color.a = alpha

# ------------------------------------------------------------------
# Helper: add a wall panel (with collision, returns MeshInstance3D)
# ------------------------------------------------------------------

func _add_wall(pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color

	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = size
	cs.shape = shp
	sb.add_child(cs)
	mi.add_child(sb)

	add_child(mi)
	return mi

# ------------------------------------------------------------------
# Helper: add a coloured box (optionally with collision)
# ------------------------------------------------------------------

func _add_box(pos: Vector3, size: Vector3, color: Color, has_collision: bool) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color

	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	if has_collision:
		var sb  := StaticBody3D.new()
		var cs  := CollisionShape3D.new()
		var shp := BoxShape3D.new()
		shp.size = size
		cs.shape = shp
		sb.add_child(cs)
		mi.add_child(sb)

	add_child(mi)
