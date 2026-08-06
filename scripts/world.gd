extends Node3D

## Procedurally generates a small town map at runtime.
##
## Layout:  a NUM_BLOCKS × NUM_BLOCKS grid of rectangular city blocks
##          (100 m × 200 m) separated by roads.  Each block is assigned
##          a category (residential / commercial / civic / industrial /
##          park / parking lot / plaza / mixed) which drives both the
##          set of buildings placed and the look of the block.
##
## Buildings are sized from a data-driven catalog (see building_catalog.gd)
## so each type lands a footprint within a realistic range and gets the
## right colour palette + visual features (signs, awnings, columns,
## chimneys, antennas, etc.).
##
## Special blocks contain non-building content — trees and benches for
## parks, parked cars for parking lots, fountains for plazas.
##
## Roads carry painted lane markings down their centres and crosswalks at
## every intersection so the grid reads as a real street network.
##
## A ground plane (grass) underlies everything, with a sun + sky env.

# Block geometry — real-world-ish (100 m × 200 m city blocks).
const BLOCK_WIDTH    := 100.0  # X extent of a single block
const BLOCK_DEPTH    := 200.0  # Z extent of a single block
const ROAD_WIDTH     := 8.0    # Width of a road between blocks
const SIDEWALK_INSET := 3.0    # Building-free margin inside each block
const CELL_WIDTH     := BLOCK_WIDTH + ROAD_WIDTH
const CELL_DEPTH     := BLOCK_DEPTH + ROAD_WIDTH

## Number of blocks per axis (NxN grid). Each block is rectangular, so the
## world is num_blocks * CELL_WIDTH wide × num_blocks * CELL_DEPTH deep.
@export var num_blocks: int = 3

## Derived half-extents of the entire map (used for boundary walls + map
## fitting). Rectangular blocks give two values; map_half returns the
## larger of the two so callers that expect a single bounding extent
## still get something sensible.
var map_half_x: float:
	get:
		return num_blocks * CELL_WIDTH * 0.5 + 1.0

var map_half_z: float:
	get:
		return num_blocks * CELL_DEPTH * 0.5 + 1.0

var map_half: float:
	get:
		return maxf(map_half_x, map_half_z)

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

const ROAD_COLOR       := Color(0.18, 0.18, 0.20)
const ROAD_MARK_COLOR  := Color(0.90, 0.88, 0.50)
const CROSSWALK_COLOR  := Color(0.92, 0.92, 0.90)
const SIDEWALK_COLOR   := Color(0.55, 0.55, 0.52)
const GRASS_COLOR      := Color(0.32, 0.46, 0.24)
const PARK_GRASS_COLOR := Color(0.30, 0.50, 0.22)
const PARK_PATH_COLOR  := Color(0.62, 0.55, 0.42)
const PARKING_COLOR    := Color(0.22, 0.22, 0.24)
const PARKING_LINE_COLOR := Color(0.92, 0.92, 0.70)
const PLAZA_COLOR      := Color(0.68, 0.65, 0.58)

const BuildingInterior = preload("res://scripts/building_interior.gd")
const BuildingCatalog  = preload("res://scripts/building_catalog.gd")
const FovCuller        = preload("res://scripts/fov_culler.gd")

var _rng := RandomNumberGenerator.new()

## Map style — drives block-category mix and per-building height scaling.
## Defaults to DOWNTOWN, overridden by NetworkManager.map_style.
var map_style: int = BuildingCatalog.MapStyle.DOWNTOWN

# ---- Performance: shared resource caches ----
# Per-color material cache. Building bodies, props, road quads and trim
# all funnel through `_mat(color)` so meshes with the same albedo share
# a single StandardMaterial3D instance. This dramatically reduces the
# number of unique materials created at world-build time and gives the
# renderer better batching headroom.
var _mat_cache: Dictionary = {}

# Aggregated road-mark transforms — emitted into one MultiMesh after the
# road network is laid down, so all the lane dashes + crosswalk stripes
# become a single draw call instead of thousands of plane meshes.
var _road_mark_xforms: Array[Transform3D] = []
var _parking_line_xforms: Array[Transform3D] = []

## Array of dictionaries describing each building placed in the world.
## Each entry: { node: MeshInstance3D, entrance_area: Area3D, type: int,
##               width: float, depth: float, height: float,
##               entrance_pos: Vector3, entrance_facing: Vector3 }
var buildings: Array = []

## Lighting handles kept so Survival's day/hour clock can drive a day-night
## cycle (see set_time_of_day). Null until _add_sun_and_sky has run.
var _sun: DirectionalLight3D = null
var _fill: DirectionalLight3D = null
var _env: Environment = null
var _sky_mat: ProceduralSkyMaterial = null

## Per-block metadata — used by the map view and gameplay code.
##   { row: int, col: int, category: int,
##     origin: Vector3, width: float, depth: float }
var block_infos: Array = []

func _ready() -> void:
	# Read map configuration from NetworkManager. The same fields are used
	# for single-player (set by the setup menu) and multiplayer (set by
	# the host and broadcast to clients). For networked play every peer
	# must build an identical world, so we always pull the host's seed.
	if NetworkManager.game_seed != 0:
		_rng.seed = NetworkManager.game_seed
	else:
		_rng.seed = 98765
	map_style = NetworkManager.map_style
	# Map size is a preset per style so the layout always has the right
	# footprint for its content (e.g. OPEN_WORLD needs space for a clean
	# rural→urban gradient). NetworkManager.map_size mirrors this so the
	# rest of the game has a single source of truth.
	num_blocks = BuildingCatalog.map_size_for(map_style)
	NetworkManager.map_size = num_blocks
	_generate_ground()
	_generate_boundary_walls()
	_generate_city_grid()
	_flush_road_marks()
	_add_sun_and_sky()
	# Vision-shadow overlay covers the entire static world: ground,
	# sidewalks, roads, buildings, props. One sweep here so the FOV-edge
	# fade matches across every surface the player can see.
	FovCuller.apply_shader_to_subtree(self)

# ------------------------------------------------------------------
# Ground
# ------------------------------------------------------------------

