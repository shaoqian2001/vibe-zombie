extends Node3D

## Procedurally generates a small town map at runtime.
##
## Layout:  a NUM_BLOCKS × NUM_BLOCKS grid of city blocks separated by roads.
## Each block is filled with randomly-sized buildings.
## A ground plane (grass) underlies everything, and a sun + sky environment is created.

const MAP_HALF       := 76.0   # Half-extent of the entire map (metres)
const BLOCK_SIZE     := 26.0   # Width/depth of one city block
const ROAD_WIDTH     := 4.0    # Width of a road between blocks
const CELL_SIZE      := BLOCK_SIZE + ROAD_WIDTH  # Distance from block edge to next block edge

const NUM_BLOCKS     := 5      # Number of blocks per axis (5×5 grid)

# Building type → height category
# Short types (single ground floor): Convenience Store, Warehouse, Diner
# Tall types (potentially multi-floor): Apartment, Office
const SHORT_TYPES: Array[int] = [
	BuildingInterior.BuildingType.CONVENIENCE_STORE,
	BuildingInterior.BuildingType.WAREHOUSE,
	BuildingInterior.BuildingType.DINER,
]
const TALL_TYPES: Array[int] = [
	BuildingInterior.BuildingType.APARTMENT,
	BuildingInterior.BuildingType.OFFICE,
]

# Palette for building colours (cartoon-ish desaturated tones)
const BUILDING_COLORS: Array[Color] = [
	Color(0.80, 0.62, 0.50),  # warm brick
	Color(0.68, 0.70, 0.82),  # cool blue-grey
	Color(0.82, 0.80, 0.62),  # cream
	Color(0.58, 0.58, 0.58),  # concrete grey
	Color(0.70, 0.58, 0.50),  # dusty terracotta
	Color(0.60, 0.75, 0.60),  # muted green
]

const DOOR_COLOR     := Color(0.35, 0.22, 0.12)
const AWNING_COLORS  := [
	Color(0.75, 0.20, 0.15),  # red
	Color(0.15, 0.45, 0.20),  # green
	Color(0.20, 0.25, 0.60),  # blue
	Color(0.70, 0.55, 0.15),  # gold
]

const ROAD_COLOR    := Color(0.18, 0.18, 0.20)
const SIDEWALK_COLOR := Color(0.55, 0.55, 0.52)
const GRASS_COLOR   := Color(0.32, 0.46, 0.24)

const BuildingInterior = preload("res://scripts/building_interior.gd")

# KayKit building models (A-H) — all have ~2×2 XZ footprint at origin, Y up
const BUILDING_SCENES := [
	preload("res://assets/buildings/building_A.gltf"),
	preload("res://assets/buildings/building_B.gltf"),
	preload("res://assets/buildings/building_C.gltf"),
	preload("res://assets/buildings/building_D.gltf"),
	preload("res://assets/buildings/building_E.gltf"),
	preload("res://assets/buildings/building_F.gltf"),
	preload("res://assets/buildings/building_G.gltf"),
	preload("res://assets/buildings/building_H.gltf"),
]
# Native height of each model (in model units, footprint is always ~2×2)
const BUILDING_MODEL_HEIGHTS := [1.65, 2.10, 2.98, 2.55, 2.35, 2.50, 1.85, 3.05]
const BUILDING_MODEL_FOOTPRINT := 2.0

# Street prop scenes
const STREET_PROPS := {
	"bench": preload("res://assets/street/bench.gltf"),
	"streetlight": preload("res://assets/street/streetlight.gltf"),
	"bush": preload("res://assets/street/bush.gltf"),
	"dumpster": preload("res://assets/street/dumpster.gltf"),
	"firehydrant": preload("res://assets/street/firehydrant.gltf"),
	"trash_A": preload("res://assets/street/trash_A.gltf"),
	"trash_B": preload("res://assets/street/trash_B.gltf"),
	"car_sedan": preload("res://assets/street/car_sedan.gltf"),
	"car_taxi": preload("res://assets/street/car_taxi.gltf"),
	"car_police": preload("res://assets/street/car_police.gltf"),
	"trafficlight": preload("res://assets/street/trafficlight_A.gltf"),
}

