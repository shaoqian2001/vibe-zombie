extends Node3D

## Main scene controller.
## Wires up the camera → player link, handles player spawn,
## spawns enemies, sets up the HUD,
## and manages seamless building enter / exit transitions.
##
## Press F near a door to open / close it (works from both sides).
## When a door is open the player can walk freely in and out.
## Closing the door from inside keeps the player inside.
## The view switches automatically between exterior and interior.

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

const DOOR_ANIM_DURATION := 0.4

# Enemy spawning constants (matching world.gd dimensions)
const ENEMY_COUNT := 25
const ENEMY_BLOCK_SIZE := 26.0
const ENEMY_ROAD_WIDTH := 4.0
const ENEMY_CELL_SIZE := ENEMY_BLOCK_SIZE + ENEMY_ROAD_WIDTH

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D        = $Camera3D
@onready var world: Node3D           = $World

# UI
var _prompt_label: Label = null
var _hud = null

# State
var _nearby_building: Dictionary = {}   # building whose door area the player overlaps
var _active_building: Dictionary = {}   # building with active interior (door may be open or closed)
var _current_interior: Node3D = null    # interior node for the active building
var _player_inside: bool = false        # whether the player is inside the active building
var _showing_interior: bool = false     # whether we are showing interior view
var _door_tween: Tween = null           # active door animation tween

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var spawn_pos: Vector3 = SPAWN_CANDIDATES[rng.randi() % SPAWN_CANDIDATES.size()]
	player.global_position = spawn_pos

	camera.set_target(player)
	player.add_to_group("player")
	_create_ui()
	_setup_hud()
	_spawn_enemies(rng)

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
# HUD (armor / health / stamina bars)
# ------------------------------------------------------------------

func _setup_hud() -> void:
	var hud_script := preload("res://scripts/hud.gd")
	_hud = CanvasLayer.new()
	_hud.set_script(hud_script)
	_hud.name = "HUD"
	add_child(_hud)
	player.hud = _hud

# ------------------------------------------------------------------
# Enemy spawning
# ------------------------------------------------------------------

func _spawn_enemies(rng: RandomNumberGenerator) -> void:
	var enemy_script := preload("res://scripts/enemy.gd")
	var total := ENEMY_CELL_SIZE * 5  # NUM_BLOCKS = 5
	var grid_origin := -total * 0.5

	for i in range(ENEMY_COUNT):
		var pos := _random_walkable_pos(rng, grid_origin)
		# Avoid spawning too close to the player
		if pos.distance_to(player.global_position) < 8.0:
			pos = _random_walkable_pos(rng, grid_origin)

		var enemy := CharacterBody3D.new()
		enemy.set_script(enemy_script)
		enemy.name = "Enemy_%d" % i
		enemy.global_position = pos
		add_child(enemy)

func _random_walkable_pos(rng: RandomNumberGenerator, grid_origin: float) -> Vector3:
	var block_col := rng.randi_range(0, 4)
	var block_row := rng.randi_range(0, 4)
	var bx := grid_origin + block_col * ENEMY_CELL_SIZE
	var bz := grid_origin + block_row * ENEMY_CELL_SIZE

	if rng.randf() < 0.5:
		# On a road
		if rng.randf() < 0.5:
			var x := bx + ENEMY_BLOCK_SIZE + rng.randf_range(0.5, ENEMY_ROAD_WIDTH - 0.5)
			var z := bz + rng.randf_range(0.0, ENEMY_CELL_SIZE)
			return Vector3(x, 0.5, z)
		else:
			var x := bx + rng.randf_range(0.0, ENEMY_CELL_SIZE)
			var z := bz + ENEMY_BLOCK_SIZE + rng.randf_range(0.5, ENEMY_ROAD_WIDTH - 0.5)
			return Vector3(x, 0.5, z)
	else:
		# On sidewalk
		var x := bx + rng.randf_range(0.3, ENEMY_BLOCK_SIZE - 0.3)
		var z := bz + rng.randf_range(0.3, ENEMY_BLOCK_SIZE - 0.3)
		return Vector3(x, 0.5, z)

# ------------------------------------------------------------------
# UI (interaction prompts)
# ------------------------------------------------------------------

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	_prompt_label = Label.new()
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 24)
	_prompt_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_prompt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_prompt_label.add_theme_constant_override("shadow_offset_x", 2)
	_prompt_label.add_theme_constant_override("shadow_offset_y", 2)
	# True centre of the screen
	_prompt_label.anchor_left = 0.0
	_prompt_label.anchor_top = 0.4
	_prompt_label.anchor_right = 1.0
	_prompt_label.anchor_bottom = 0.6
	_prompt_label.offset_left = 0
	_prompt_label.offset_top = 0
	_prompt_label.offset_right = 0
	_prompt_label.offset_bottom = 0
	_prompt_label.visible = false
	canvas.add_child(_prompt_label)

func _update_prompt() -> void:
	if _prompt_label == null:
		return

	# Near a door (from either side) — show open/close prompt
	if not _nearby_building.is_empty():
		var is_open: bool = _nearby_building.get("door_open", false)
		if is_open:
			_prompt_label.text = "Press 'F' to close the door"
		else:
			_prompt_label.text = "Press 'F' to open the door"
		_prompt_label.visible = true
	elif _player_inside and not _active_building.is_empty():
		var btype: int = _active_building.get("type", 0)
		var type_name: String = BUILDING_TYPE_NAMES[btype] if btype < BUILDING_TYPE_NAMES.size() else "Building"
		_prompt_label.text = "Inside: " + type_name
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
# Interact (F key) — works from both inside and outside
# ------------------------------------------------------------------