func _generate_ground() -> void:
	var size_x := map_half_x * 2.0
	var size_z := map_half_z * 2.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = GRASS_COLOR
	mat.roughness = 0.95
	mat.metallic = 0.0

	var mesh := PlaneMesh.new()
	mesh.size = Vector2(size_x, size_z)
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
	var ex := map_half_x
	var ez := map_half_z
	# Four walls: +X, -X, +Z, -Z
	var walls := [
		Vector3(ex + wall_thickness * 0.5, wall_h * 0.5, 0.0),
		Vector3(-ex - wall_thickness * 0.5, wall_h * 0.5, 0.0),
		Vector3(0.0, wall_h * 0.5, ez + wall_thickness * 0.5),
		Vector3(0.0, wall_h * 0.5, -ez - wall_thickness * 0.5),
	]
	var sizes := [
		Vector3(wall_thickness, wall_h, ez * 2.0 + wall_thickness * 2.0),
		Vector3(wall_thickness, wall_h, ez * 2.0 + wall_thickness * 2.0),
		Vector3(ex * 2.0 + wall_thickness * 2.0, wall_h, wall_thickness),
		Vector3(ex * 2.0 + wall_thickness * 2.0, wall_h, wall_thickness),
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
	var total_x := num_blocks * CELL_WIDTH
	var total_z := num_blocks * CELL_DEPTH
	var origin := Vector3(-total_x * 0.5, 0.0, -total_z * 0.5)

	for row in range(num_blocks):
		for col in range(num_blocks):
			var bx := origin.x + col * CELL_WIDTH
			var bz := origin.z + row * CELL_DEPTH
			var block_origin := Vector3(bx, 0.0, bz)
			var category := BuildingCatalog.pick_block_category(_rng, map_style, row, col, num_blocks)

			block_infos.append({
				row = row,
				col = col,
				category = category,
				origin = block_origin,
				width = BLOCK_WIDTH,
				depth = BLOCK_DEPTH,
			})

			_create_block_ground(block_origin, category)
			_populate_block(block_origin, category)

	# Roads come after blocks so paint markings render on top of the road
	# surface without z-fighting with sidewalk tiles.
	_generate_road_network(origin)

func _create_block_ground(origin: Vector3, category: int) -> void:
	# Default: sidewalk-coloured block. Special blocks paint over with
	# their own surface (grass / asphalt / paving). Farm + forest blocks
	# blend into the surrounding grass plane, so we skip painting a
	# sidewalk slab over them — saves a draw call per rural block.
	if category == BuildingCatalog.BlockCategory.FARM \
			or category == BuildingCatalog.BlockCategory.FOREST:
		return
	var base_color := SIDEWALK_COLOR
	match category:
		BuildingCatalog.BlockCategory.PARK:
			base_color = PARK_GRASS_COLOR
		BuildingCatalog.BlockCategory.PARKING_LOT:
			base_color = PARKING_COLOR
		BuildingCatalog.BlockCategory.PLAZA:
			base_color = PLAZA_COLOR
	_create_flat_quad(
		Vector3(origin.x + BLOCK_WIDTH * 0.5, 0.005, origin.z + BLOCK_DEPTH * 0.5),
		BLOCK_WIDTH, BLOCK_DEPTH,
		base_color
	)

# ------------------------------------------------------------------
# Block content dispatcher
# ------------------------------------------------------------------

func _populate_block(origin: Vector3, category: int) -> void:
	match category:
		BuildingCatalog.BlockCategory.PARK:
			_populate_park(origin)
		BuildingCatalog.BlockCategory.PARKING_LOT:
			_populate_parking_lot(origin)
		BuildingCatalog.BlockCategory.PLAZA:
			_populate_plaza(origin)
		BuildingCatalog.BlockCategory.FARM:
			_populate_farm(origin)
		BuildingCatalog.BlockCategory.FOREST:
			_populate_forest(origin)
		_:
			_populate_building_block(origin, category)

# ------------------------------------------------------------------
# Buildings — generic catalog-driven packing
# ------------------------------------------------------------------

func _populate_building_block(origin: Vector3, category: int) -> void:
	# Compute the buildable rectangle (block minus sidewalk inset).
	var bx := origin.x + SIDEWALK_INSET
	var bz := origin.z + SIDEWALK_INSET
	var avail_w := BLOCK_WIDTH - SIDEWALK_INSET * 2.0
	var avail_d := BLOCK_DEPTH - SIDEWALK_INSET * 2.0

	# Try to fill the block until we either pack enough or run out of attempts.
	var placed: Array = []  # array of { cx, cz, hw, hd }
	var attempts := 0
	var max_attempts := 120
	var min_buildings := 6
	var max_buildings := 24

	while placed.size() < max_buildings and attempts < max_attempts:
		attempts += 1
		var btype: int = BuildingCatalog.pick_building_for_category(_rng, category)
		var info: Dictionary = BuildingCatalog.info_for(btype)

		var bw := _rng.randf_range(info.w_min, info.w_max)
		var bd := _rng.randf_range(info.d_min, info.d_max)
		var bh: float = _rng.randf_range(info.h_min, info.h_max) * BuildingCatalog.style_height_scale(map_style)

		# Randomly rotate 90° on the long axis — adds variety so apartments
		# don't all line up the same way.
		if _rng.randf() < 0.5:
			var tmp := bw
			bw = bd
			bd = tmp

		# Footprint must fit in the buildable area
		if bw > avail_w - 1.0 or bd > avail_d - 1.0:
			continue

		var margin := 1.5
		var max_x := avail_w - bw - margin
		var max_z := avail_d - bd - margin
		if max_x < margin or max_z < margin:
			continue

		var px := bx + _rng.randf_range(margin, max_x)
		var pz := bz + _rng.randf_range(margin, max_z)

		var cx := px + bw * 0.5
		var cz := pz + bd * 0.5
		var hw := bw * 0.5 + 1.5
		var hd := bd * 0.5 + 1.5

		var ok := true
		for p in placed:
			if abs(cx - p.cx) < hw + p.hw and abs(cz - p.cz) < hd + p.hd:
				ok = false
				break
		if not ok:
			continue

		placed.append({cx = cx, cz = cz, hw = bw * 0.5, hd = bd * 0.5})
		_create_building(
			Vector3(cx, bh * 0.5, cz),
			bw, bh, bd,
			info,
			btype,
			origin.x, origin.z
		)

		# Once we've hit the soft minimum, keep going but bias to stop if
		# the block looks already dense.
		if placed.size() >= min_buildings and _rng.randf() < 0.15:
			break

# ------------------------------------------------------------------
# Buildings — actual construction
# ------------------------------------------------------------------

func _create_building(pos: Vector3, w: float, h: float, d: float,
		info: Dictionary, btype: int,
		block_x: float, block_z: float) -> void:
	var palette: Array = info.get("palette", BUILDING_COLORS)
	var base_color: Color = palette[_rng.randi() % palette.size()]
	# Skip the per-building tint jitter. The palette already supplies
	# colour variety; the extra ±4% jitter blew the material cache to
	# unique-per-building, defeating the whole point of sharing.
	var tinted := base_color
	var accent: Color = info.get("accent", DOOR_COLOR)
	var features: Array = info.get("features", [])

	# Per-building container so every mesh (body, windows, trim, ledge,
	# awning, props) and the door pivot can be hidden as one unit when the
	# FOV culler decides the whole building is outside the player's view.
	var container := Node3D.new()
	container.name = "Building_%d" % buildings.size()
	add_child(container)
	container.add_to_group(&"fov_cullable")
	container.set_meta(&"fov_cull_radius", maxf(w, d) * 0.5 + 2.0)
	container.set_meta(&"fov_cull_center", Vector2(pos.x, pos.z))

	var mesh := BoxMesh.new()
	mesh.size = Vector3(w, h, d)
	mesh.material = _mat(tinted, 0.75, 0.05)

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

	container.add_child(mi)

	_add_building_details(container, pos, w, h, d, tinted)
	_add_building_features(container, pos, w, h, d, accent, features)

	# --- Determine entrance side (face closest to nearest road) ---
	var entrance_dir := _pick_entrance_side(pos, w, d, block_x, block_z)
	var entrance_pos := _compute_entrance_position(pos, w, h, d, entrance_dir)

	# --- Create visual door + sign ---
	var door_info := _create_door(container, entrance_pos, entrance_dir, base_color, accent, features, info.get("name", ""))

	# --- Create entrance trigger area ---
	var entrance_area := _create_entrance_area(container, entrance_pos, entrance_dir)

	buildings.append({
		container = container,
		node = mi,
		door_pivot = door_info.pivot,
		door_base_angle = door_info.base_angle,
		entrance_area = entrance_area,
		type = btype,
		width = w,
		depth = d,
		height = h,
		color = base_color,
		entrance_pos = entrance_pos,
		entrance_facing = entrance_dir,
		door_open = false,
	})

func _add_building_details(parent: Node3D, pos: Vector3, w: float, h: float, d: float, base_color: Color) -> void:
	# Windows + roof ledge + horizontal trim. Window count is capped so a
	# 30 m wide, 10-floor tower still tops out at ~24 window meshes per
	# face — across hundreds of buildings this is the difference between
	# tractable and unplayably laggy at large map sizes.
	var ground_y := pos.y - h * 0.5
	var window_mat := _mat(Color(0.22, 0.28, 0.38, 1.0), 0.2, 0.4)

	var floor_h := 3.2
	var num_floors := int(h / floor_h)
	# Cap window floors. Above floor 4 the isometric camera + FOV shadow
	# rarely show useful detail, so don't pay for windows up there.
	var window_floors := mini(num_floors, 4)
	var win_size := 0.6

	for face in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var face_w := d if absf(face.x) > 0.5 else w
		# Cap horizontal column count at 3 per face regardless of width
		# (was face_w / 2.5 → could hit 10+ on big factories).
		var num_win := mini(int(face_w / 3.5), 3)
		if num_win < 1:
			continue

		for fl in range(window_floors):
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
				parent.add_child(wmi)

	# Rooftop ledge — share material via cache so identical-coloured
	# buildings consume one Material instance for all their ledges.
	var ledge_color := Color(
		clampf(base_color.r - 0.1, 0.0, 1.0),
		clampf(base_color.g - 0.1, 0.0, 1.0),
		clampf(base_color.b - 0.1, 0.0, 1.0)
	)
	var ledge_mat := _mat(ledge_color, 0.8, 0.0)
	var ledge_mesh := BoxMesh.new()
	ledge_mesh.size = Vector3(w + 0.3, 0.2, d + 0.3)
	ledge_mesh.material = ledge_mat
	var ledge := MeshInstance3D.new()
	ledge.mesh = ledge_mesh
	ledge.position = Vector3(pos.x, pos.y + h * 0.5 + 0.1, pos.z)
	parent.add_child(ledge)

	# Horizontal trim line at mid-height — only on noticeably tall
	# buildings; on a 5 m diner / store the trim disappears anyway.
	if num_floors >= 3:
		var trim_mat := _mat(ledge_color, 0.8, 0.0)
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
			parent.add_child(tmi)

# ------------------------------------------------------------------
# Building feature props — chimneys, columns, antennas, crosses, etc.
# ------------------------------------------------------------------

func _add_building_features(parent: Node3D, pos: Vector3, w: float, h: float, d: float,
		accent: Color, features: Array) -> void:
	var roof_y := pos.y + h * 0.5
	var ground_y := pos.y - h * 0.5

	if "chimney" in features:
		var chim_mat := StandardMaterial3D.new()
		chim_mat.albedo_color = Color(0.45, 0.42, 0.40)
		chim_mat.roughness = 0.85
		var chim_mesh := CylinderMesh.new()
		chim_mesh.top_radius = 0.6
		chim_mesh.bottom_radius = 0.8
		chim_mesh.height = h * 0.45
		chim_mesh.material = chim_mat
		var chim := MeshInstance3D.new()
		chim.mesh = chim_mesh
		chim.position = Vector3(pos.x + w * 0.32, roof_y + chim_mesh.height * 0.5, pos.z - d * 0.32)
		parent.add_child(chim)

	if "antenna" in features:
		var ant_mat := StandardMaterial3D.new()
		ant_mat.albedo_color = Color(0.30, 0.30, 0.32)
		var ant_mesh := CylinderMesh.new()
		ant_mesh.top_radius = 0.06
		ant_mesh.bottom_radius = 0.10
		ant_mesh.height = 3.0
		ant_mesh.material = ant_mat
		var ant := MeshInstance3D.new()
		ant.mesh = ant_mesh
		ant.position = Vector3(pos.x - w * 0.25, roof_y + 1.5, pos.z + d * 0.25)
		parent.add_child(ant)

	if "columns" in features:
		var col_mat := StandardMaterial3D.new()
		col_mat.albedo_color = Color(0.92, 0.90, 0.85)
		col_mat.roughness = 0.6
		# Run a colonnade across the longer face of the building
		var face_long := w >= d
		var n_cols := 4
		for i in range(n_cols):
			var t := (float(i) + 0.5) / float(n_cols) - 0.5
			var col_mesh := CylinderMesh.new()
			col_mesh.top_radius = 0.35
			col_mesh.bottom_radius = 0.35
			col_mesh.height = h * 0.7
			col_mesh.material = col_mat
			var col := MeshInstance3D.new()
			col.mesh = col_mesh
			if face_long:
				col.position = Vector3(pos.x + t * (w - 1.5), ground_y + col_mesh.height * 0.5, pos.z + d * 0.5 + 0.7)
			else:
				col.position = Vector3(pos.x + w * 0.5 + 0.7, ground_y + col_mesh.height * 0.5, pos.z + t * (d - 1.5))
			parent.add_child(col)

	if "cross" in features:
		# Hospital cross on the roof
		var cross_mat := StandardMaterial3D.new()
		cross_mat.albedo_color = accent
		cross_mat.emission_enabled = true
		cross_mat.emission = accent
		cross_mat.emission_energy_multiplier = 0.4
		var v_mesh := BoxMesh.new()
		v_mesh.size = Vector3(0.6, 3.0, 0.3)
		v_mesh.material = cross_mat
		var v_mi := MeshInstance3D.new()
		v_mi.mesh = v_mesh
		v_mi.position = Vector3(pos.x, roof_y + 1.6, pos.z)
		parent.add_child(v_mi)
		var h_mesh := BoxMesh.new()
		h_mesh.size = Vector3(2.0, 0.6, 0.3)
		h_mesh.material = cross_mat
		var h_mi := MeshInstance3D.new()
		h_mi.mesh = h_mesh
		h_mi.position = Vector3(pos.x, roof_y + 1.6, pos.z)
		parent.add_child(h_mi)

	if "tower" in features:
		# A small roof tower (used by the school for a clock-tower feel)
		var tow_mat := StandardMaterial3D.new()
		tow_mat.albedo_color = accent
		var tow_mesh := BoxMesh.new()
		tow_mesh.size = Vector3(2.5, 4.0, 2.5)
		tow_mesh.material = tow_mat
		var tow := MeshInstance3D.new()
		tow.mesh = tow_mesh
		tow.position = Vector3(pos.x, roof_y + 2.0, pos.z)
		parent.add_child(tow)
		# Pointed cap
		var cap_mat := StandardMaterial3D.new()
		cap_mat.albedo_color = Color(0.30, 0.18, 0.15)
		var cap_mesh := PrismMesh.new()
		cap_mesh.size = Vector3(3.0, 1.6, 3.0)
		cap_mesh.material = cap_mat
		var cap := MeshInstance3D.new()
		cap.mesh = cap_mesh
		cap.position = Vector3(pos.x, roof_y + 4.8, pos.z)
		parent.add_child(cap)

	if "billboard" in features and h >= 6.0:
		var bb_mat := StandardMaterial3D.new()
		bb_mat.albedo_color = accent
		var bb_mesh := BoxMesh.new()
		bb_mesh.size = Vector3(minf(w * 0.6, 6.0), 1.6, 0.15)
		bb_mesh.material = bb_mat
		var bb := MeshInstance3D.new()
		bb.mesh = bb_mesh
		bb.position = Vector3(pos.x, roof_y + 1.2, pos.z + d * 0.5 + 0.2)
		parent.add_child(bb)

# ------------------------------------------------------------------
# Park content
# ------------------------------------------------------------------

func _populate_park(origin: Vector3) -> void:
	var bx := origin.x
	var bz := origin.z
	var w := BLOCK_WIDTH
	var d := BLOCK_DEPTH

	# Park container so the trees + paths + fountain hide as one unit when
	# the FOV culler decides the whole block is off-screen.
	var container := Node3D.new()
	container.name = "Park_%d_%d" % [int(bx), int(bz)]
	add_child(container)
	container.add_to_group(&"fov_cullable")
	container.set_meta(&"fov_cull_radius", maxf(w, d) * 0.5)
	container.set_meta(&"fov_cull_center", Vector2(bx + w * 0.5, bz + d * 0.5))

	# Cross paths
	var path_w := 3.0
	_create_flat_quad(Vector3(bx + w * 0.5, 0.02, bz + d * 0.5), w, path_w, PARK_PATH_COLOR)
	_create_flat_quad(Vector3(bx + w * 0.5, 0.02, bz + d * 0.5), path_w, d, PARK_PATH_COLOR)

	# Central fountain
	_create_fountain(Vector3(bx + w * 0.5, 0.0, bz + d * 0.5))

	# Scattered trees batched into one MultiMesh
	var positions: Array = []
	var tree_count := 18
	for _i in range(tree_count):
		var tx := bx + _rng.randf_range(SIDEWALK_INSET + 1.0, w - SIDEWALK_INSET - 1.0)
		var tz := bz + _rng.randf_range(SIDEWALK_INSET + 1.0, d - SIDEWALK_INSET - 1.0)
		if absf(tx - (bx + w * 0.5)) < path_w * 0.6:
			continue
		if absf(tz - (bz + d * 0.5)) < path_w * 0.6:
			continue
		positions.append(Vector3(tx, 0.0, tz))
	_emit_tree_field(positions, container, true)

	# A few benches
	for _i in range(6):
		var bxp := bx + _rng.randf_range(SIDEWALK_INSET + 2.0, w - SIDEWALK_INSET - 2.0)
		var bzp := bz + _rng.randf_range(SIDEWALK_INSET + 2.0, d - SIDEWALK_INSET - 2.0)
		_create_bench(Vector3(bxp, 0.0, bzp), _rng.randf() < 0.5)

# ------------------------------------------------------------------
# Farm block — fields, barn, silo, crop rows. Cheap to render: the field
# is a handful of striped quads and the trees/crops are batched.
# ------------------------------------------------------------------

func _populate_farm(origin: Vector3) -> void:
	var bx := origin.x
	var bz := origin.z
	var w := BLOCK_WIDTH
	var d := BLOCK_DEPTH

	var container := Node3D.new()
	container.name = "Farm_%d_%d" % [int(bx), int(bz)]
	add_child(container)
	container.add_to_group(&"fov_cullable")
	container.set_meta(&"fov_cull_radius", maxf(w, d) * 0.5)
	container.set_meta(&"fov_cull_center", Vector2(bx + w * 0.5, bz + d * 0.5))

	# Field base — a tilled-soil rectangle covering most of the block
	var field_color := Color(0.45, 0.32, 0.20)
	_create_flat_quad(
		Vector3(bx + w * 0.5, 0.006, bz + d * 0.5),
		w - 6.0, d - 6.0,
		field_color
	)

	# Crop rows running along the long axis — alternating greens/yellows.
	# Big quads (one per row), so even a 9x9 OPEN_WORLD only adds ~16
	# meshes per farm block.
	var crop_colors := [
		Color(0.55, 0.65, 0.22),
		Color(0.78, 0.72, 0.30),
		Color(0.50, 0.58, 0.20),
	]
	var row_count := 8
	var row_w := (w - 8.0) / float(row_count)
	for r in range(row_count):
		var cx := bx + 4.0 + (r + 0.5) * row_w
		var color: Color = crop_colors[r % crop_colors.size()]
		_create_flat_quad(
			Vector3(cx, 0.012, bz + d * 0.5),
			row_w * 0.7, d - 12.0,
			color
		)

	# Barn — large red structure near one corner
	_create_barn(Vector3(bx + 14.0, 0.0, bz + 18.0))
	# Silo near the barn
	_create_silo(Vector3(bx + 26.0, 0.0, bz + 14.0))

	# A small grove on the opposite corner — softens the perimeter so the
	# field doesn't look like a clean rectangle stamped on the grass.
	var tree_positions: Array = []
	for _i in range(8):
		var tx := bx + _rng.randf_range(w - 22.0, w - 3.0)
		var tz := bz + _rng.randf_range(d - 22.0, d - 3.0)
		tree_positions.append(Vector3(tx, 0.0, tz))
	_emit_tree_field(tree_positions, container, true)

func _create_barn(pos: Vector3) -> void:
	var barn_color := Color(0.65, 0.18, 0.15)
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(12.0, 5.0, 16.0)
	wall_mesh.material = _mat(barn_color, 0.85, 0.0)
	var walls := MeshInstance3D.new()
	walls.mesh = wall_mesh
	walls.position = Vector3(pos.x, 2.5, pos.z)
	add_child(walls)

	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = wall_mesh.size
	cs.shape = shp
	sb.add_child(cs)
	walls.add_child(sb)

	# Pitched roof — a prism on top
	var roof_mesh := PrismMesh.new()
	roof_mesh.size = Vector3(12.4, 3.0, 16.4)
	roof_mesh.material = _mat(Color(0.30, 0.18, 0.14), 0.9, 0.0)
	var roof := MeshInstance3D.new()
	roof.mesh = roof_mesh
	roof.position = Vector3(pos.x, 5.0 + 1.5, pos.z)
	walls.add_child(roof)

	# Door
	var door_mesh := BoxMesh.new()
	door_mesh.size = Vector3(2.0, 3.0, 0.1)
	door_mesh.material = _mat(Color(0.25, 0.15, 0.10), 0.95, 0.0)
	var door := MeshInstance3D.new()
	door.mesh = door_mesh
	door.position = Vector3(pos.x, 1.5, pos.z + 8.05)
	add_child(door)

func _create_silo(pos: Vector3) -> void:
	var mat := _mat(Color(0.78, 0.72, 0.62), 0.6, 0.1)
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 2.0
	body_mesh.bottom_radius = 2.0
	body_mesh.height = 8.0
	body_mesh.material = mat
	var body := MeshInstance3D.new()
	body.mesh = body_mesh
	body.position = Vector3(pos.x, 4.0, pos.z)
	add_child(body)

	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shp := CylinderShape3D.new()
	shp.radius = 2.0
	shp.height = 8.0
	cs.shape = shp
	sb.add_child(cs)
	body.add_child(sb)

	# Dome cap
	var cap_mesh := SphereMesh.new()
	cap_mesh.radius = 2.0
	cap_mesh.height = 2.0
	cap_mesh.material = _mat(Color(0.55, 0.50, 0.42), 0.7, 0.1)
	var cap := MeshInstance3D.new()
	cap.mesh = cap_mesh
	cap.position = Vector3(pos.x, 8.5, pos.z)
	add_child(cap)

# ------------------------------------------------------------------
# Forest block — dense woods. Single MultiMesh per block, no per-tree
# colliders so the player can stroll through (and the physics step
# doesn't choke on hundreds of static bodies at 9x9 map size).
# ------------------------------------------------------------------

func _populate_forest(origin: Vector3) -> void:
	var bx := origin.x
	var bz := origin.z
	var w := BLOCK_WIDTH
	var d := BLOCK_DEPTH

	var container := Node3D.new()
	container.name = "Forest_%d_%d" % [int(bx), int(bz)]
	add_child(container)
	container.add_to_group(&"fov_cullable")
	container.set_meta(&"fov_cull_radius", maxf(w, d) * 0.5)
	container.set_meta(&"fov_cull_center", Vector2(bx + w * 0.5, bz + d * 0.5))

	# Poisson-ish sample of tree positions — accept a candidate only if
	# it's at least min_dist from every previously placed tree.
	var positions: Array = []
	var min_dist := 4.5
	var attempts := 0
	var target := 60
	while positions.size() < target and attempts < target * 8:
		attempts += 1
		var tx := bx + _rng.randf_range(2.0, w - 2.0)
		var tz := bz + _rng.randf_range(2.0, d - 2.0)
		var ok := true
		for p in positions:
			var dx: float = tx - p.x
			var dz: float = tz - p.z
			if dx * dx + dz * dz < min_dist * min_dist:
				ok = false
				break
		if ok:
			positions.append(Vector3(tx, 0.0, tz))
	_emit_tree_field(positions, container, false)

func _create_bench(pos: Vector3, vertical: bool) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.32, 0.22)
	var seat := MeshInstance3D.new()
	var seat_mesh := BoxMesh.new()
	if vertical:
		seat_mesh.size = Vector3(0.5, 0.1, 1.6)
	else:
		seat_mesh.size = Vector3(1.6, 0.1, 0.5)
	seat_mesh.material = mat
	seat.mesh = seat_mesh
	seat.position = Vector3(pos.x, 0.45, pos.z)
	add_child(seat)
	# Backrest
	var back := MeshInstance3D.new()
	var back_mesh := BoxMesh.new()
	if vertical:
		back_mesh.size = Vector3(0.1, 0.6, 1.6)
		back.position = Vector3(pos.x - 0.2, 0.75, pos.z)
	else:
		back_mesh.size = Vector3(1.6, 0.6, 0.1)
		back.position = Vector3(pos.x, 0.75, pos.z - 0.2)
	back_mesh.material = mat
	back.mesh = back_mesh
	add_child(back)

