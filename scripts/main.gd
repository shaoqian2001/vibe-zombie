extends Node3D

## Main scene controller.
## Manages the mission system: pick up a package from one building, deliver to another.
## Wires up the camera → player link, handles player spawn near map rim,
## spawns enemies with density hotspots, sets up the HUD,
## and manages seamless building enter / exit transitions.
##
## Press F near a door to open / close it (works from both sides).
## When a door is open the player can walk freely in and out.
## Closing the door from inside keeps the player inside.
## The view switches automatically between exterior and interior.

const BuildingInterior = preload("res://scripts/building_interior.gd")
const WeaponPickup = preload("res://scripts/weapon_pickup.gd")
const MapView = preload("res://scripts/map_view.gd")
const FovOverlay = preload("res://scripts/fov_overlay.gd")
const MissionSystem = preload("res://scripts/mission_system.gd")
const DebugPanel = preload("res://scripts/debug_panel.gd")

const DEV_MODE := true

const BUILDING_TYPE_NAMES := [
	"Convenience Store",
	"Apartment",
	"Office",
	"Warehouse",
	"Diner",
]

const DOOR_ANIM_DURATION := 0.4
const OCCLUDE_ALPHA := 0.25  # transparency when building blocks player view

# Enemy spawning — base density scales with map area so larger worlds feel populated
# without exploding the entity count. DEV_MODE keeps the playtest count tiny.
const ENEMIES_PER_BLOCK_NORMAL := 2.0
const ENEMIES_PER_BLOCK_DEV := 0.2
const ENEMY_BLOCK_SIZE := 26.0
const ENEMY_ROAD_WIDTH := 4.0
const ENEMY_CELL_SIZE := ENEMY_BLOCK_SIZE + ENEMY_ROAD_WIDTH

# Weapon pickup spawning — density scales with map size as well
const WEAPON_PICKUPS_PER_BLOCK := 0.5
const WEAPON_PICKUP_MIN_DIST := 15.0

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D        = $Camera3D
@onready var world: Node3D           = $World

# UI
var _prompt_label: Label = null
var _hud = null
var _game_manual: CanvasLayer = null
var _inventory: CanvasLayer = null
var _manual_open: bool = false
var _inventory_open: bool = false
var _map_view: CanvasLayer = null
var _map_open: bool = false
var _fov_overlay: CanvasLayer = null

# State
var _nearby_building: Dictionary = {}   # building whose door area the player overlaps
var _active_building: Dictionary = {}   # building with active interior (door may be open or closed)
var _current_interior: Node3D = null    # interior node for the active building
var _player_inside: bool = false        # whether the player is inside the active building
var _showing_interior: bool = false     # whether we are showing interior view
var _door_tween: Tween = null           # active door animation tween
var _occluded_buildings: Array = []     # buildings currently made transparent

# Mission system
enum GameState { PLAYING, WON, LOST }
var _game_state: int = GameState.PLAYING
var _mission_system: Node = null
var _debug_panel: CanvasLayer = null
var _objective_label: Label = null
var _overlay_canvas: CanvasLayer = null

const MISSION_COUNT := 4

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	# FOV overlay added first so it renders below the HUD/UI CanvasLayers
	_fov_overlay = CanvasLayer.new()
	_fov_overlay.set_script(FovOverlay)
	_fov_overlay.name = "FovOverlay"
	add_child(_fov_overlay)

	# Spawn player near map rim — positions derived from the world's actual size
	var rim_candidates := _build_rim_spawn_candidates()
	var spawn_pos: Vector3 = rim_candidates[rng.randi() % rim_candidates.size()]
	player.global_position = spawn_pos

	camera.set_target(player)
	_fov_overlay.configure(player, camera)
	player.add_to_group("player")
	_create_ui()
	_setup_hud()

	if DEV_MODE:
		player.god_mode = true
		if _hud and _hud.has_method("show_dev_mode"):
			_hud.show_dev_mode()
		_setup_debug_panel()

	await get_tree().process_frame

	_setup_mission_system(rng)

	_spawn_enemies(rng)
	_spawn_weapon_pickups(rng)
	_connect_entrance_areas()

	player.died.connect(_on_player_died)

