extends Node3D

## Procedurally generates a small town map at runtime.
##
## Layout:  a NUM_BLOCKS × NUM_BLOCKS grid of city blocks separated by roads.
## Each block is filled with randomly-sized buildings.
## A ground plane (grass) underlies everything, and a sun + sky environment is created.

const MAP_HALF       := 44.0   # Half-extent of the entire map (metres)
const BLOCK_SIZE     := 14.0   # Width/depth of one city block
const ROAD_WIDTH     := 4.0    # Width of a road between blocks
const CELL_SIZE      := BLOCK_SIZE + ROAD_WIDTH  # Distance from block edge to next block edge

const NUM_BLOCKS     := 5      # Number of blocks per axis (5×5 grid)

# Palette for building colours (cartoon-ish desaturated tones)
const BUILDING_COLORS: Array[Color] = [
	Color(0.80, 0.62, 0.50),  # warm brick
	Color(0.68, 0.70, 0.82),  # cool blue-grey
	Color(0.82, 0.80, 0.62),  # cream
	Color(0.58, 0.58, 0.58),  # concrete grey
	Color(0.70, 0.58, 0.50),  # dusty terracotta
	Color(0.60, 0.75, 0.60),  # muted green
]

const ROAD_COLOR    := Color(0.18, 0.18, 0.20)
const SIDEWALK_COLOR := Color(0.55, 0.55, 0.52)
const GRASS_COLOR   := Color(0.32, 0.46, 0.24)

var _rng := RandomNumberGenerator.new()

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
	var count := _rng.randi_range(3, 6)
	var placed := []  # Array of {cx, cz, hw, hd}  (half-extents + centre)

	var attempts := 0
	while placed.size() < count and attempts < 40:
		attempts += 1

		var bw := _rng.randf_range(2.5, 5.5)
		var bd := _rng.randf_range(2.5, 5.5)
		var bh := _rng.randf_range(3.0, 12.0)

		var margin := 0.6
		var px := bx + _rng.randf_range(margin, BLOCK_SIZE - bw - margin)
		var pz := bz + _rng.randf_range(margin, BLOCK_SIZE - bd - margin)

		# AABB overlap check
		var cx := px + bw * 0.5
		var cz := pz + bd * 0.5
		var hw := bw * 0.5 + 0.3
		var hd := bd * 0.5 + 0.3

		var ok := true
		for p in placed:
			if abs(cx - p.cx) < hw + p.hw and abs(cz - p.cz) < hd + p.hd:
				ok = false
				break

		if ok:
			placed.append({cx = cx, cz = cz, hw = bw * 0.5, hd = bd * 0.5})
			var color := BUILDING_COLORS[_rng.randi() % BUILDING_COLORS.size()]
			_create_building(Vector3(cx, bh * 0.5, cz), bw, bh, bd, color)

func _create_building(pos: Vector3, w: float, h: float, d: float, color: Color) -> void:
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