func _create_fountain(pos: Vector3) -> void:
	var stone_mat := StandardMaterial3D.new()
	stone_mat.albedo_color = Color(0.65, 0.62, 0.58)
	stone_mat.roughness = 0.85
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 3.5
	base_mesh.bottom_radius = 3.7
	base_mesh.height = 0.6
	base_mesh.material = stone_mat
	var base := MeshInstance3D.new()
	base.mesh = base_mesh
	base.position = Vector3(pos.x, 0.3, pos.z)
	add_child(base)

	var water_mat := StandardMaterial3D.new()
	water_mat.albedo_color = Color(0.30, 0.55, 0.75, 0.85)
	water_mat.metallic = 0.4
	water_mat.roughness = 0.2
	water_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var water_mesh := CylinderMesh.new()
	water_mesh.top_radius = 3.0
	water_mesh.bottom_radius = 3.0
	water_mesh.height = 0.2
	water_mesh.material = water_mat
	var water := MeshInstance3D.new()
	water.mesh = water_mesh
	water.position = Vector3(pos.x, 0.55, pos.z)
	add_child(water)

	# Centre pillar
	var pillar_mesh := CylinderMesh.new()
	pillar_mesh.top_radius = 0.4
	pillar_mesh.bottom_radius = 0.6
	pillar_mesh.height = 1.6
	pillar_mesh.material = stone_mat
	var pillar := MeshInstance3D.new()
	pillar.mesh = pillar_mesh
	pillar.position = Vector3(pos.x, 1.2, pos.z)
	add_child(pillar)

