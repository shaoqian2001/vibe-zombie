extends Node3D

## Main scene controller.
## Wires up the camera → player link, handles player spawn,
## and manages seamless building enter / exit transitions.
##
## Buildings are entered/exited by walking through the door — no key press.
## The interior is spawned at the building's world position so the camera
## and player position stay continuous (no jump).

const BuildingInterior = preload("res://scripts/building_interior.gd")

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

# UI
var _prompt_label: Label = null

# State
var _nearby_building: Dictionary = {}
var _inside_building: bool = false
var _current_interior: Node3D = null
var _current_building_info: Dictionary = {}

# Cooldown to prevent instant re-enter after exiting
var _transition_cooldown: float = 0.0
const TRANSITION_COOLDOWN_TIME := 0.8

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var spawn_pos: Vector3 = SPAWN_CANDIDATES[rng.randi() % SPAWN_CANDIDATES.size()]
	player.global_position = spawn_pos

	camera.set_target(player)
	_create_ui()

	await get_tree().process_frame
	_connect_entrance_areas()

func _process(delta: float) -> void:
	_update_prompt()

	if _transition_cooldown > 0.0:
		_transition_cooldown -= delta

# ------------------------------------------------------------------
# UI
# ------------------------------------------------------------------

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	_prompt_label = Label.new()
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 20)
	_prompt_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_prompt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_prompt_label.add_theme_constant_override("shadow_offset_x", 2)
	_prompt_label.add_theme_constant_override("shadow_offset_y", 2)
	_prompt_label.anchors_preset = Control.PRESET_CENTER_BOTTOM
	_prompt_label.position = Vector2(-150, -60)
	_prompt_label.size = Vector2(300, 40)
	_prompt_label.visible = false
	canvas.add_child(_prompt_label)

func _update_prompt() -> void:
	if _prompt_label == null:
		return
	if _inside_building:
		var btype: int = _current_building_info.get("type", 0)
		var type_name: String = BUILDING_TYPE_NAMES[btype] if btype < BUILDING_TYPE_NAMES.size() else "Building"
		_prompt_label.text = "Inside: " + type_name + "  (walk to door to exit)"
		_prompt_label.visible = true
	elif not _nearby_building.is_empty():
		var btype: int = _nearby_building.type
		var type_name: String = BUILDING_TYPE_NAMES[btype] if btype < BUILDING_TYPE_NAMES.size() else "Building"
		_prompt_label.text = type_name
		_prompt_label.visible = true
	else:
		_prompt_label.visible = false

# ------------------------------------------------------------------
# Entrance / exit area connections
# ------------------------------------------------------------------

func _connect_entrance_areas() -> void:
	for binfo in world.buildings:
		var area: Area3D = binfo.entrance_area
		area.body_entered.connect(func(body: Node3D) -> void:
			if body == player:
				if not _inside_building and _transition_cooldown <= 0.0:
					_nearby_building = binfo
					_enter_building(binfo)
		)
		area.body_exited.connect(func(body: Node3D) -> void:
			if body == player and _nearby_building == binfo:
				_nearby_building = {}
		)

# ------------------------------------------------------------------
# Enter building — seamless in-place transition
# ------------------------------------------------------------------

func _enter_building(binfo: Dictionary) -> void:
	_inside_building = true
	_current_building_info = binfo
	_transition_cooldown = TRANSITION_COOLDOWN_TIME

	# Make the entered building's exterior semi-transparent
	var building_node: MeshInstance3D = binfo.node
	_set_building_transparency(building_node, 0.2)
	# Disable exterior collision for this building
	for child in building_node.get_children():
		if child is StaticBody3D:
			child.process_mode = Node.PROCESS_MODE_DISABLED
			for sub in child.get_children():
				if sub is CollisionShape3D:
					(sub as CollisionShape3D).disabled = true

	# Disable all entrance areas while inside
	for bi in world.buildings:
		var a: Area3D = bi.entrance_area
		a.monitoring = false
		a.monitorable = false

	# Compute building centre at ground level
	var bpos: Vector3 = building_node.position
	var building_ground := Vector3(bpos.x, 0.0, bpos.z)

	# Create interior at the building's world position
	_current_interior = Node3D.new()
	_current_interior.name = "BuildingInterior"
	_current_interior.set_script(BuildingInterior)
	add_child(_current_interior)

	var facing: Vector3 = binfo.entrance_facing
	# When entrance faces ±X the interior rotates 90°, so local X↔Z swap.
	# Swap width/depth so the interior walls align with the exterior box.
	var iw: float = binfo.width
	var id: float = binfo.depth
	if absf(facing.x) > 0.5:
		iw = binfo.depth
		id = binfo.width
	_current_interior.setup(
		binfo.type as BuildingInterior.BuildingType,
		iw, id, binfo.height,
		building_ground, facing, binfo.color
	)

	# Move player just inside the entrance (small step inward from door)
	# The entrance is on the +Z side of the interior (in local space).
	# Inward = -Z in local space. Transform to world space.
	var inward_local := Vector3(0.0, 0.0, id * 0.35)
	var inward_world := _current_interior.global_transform * inward_local
	player.global_position = Vector3(inward_world.x, 0.1, inward_world.z)
	player.velocity = Vector3.ZERO

	# Connect exit area
	if _current_interior.exit_area:
		_current_interior.exit_area.body_entered.connect(func(body: Node3D) -> void:
			if body == player and _inside_building and _transition_cooldown <= 0.0:
				_exit_building()
		)

# ------------------------------------------------------------------
# Exit building — seamless return to outdoor
# ------------------------------------------------------------------

func _exit_building() -> void:
	_inside_building = false
	_transition_cooldown = TRANSITION_COOLDOWN_TIME

	# Restore the building's exterior mesh to full opacity
	var building_node: MeshInstance3D = _current_building_info.node
	_set_building_transparency(building_node, 1.0)
	for child in building_node.get_children():
		if child is StaticBody3D:
			child.process_mode = Node.PROCESS_MODE_INHERIT
			for sub in child.get_children():
				if sub is CollisionShape3D:
					(sub as CollisionShape3D).disabled = false

	# Place player just outside the entrance
	var facing: Vector3 = _current_building_info.entrance_facing
	var entrance_pos: Vector3 = _current_building_info.entrance_pos
	player.global_position = entrance_pos + facing * 1.2 + Vector3(0.0, 0.1, 0.0)
	player.velocity = Vector3.ZERO

	# Remove interior
	if _current_interior:
		_current_interior.queue_free()
		_current_interior = null

	# Re-enable entrance areas
	for bi in world.buildings:
		var a: Area3D = bi.entrance_area
		a.monitoring = true
		a.monitorable = true

	_current_building_info = {}
	_nearby_building = {}

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

func _set_building_transparency(mi: MeshInstance3D, alpha: float) -> void:
	var mat: StandardMaterial3D = mi.mesh.material as StandardMaterial3D
	if mat == null:
		return
	if alpha >= 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.albedo_color.a = 1.0
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = alpha