func _process(delta: float) -> void:
	if _game_state != GameState.PLAYING:
		return
	_update_mouse_look()
	_update_player_inside()
	_update_prompt()
	_update_interior_wall_visibility()
	_update_building_occlusion()
	if _mission_system:
		_mission_system.process(delta)
		_update_objective_label()

func _unhandled_input(event: InputEvent) -> void:
	# Debug panel toggle (always available in dev mode)
	if DEV_MODE and event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		if _debug_panel:
			_debug_panel.toggle()
		return

	if _game_state != GameState.PLAYING:
		return
	if event.is_action_pressed("game_manual"):
		_toggle_game_manual()
		return
	if event.is_action_pressed("inventory"):
		_toggle_inventory()
		return
	if event.is_action_pressed("map"):
		_toggle_map()
		return
	if _manual_open or _inventory_open or _map_open:
		return  # block other input while overlay is open
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

func _rebuild_hud() -> void:
	if _hud:
		_hud.queue_free()
		_hud = null
	# Defer so the old HUD is freed first
	call_deferred("_setup_hud")

# ------------------------------------------------------------------
# Game Manual (ESC) & Inventory (I)
# ------------------------------------------------------------------

func _toggle_game_manual() -> void:
	if _inventory_open:
		_close_inventory()
	if _map_open:
		_close_map()
	if _manual_open:
		_close_game_manual()
	else:
		_open_game_manual()

func _open_game_manual() -> void:
	_manual_open = true
	var manual_script := preload("res://scripts/game_manual.gd")
	_game_manual = CanvasLayer.new()
	_game_manual.set_script(manual_script)
	_game_manual.name = "GameManual"
	_game_manual.manual_closed.connect(_close_game_manual)
	add_child(_game_manual)

func _close_game_manual() -> void:
	_manual_open = false
	if _game_manual:
		_game_manual.queue_free()
		_game_manual = null
	# Rebuild the HUD so it picks up any resolution change from settings
	_rebuild_hud()

func _toggle_inventory() -> void:
	if _manual_open:
		return  # don't open inventory while manual is open
	if _inventory_open:
		_close_inventory()
	else:
		_open_inventory()

func _open_inventory() -> void:
	_inventory_open = true
	var inv_script := preload("res://scripts/inventory.gd")
	_inventory = CanvasLayer.new()
	_inventory.set_script(inv_script)
	_inventory.name = "Inventory"
	add_child(_inventory)

func _close_inventory() -> void:
	_inventory_open = false
	if _inventory:
		_inventory.queue_free()
		_inventory = null

# ------------------------------------------------------------------
# Map overlay (M)
# ------------------------------------------------------------------

func _toggle_map() -> void:
	if _manual_open or _inventory_open:
		return
	if _map_open:
		_close_map()
	else:
		_open_map()

func _open_map() -> void:
	_map_open = true
	_map_view = CanvasLayer.new()
	_map_view.set_script(MapView)
	_map_view.name = "MapView"
	add_child(_map_view)
	_map_view.configure(world, player, _mission_system)

func _close_map() -> void:
	_map_open = false
	if _map_view:
		_map_view.queue_free()
		_map_view = null

# ------------------------------------------------------------------
# Rim spawn candidates — positions just inside each edge of the map
# ------------------------------------------------------------------

func _build_rim_spawn_candidates() -> Array:
	var extent: float = world.num_blocks * world.CELL_SIZE * 0.5 - 4.0
	var diag: float = extent * 0.9
	return [
		Vector3( extent, 0.5,  0.0),
		Vector3(-extent, 0.5,  0.0),
		Vector3(  0.0,   0.5,  extent),
		Vector3(  0.0,   0.5, -extent),
		Vector3( diag,   0.5,  diag),
		Vector3(-diag,   0.5,  diag),
		Vector3( diag,   0.5, -diag),
		Vector3(-diag,   0.5, -diag),
	]