# ------------------------------------------------------------------
# Parking lot content
# ------------------------------------------------------------------

func _populate_parking_lot(origin: Vector3) -> void:
	var bx := origin.x + SIDEWALK_INSET
	var bz := origin.z + SIDEWALK_INSET
	var w := BLOCK_WIDTH - SIDEWALK_INSET * 2.0
	var d := BLOCK_DEPTH - SIDEWALK_INSET * 2.0

	# Painted parking lines — pairs of rows running along the long axis.
	var stall_w := 2.8
	var stall_d := 5.5
	var rows := int(d / (stall_d * 2.0 + 5.0))
	var cols := int(w / stall_w)

	# Draw row-separating drive lanes lightly
	for r in range(rows):
		var row_z := bz + r * (stall_d * 2.0 + 5.0) + stall_d
		# Two rows of stalls back-to-back per "row" group
		_paint_parking_row(bx, row_z - stall_d, cols, stall_w)
		_paint_parking_row(bx, row_z + stall_d, cols, stall_w)

		# Park some cars
		for c in range(cols):
			if _rng.randf() < 0.6:
				_create_car(Vector3(bx + c * stall_w + stall_w * 0.5, 0.0, row_z - stall_d * 0.5),
					_rng.randf() < 0.5)
			if _rng.randf() < 0.6:
				_create_car(Vector3(bx + c * stall_w + stall_w * 0.5, 0.0, row_z + stall_d * 0.5),
					_rng.randf() < 0.5)