var _rng := RandomNumberGenerator.new()

## Array of dictionaries describing each building placed in the world.
## Each entry: { node: MeshInstance3D, entrance_area: Area3D, type: int,
##               width: float, depth: float, height: float,
##               entrance_pos: Vector3, entrance_facing: Vector3 }
var buildings: Array = []

func _ready() -> void:
	_rng.seed = 98765
	_generate_ground()
	_generate_boundary_walls()
	_generate_city_grid()
	_add_sun_and_sky()

# ------------------------------------------------------------------
# Ground
# ------------------------------------------------------------------

func _generate_ground() -> void:
	var size := MAP_HALF * 2.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = GRASS_COLOR
	mat.roughness = 0.95
	mat.metallic = 0.0

	var mesh := PlaneMesh.new()
	mesh.size = Vector2(size, size)
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Ground"
	add_child(mi)

	# Flat collision for the ground
	var sb  := StaticBody3D.new()
	var cs  := CollisionShape3D.new()
	var shp := WorldBoundaryShape3D.new()
	cs.shape = shp
	sb.add_child(cs)
	add_child(sb)

# ------------------------------------------------------------------
# Boundary walls (invisible colliders at map edges)
# ------------------------------------------------------------------

func _generate_boundary_walls() -> void:
	var wall_h := 10.0
	var wall_thickness := 1.0
	var extent := MAP_HALF
	# Four walls: +X, -X, +Z, -Z
	var walls := [
		Vector3(extent + wall_thickness * 0.5, wall_h * 0.5, 0.0),   # +X
		Vector3(-extent - wall_thickness * 0.5, wall_h * 0.5, 0.0),  # -X
		Vector3(0.0, wall_h * 0.5, extent + wall_thickness * 0.5),   # +Z
		Vector3(0.0, wall_h * 0.5, -extent - wall_thickness * 0.5),  # -Z
	]
	var sizes := [
		Vector3(wall_thickness, wall_h, extent * 2.0 + wall_thickness * 2.0),  # +X/-X
		Vector3(wall_thickness, wall_h, extent * 2.0 + wall_thickness * 2.0),
		Vector3(extent * 2.0 + wall_thickness * 2.0, wall_h, wall_thickness),  # +Z/-Z
		Vector3(extent * 2.0 + wall_thickness * 2.0, wall_h, wall_thickness),
	]
	for i in range(4):
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shp := BoxShape3D.new()
		shp.size = sizes[i]
		cs.shape = shp
		sb.position = walls[i]
		sb.add_child(cs)
		add_child(sb)

# ------------------------------------------------------------------
# City grid
# ------------------------------------------------------------------

func _generate_city_grid() -> void:
	var total := NUM_BLOCKS * CELL_SIZE
	var origin := Vector3(-total * 0.5, 0.0, -total * 0.5)

	for row in range(NUM_BLOCKS):
		for col in range(NUM_BLOCKS):
			var bx := origin.x + col * CELL_SIZE
			var bz := origin.z + row * CELL_SIZE

			# Sidewalk beneath the whole block (slightly raised)
			_create_flat_quad(
				Vector3(bx + BLOCK_SIZE * 0.5, 0.005, bz + BLOCK_SIZE * 0.5),
				BLOCK_SIZE, BLOCK_SIZE,
				SIDEWALK_COLOR
			)

			# Road on the right side of this block
			_create_flat_quad(
				Vector3(bx + BLOCK_SIZE + ROAD_WIDTH * 0.5, 0.008, bz + CELL_SIZE * 0.5),
				ROAD_WIDTH, CELL_SIZE,
				ROAD_COLOR
			)

			# Road on the bottom side of this block
			_create_flat_quad(
				Vector3(bx + CELL_SIZE * 0.5, 0.008, bz + BLOCK_SIZE + ROAD_WIDTH * 0.5),
				CELL_SIZE, ROAD_WIDTH,
				ROAD_COLOR
			)

			# Buildings inside the block
			_populate_block(bx, bz)

			# Street props along the roads adjacent to this block
			_populate_street_props(bx, bz)