# ------------------------------------------------------------------
# Enemy spawning
# ------------------------------------------------------------------

func _spawn_enemies(rng: RandomNumberGenerator) -> void:
	var enemy_script := preload("res://scripts/enemy.gd")
	var nb: int = world.num_blocks
	var total := ENEMY_CELL_SIZE * nb
	var grid_origin := -total * 0.5
	var idx := 0

	var per_block: float = ENEMIES_PER_BLOCK_DEV if DEV_MODE else ENEMIES_PER_BLOCK_NORMAL
	var base_count := int(per_block * nb * nb)

	for i in range(base_count):
		var pos := _random_walkable_pos(rng, grid_origin)
		if pos.distance_to(player.global_position) < 8.0:
			pos = _random_walkable_pos(rng, grid_origin)

		var enemy := CharacterBody3D.new()
		enemy.set_script(enemy_script)
		enemy.name = "Enemy_%d" % idx
		enemy.global_position = pos
		add_child(enemy)
		idx += 1

func _random_walkable_pos(rng: RandomNumberGenerator, grid_origin: float) -> Vector3:
	var last_block: int = world.num_blocks - 1
	var block_col := rng.randi_range(0, last_block)
	var block_row := rng.randi_range(0, last_block)
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
# Weapon pickup spawning
# ------------------------------------------------------------------

func _spawn_weapon_pickups(rng: RandomNumberGenerator) -> void:
	var nb: int = world.num_blocks
	var total := ENEMY_CELL_SIZE * nb
	var grid_origin := -total * 0.5
	var placed_positions: Array[Vector3] = []
	var weapon_types := ["pistol", "shotgun", "smg", "grenade_launcher", "bat"]

	var pickup_count := int(WEAPON_PICKUPS_PER_BLOCK * nb * nb)

	for i in range(pickup_count):
		var pos := Vector3.ZERO
		var valid := false

		for _attempt in range(20):
			pos = _random_walkable_pos(rng, grid_origin)
			pos.y = 0.0

			if pos.distance_to(player.global_position) < 10.0:
				continue

			var too_close := false
			for prev in placed_positions:
				if pos.distance_to(prev) < WEAPON_PICKUP_MIN_DIST:
					too_close = true
					break
			if too_close:
				continue

			if _pos_inside_building(pos):
				continue

			valid = true
			break

		if not valid:
			continue

		placed_positions.append(pos)

		var pickup := Area3D.new()
		pickup.set_script(WeaponPickup)
		pickup.name = "WeaponPickup_%d" % i
		pickup.weapon_type = weapon_types[i % weapon_types.size()]
		pickup.global_position = pos
		add_child(pickup)

func _pos_inside_building(pos: Vector3) -> bool:
	for binfo in world.buildings:
		var bpos: Vector3 = binfo.node.position
		var hw: float = binfo.width * 0.5 + 1.0
		var hd: float = binfo.depth * 0.5 + 1.0
		if pos.x > bpos.x - hw and pos.x < bpos.x + hw \
			and pos.z > bpos.z - hd and pos.z < bpos.z + hd:
			return true
	return false

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
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_prompt_label)

	# Mission objective label (top center)
	_objective_label = Label.new()
	_objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_objective_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_objective_label.add_theme_font_size_override("font_size", 18)
	_objective_label.add_theme_color_override("font_color", Color(1, 1, 0.7))
	_objective_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_objective_label.add_theme_constant_override("shadow_offset_x", 1)
	_objective_label.add_theme_constant_override("shadow_offset_y", 1)
	_objective_label.anchor_left = 0.1
	_objective_label.anchor_top = 0.02
	_objective_label.anchor_right = 0.9
	_objective_label.anchor_bottom = 0.1
	_objective_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_objective_label)

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
# Mission system (multi-mission with sequential unlocking)
# ------------------------------------------------------------------