func _paint_parking_row(bx: float, z_center: float, cols: int, stall_w: float) -> void:
	for c in range(cols + 1):
		_emit_parking_line(
			Vector3(bx + c * stall_w, 0.012, z_center),
			0.12, 5.0
		)

func _create_car(pos: Vector3, facing_x: bool) -> void:
	var palette := [
		Color(0.85, 0.20, 0.18), Color(0.20, 0.45, 0.78),
		Color(0.92, 0.92, 0.92), Color(0.15, 0.15, 0.18),
		Color(0.55, 0.55, 0.58), Color(0.95, 0.78, 0.20),
	]
	var car_color: Color = palette[_rng.randi() % palette.size()]
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = car_color
	body_mat.metallic = 0.4
	body_mat.roughness = 0.4

	var width := 1.8
	var length := 4.2
	var bw: float
	var bl: float
	if facing_x:
		bw = length
		bl = width
	else:
		bw = width
		bl = length

	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(bw, 1.2, bl)
	body_mesh.material = body_mat
	var body := MeshInstance3D.new()
	body.mesh = body_mesh
	body.position = Vector3(pos.x, 0.6, pos.z)
	add_child(body)
	body.add_to_group(&"fov_cullable")
	body.set_meta(&"fov_cull_radius", 3.0)

	# Collision
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(bw, 1.2, bl)
	cs.shape = shp
	sb.add_child(cs)
	body.add_child(sb)

	# Cabin / roof
	var roof_mat := StandardMaterial3D.new()
	roof_mat.albedo_color = car_color.darkened(0.15)
	roof_mat.metallic = 0.3
	var roof_mesh := BoxMesh.new()
	if facing_x:
		roof_mesh.size = Vector3(length * 0.55, 0.6, width * 0.85)
	else:
		roof_mesh.size = Vector3(width * 0.85, 0.6, length * 0.55)
	roof_mesh.material = roof_mat
	var roof := MeshInstance3D.new()
	roof.mesh = roof_mesh
	roof.position = Vector3(pos.x, 1.45, pos.z)
	body.add_child(roof)