# ------------------------------------------------------------------
# Buildings
# ------------------------------------------------------------------

func _populate_block(bx: float, bz: float) -> void:
	var count := _rng.randi_range(2, 4)
	var placed := []  # Array of {cx, cz, hw, hd}  (half-extents + centre)

	var attempts := 0
	while placed.size() < count and attempts < 40:
		attempts += 1

		# Pick a building category: 50/50 tall vs short
		var is_tall := _rng.randf() < 0.5
		var btype: int
		if is_tall:
			btype = TALL_TYPES[_rng.randi() % TALL_TYPES.size()]
		else:
			btype = SHORT_TYPES[_rng.randi() % SHORT_TYPES.size()]

		# Dimensions based on category
		var bw: float
		var bd: float
		var bh: float
		if is_tall:
			bw = _rng.randf_range(7.0, 12.0)
			bd = _rng.randf_range(7.0, 12.0)
			bh = _rng.randf_range(8.0, 16.0)
		else:
			bw = _rng.randf_range(6.0, 10.0)
			bd = _rng.randf_range(6.0, 10.0)
			bh = _rng.randf_range(3.5, 5.5)

		var margin := 0.8
		var max_x := BLOCK_SIZE - bw - margin
		var max_z := BLOCK_SIZE - bd - margin
		if max_x < margin or max_z < margin:
			continue

		var px := bx + _rng.randf_range(margin, max_x)
		var pz := bz + _rng.randf_range(margin, max_z)

		# AABB overlap check
		var cx := px + bw * 0.5
		var cz := pz + bd * 0.5
		var hw := bw * 0.5 + 0.4
		var hd := bd * 0.5 + 0.4

		var ok := true
		for p in placed:
			if abs(cx - p.cx) < hw + p.hw and abs(cz - p.cz) < hd + p.hd:
				ok = false
				break

		if ok:
			placed.append({cx = cx, cz = cz, hw = bw * 0.5, hd = bd * 0.5})
			var color := BUILDING_COLORS[_rng.randi() % BUILDING_COLORS.size()]
			_create_building(Vector3(cx, bh * 0.5, cz), bw, bh, bd, color, btype, bx, bz)

func _populate_street_props(bx: float, bz: float) -> void:
	var prop_keys := STREET_PROPS.keys()
	var sidewalk_edge := BLOCK_SIZE

	# Props along the right-side road (between block and next block)
	var road_x := bx + sidewalk_edge + ROAD_WIDTH * 0.5
	var num_along_z := _rng.randi_range(1, 3)
	for i in range(num_along_z):
		var z := bz + _rng.randf_range(2.0, BLOCK_SIZE - 2.0)
		# Place on sidewalk edge, not in the road itself
		var side := -1.0 if _rng.randf() < 0.5 else 1.0
		var x := road_x + side * (ROAD_WIDTH * 0.5 + 0.5)
		_place_street_prop(Vector3(x, 0.0, z), prop_keys)

	# Props along the bottom-side road
	var road_z := bz + sidewalk_edge + ROAD_WIDTH * 0.5
	var num_along_x := _rng.randi_range(1, 3)
	for i in range(num_along_x):
		var x := bx + _rng.randf_range(2.0, BLOCK_SIZE - 2.0)
		var side := -1.0 if _rng.randf() < 0.5 else 1.0
		var z := road_z + side * (ROAD_WIDTH * 0.5 + 0.5)
		_place_street_prop(Vector3(x, 0.0, z), prop_keys)

