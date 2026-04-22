extends Node

## Manages a sequence of missions the player must complete before rescue arrives.
## Supports: delivery, hold-zone, and elimination mission types.
## The final mission spawns at the rescue point and typically involves defending a horde.

signal mission_started(mission_index: int, mission_data: Dictionary)
signal mission_completed(mission_index: int)
signal all_missions_completed
signal player_rescued

enum MissionType { DELIVERY, HOLD_ZONE, ELIMINATION }

const HOLD_ZONE_RADIUS := 6.0
const HOLD_ZONE_DURATION := 30.0  # seconds player must remain in zone
const ELIMINATION_TARGET := 15

# Horde spawn settings
const HORDE_SPAWN_RADIUS := 12.0
const HORDE_WAVE_INTERVAL := 3.0  # seconds between waves during hold missions

var missions: Array[Dictionary] = []
var current_mission_index: int = -1
var _rng: RandomNumberGenerator
var _world: Node3D
var _player: CharacterBody3D
var _main: Node3D
var _buildings: Array = []

# Current mission runtime state
var _mission_active: bool = false
var _hold_timer: float = 0.0
var _hold_in_zone: bool = false
var _elimination_count: int = 0
var _horde_timer: float = 0.0
var _current_zone_area: Area3D = null
var _current_zone_visual: MeshInstance3D = null
var _current_marker: MeshInstance3D = null
var _horde_enemies: Array = []

# Rescue point
var _rescue_pos: Vector3 = Vector3.ZERO
var _rescue_marker: MeshInstance3D = null
var _rescue_area: Area3D = null
var _rescue_visible: bool = false

# Zombie density multiplier (controlled by debug panel)
var zombie_density_multiplier: float = 1.0

func setup(main: Node3D, world_node: Node3D, player_node: CharacterBody3D, rng: RandomNumberGenerator) -> void:
	_main = main
	_world = world_node
	_player = player_node
	_rng = rng
	_buildings = world_node.buildings

func generate_missions(count: int) -> void:
	missions.clear()

	# Pick rescue point location — a random building entrance
	var rescue_bldg_idx := _rng.randi() % _buildings.size()
	var rescue_bldg: Dictionary = _buildings[rescue_bldg_idx]
	_rescue_pos = rescue_bldg.entrance_pos + rescue_bldg.entrance_facing * 3.0

	# Generate count-1 random missions, then the final defend mission at rescue
	var used_building_indices: Array[int] = [rescue_bldg_idx]

	for i in range(count - 1):
		var mission_type: int = _pick_mission_type(i)
		var mission := _create_mission(mission_type, used_building_indices)
		missions.append(mission)

	# Final mission: HOLD_ZONE at the rescue point (defend the landing zone)
	missions.append({
		type = MissionType.HOLD_ZONE,
		position = _rescue_pos,
		building_index = rescue_bldg_idx,
		name = "Defend the Rescue Point",
		description = "Hold position at the rescue point until extraction arrives!",
		hold_duration = 40.0,
		horde_size = _get_horde_size(count - 1),
		is_final = true,
	})

func start_next_mission() -> void:
	current_mission_index += 1
	if current_mission_index >= missions.size():
		_reveal_rescue()
		all_missions_completed.emit()
		return

	var mission: Dictionary = missions[current_mission_index]
	_mission_active = true
	_setup_current_mission(mission)
	mission_started.emit(current_mission_index, mission)

func process(delta: float) -> void:
	if not _mission_active:
		return

	var mission: Dictionary = missions[current_mission_index]
	match mission.type:
		MissionType.HOLD_ZONE:
			_process_hold_zone(delta, mission)
		MissionType.ELIMINATION:
			_process_elimination(delta, mission)
		MissionType.DELIVERY:
			pass  # handled by area trigger

	# Animate marker
	if _current_marker and is_instance_valid(_current_marker):
		_current_marker.rotation.y += delta * 1.5
		_current_marker.position.y += sin(Time.get_ticks_msec() * 0.003) * delta * 0.5

