extends Node3D

## Main scene controller.
## Wires up the camera → player link, handles player spawn,
## and manages seamless building enter / exit transitions.
##
## Press F near a closed door to open it.  Once open the player can
## walk freely in and out.  Press F near an open door to close it.

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
var _nearby_building: Dictionary = {}   # building whose entrance area the player overlaps
var _open_building: Dictionary = {}     # building whose door is currently open
var _current_interior: Node3D = null    # interior node for the open building
var _player_inside: bool = false        # whether the player is inside the open building

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var spawn_pos: Vector3 = SPAWN_CANDIDATES[rng.randi() % SPAWN_CANDIDATES.size()]
	player.global_position = spawn_pos

	camera.set_target(player)
	_create_ui()

	await get_tree().process_frame
	_connect_entrance_areas()

func _process(_delta: float) -> void:
	_update_player_inside()
	_update_prompt()
	_update_interior_wall_visibility()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		_handle_interact()

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
	_prompt_label.position = Vector2(-200, -60)
	_prompt_label.size = Vector2(400, 40)
	_prompt_label.visible = false
	canvas.add_child(_prompt_label)

func _update_prompt() -> void:
	if _prompt_label == null:
		return

	if _player_inside and not _open_building.is_empty():
		var btype: int = _open_building.get("type", 0)
		var type_name: String = BUILDING_TYPE_NAMES[btype] if btype < BUILDING_TYPE_NAMES.size() else "Building"
		_prompt_label.text = "Inside: " + type_name
		_prompt_label.visible = true
	elif not _nearby_building.is_empty():
		var is_open: bool = _nearby_building.get("door_open", false)
		if is_open:
			_prompt_label.text = "Press 'F' to close the door"
		else:
			_prompt_label.text = "Press 'F' to open the door"
		_prompt_label.visible = true
	else:
		_prompt_label.visible = false

# ------------------------------------------------------------------
# Entrance area connections (proximity detection only)
# ------------------------------------------------------------------

func _connect_entrance_areas() -> void:
	for binfo in world.buildings:
		var area: Area3D = binfo.entrance_area
		area.body_entered.connect(func(body: Node3D) -> void:
			if body == player:
				_nearby_building = binfo
		)
		area.body_exited.connect(func(body: Node3D) -> void:
			if body == player and _nearby_building == binfo:
				_nearby_building = {}
		)

# ------------------------------------------------------------------
# Interact (F key)
# ------------------------------------------------------------------

func _handle_interact() -> void:
	if _nearby_building.is_empty():
		return

	var is_open: bool = _nearby_building.get("door_open", false)
	if is_open:
		# Don't close while player is inside
		if _player_inside:
			return
		_close_door()
	else:
		_open_door(_nearby_building)

# ------------------------------------------------------------------
# Open door
# ------------------------------------------------------------------

func _open_door(binfo: Dictionary) -> void:
	# Close any previously open building first
	if not _open_building.is_empty():
		_close_door()

	binfo.door_open = true
	_open_building = binfo

	# Hide exterior mesh
	var building_node: MeshInstance3D = binfo.node
	building_node.visible = false

	# Hide the door panel
	var door_mi: MeshInstance3D = binfo.door_mesh
	door_mi.visible = false

	# Disable exterior collision so player can walk inside
	for child in building_node.get_children():
		if child is StaticBody3D:
			child.process_mode = Node.PROCESS_MODE_DISABLED
			for sub in child.get_children():
				if sub is CollisionShape3D:
					(sub as CollisionShape3D).disabled = true

	# Create interior at the building's world position
	var bpos: Vector3 = building_node.position
	var building_ground := Vector3(bpos.x, 0.0, bpos.z)

	_current_interior = Node3D.new()
	_current_interior.name = "BuildingInterior"
	_current_interior.set_script(BuildingInterior)
	add_child(_current_interior)

	var facing: Vector3 = binfo.entrance_facing
	# When entrance faces ±X the interior rotates 90°, so local X↔Z swap.
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

# ------------------------------------------------------------------
# Close door
# ------------------------------------------------------------------

func _close_door() -> void:
	if _open_building.is_empty():
		return

	_open_building.door_open = false

	# Restore exterior mesh
	var building_node: MeshInstance3D = _open_building.node
	building_node.visible = true

	# Show the door panel again
	var door_mi: MeshInstance3D = _open_building.door_mesh
	door_mi.visible = true

	# Re-enable exterior collision
	for child in building_node.get_children():
		if child is StaticBody3D:
			child.process_mode = Node.PROCESS_MODE_INHERIT
			for sub in child.get_children():
				if sub is CollisionShape3D:
					(sub as CollisionShape3D).disabled = false

	# Remove interior
	if _current_interior:
		_current_interior.queue_free()
		_current_interior = null

	_open_building = {}
	_player_inside = false

# ------------------------------------------------------------------
# Position-based inside detection
# ------------------------------------------------------------------

func _update_player_inside() -> void:
	if _open_building.is_empty():
		_player_inside = false
		return
	var bpos: Vector3 = _open_building.node.position
	var hw: float = _open_building.width * 0.5
	var hd: float = _open_building.depth * 0.5
	var px: float = player.global_position.x
	var pz: float = player.global_position.z
	_player_inside = (px > bpos.x - hw and px < bpos.x + hw
		and pz > bpos.z - hd and pz < bpos.z + hd)

# ------------------------------------------------------------------
# Interior wall visibility based on camera angle
# ------------------------------------------------------------------

func _update_interior_wall_visibility() -> void:
	if not _player_inside or _current_interior == null:
		return
	# Camera direction in world space (from player toward camera)
	var cam_dir := camera.global_position - player.global_position
	cam_dir.y = 0.0
	if cam_dir.length_squared() < 0.001:
		return
	cam_dir = cam_dir.normalized()
	# Transform to interior local space
	var local_dir := _current_interior.global_transform.basis.inverse() * cam_dir
	_current_interior.update_wall_visibility(local_dir)
