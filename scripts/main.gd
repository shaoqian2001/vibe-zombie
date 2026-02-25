extends Node

## Main scene controller.
## Wires up the camera → player link, handles player spawn,
## and manages entering / exiting buildings.

const BuildingInterior = preload("res://scripts/building_interior.gd")

# Spawn point: far from map centre (near the rim of the 5×5 block grid).
const SPAWN_CANDIDATES := [
	Vector3( 38.0, 0.5,  38.0),
	Vector3(-38.0, 0.5,  38.0),
	Vector3( 38.0, 0.5, -38.0),
	Vector3(-38.0, 0.5, -38.0),
]

const BUILDING_TYPE_NAMES := [
	"Convenience Store",
	"Apartment",
	"Office",
	"Warehouse",
	"Diner",
]

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D        = $Camera3D
@onready var world: Node3D           = $World

# UI elements
var _prompt_label: Label = null

# State tracking
var _nearby_building: Dictionary = {}   # The building dict the player is near (or empty)
var _inside_building: bool = false
var _current_interior: Node3D = null     # The BuildingInterior node when indoors
var _saved_outdoor_pos: Vector3          # Where the player was before entering

# The building info for the building we're currently inside
var _current_building_info: Dictionary = {}

func _ready() -> void:
	# Pick a random rim spawn
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var spawn_pos: Vector3 = SPAWN_CANDIDATES[rng.randi() % SPAWN_CANDIDATES.size()]
	player.global_position = spawn_pos

	# Connect camera to player
	camera.set_target(player)

	# Create the UI prompt
	_create_ui()

	# Connect entrance areas after world finishes generating
	await get_tree().process_frame
	_connect_entrance_areas()

func _process(_delta: float) -> void:
	_update_prompt_visibility()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		if _inside_building:
			_exit_building()
		elif not _nearby_building.is_empty():
			_enter_building(_nearby_building)

# ------------------------------------------------------------------
# UI
# ------------------------------------------------------------------

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	_prompt_label = Label.new()
	_prompt_label.text = "Press E to Enter"
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	# Style the label
	_prompt_label.add_theme_font_size_override("font_size", 22)
	_prompt_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_prompt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_prompt_label.add_theme_constant_override("shadow_offset_x", 2)
	_prompt_label.add_theme_constant_override("shadow_offset_y", 2)

	# Position at bottom-centre of screen
	_prompt_label.anchors_preset = Control.PRESET_CENTER_BOTTOM
	_prompt_label.position = Vector2(-100, -60)
	_prompt_label.size = Vector2(200, 40)
	_prompt_label.visible = false

	canvas.add_child(_prompt_label)

func _update_prompt_visibility() -> void:
	if _prompt_label == null:
		return
	if _inside_building:
		_prompt_label.text = "Press E to Exit"
		_prompt_label.visible = true
	elif not _nearby_building.is_empty():
		var btype: int = _nearby_building.type
		var type_name: String = BUILDING_TYPE_NAMES[btype] if btype < BUILDING_TYPE_NAMES.size() else "Building"
		_prompt_label.text = "Press E to Enter " + type_name
		_prompt_label.visible = true
	else:
		_prompt_label.visible = false

# ------------------------------------------------------------------
# Entrance area connections
# ------------------------------------------------------------------

func _connect_entrance_areas() -> void:
	for binfo in world.buildings:
		var area: Area3D = binfo.entrance_area
		# Use lambdas that capture the building info
		area.body_entered.connect(func(body: Node3D) -> void:
			if body == player and not _inside_building:
				_nearby_building = binfo
		)
		area.body_exited.connect(func(body: Node3D) -> void:
			if body == player and _nearby_building == binfo:
				_nearby_building = {}
		)

# ------------------------------------------------------------------
# Enter / Exit building
# ------------------------------------------------------------------

func _enter_building(binfo: Dictionary) -> void:
	_inside_building = true
	_current_building_info = binfo
	_saved_outdoor_pos = player.global_position

	# Hide the outdoor world
	world.visible = false
	# Disable outdoor collision by hiding all static bodies in world
	_set_world_collision(false)

	# Create the interior
	_current_interior = Node3D.new()
	_current_interior.name = "BuildingInterior"
	_current_interior.set_script(BuildingInterior)
	add_child(_current_interior)

	# Position interior at the origin for simplicity
	_current_interior.global_position = Vector3.ZERO
	_current_interior.setup(
		binfo.type as BuildingInterior.BuildingType,
		binfo.width,
		binfo.depth,
		binfo.height
	)

	# Place player inside near the exit door (front of the interior, +Z side)
	var interior_d: float = maxf(binfo.depth, 4.0)
	player.global_position = Vector3(0.0, 0.1, interior_d * 0.35)
	player.velocity = Vector3.ZERO

	# Adjust camera for indoor view
	camera.distance = 10.0
	camera.pitch_deg = 50.0
	camera._update_offset()

	# Connect exit area
	if _current_interior.exit_area:
		_current_interior.exit_area.body_entered.connect(func(body: Node3D) -> void:
			if body == player and _inside_building:
				# Show the exit prompt - player still needs to press E
				pass
		)

	# Create interior environment (darker, indoor lighting)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.08, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.25, 0.25, 0.28)
	env.ambient_light_energy = 0.5

	var we := WorldEnvironment.new()
	we.name = "IndoorEnvironment"
	we.environment = env
	_current_interior.add_child(we)

	_nearby_building = {}

func _exit_building() -> void:
	_inside_building = false

	# Remove interior
	if _current_interior:
		_current_interior.queue_free()
		_current_interior = null

	# Show outdoor world again
	world.visible = true
	_set_world_collision(true)

	# Restore player position (slightly in front of the entrance)
	var facing: Vector3 = _current_building_info.get("entrance_facing", Vector3(0, 0, 1))
	player.global_position = _saved_outdoor_pos + facing * 1.5
	player.velocity = Vector3.ZERO

	# Restore camera for outdoor view
	camera.distance = 22.0
	camera.pitch_deg = 42.0
	camera._update_offset()

	_current_building_info = {}
	_nearby_building = {}

func _set_world_collision(enabled: bool) -> void:
	# Enable or disable all collision shapes in the world node
	var static_bodies := _find_nodes_of_type(world, "StaticBody3D")
	for sb in static_bodies:
		(sb as StaticBody3D).process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
		for child in sb.get_children():
			if child is CollisionShape3D:
				(child as CollisionShape3D).disabled = not enabled

	# Also handle entrance Area3D nodes
	var areas := _find_nodes_of_type(world, "Area3D")
	for a in areas:
		(a as Area3D).monitoring = enabled
		(a as Area3D).monitorable = enabled

func _find_nodes_of_type(root: Node, type_name: String) -> Array:
	var result := []
	for child in root.get_children():
		if child.get_class() == type_name:
			result.append(child)
		result.append_array(_find_nodes_of_type(child, type_name))
	return result