# ------------------------------------------------------------------
# Plaza content
# ------------------------------------------------------------------

func _populate_plaza(origin: Vector3) -> void:
	var bx := origin.x
	var bz := origin.z
	var w := BLOCK_WIDTH
	var d := BLOCK_DEPTH

	# Decorative grid pattern using darker tiles
	var stripe_color := PLAZA_COLOR.darkened(0.1)
	for i in range(8):
		var t := float(i) / 8.0
		_create_flat_quad(Vector3(bx + w * t + w * 0.0625, 0.011, bz + d * 0.5), 0.4, d * 0.92, stripe_color)

	# Central fountain or pavilion
	_create_fountain(Vector3(bx + w * 0.5, 0.0, bz + d * 0.5))

	# Some benches at the perimeter, paired in groups
	for _i in range(6):
		var bxp := bx + _rng.randf_range(SIDEWALK_INSET + 4.0, w - SIDEWALK_INSET - 4.0)
		var bzp := bz + _rng.randf_range(SIDEWALK_INSET + 4.0, d - SIDEWALK_INSET - 4.0)
		_create_bench(Vector3(bxp, 0.0, bzp), _rng.randf() < 0.5)

	# A small kiosk near a corner
	var kiosk_pos := Vector3(bx + w * 0.85, 1.4, bz + d * 0.15)
	var kiosk_mat := StandardMaterial3D.new()
	kiosk_mat.albedo_color = Color(0.78, 0.45, 0.20)
	var kiosk_mesh := BoxMesh.new()
	kiosk_mesh.size = Vector3(4.0, 2.8, 4.0)
	kiosk_mesh.material = kiosk_mat
	var kiosk := MeshInstance3D.new()
	kiosk.mesh = kiosk_mesh
	kiosk.position = kiosk_pos
	add_child(kiosk)
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	shp.size = Vector3(4.0, 2.8, 4.0)
	cs.shape = shp
	sb.add_child(cs)
	kiosk.add_child(sb)

# ------------------------------------------------------------------
# Roads — full network with lane markings and crosswalks.
# ------------------------------------------------------------------

func _generate_road_network(origin: Vector3) -> void:
	# Vertical roads (one per column gap, plus the +X edge of the last column)
	for col in range(num_blocks):
		var rx := origin.x + col * CELL_WIDTH + BLOCK_WIDTH + ROAD_WIDTH * 0.5
		var rz_center := origin.z + (num_blocks * CELL_DEPTH) * 0.5
		_create_flat_quad(Vector3(rx, 0.008, rz_center), ROAD_WIDTH, num_blocks * CELL_DEPTH, ROAD_COLOR)
		# Centre dashed yellow line
		_paint_dashed_line(Vector3(rx, 0.014, origin.z), Vector3(rx, 0.014, origin.z + num_blocks * CELL_DEPTH), false)

	# Horizontal roads
	for row in range(num_blocks):
		var rz := origin.z + row * CELL_DEPTH + BLOCK_DEPTH + ROAD_WIDTH * 0.5
		var rx_center := origin.x + (num_blocks * CELL_WIDTH) * 0.5
		_create_flat_quad(Vector3(rx_center, 0.008, rz), num_blocks * CELL_WIDTH, ROAD_WIDTH, ROAD_COLOR)
		_paint_dashed_line(Vector3(origin.x, 0.014, rz), Vector3(origin.x + num_blocks * CELL_WIDTH, 0.014, rz), true)

	# Crosswalks at each intersection (4 walks per intersection)
	for col in range(num_blocks):
		for row in range(num_blocks):
			var ix := origin.x + col * CELL_WIDTH + BLOCK_WIDTH + ROAD_WIDTH * 0.5
			var iz := origin.z + row * CELL_DEPTH + BLOCK_DEPTH + ROAD_WIDTH * 0.5
			_create_crosswalk(Vector3(ix, 0.018, iz - ROAD_WIDTH * 0.5 - 1.2), true)
			_create_crosswalk(Vector3(ix, 0.018, iz + ROAD_WIDTH * 0.5 + 1.2), true)
			_create_crosswalk(Vector3(ix - ROAD_WIDTH * 0.5 - 1.2, 0.018, iz), false)
			_create_crosswalk(Vector3(ix + ROAD_WIDTH * 0.5 + 1.2, 0.018, iz), false)

func _paint_dashed_line(start_pos: Vector3, end_pos: Vector3, horizontal: bool) -> void:
	var dash_len := 3.0
	var gap_len := 3.0
	var total := start_pos.distance_to(end_pos)
	var steps := int(total / (dash_len + gap_len))
	var dir := (end_pos - start_pos).normalized()
	for i in range(steps):
		var t := i * (dash_len + gap_len) + dash_len * 0.5
		var p := start_pos + dir * t
		var w := dash_len if horizontal else 0.15
		var d := 0.15 if horizontal else dash_len
		_emit_road_mark(p, w, d)

func _create_crosswalk(center: Vector3, horizontal: bool) -> void:
	# Crosswalk is a series of white stripes across the road, perpendicular
	# to the flow of traffic. `horizontal` means the crosswalk runs along
	# the X axis (it crosses an N-S road). Stripes span across the road.
	# Crosswalk stripes share the road-mark MultiMesh — they're white, not
	# yellow, but at this scale + camera angle the bias toward batching is
	# more visible than the colour difference.
	var stripe_count := 6
	var stripe_w := 0.45
	var gap := 0.35
	var road_w := ROAD_WIDTH - 1.0
	var pitch := stripe_w + gap
	for i in range(stripe_count):
		var off := (i - (stripe_count - 1) * 0.5) * pitch
		if horizontal:
			_emit_road_mark(
				Vector3(center.x + off, center.y, center.z),
				stripe_w, road_w
			)
		else:
			_emit_road_mark(
				Vector3(center.x, center.y, center.z + off),
				road_w, stripe_w
			)