func _handle_interact() -> void:
	if _nearby_building.is_empty():
		return

	var is_open: bool = _nearby_building.get("door_open", false)
	if is_open:
		_close_door()
	else:
		_open_door(_nearby_building)

# ------------------------------------------------------------------
# Open door
# ------------------------------------------------------------------

func _open_door(binfo: Dictionary) -> void:
	var need_interior := (_active_building != binfo)

	# Close/cleanup any other active building first
	if not _active_building.is_empty() and _active_building != binfo:
		_full_cleanup()

	binfo.door_open = true
	_active_building = binfo

	# Animate the door open
	_animate_door(binfo, true)

	# Disable exterior collision — interior walls provide collision instead
	_set_exterior_collision(binfo.node, false)

	# Create interior if needed (skip if re-opening same building from inside)
	if need_interior:
		_create_interior(binfo)

	# Set initial view based on player position
	_update_player_inside()
	if _player_inside:
		_switch_to_interior_view()
	else:
		_switch_to_exterior_view()

# ------------------------------------------------------------------
# Close door
# ------------------------------------------------------------------

func _close_door() -> void:
	if _active_building.is_empty():
		return

	_active_building.door_open = false

	# Animate the door closed
	_animate_door(_active_building, false)

	# Re-enable exterior collision
	_set_exterior_collision(_active_building.node, true)

	if _player_inside:
		# Player is inside: keep interior, keep active building
		# They can press F again to re-open and leave
		pass
	else:
		# Player is outside: full cleanup
		_destroy_interior()
		var building_node: MeshInstance3D = _active_building.node
		building_node.visible = true
		_active_building = {}
		_showing_interior = false

# ------------------------------------------------------------------
# Door animation
# ------------------------------------------------------------------

func _animate_door(binfo: Dictionary, opening: bool) -> void:
	if _door_tween and _door_tween.is_valid():
		_door_tween.kill()

	var pivot: Node3D = binfo.door_pivot
	var base_angle: float = binfo.door_base_angle
	var target: float
	if opening:
		target = base_angle - PI * 0.5
	else:
		target = base_angle

	_door_tween = create_tween()
	_door_tween.tween_property(pivot, "rotation:y", target, DOOR_ANIM_DURATION) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_QUAD)

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

func _set_exterior_collision(building_node: MeshInstance3D, enabled: bool) -> void:
	for child in building_node.get_children():
		if child is StaticBody3D:
			child.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
			for sub in child.get_children():
				if sub is CollisionShape3D:
					(sub as CollisionShape3D).disabled = not enabled

func _create_interior(binfo: Dictionary) -> void:
	var building_node: MeshInstance3D = binfo.node
	var bpos: Vector3 = building_node.position
	var building_ground := Vector3(bpos.x, 0.0, bpos.z)

	_current_interior = Node3D.new()
	_current_interior.name = "BuildingInterior"
	_current_interior.set_script(BuildingInterior)
	add_child(_current_interior)

	var facing: Vector3 = binfo.entrance_facing
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

func _destroy_interior() -> void:
	if _current_interior:
		_current_interior.queue_free()
		_current_interior = null

func _full_cleanup() -> void:
	if _active_building.is_empty():
		return

	# Close door if open
	if _active_building.door_open:
		_active_building.door_open = false
		var pivot: Node3D = _active_building.door_pivot
		var base_angle: float = _active_building.door_base_angle
		pivot.rotation.y = base_angle

	# Re-enable exterior collision
	_set_exterior_collision(_active_building.node, true)

	# Restore exterior visibility
	_active_building.node.visible = true

	_destroy_interior()
	_active_building = {}
	_player_inside = false
	_showing_interior = false

# ------------------------------------------------------------------
# Position-based inside detection + auto view switching
# ------------------------------------------------------------------

func _update_player_inside() -> void:
	if _active_building.is_empty():
		if _player_inside:
			_player_inside = false
			_showing_interior = false
		return

	var bpos: Vector3 = _active_building.node.position
	var hw: float = _active_building.width * 0.5
	var hd: float = _active_building.depth * 0.5
	var px: float = player.global_position.x
	var pz: float = player.global_position.z
	var now_inside := (px > bpos.x - hw and px < bpos.x + hw
		and pz > bpos.z - hd and pz < bpos.z + hd)

	if now_inside and not _player_inside:
		_player_inside = true
		if _active_building.door_open:
			_switch_to_interior_view()
	elif not now_inside and _player_inside:
		_player_inside = false
		if _active_building.door_open:
			_switch_to_exterior_view()

# ------------------------------------------------------------------
# View switching
# ------------------------------------------------------------------

func _switch_to_interior_view() -> void:
	if _showing_interior:
		return
	_showing_interior = true
	var building_node: MeshInstance3D = _active_building.node
	building_node.visible = false
	if _current_interior:
		_current_interior.visible = true

func _switch_to_exterior_view() -> void:
	if not _showing_interior:
		return
	_showing_interior = false
	var building_node: MeshInstance3D = _active_building.node
	building_node.visible = true
	# Keep door mesh hidden (it's part of the pivot, not the exterior)
	if _current_interior:
		_current_interior.visible = false

# ------------------------------------------------------------------
# Interior wall visibility based on camera angle
# ------------------------------------------------------------------

func _update_interior_wall_visibility() -> void:
	if not _showing_interior or _current_interior == null:
		return
	var cam_dir := camera.global_position - player.global_position
	cam_dir.y = 0.0
	if cam_dir.length_squared() < 0.001:
		return
	cam_dir = cam_dir.normalized()
	var local_dir := _current_interior.global_transform.basis.inverse() * cam_dir
	_current_interior.update_wall_visibility(local_dir)