func _setup_mission_system(rng: RandomNumberGenerator) -> void:
	_mission_system = Node.new()
	_mission_system.set_script(MissionSystem)
	_mission_system.name = "MissionSystem"
	add_child(_mission_system)
	_mission_system.add_to_group("mission_system")

	_mission_system.setup(self, world, player, rng)
	_mission_system.generate_missions(MISSION_COUNT)

	_mission_system.mission_started.connect(_on_mission_started)
	_mission_system.mission_completed.connect(_on_mission_completed)
	_mission_system.all_missions_completed.connect(_on_all_missions_completed)
	_mission_system.player_rescued.connect(_on_player_rescued)

	# Start first mission
	_mission_system.start_next_mission()

func _on_mission_started(_index: int, _data: Dictionary) -> void:
	_update_objective_label()

func _on_mission_completed(_index: int) -> void:
	if _objective_label:
		_objective_label.text = "Mission complete! Next mission incoming..."

func _on_all_missions_completed() -> void:
	if _objective_label:
		_objective_label.text = "All missions done! Get to the rescue point! (green marker)"

func _on_player_rescued() -> void:
	_game_state = GameState.WON
	_show_overlay("RESCUED!", Color(0.1, 0.8, 0.2))
	if _objective_label:
		_objective_label.text = "You survived!"

func _on_player_died() -> void:
	_game_state = GameState.LOST
	_show_overlay("YOU DIED", Color(0.7, 0.1, 0.05))
	if _objective_label:
		_objective_label.text = ""

func _update_objective_label() -> void:
	if _objective_label == null or _mission_system == null:
		return
	_objective_label.text = _mission_system.get_objective_text()

	# Check rescue point proximity
	if _mission_system.is_rescue_active():
		if _mission_system.check_rescue(player.global_position):
			pass  # handled by area trigger in mission_system

# ------------------------------------------------------------------
# Debug panel (DEV_MODE only, toggled with F3)
# ------------------------------------------------------------------

func _setup_debug_panel() -> void:
	_debug_panel = CanvasLayer.new()
	_debug_panel.set_script(DebugPanel)
	_debug_panel.name = "DebugPanel"
	add_child(_debug_panel)

	_debug_panel.set_god_mode(player.god_mode)
	_debug_panel.density_changed.connect(_on_debug_density_changed)
	_debug_panel.god_mode_changed.connect(_on_debug_god_mode_changed)
	_debug_panel.spawn_horde_requested.connect(_on_debug_spawn_horde)

func _on_debug_density_changed(multiplier: float) -> void:
	if _mission_system:
		_mission_system.zombie_density_multiplier = multiplier

func _on_debug_god_mode_changed(enabled: bool) -> void:
	player.god_mode = enabled

func _on_debug_spawn_horde(count: int) -> void:
	if _mission_system:
		_mission_system.spawn_horde_at(player.global_position + Vector3(10, 0, 10), count)

# ------------------------------------------------------------------
# Game Over / Win overlay
# ------------------------------------------------------------------

func _show_overlay(title_text: String, title_color: Color) -> void:
	_overlay_canvas = CanvasLayer.new()
	_overlay_canvas.name = "OverlayUI"
	_overlay_canvas.layer = 10
	add_child(_overlay_canvas)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_canvas.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.anchor_left = 0.2
	vbox.anchor_right = 0.8
	vbox.anchor_top = 0.25
	vbox.anchor_bottom = 0.75
	vbox.offset_left = 0
	vbox.offset_right = 0
	vbox.offset_top = 0
	vbox.offset_bottom = 0
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 30)
	_overlay_canvas.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", title_color)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	vbox.add_child(title)

	var restart_btn := Button.new()
	restart_btn.text = "Restart" if _game_state == GameState.LOST else "Play Again"
	restart_btn.custom_minimum_size = Vector2(200, 50)
	restart_btn.add_theme_font_size_override("font_size", 24)
	restart_btn.pressed.connect(func() -> void:
		get_tree().reload_current_scene()
	)
	vbox.add_child(restart_btn)

	var exit_btn := Button.new()
	exit_btn.text = "Exit Game"
	exit_btn.custom_minimum_size = Vector2(200, 50)
	exit_btn.add_theme_font_size_override("font_size", 24)
	exit_btn.pressed.connect(func() -> void:
		get_tree().quit()
	)
	vbox.add_child(exit_btn)