func get_objective_text() -> String:
	if current_mission_index < 0 or current_mission_index >= missions.size():
		if _rescue_visible:
			return "Get to the rescue point! (green marker)"
		return ""

	var mission: Dictionary = missions[current_mission_index]
	var prefix := "MISSION %d/%d: " % [current_mission_index + 1, missions.size()]

	match mission.type:
		MissionType.DELIVERY:
			if mission.get("picked_up", false):
				return prefix + "Deliver the package (yellow marker)"
			return prefix + "Pick up the package (blue marker)"
		MissionType.HOLD_ZONE:
			if _hold_in_zone:
				var remaining: float = mission.hold_duration - _hold_timer
				return prefix + "Hold position! %.0fs remaining" % remaining
			return prefix + mission.description
		MissionType.ELIMINATION:
			var target: int = mission.get("target_count", ELIMINATION_TARGET)
			return prefix + "Eliminate zombies: %d / %d" % [_elimination_count, target]

	return prefix + mission.get("description", "")

func notify_enemy_killed() -> void:
	if not _mission_active:
		return
	if current_mission_index < 0 or current_mission_index >= missions.size():
		return
	var mission: Dictionary = missions[current_mission_index]
	if mission.type == MissionType.ELIMINATION:
		_elimination_count += 1
		var target: int = mission.get("target_count", ELIMINATION_TARGET)
		if _elimination_count >= target:
			_complete_current_mission()

func is_rescue_active() -> bool:
	return _rescue_visible

func check_rescue(player_pos: Vector3) -> bool:
	return _rescue_visible and player_pos.distance_to(_rescue_pos) < 3.0

# ------------------------------------------------------------------
# Internal
# ------------------------------------------------------------------

func _pick_mission_type(index: int) -> int:
	# First mission is always delivery (easy intro), rest are random
	if index == 0:
		return MissionType.DELIVERY
	var roll := _rng.randf()
	if roll < 0.33:
		return MissionType.DELIVERY
	elif roll < 0.66:
		return MissionType.HOLD_ZONE
	else:
		return MissionType.ELIMINATION

func _create_mission(mission_type: int, used_indices: Array[int]) -> Dictionary:
	match mission_type:
		MissionType.DELIVERY:
			return _create_delivery_mission(used_indices)
		MissionType.HOLD_ZONE:
			return _create_hold_mission(used_indices)
		MissionType.ELIMINATION:
			return _create_elimination_mission(used_indices)
	return {}

func _create_delivery_mission(used_indices: Array[int]) -> Dictionary:
	var pickup_idx := _pick_unused_building(used_indices)
	used_indices.append(pickup_idx)
	var delivery_idx := _pick_unused_building(used_indices)
	used_indices.append(delivery_idx)

	var pickup_bldg: Dictionary = _buildings[pickup_idx]
	var delivery_bldg: Dictionary = _buildings[delivery_idx]

	return {
		type = MissionType.DELIVERY,
		pickup_pos = pickup_bldg.entrance_pos,
		delivery_pos = delivery_bldg.entrance_pos,
		pickup_building_index = pickup_idx,
		delivery_building_index = delivery_idx,
		name = "Package Delivery",
		description = "Pick up a package and deliver it",
		horde_size = _get_horde_size(used_indices.size()),
		picked_up = false,
	}

func _create_hold_mission(used_indices: Array[int]) -> Dictionary:
	var bldg_idx := _pick_unused_building(used_indices)
	used_indices.append(bldg_idx)
	var bldg: Dictionary = _buildings[bldg_idx]
	var hold_pos: Vector3 = bldg.entrance_pos + bldg.entrance_facing * 3.0

	return {
		type = MissionType.HOLD_ZONE,
		position = hold_pos,
		building_index = bldg_idx,
		name = "Hold Position",
		description = "Hold the zone for %.0f seconds!" % HOLD_ZONE_DURATION,
		hold_duration = HOLD_ZONE_DURATION,
		horde_size = _get_horde_size(used_indices.size()),
		is_final = false,
	}