func _place_street_prop(pos: Vector3, prop_keys: Array) -> void:
	var key: String = prop_keys[_rng.randi() % prop_keys.size()]
	var scene: PackedScene = STREET_PROPS[key]
	var instance := scene.instantiate()
	instance.position = pos

	var prop_scale := 1.0
	var is_car := false
	match key:
		"streetlight":
			prop_scale = 4.0
		"bench":
			prop_scale = 3.0
		"bush":
			prop_scale = _rng.randf_range(2.5, 4.0)
		"dumpster":
			prop_scale = 3.0
		"firehydrant":
			prop_scale = 2.5
		"trash_A", "trash_B":
			prop_scale = 2.0
		"car_sedan", "car_taxi", "car_police":
			prop_scale = 3.0
			is_car = true
		"trafficlight":
			prop_scale = 4.0
		"box_A", "box_B":
			prop_scale = 2.5
		"watertower":
			prop_scale = 5.0

	instance.scale = Vector3.ONE * prop_scale

	if is_car:
		instance.rotation.y = (PI * 0.5) * float(_rng.randi_range(0, 1))
	else:
		instance.rotation.y = _rng.randf_range(0.0, TAU)

	# Collision only for dumpsters — cars are purely decorative
	if key == "dumpster":
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shp := BoxShape3D.new()
		shp.size = Vector3(1.0, 0.8, 1.2)
		cs.shape = shp
		sb.position = Vector3(0.0, 0.4, 0.0)
		sb.add_child(cs)
		instance.add_child(sb)

	add_child(instance)

func _create_building(pos: Vector3, w: float, h: float, d: float, color: Color, btype: int, block_x: float, block_z: float) -> void:
	var model_idx := _rng.randi() % BUILDING_SCENES.size()
	var scene: PackedScene = BUILDING_SCENES[model_idx]
	var model_h: float = BUILDING_MODEL_HEIGHTS[model_idx]

	var scale_x := w / BUILDING_MODEL_FOOTPRINT
	var scale_y := h / model_h
	var scale_z := d / BUILDING_MODEL_FOOTPRINT

	var container := Node3D.new()
	container.name = "Building"
	container.position = Vector3(pos.x, 0.0, pos.z)
	add_child(container)

	var model_instance := scene.instantiate()
	model_instance.scale = Vector3(scale_x, scale_y, scale_z)
	container.add_child(model_instance)

	# Collision box matching the building dimensions
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(w, h, d)
	cs.shape = shp
	sb.position = Vector3(0.0, h * 0.5, 0.0)
	sb.add_child(cs)
	container.add_child(sb)

	# pos was passed as (cx, h*0.5, cz) from _populate_block — reconstruct center pos
	var center_pos := Vector3(pos.x, h * 0.5, pos.z)
	var entrance_dir := _pick_entrance_side(center_pos, w, d, block_x, block_z)
	var entrance_pos := _compute_entrance_position(center_pos, w, h, d, entrance_dir)

	var door_info := _create_door(entrance_pos, entrance_dir, color)
	var entrance_area := _create_entrance_area(entrance_pos, entrance_dir)

	buildings.append({
		node = container,
		door_pivot = door_info.pivot,
		door_base_angle = door_info.base_angle,
		entrance_area = entrance_area,
		type = btype,
		width = w,
		depth = d,
		height = h,
		color = color,
		entrance_pos = entrance_pos,
		entrance_facing = entrance_dir,
		door_open = false,
	})