# ------------------------------------------------------------------
# Mouse look — raycast mouse to ground plane, set player facing
# ------------------------------------------------------------------

func _update_mouse_look() -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	# Intersect with Y=0 ground plane
	if absf(ray_dir.y) < 0.001:
		return
	var t := -ray_origin.y / ray_dir.y
	if t < 0.0:
		return
	var ground_point := ray_origin + ray_dir * t
	player.look_target = ground_point

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

# ------------------------------------------------------------------
# Building occlusion — make buildings between camera and player transparent
# ------------------------------------------------------------------

func _update_building_occlusion() -> void:
	var cam_pos := camera.global_position
	var player_pos := player.global_position

	# Find buildings that occlude the player
	var now_occluded: Array = []
	for binfo in world.buildings:
		var node: MeshInstance3D = binfo.node
		if not node.visible:
			continue
		# Check if the building's AABB intersects the line from camera to player
		if _building_occludes(binfo, cam_pos, player_pos):
			now_occluded.append(binfo)

	# Restore buildings that are no longer occluding
	for binfo in _occluded_buildings:
		if binfo not in now_occluded:
			_set_building_alpha(binfo, 1.0)

	# Make newly occluding buildings transparent
	for binfo in now_occluded:
		_set_building_alpha(binfo, OCCLUDE_ALPHA)

	_occluded_buildings = now_occluded

func _building_occludes(binfo: Dictionary, cam_pos: Vector3, player_pos: Vector3) -> bool:
	var bpos: Vector3 = binfo.node.position
	var hw: float = binfo.width * 0.5
	var hh: float = binfo.height * 0.5
	var hd: float = binfo.depth * 0.5

	# AABB min/max
	var aabb_min := Vector3(bpos.x - hw, bpos.y - hh, bpos.z - hd)
	var aabb_max := Vector3(bpos.x + hw, bpos.y + hh, bpos.z + hd)

	# Ray-AABB intersection (slab method)
	var dir := player_pos - cam_pos
	var inv_dir := Vector3(
		1.0 / dir.x if absf(dir.x) > 0.0001 else 1e10,
		1.0 / dir.y if absf(dir.y) > 0.0001 else 1e10,
		1.0 / dir.z if absf(dir.z) > 0.0001 else 1e10,
	)

	var t1 := (aabb_min.x - cam_pos.x) * inv_dir.x
	var t2 := (aabb_max.x - cam_pos.x) * inv_dir.x
	var tmin := minf(t1, t2)
	var tmax := maxf(t1, t2)

	t1 = (aabb_min.y - cam_pos.y) * inv_dir.y
	t2 = (aabb_max.y - cam_pos.y) * inv_dir.y
	tmin = maxf(tmin, minf(t1, t2))
	tmax = minf(tmax, maxf(t1, t2))

	t1 = (aabb_min.z - cam_pos.z) * inv_dir.z
	t2 = (aabb_max.z - cam_pos.z) * inv_dir.z
	tmin = maxf(tmin, minf(t1, t2))
	tmax = minf(tmax, maxf(t1, t2))

	# Hit if slab overlap is valid AND the intersection is between camera and player
	return tmax >= tmin and tmax > 0.0 and tmin < 1.0

func _set_building_alpha(binfo: Dictionary, alpha: float) -> void:
	var node: MeshInstance3D = binfo.node
	var mat: StandardMaterial3D = node.mesh.material
	if mat == null:
		return
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = alpha
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.albedo_color.a = 1.0