func _create_elimination_mission(used_indices: Array[int]) -> Dictionary:
	var bldg_idx := _pick_unused_building(used_indices)
	used_indices.append(bldg_idx)
	var bldg: Dictionary = _buildings[bldg_idx]

	return {
		type = MissionType.ELIMINATION,
		position = bldg.entrance_pos + bldg.entrance_facing * 4.0,
		building_index = bldg_idx,
		name = "Elimination",
		description = "Eliminate %d zombies near the target area" % ELIMINATION_TARGET,
		target_count = ELIMINATION_TARGET,
		horde_size = _get_horde_size(used_indices.size()),
	}

func _pick_unused_building(used: Array[int]) -> int:
	var idx := _rng.randi() % _buildings.size()
	var attempts := 0
	while idx in used and attempts < 50:
		idx = _rng.randi() % _buildings.size()
		attempts += 1
	return idx

func _get_horde_size(progression: int) -> int:
	return int((8 + progression * 4) * zombie_density_multiplier)

# ------------------------------------------------------------------
# Mission activation
# ------------------------------------------------------------------

func _setup_current_mission(mission: Dictionary) -> void:
	_hold_timer = 0.0
	_hold_in_zone = false
	_elimination_count = 0
	_horde_timer = 0.0
	_cleanup_mission_objects()

	match mission.type:
		MissionType.DELIVERY:
			_setup_delivery(mission)
		MissionType.HOLD_ZONE:
			_setup_hold_zone(mission)
		MissionType.ELIMINATION:
			_setup_elimination(mission)

func _setup_delivery(mission: Dictionary) -> void:
	var pickup_pos: Vector3 = mission.pickup_pos
	var delivery_pos: Vector3 = mission.delivery_pos

	# Pickup area
	_current_zone_area = _create_trigger_area(pickup_pos, 2.5)
	_current_zone_area.body_entered.connect(func(body: Node3D) -> void:
		if body == _player and not mission.picked_up:
			mission.picked_up = true
			_on_delivery_picked_up(mission)
	)

	# Pickup marker (blue)
	_current_marker = _create_marker(pickup_pos + Vector3(0, 3, 0), Color(0.2, 0.8, 1.0))

	# Spawn horde near pickup
	_spawn_horde(pickup_pos, mission.horde_size / 2)

func _on_delivery_picked_up(mission: Dictionary) -> void:
	# Remove pickup marker + area, create delivery marker + area
	_cleanup_mission_objects()

	var delivery_pos: Vector3 = mission.delivery_pos
	_current_zone_area = _create_trigger_area(delivery_pos, 2.5)
	_current_zone_area.body_entered.connect(func(body: Node3D) -> void:
		if body == _player and mission.picked_up:
			_complete_current_mission()
	)

	_current_marker = _create_marker(delivery_pos + Vector3(0, 3, 0), Color(1.0, 0.8, 0.1))

	# Spawn horde near delivery
	_spawn_horde(delivery_pos, mission.horde_size / 2)

func _setup_hold_zone(mission: Dictionary) -> void:
	var pos: Vector3 = mission.position

	# Zone visual (flat circle on ground)
	_current_zone_visual = _create_zone_visual(pos, HOLD_ZONE_RADIUS)

	# Zone detection area
	_current_zone_area = _create_trigger_area(pos, HOLD_ZONE_RADIUS)
	_current_zone_area.body_entered.connect(func(body: Node3D) -> void:
		if body == _player:
			_hold_in_zone = true
	)
	_current_zone_area.body_exited.connect(func(body: Node3D) -> void:
		if body == _player:
			_hold_in_zone = false
	)

	# Marker above zone
	_current_marker = _create_marker(pos + Vector3(0, 4, 0), Color(0.9, 0.4, 0.1))

	# Initial horde
	_spawn_horde(pos, mission.horde_size)

func _setup_elimination(mission: Dictionary) -> void:
	var pos: Vector3 = mission.position

	# Marker at target area
	_current_marker = _create_marker(pos + Vector3(0, 3, 0), Color(1.0, 0.2, 0.2))

	# Zone visual
	_current_zone_visual = _create_zone_visual(pos, HORDE_SPAWN_RADIUS)

	# Spawn horde
	_spawn_horde(pos, mission.horde_size)