func _add_building_details(pos: Vector3, w: float, h: float, d: float, base_color: Color) -> void:
	var ground_y := pos.y - h * 0.5
	var window_color := Color(0.22, 0.28, 0.38, 1.0)
	var window_mat := StandardMaterial3D.new()
	window_mat.albedo_color = window_color
	window_mat.roughness = 0.2
	window_mat.metallic = 0.4

	var floor_h := 3.2
	var num_floors := int(h / floor_h)
	var win_size := 0.6

	# Windows on ±X and ±Z faces
	for face in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var face_w := d if absf(face.x) > 0.5 else w
		var num_win := int(face_w / 2.5)
		if num_win < 1:
			continue

		for fl in range(num_floors):
			var y := ground_y + 1.8 + fl * floor_h
			if y + win_size * 0.5 > pos.y + h * 0.5 - 0.3:
				continue
			for wi in range(num_win):
				var t := (float(wi) + 0.5) / float(num_win) - 0.5
				var local_off := t * (face_w - 1.0)

				var wpos := pos
				if absf(face.x) > 0.5:
					wpos += Vector3(face.x * (w * 0.5 + 0.01), y - pos.y, local_off)
				else:
					wpos += Vector3(local_off, y - pos.y, face.z * (d * 0.5 + 0.01))

				var wmesh := BoxMesh.new()
				if absf(face.x) > 0.5:
					wmesh.size = Vector3(0.02, win_size, win_size * 0.8)
				else:
					wmesh.size = Vector3(win_size * 0.8, win_size, 0.02)
				wmesh.material = window_mat

				var wmi := MeshInstance3D.new()
				wmi.mesh = wmesh
				wmi.position = wpos
				wmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				add_child(wmi)

	# Rooftop ledge
	var ledge_color := Color(
		clampf(base_color.r - 0.1, 0.0, 1.0),
		clampf(base_color.g - 0.1, 0.0, 1.0),
		clampf(base_color.b - 0.1, 0.0, 1.0)
	)
	var ledge_mat := StandardMaterial3D.new()
	ledge_mat.albedo_color = ledge_color
	ledge_mat.roughness = 0.8
	var ledge_mesh := BoxMesh.new()
	ledge_mesh.size = Vector3(w + 0.3, 0.2, d + 0.3)
	ledge_mesh.material = ledge_mat
	var ledge := MeshInstance3D.new()
	ledge.mesh = ledge_mesh
	ledge.position = Vector3(pos.x, pos.y + h * 0.5 + 0.1, pos.z)
	add_child(ledge)

	# Horizontal trim line at mid-height
	if num_floors >= 2:
		var trim_mat := StandardMaterial3D.new()
		trim_mat.albedo_color = ledge_color
		trim_mat.roughness = 0.8
		var trim_y := ground_y + floor_h
		for face in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
			var face_w2 := d if absf(face.x) > 0.5 else w
			var tmesh := BoxMesh.new()
			if absf(face.x) > 0.5:
				tmesh.size = Vector3(0.06, 0.12, face_w2 + 0.1)
			else:
				tmesh.size = Vector3(face_w2 + 0.1, 0.12, 0.06)
			tmesh.material = trim_mat
			var tmi := MeshInstance3D.new()
			tmi.mesh = tmesh
			tmi.position = Vector3(
				pos.x + face.x * (w * 0.5 + 0.03),
				trim_y,
				pos.z + face.z * (d * 0.5 + 0.03)
			)
			tmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(tmi)

## Pick the building face closest to the edge of the block (nearest road).
func _pick_entrance_side(pos: Vector3, w: float, d: float, block_x: float, block_z: float) -> Vector3:
	var dist_left  := absf(pos.x - w * 0.5 - block_x)
	var dist_right := absf(pos.x + w * 0.5 - (block_x + BLOCK_SIZE))
	var dist_front := absf(pos.z + d * 0.5 - (block_z + BLOCK_SIZE))
	var dist_back  := absf(pos.z - d * 0.5 - block_z)

	var min_dist := dist_left
	var dir := Vector3(-1, 0, 0)  # left face

	if dist_right < min_dist:
		min_dist = dist_right
		dir = Vector3(1, 0, 0)

	if dist_front < min_dist:
		min_dist = dist_front
		dir = Vector3(0, 0, 1)

	if dist_back < min_dist:
		dir = Vector3(0, 0, -1)

	return dir

func _compute_entrance_position(pos: Vector3, w: float, h: float, d: float, facing: Vector3) -> Vector3:
	var ground_y := pos.y - h * 0.5  # base of the building
	if facing.x != 0:
		return Vector3(pos.x + facing.x * w * 0.5, ground_y, pos.z)
	else:
		return Vector3(pos.x, ground_y, pos.z + facing.z * d * 0.5)