# ------------------------------------------------------------------
# Entrance / door geometry (used by every building)
# ------------------------------------------------------------------

func _pick_entrance_side(pos: Vector3, w: float, d: float, block_x: float, block_z: float) -> Vector3:
	var dist_left  := absf(pos.x - w * 0.5 - block_x)
	var dist_right := absf(pos.x + w * 0.5 - (block_x + BLOCK_WIDTH))
	var dist_front := absf(pos.z + d * 0.5 - (block_z + BLOCK_DEPTH))
	var dist_back  := absf(pos.z - d * 0.5 - block_z)

	var min_dist := dist_left
	var dir := Vector3(-1, 0, 0)

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
	var ground_y := pos.y - h * 0.5
	if facing.x != 0:
		return Vector3(pos.x + facing.x * w * 0.5, ground_y, pos.z)
	else:
		return Vector3(pos.x, ground_y, pos.z + facing.z * d * 0.5)

func _create_door(parent: Node3D, entrance_pos: Vector3, facing: Vector3,
		building_color: Color, accent: Color, features: Array, _type_name: String) -> Dictionary:
	var door_w := 1.2
	var door_h := 2.2

	# Pivot at hinge edge
	var hinge_offset := Vector3.UP.cross(facing) * (door_w * 0.5)
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	pivot.position = entrance_pos + hinge_offset + Vector3(facing.x * 0.05, 0.0, facing.z * 0.05)
	var base_angle := atan2(facing.x, facing.z)
	pivot.rotation.y = base_angle
	parent.add_child(pivot)

	# Door mesh
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

	# Door collision
	var door_body := StaticBody3D.new()
	door_body.name = "DoorBody"
	var door_col := CollisionShape3D.new()
	var door_col_shape := BoxShape3D.new()
	door_col_shape.size = Vector3(door_w, door_h, 0.15)
	door_col.shape = door_col_shape
	door_body.position = Vector3(-door_w * 0.5, door_h * 0.5, 0.0)
	door_body.add_child(door_col)
	pivot.add_child(door_body)

	# Awning above the door — most buildings get one
	if "awning" in features or "sign" in features:
		var awning_color: Color = accent
		if "awning" in features:
			awning_color = AWNING_COLORS[_rng.randi() % AWNING_COLORS.size()]
		var awning_mat := StandardMaterial3D.new()
		awning_mat.albedo_color = awning_color
		var awning_mesh := BoxMesh.new()
		if facing.x != 0:
			awning_mesh.size = Vector3(0.9, 0.1, door_w + 1.2)
		else:
			awning_mesh.size = Vector3(door_w + 1.2, 0.1, 0.9)
		awning_mesh.material = awning_mat
		var awning_mi := MeshInstance3D.new()
		awning_mi.mesh = awning_mesh
		awning_mi.position = entrance_pos + Vector3(facing.x * 0.5, door_h + 0.2, facing.z * 0.5)
		parent.add_child(awning_mi)

	# Sign plaque above the awning — uses the accent colour as the plaque
	if "sign" in features:
		var sign_mat := StandardMaterial3D.new()
		sign_mat.albedo_color = accent
		sign_mat.emission_enabled = true
		sign_mat.emission = accent
		sign_mat.emission_energy_multiplier = 0.6
		var sign_mesh := BoxMesh.new()
		if facing.x != 0:
			sign_mesh.size = Vector3(0.06, 0.7, 2.4)
		else:
			sign_mesh.size = Vector3(2.4, 0.7, 0.06)
		sign_mesh.material = sign_mat
		var sign_mi := MeshInstance3D.new()
		sign_mi.mesh = sign_mesh
		sign_mi.position = entrance_pos + Vector3(facing.x * 0.55, door_h + 1.05, facing.z * 0.55)
		parent.add_child(sign_mi)

	# Garage gate (warehouse / factory)
	if "gate" in features:
		var gate_mat := StandardMaterial3D.new()
		gate_mat.albedo_color = Color(0.32, 0.32, 0.34)
		var gate_mesh := BoxMesh.new()
		if facing.x != 0:
			gate_mesh.size = Vector3(0.1, 3.8, 4.0)
		else:
			gate_mesh.size = Vector3(4.0, 3.8, 0.1)
		gate_mesh.material = gate_mat
		var gate_mi := MeshInstance3D.new()
		gate_mi.mesh = gate_mesh
		var gate_offset := 3.5
		gate_mi.position = entrance_pos + Vector3(
			facing.x * 0.05 + (facing.z * gate_offset if facing.x != 0 else 0.0),
			1.9,
			facing.z * 0.05 + (facing.x * gate_offset if facing.z != 0 else 0.0)
		)
		parent.add_child(gate_mi)

	return {pivot = pivot, base_angle = base_angle}

func _create_entrance_area(parent: Node3D, entrance_pos: Vector3, facing: Vector3) -> Area3D:
	var area := Area3D.new()
	area.name = "EntranceArea"
	var cs := CollisionShape3D.new()
	var shp := BoxShape3D.new()
	if absf(facing.x) > 0.5:
		shp.size = Vector3(3.0, 2.5, 2.0)
	else:
		shp.size = Vector3(2.0, 2.5, 3.0)
	cs.shape = shp
	area.add_child(cs)
	area.position = entrance_pos + Vector3(0.0, 1.25, 0.0)
	parent.add_child(area)
	return area

# ------------------------------------------------------------------
# Helper: flat coloured quad (for roads / sidewalks)
# ------------------------------------------------------------------

func _create_flat_quad(pos: Vector3, w: float, d: float, color: Color) -> void:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(w, d)
	mesh.material = _mat(color, 0.85 if color == ROAD_COLOR else 0.9, 0.0)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)

# ------------------------------------------------------------------
# Performance helpers — material cache + batched MultiMesh emitters
# ------------------------------------------------------------------

## Return a StandardMaterial3D that the world script reuses across every
## mesh asking for the same (colour, roughness, metallic) tuple. Sharing
## materials avoids per-mesh allocations and gives Godot's renderer the
## chance to batch identical surfaces.
func _mat(color: Color, roughness: float = 0.75, metallic: float = 0.05) -> StandardMaterial3D:
	var key := "%d_%d_%d_%d_%d_%d" % [
		int(color.r * 255), int(color.g * 255), int(color.b * 255),
		int(color.a * 255), int(roughness * 100), int(metallic * 100),
	]
	var existing: StandardMaterial3D = _mat_cache.get(key, null)
	if existing != null:
		return existing
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	_mat_cache[key] = mat
	return mat

## Queue a single road-paint quad (lane dash, crosswalk stripe). All
## queued quads are emitted as a single MultiMesh once the road network
## is fully laid down — cuts thousands of quads down to one draw call.
func _emit_road_mark(pos: Vector3, w: float, d: float) -> void:
	var t := Transform3D.IDENTITY
	t.basis = Basis().scaled(Vector3(w, 1.0, d))
	t.origin = pos
	_road_mark_xforms.append(t)

