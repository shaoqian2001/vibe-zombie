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

var _rng := RandomNumberGenerator.new()

## Array of dictionaries describing each building placed in the world.
## Each entry: { node: MeshInstance3D, entrance_area: Area3D, type: int,
##               width: float, depth: float, height: float,
##               entrance_pos: Vector3, entrance_facing: Vector3 }
var buildings: Array = []

func _ready() -> void:
	_rng.seed = 98765
	_generate_ground()
	_generate_city_grid()
	_add_sun_and_sky()

# ------------------------------------------------------------------
# Ground
# ------------------------------------------------------------------

func _generate_ground() -> void:
	var size := MAP_HALF * 2.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = GRASS_COLOR

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

func _create_building(pos: Vector3, w: float, h: float, d: float, color: Color, btype: int, block_x: float, block_z: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color

	var mesh := BoxMesh.new()
	mesh.size = Vector3(w, h, d)
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos

	# Collision
	var sb  := StaticBody3D.new()
	var cs  := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(w, h, d)
	cs.shape = shp
	sb.add_child(cs)
	mi.add_child(sb)

	add_child(mi)

	# --- Determine entrance side (face closest to nearest road) ---
	var entrance_dir := _pick_entrance_side(pos, w, d, block_x, block_z)
	var entrance_pos := _compute_entrance_position(pos, w, h, d, entrance_dir)

	# --- Create visual door ---
	_create_door(entrance_pos, entrance_dir, color)

	# --- Create entrance trigger area ---
	var entrance_area := _create_entrance_area(entrance_pos, entrance_dir)

	# Store building info for the main scene to use
	buildings.append({
		node = mi,
		entrance_area = entrance_area,
		type = btype,
		width = w,
		depth = d,
		height = h,
		color = color,
		entrance_pos = entrance_pos,
		entrance_facing = entrance_dir,
	})

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

func _create_door(entrance_pos: Vector3, facing: Vector3, building_color: Color) -> void:
	var door_w := 1.0
	var door_h := 2.0

	# Door panel (slightly in front of the wall)
	var door_mat := StandardMaterial3D.new()
	door_mat.albedo_color = DOOR_COLOR

	var door_mesh := BoxMesh.new()
	var door_mi := MeshInstance3D.new()

	if facing.x != 0:
		door_mesh.size = Vector3(0.08, door_h, door_w)
	else:
		door_mesh.size = Vector3(door_w, door_h, 0.08)

	door_mesh.material = door_mat
	door_mi.mesh = door_mesh
	door_mi.position = entrance_pos + Vector3(facing.x * 0.05, door_h * 0.5, facing.z * 0.05)
	add_child(door_mi)

	# Awning / canopy above the door
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

func _create_entrance_area(entrance_pos: Vector3, facing: Vector3) -> Area3D:
	var area := Area3D.new()
	area.name = "EntranceArea"
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(1.8, 2.5, 1.8)
	cs.shape = shp
	area.add_child(cs)
	# Position slightly in front of the door
	area.position = entrance_pos + Vector3(
		facing.x * 0.9,
		1.25,
		facing.z * 0.9
	)
	add_child(area)
	return area

# ------------------------------------------------------------------
# Helper: flat coloured quad (for roads / sidewalks)
# ------------------------------------------------------------------

func _create_flat_quad(pos: Vector3, w: float, d: float, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color

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
	# Directional "sun" light
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, 38.0, 0.0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	add_child(sun)

	# Environment / sky
	var env := Environment.new()
	env.background_mode      = Environment.BG_COLOR
	env.background_color     = Color(0.55, 0.65, 0.80)  # hazy overcast blue
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = Color(0.40, 0.42, 0.50)
	env.ambient_light_energy = 0.7

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