func _create_door(entrance_pos: Vector3, facing: Vector3, building_color: Color) -> Dictionary:
	var door_w := 1.0
	var door_h := 2.0

	# --- Pivot at hinge edge (right side when viewed from outside) ---
	var hinge_offset := Vector3.UP.cross(facing) * (door_w * 0.5)
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	pivot.position = entrance_pos + hinge_offset + Vector3(facing.x * 0.05, 0.0, facing.z * 0.05)
	var base_angle := atan2(facing.x, facing.z)
	pivot.rotation.y = base_angle
	add_child(pivot)

	# --- Door mesh (child of pivot, offset so hinge edge aligns with pivot origin) ---
	var door_mat := StandardMaterial3D.new()
	door_mat.albedo_color = DOOR_COLOR
	var dmesh := BoxMesh.new()
	dmesh.size = Vector3(door_w, door_h, 0.08)
	dmesh.material = door_mat
	var door_mi := MeshInstance3D.new()
	door_mi.mesh = dmesh
	door_mi.name = "Door"
	door_mi.position = Vector3(-door_w * 0.5, door_h * 0.5, 0.0)
	pivot.add_child(door_mi)

	# --- Door collision (child of pivot, moves with animation) ---
	var door_body := StaticBody3D.new()
	door_body.name = "DoorBody"
	var door_col := CollisionShape3D.new()
	var door_col_shape := BoxShape3D.new()
	door_col_shape.size = Vector3(door_w, door_h, 0.15)
	door_col.shape = door_col_shape
	door_body.position = Vector3(-door_w * 0.5, door_h * 0.5, 0.0)
	door_body.add_child(door_col)
	pivot.add_child(door_body)

	# --- Awning / canopy above the door (not part of pivot) ---
	var awning_color: Color = AWNING_COLORS[_rng.randi() % AWNING_COLORS.size()]
	var awning_mat := StandardMaterial3D.new()
	awning_mat.albedo_color = awning_color
	var awning_mesh := BoxMesh.new()
	var awning_mi := MeshInstance3D.new()
	if facing.x != 0:
		awning_mesh.size = Vector3(0.8, 0.08, door_w + 0.6)
	else:
		awning_mesh.size = Vector3(door_w + 0.6, 0.08, 0.8)
	awning_mesh.material = awning_mat
	awning_mi.mesh = awning_mesh
	awning_mi.position = entrance_pos + Vector3(
		facing.x * 0.4,
		door_h + 0.15,
		facing.z * 0.4
	)
	add_child(awning_mi)

	return {pivot = pivot, base_angle = base_angle}

func _create_entrance_area(entrance_pos: Vector3, facing: Vector3) -> Area3D:
	var area := Area3D.new()
	area.name = "EntranceArea"
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	# Wide enough for the door, deep enough to cover both sides of the wall
	if absf(facing.x) > 0.5:
		shp.size = Vector3(3.0, 2.5, 2.0)
	else:
		shp.size = Vector3(2.0, 2.5, 3.0)
	cs.shape = shp
	area.add_child(cs)
	# Centered on the door position (straddles inside and outside)
	area.position = entrance_pos + Vector3(0.0, 1.25, 0.0)
	add_child(area)
	return area

# ------------------------------------------------------------------
# Helper: flat coloured quad (for roads / sidewalks)
# ------------------------------------------------------------------

func _create_flat_quad(pos: Vector3, w: float, d: float, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85 if color == ROAD_COLOR else 0.9
	mat.metallic = 0.0

	var mesh := PlaneMesh.new()
	mesh.size = Vector2(w, d)
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)

# ------------------------------------------------------------------
# Lighting & sky
# ------------------------------------------------------------------

func _add_sun_and_sky() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, 38.0, 0.0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	sun.shadow_bias = 0.06
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)

	# Fill light from opposite side for softer shadows
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-30.0, -140.0, 0.0)
	fill.light_energy = 0.35
	fill.light_color = Color(0.75, 0.82, 1.0)
	fill.shadow_enabled = false
	add_child(fill)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.85)
	sky_mat.sky_horizon_color = Color(0.65, 0.75, 0.90)
	sky_mat.ground_bottom_color = Color(0.22, 0.20, 0.18)
	sky_mat.ground_horizon_color = Color(0.55, 0.55, 0.50)
	sky_mat.sun_angle_max = 30.0

	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5

	env.fog_enabled = true
	env.fog_light_color = Color(0.65, 0.72, 0.82)
	env.fog_density = 0.003
	env.fog_sky_affect = 0.4

	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 1.5

	env.glow_enabled = true
	env.glow_intensity = 0.3
	env.glow_bloom = 0.1

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
