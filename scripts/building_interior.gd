extends Node3D

## Generates a procedural interior for a building when the player enters.
##
## The interior is spawned at the building's world position and rotated so
## its entrance aligns with the exterior entrance direction.
## No ceiling is generated so the isometric camera can see inside.

enum BuildingType {
	CONVENIENCE_STORE,
	APARTMENT,
	OFFICE,
	WAREHOUSE,
	DINER,
	SHOP,
	FACTORY,
	BANK,
	POLICE_STATION,
	HOSPITAL,
	SCHOOL,
}

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

const FovCuller = preload("res://scripts/fov_culler.gd")

var building_type: BuildingType
var interior_width: float
var interior_depth: float
var interior_height: float
var wall_color: Color = WALL_COLOR

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
	_create_door_frame()
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
		BuildingType.SHOP:
			_furnish_shop()
		BuildingType.FACTORY:
			_furnish_factory()
		BuildingType.BANK:
			_furnish_bank()
		BuildingType.POLICE_STATION:
			_furnish_police_station()
		BuildingType.HOSPITAL:
			_furnish_hospital()
		BuildingType.SCHOOL:
			_furnish_school()

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

func _create_door_frame() -> void:
	var d := interior_depth
	# Visual door frame on the entrance side (+Z)
	_add_box(
		Vector3(0.0, 1.1, d * 0.5 + 0.1),
		Vector3(1.2, 2.2, 0.08),
		DOOR_COLOR, false
	)

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
# Furniture: Shop (slightly bigger than convenience store, retail floor)
# ------------------------------------------------------------------

func _furnish_shop() -> void:
	var w := interior_width
	var d := interior_depth

	# Long checkout counter near the front
	_add_box(Vector3(0.0, 0.5, d * 0.28), Vector3(w * 0.55, 1.0, 0.7), COUNTER_COLOR, true)
	# Register
	_add_box(Vector3(w * 0.18, 1.05, d * 0.28), Vector3(0.4, 0.3, 0.35), Color(0.12, 0.12, 0.12), false)

	# Display racks in rows
	var rows := int(maxf(2.0, floorf(d / 3.0)))
	var cols := int(maxf(2.0, floorf(w / 3.0)))
	for r in range(rows):
		var z_pos := -d * 0.4 + r * (d * 0.55 / maxf(rows - 1, 1))
		for c in range(cols):
			var x_pos := -w * 0.35 + c * (w * 0.7 / maxf(cols - 1, 1))
			_add_box(Vector3(x_pos, 0.55, z_pos), Vector3(0.7, 1.1, 1.1), SHELF_COLOR, true)

	# Mannequin or display stand near entrance
	_add_box(Vector3(w * 0.35, 0.9, d * 0.05), Vector3(0.5, 1.8, 0.5), Color(0.85, 0.78, 0.65), true)

# ------------------------------------------------------------------
# Furniture: Factory
# ------------------------------------------------------------------

func _furnish_factory() -> void:
	var w := interior_width
	var d := interior_depth

	# Conveyor belt running the length
	_add_box(Vector3(0.0, 0.5, 0.0), Vector3(w * 0.18, 0.18, d * 0.7), Color(0.30, 0.30, 0.32), true)
	# Machinery banks on either side
	for i in range(3):
		var z_pos := -d * 0.35 + i * (d * 0.35)
		_add_box(Vector3(-w * 0.3, 0.9, z_pos), Vector3(1.5, 1.8, 1.5), Color(0.45, 0.42, 0.40), true)
		_add_box(Vector3( w * 0.3, 0.9, z_pos), Vector3(1.5, 1.8, 1.5), Color(0.45, 0.42, 0.40), true)
		# Pipe stack above
		_add_box(Vector3(-w * 0.3, 2.3, z_pos), Vector3(0.4, 1.4, 0.4), Color(0.55, 0.52, 0.48), false)
	# Stack of pallets at the back
	_add_box(Vector3(-w * 0.4, 0.2, -d * 0.45), Vector3(1.2, 0.4, 1.4), CRATE_COLOR, true)
	_add_box(Vector3( w * 0.4, 0.2, -d * 0.45), Vector3(1.2, 0.4, 1.4), CRATE_COLOR, true)

# ------------------------------------------------------------------
# Furniture: Bank
# ------------------------------------------------------------------

func _furnish_bank() -> void:
	var w := interior_width
	var d := interior_depth

	# Teller counter at the back
	_add_box(Vector3(0.0, 0.55, -d * 0.32), Vector3(w * 0.7, 1.1, 0.6), Color(0.65, 0.55, 0.40), true)
	# Glass partitions on top of counter
	for i in range(3):
		var x_pos := -w * 0.28 + i * (w * 0.28)
		_add_box(Vector3(x_pos, 1.6, -d * 0.32), Vector3(0.06, 0.9, 0.6), Color(0.65, 0.75, 0.85, 0.6), false)
	# Pedestal desks for customers
	for i in range(2):
		var x_pos := -w * 0.2 + i * (w * 0.4)
		_add_box(Vector3(x_pos, 0.55, d * 0.1), Vector3(0.9, 1.1, 0.5), Color(0.45, 0.30, 0.20), true)
	# Roped queue stanchions
	for i in range(3):
		_add_box(Vector3(-w * 0.25 + i * 0.6, 0.5, 0.0), Vector3(0.08, 1.0, 0.08), Color(0.55, 0.45, 0.30), false)