## Queue a parking-stall line. Slightly thinner; uses the parking line
## colour rather than the lane-mark yellow.
func _emit_parking_line(pos: Vector3, w: float, d: float) -> void:
	var t := Transform3D.IDENTITY
	t.basis = Basis().scaled(Vector3(w, 1.0, d))
	t.origin = pos
	_parking_line_xforms.append(t)

func _flush_road_marks() -> void:
	if _road_mark_xforms.size() > 0:
		_emit_multimesh_quads(_road_mark_xforms, ROAD_MARK_COLOR, "RoadMarks")
		_road_mark_xforms.clear()
	if _parking_line_xforms.size() > 0:
		_emit_multimesh_quads(_parking_line_xforms, PARKING_LINE_COLOR, "ParkingLines")
		_parking_line_xforms.clear()

## Build a single MultiMeshInstance3D from a transform list. The base
## mesh is a 1×1 unit plane; each transform scales it to the desired
## quad size and places it in world space.
func _emit_multimesh_quads(xforms: Array, color: Color, debug_name: String) -> void:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(1.0, 1.0)
	mesh.material = _mat(color, 0.9, 0.0)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in range(xforms.size()):
		mm.set_instance_transform(i, xforms[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.name = debug_name
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

## Build trunk + leaf MultiMeshes for an array of tree XZ positions.
## Used by park / forest / farm blocks. Trees inside the same block share
## one MultiMesh per part so the whole field renders as 2 draw calls.
## When with_collision is true (default for parks) each tree also gets a
## thin StaticBody3D so the player can't walk through it; forest blocks
## skip the colliders to keep the physics step cheap.
func _emit_tree_field(positions: Array, parent: Node3D, with_collision: bool = true) -> void:
	if positions.is_empty():
		return

	var trunk_color := Color(0.32, 0.22, 0.15)
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.25
	trunk_mesh.bottom_radius = 0.35
	trunk_mesh.height = 2.0
	trunk_mesh.material = _mat(trunk_color, 0.95, 0.0)

	var trunk_mm := MultiMesh.new()
	trunk_mm.transform_format = MultiMesh.TRANSFORM_3D
	trunk_mm.mesh = trunk_mesh
	trunk_mm.instance_count = positions.size()

	var leaf_mesh := SphereMesh.new()
	leaf_mesh.radius = 1.6
	leaf_mesh.height = 3.2
	leaf_mesh.material = _mat(Color(0.24, 0.50, 0.21), 0.9, 0.0)

	var leaf_mm := MultiMesh.new()
	leaf_mm.transform_format = MultiMesh.TRANSFORM_3D
	leaf_mm.mesh = leaf_mesh
	leaf_mm.instance_count = positions.size()

	for i in range(positions.size()):
		var p: Vector3 = positions[i]
		var t_trunk := Transform3D.IDENTITY
		t_trunk.origin = Vector3(p.x, 1.0, p.z)
		trunk_mm.set_instance_transform(i, t_trunk)
		var t_leaf := Transform3D.IDENTITY
		t_leaf.origin = Vector3(p.x, 3.0, p.z)
		leaf_mm.set_instance_transform(i, t_leaf)

	var trunk_mmi := MultiMeshInstance3D.new()
	trunk_mmi.multimesh = trunk_mm
	trunk_mmi.name = "TreeTrunks"
	parent.add_child(trunk_mmi)

	var leaf_mmi := MultiMeshInstance3D.new()
	leaf_mmi.multimesh = leaf_mm
	leaf_mmi.name = "TreeLeaves"
	leaf_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(leaf_mmi)

	if not with_collision:
		return
	# Per-tree colliders. Cheap individually but adds up — caller turns
	# this off for forest blocks where there are 60+ trees.
	for p in positions:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shp := CylinderShape3D.new()
		shp.height = 2.0
		shp.radius = 0.35
		cs.shape = shp
		sb.position = Vector3(p.x, 1.0, p.z)
		sb.add_child(cs)
		parent.add_child(sb)

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
	# Larger world → push the cascaded shadow farther so distant buildings
	# still receive crisp shadows.
	sun.directional_shadow_max_distance = 240.0
	add_child(sun)
	_sun = sun

	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-30.0, -140.0, 0.0)
	fill.light_energy = 0.35
	fill.light_color = Color(0.75, 0.82, 1.0)
	fill.shadow_enabled = false
	add_child(fill)
	_fill = fill

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
	_env = env
	_sky_mat = sky_mat

# ------------------------------------------------------------------
# Day / night cycle (Survival mode)
# ------------------------------------------------------------------

## Drive the sky and lights from the game clock. `hour` is the fractional
## hour-of-day (13.5 == 13:30). Campaign never calls this, so those runs keep
## the fixed midday lighting they've always had.
##
## The sun sweeps from the eastern horizon at 06:00 to the western one at
## 18:00; outside that window everything drops to a cold, dim moonlit look.
func set_time_of_day(hour: float) -> void:
	if _sun == null:
		return
	var day_t := clampf((hour - 6.0) / 12.0, 0.0, 1.0)   # 0 at dawn, 1 at dusk
	var is_daytime := hour >= 6.0 and hour < 18.0
	# 0 at the horizons, 1 at noon — drives both elevation and brightness.
	var elevation := sin(day_t * PI) if is_daytime else 0.0

	_sun.rotation_degrees = Vector3(-(6.0 + elevation * 66.0), -60.0 + day_t * 200.0, 0.0)
	_sun.light_energy = 0.05 + elevation * 1.45
	# Warm at the horizons, neutral at noon.
	_sun.light_color = Color(1.0, 0.62, 0.38).lerp(Color(1.0, 0.97, 0.92), clampf(elevation * 1.6, 0.0, 1.0))
	_sun.visible = is_daytime

	if _fill:
		# Night keeps a faint blue fill so the city reads as moonlit rather than black.
		_fill.light_energy = 0.10 + elevation * 0.28
		_fill.light_color = Color(0.45, 0.55, 0.95) if not is_daytime else Color(0.75, 0.82, 1.0)

	if _env:
		_env.ambient_light_energy = 0.10 + elevation * 0.45
		_env.fog_light_color = Color(0.10, 0.13, 0.22).lerp(Color(0.65, 0.72, 0.82), elevation)

	if _sky_mat:
		var night_top := Color(0.03, 0.04, 0.09)
		var night_horizon := Color(0.08, 0.10, 0.18)
		var dusk_horizon := Color(0.85, 0.55, 0.35)
		_sky_mat.sky_top_color = night_top.lerp(Color(0.35, 0.55, 0.85), elevation)
		# Blend through a sunset band so dawn/dusk aren't a hard cut to night.
		var horizon := night_horizon.lerp(dusk_horizon, clampf(elevation * 3.0, 0.0, 1.0))
		_sky_mat.sky_horizon_color = horizon.lerp(Color(0.65, 0.75, 0.90), clampf((elevation - 0.35) / 0.65, 0.0, 1.0))