# ------------------------------------------------------------------
# Mission processing
# ------------------------------------------------------------------

func _process_hold_zone(delta: float, mission: Dictionary) -> void:
	if _hold_in_zone:
		_hold_timer += delta
		var duration: float = mission.get("hold_duration", HOLD_ZONE_DURATION)
		if _hold_timer >= duration:
			_complete_current_mission()

	# Spawn waves during hold
	_horde_timer += delta
	if _horde_timer >= HORDE_WAVE_INTERVAL:
		_horde_timer = 0.0
		var wave_size := int(3 * zombie_density_multiplier)
		var pos: Vector3 = mission.position
		_spawn_horde(pos, wave_size)

func _process_elimination(_delta: float, _mission: Dictionary) -> void:
	pass  # kill counting handled by notify_enemy_killed()

func _complete_current_mission() -> void:
	_mission_active = false
	_cleanup_mission_objects()
	mission_completed.emit(current_mission_index)

	# Auto-start next after brief delay
	var timer := get_tree().create_timer(2.0)
	timer.timeout.connect(func() -> void:
		start_next_mission()
	)

# ------------------------------------------------------------------
# Rescue point
# ------------------------------------------------------------------

func _reveal_rescue() -> void:
	_rescue_visible = true
	_rescue_marker = _create_marker(_rescue_pos + Vector3(0, 4, 0), Color(0.1, 1.0, 0.2))

	# Create rescue trigger area
	_rescue_area = _create_trigger_area(_rescue_pos, 3.0)
	_rescue_area.body_entered.connect(func(body: Node3D) -> void:
		if body == _player and _rescue_visible:
			_rescue_visible = false
			player_rescued.emit()
	)

# ------------------------------------------------------------------
# Horde spawning
# ------------------------------------------------------------------

func _spawn_horde(center: Vector3, count: int) -> void:
	# Apply lobby difficulty's horde multiplier (only meaningful in MP, but
	# harmless in single-player).
	var horde_mult := 1.0
	if NetworkManager.is_networked:
		horde_mult = NetworkManager.difficulty_settings(NetworkManager.difficulty).horde_mult
	var actual_count := int(count * zombie_density_multiplier * horde_mult)

	for i in range(actual_count):
		var angle := _rng.randf_range(0.0, TAU)
		var dist := _rng.randf_range(HORDE_SPAWN_RADIUS * 0.5, HORDE_SPAWN_RADIUS)
		var pos := Vector3(
			center.x + cos(angle) * dist,
			0.5,
			center.z + sin(angle) * dist
		)

		# Route through main so spawns are replicated in MP.
		var enemy: CharacterBody3D = _main._spawn_enemy_at(pos)
		if enemy:
			_horde_enemies.append(enemy)

func spawn_horde_at(center: Vector3, count: int) -> void:
	_spawn_horde(center, count)

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

func _create_trigger_area(pos: Vector3, radius: float) -> Area3D:
	var area := Area3D.new()
	area.name = "MissionTrigger"
	var cs := CollisionShape3D.new()
	var shp := SphereShape3D.new()
	shp.radius = radius
	cs.shape = shp
	area.add_child(cs)
	area.position = pos + Vector3(0, 1.0, 0)
	_main.add_child(area)
	return area

func _create_marker(pos: Vector3, color: Color) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.85)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var mesh := PrismMesh.new()
	mesh.size = Vector3(1.2, 1.8, 1.2)
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees.x = 180
	_main.add_child(mi)
	return mi

func _create_zone_visual(pos: Vector3, radius: float) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.6, 0.1, 0.25)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 0.1
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(pos.x, 0.05, pos.z)
	_main.add_child(mi)
	return mi

func _cleanup_mission_objects() -> void:
	if _current_zone_area and is_instance_valid(_current_zone_area):
		_current_zone_area.queue_free()
	_current_zone_area = null

	if _current_zone_visual and is_instance_valid(_current_zone_visual):
		_current_zone_visual.queue_free()
	_current_zone_visual = null

	if _current_marker and is_instance_valid(_current_marker):
		_current_marker.queue_free()
	_current_marker = null