# ------------------------------------------------------------------
# Furniture: Police Station
# ------------------------------------------------------------------

func _furnish_police_station() -> void:
	var w := interior_width
	var d := interior_depth

	# Reception desk
	_add_box(Vector3(0.0, 0.55, d * 0.18), Vector3(w * 0.5, 1.1, 0.7), Color(0.45, 0.45, 0.50), true)
	# Bulletin board / map on back wall
	_add_box(Vector3(0.0, 1.8, -d * 0.48), Vector3(2.0, 1.2, 0.05), Color(0.20, 0.30, 0.45), false)
	# Holding cell bars at one side
	for i in range(5):
		var z_pos := -d * 0.35 + i * 0.4
		_add_box(Vector3(-w * 0.35, 1.2, z_pos), Vector3(0.08, 2.2, 0.08), Color(0.20, 0.20, 0.22), false)
	_add_box(Vector3(-w * 0.42, 0.05, -d * 0.2), Vector3(0.2, 0.05, d * 0.45), Color(0.20, 0.20, 0.22), false)
	# Cluster of officer desks
	for i in range(2):
		var x_pos := w * 0.15 + i * 0.0
		_add_box(Vector3(w * 0.2, 0.4, -d * 0.1 + i * 1.4), Vector3(1.0, 0.8, 0.6), DESK_COLOR, true)

# ------------------------------------------------------------------
# Furniture: Hospital
# ------------------------------------------------------------------

func _furnish_hospital() -> void:
	var w := interior_width
	var d := interior_depth

	# Long reception counter
	_add_box(Vector3(0.0, 0.55, d * 0.25), Vector3(w * 0.55, 1.1, 0.7), Color(0.92, 0.92, 0.90), true)
	# Waiting chairs in a row
	for i in range(4):
		var x_pos := -w * 0.35 + i * (w * 0.7 / 3.0)
		_add_box(Vector3(x_pos, 0.25, d * 0.4), Vector3(0.5, 0.5, 0.5), Color(0.20, 0.35, 0.45), true)
	# Beds at the back / sides
	for i in range(3):
		var z_pos := -d * 0.4 + i * (d * 0.25)
		_add_box(Vector3(-w * 0.3, 0.35, z_pos), Vector3(0.9, 0.4, 2.0), Color(0.92, 0.92, 0.95), true)
		_add_box(Vector3(-w * 0.3, 0.75, z_pos - 0.8), Vector3(0.9, 0.5, 0.4), Color(0.20, 0.45, 0.45), false)
	# Cabinet
	_add_box(Vector3(w * 0.4, 0.9, 0.0), Vector3(0.4, 1.7, 1.2), Color(0.95, 0.95, 0.93), true)
	# Red cross on cabinet
	_add_box(Vector3(w * 0.4 - 0.18, 1.0, 0.0), Vector3(0.05, 0.5, 0.12), Color(0.85, 0.15, 0.15), false)
	_add_box(Vector3(w * 0.4 - 0.18, 1.0, 0.0), Vector3(0.05, 0.12, 0.5), Color(0.85, 0.15, 0.15), false)

# ------------------------------------------------------------------
# Furniture: School
# ------------------------------------------------------------------

func _furnish_school() -> void:
	var w := interior_width
	var d := interior_depth

	# Teacher's desk at the front
	_add_box(Vector3(0.0, 0.4, -d * 0.35), Vector3(1.6, 0.8, 0.8), DESK_COLOR, true)
	# Blackboard
	_add_box(Vector3(0.0, 1.7, -d * 0.48), Vector3(3.0, 1.2, 0.06), Color(0.10, 0.25, 0.18), false)
	# Rows of student desks
	var rows := int(maxf(3.0, floorf(d / 3.0)))
	var cols := int(maxf(3.0, floorf(w / 2.5)))
	for r in range(rows):
		var z_pos := -d * 0.15 + r * (d * 0.5 / maxf(rows - 1, 1))
		for c in range(cols):
			var x_pos := -w * 0.35 + c * (w * 0.7 / maxf(cols - 1, 1))
			_add_box(Vector3(x_pos, 0.4, z_pos), Vector3(0.7, 0.8, 0.5), DESK_COLOR, true)
			_add_box(Vector3(x_pos, 0.22, z_pos + 0.45), Vector3(0.4, 0.45, 0.4), Color(0.40, 0.30, 0.22), true)

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
				# Opaque again → restore the FOV shadow so the wall darkens
				# normally when it sits outside the player's vision cone.
				if mi.material_overlay == null:
					mi.material_overlay = FovCuller.get_shadow_material()
			else:
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.albedo_color.a = alpha
				# See-through walls are almost always behind the player's aim
				# (i.e. in shadow). The black FOV-shadow overlay fighting the
				# 0.2 alpha turned them into a murky slab instead of a clean
				# window onto the room, so drop the overlay while transparent.
				if mi.material_overlay != null:
					mi.material_overlay = null

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
