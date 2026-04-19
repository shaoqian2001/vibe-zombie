extends CharacterBody3D

# Movement constants
const SPEED = 6.0
const SPRINT_SPEED = 10.0
const ACCELERATION = 18.0
const GRAVITY = 24.0
const ROTATION_SPEED = 14.0

# Stamina
const STAMINA_MAX := 40.0
const STAMINA_DRAIN := 15.0
const STAMINA_RECOVER := 10.0
const STAMINA_RECOVER_DELAY := 2.0

# Health
const HEALTH_MAX := 100.0
var health: float = HEALTH_MAX
var is_dead: bool = false
var god_mode: bool = false

signal died

var stamina: float = STAMINA_MAX
var _sprint_cooldown: float = 0.0
var _is_sprinting: bool = false

# Weapon inventory
var _weapons: Array[String] = []
var _weapon_index: int = -1
var _weapon_ammo: Dictionary = {}
var _current_weapon: String = ""
var _weapon_stats: Dictionary = {}
var _armed: bool = false

# Gun state (for the currently equipped weapon)
var ammo: int = 0
var _shoot_timer: float = 0.0
var _reload_timer: float = 0.0
var _is_reloading: bool = false

# Reference to the isometric camera
var _camera: Camera3D = null

# Reference to the HUD (set by main.gd)
var hud = null

# Mouse look target on the ground plane (set externally by main.gd)
var look_target: Vector3 = Vector3.INF

# Weapon model nodes
var _pistol_node: Node3D = null
var _shotgun_node: Node3D = null
var _smg_node: Node3D = null
var _grenade_launcher_node: Node3D = null
var _bat_node: Node3D = null

# Aim line
var _aim_line: MeshInstance3D = null
var _aim_dot: MeshInstance3D = null
var aim_line_enabled: bool = true

func _ready() -> void:
	await get_tree().process_frame
	_camera = get_viewport().get_camera_3d()
	_build_pistol()
	_build_shotgun()
	_build_smg()
	_build_grenade_launcher()
	_build_bat()
	_pistol_node.visible = false
	_shotgun_node.visible = false
	_smg_node.visible = false
	_grenade_launcher_node.visible = false
	_bat_node.visible = false
	_build_aim_line()

func _physics_process(delta: float) -> void:
	if is_dead:
		return
	_apply_gravity(delta)
	var move_dir := _get_world_movement_direction()
	_update_sprint(move_dir, delta)
	var current_speed := SPRINT_SPEED if _is_sprinting else SPEED
	_apply_movement(move_dir, current_speed, delta)
	_rotate_to_face_mouse(delta)
	move_and_slide()
	_update_gun(delta)
	_update_aim_line()
	_sync_hud()

func take_damage(amount: float) -> void:
	if is_dead or god_mode:
		return
	health = max(health - amount, 0.0)
	if hud:
		hud.set_health(health / HEALTH_MAX * 100.0)
	if health <= 0.0:
		is_dead = true
		velocity = Vector3.ZERO
		died.emit()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("weapon_1"):
		_switch_weapon(0)
	elif event.is_action_pressed("weapon_2"):
		_switch_weapon(1)
	elif event.is_action_pressed("weapon_3"):
		_switch_weapon(2)
	elif event.is_action_pressed("weapon_4"):
		_switch_weapon(3)
	elif event.is_action_pressed("weapon_5"):
		_switch_weapon(4)
	elif event.is_action_pressed("shoot"):
		_try_shoot()
	elif event.is_action_pressed("reload"):
		_try_reload()

# ------------------------------------------------------------------
# Weapon inventory
# ------------------------------------------------------------------

func pickup_weapon(weapon_name: String) -> void:
	var stats := WeaponData.get_weapon(weapon_name)
	if stats.is_empty():
		return

	var mag: int = stats.get("magazine_size", 8)

	if weapon_name in _weapons:
		_weapon_ammo[weapon_name] = mag
		if _current_weapon == weapon_name:
			ammo = mag
			_is_reloading = false
		return

	_weapons.append(weapon_name)
	_weapon_ammo[weapon_name] = mag

	var new_idx := _weapons.size() - 1
	_equip_weapon(new_idx)

func _switch_weapon(slot: int) -> void:
	if slot < 0 or slot >= _weapons.size():
		return
	if slot == _weapon_index:
		return
	_equip_weapon(slot)

func _equip_weapon(idx: int) -> void:
	if idx < 0 or idx >= _weapons.size():
		return

	# Save ammo of the old weapon
	if _armed and _current_weapon != "":
		_weapon_ammo[_current_weapon] = ammo

	_weapon_index = idx
	_current_weapon = _weapons[idx]
	_weapon_stats = WeaponData.get_weapon(_current_weapon)
	ammo = _weapon_ammo.get(_current_weapon, _weapon_stats.get("magazine_size", 8))
	_armed = true
	_is_reloading = false
	_shoot_timer = 0.0

	_pistol_node.visible = (_current_weapon == "pistol")
	_shotgun_node.visible = (_current_weapon == "shotgun")
	_smg_node.visible = (_current_weapon == "smg")
	_grenade_launcher_node.visible = (_current_weapon == "grenade_launcher")
	_bat_node.visible = (_current_weapon == "bat")

func _get_forward() -> Vector3:
	var fwd := global_transform.basis.z
	fwd.y = 0.0
	return fwd.normalized()

# ------------------------------------------------------------------
# Pistol model
# ------------------------------------------------------------------

func _build_pistol() -> void:
	_pistol_node = Node3D.new()
	_pistol_node.name = "Pistol"
	_pistol_node.position = Vector3(0.35, 1.0, 0.30)
	add_child(_pistol_node)

	var grip_mat := StandardMaterial3D.new()
	grip_mat.albedo_color = Color(0.15, 0.15, 0.15, 1)
	var grip_mesh := BoxMesh.new()
	grip_mesh.size = Vector3(0.08, 0.18, 0.10)
	grip_mesh.material = grip_mat
	var grip := MeshInstance3D.new()
	grip.name = "Grip"
	grip.mesh = grip_mesh
	grip.position = Vector3(0.0, -0.06, 0.0)
	_pistol_node.add_child(grip)

	var slide_mat := StandardMaterial3D.new()
	slide_mat.albedo_color = Color(0.22, 0.22, 0.24, 1)
	var slide_mesh := BoxMesh.new()
	slide_mesh.size = Vector3(0.07, 0.07, 0.22)
	slide_mesh.material = slide_mat
	var slide := MeshInstance3D.new()
	slide.name = "Slide"
	slide.mesh = slide_mesh
	slide.position = Vector3(0.0, 0.06, 0.04)
	_pistol_node.add_child(slide)

	var muzzle_mat := StandardMaterial3D.new()
	muzzle_mat.albedo_color = Color(0.10, 0.10, 0.10, 1)
	var muzzle_mesh := CylinderMesh.new()
	muzzle_mesh.top_radius = 0.02
	muzzle_mesh.bottom_radius = 0.02
	muzzle_mesh.height = 0.04
	muzzle_mesh.material = muzzle_mat
	var muzzle := MeshInstance3D.new()
	muzzle.name = "Muzzle"
	muzzle.mesh = muzzle_mesh
	muzzle.position = Vector3(0.0, 0.06, 0.14)
	muzzle.rotation_degrees = Vector3(90, 0, 0)
	_pistol_node.add_child(muzzle)

# ------------------------------------------------------------------
# Shotgun model
# ------------------------------------------------------------------

func _build_shotgun() -> void:
	_shotgun_node = Node3D.new()
	_shotgun_node.name = "Shotgun"
	_shotgun_node.position = Vector3(0.35, 0.95, 0.30)
	add_child(_shotgun_node)

	# Stock (wooden rear grip)
	var stock_mat := StandardMaterial3D.new()
	stock_mat.albedo_color = Color(0.40, 0.26, 0.13, 1)
	var stock_mesh := BoxMesh.new()
	stock_mesh.size = Vector3(0.09, 0.10, 0.18)
	stock_mesh.material = stock_mat
	var stock := MeshInstance3D.new()
	stock.name = "Stock"
	stock.mesh = stock_mesh
	stock.position = Vector3(0.0, -0.04, -0.14)
	_shotgun_node.add_child(stock)

	# Receiver (metal body connecting stock to barrels)
	var receiver_mat := StandardMaterial3D.new()
	receiver_mat.albedo_color = Color(0.18, 0.18, 0.20, 1)
	var receiver_mesh := BoxMesh.new()
	receiver_mesh.size = Vector3(0.08, 0.08, 0.12)
	receiver_mesh.material = receiver_mat
	var receiver := MeshInstance3D.new()
	receiver.name = "Receiver"
	receiver.mesh = receiver_mesh
	receiver.position = Vector3(0.0, 0.0, -0.02)
	_shotgun_node.add_child(receiver)

	# Pump forend (wood)
	var forend_mat := StandardMaterial3D.new()
	forend_mat.albedo_color = Color(0.45, 0.30, 0.15, 1)
	var forend_mesh := BoxMesh.new()
	forend_mesh.size = Vector3(0.09, 0.07, 0.10)
	forend_mesh.material = forend_mat
	var forend := MeshInstance3D.new()
	forend.name = "Forend"
	forend.mesh = forend_mesh
	forend.position = Vector3(0.0, -0.02, 0.10)
	_shotgun_node.add_child(forend)

	# Double barrels
	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.12, 0.12, 0.14, 1)
	for i in range(2):
		var offset_x := -0.025 + i * 0.05
		var barrel_mesh := CylinderMesh.new()
		barrel_mesh.top_radius = 0.025
		barrel_mesh.bottom_radius = 0.025
		barrel_mesh.height = 0.28
		barrel_mesh.material = barrel_mat
		var barrel := MeshInstance3D.new()
		barrel.name = "Barrel_%d" % i
		barrel.mesh = barrel_mesh
		barrel.position = Vector3(offset_x, 0.02, 0.18)
		barrel.rotation_degrees = Vector3(90, 0, 0)
		_shotgun_node.add_child(barrel)

	# Muzzle tips
	var muzzle_mat := StandardMaterial3D.new()
	muzzle_mat.albedo_color = Color(0.08, 0.08, 0.08, 1)
	for i in range(2):
		var offset_x := -0.025 + i * 0.05
		var muzzle_mesh := CylinderMesh.new()
		muzzle_mesh.top_radius = 0.028
		muzzle_mesh.bottom_radius = 0.028
		muzzle_mesh.height = 0.02
		muzzle_mesh.material = muzzle_mat
		var muzzle := MeshInstance3D.new()
		muzzle.name = "MuzzleTip_%d" % i
		muzzle.mesh = muzzle_mesh
		muzzle.position = Vector3(offset_x, 0.02, 0.32)
		muzzle.rotation_degrees = Vector3(90, 0, 0)
		_shotgun_node.add_child(muzzle)

# ------------------------------------------------------------------
# SMG model
# ------------------------------------------------------------------

func _build_smg() -> void:
	_smg_node = Node3D.new()
	_smg_node.name = "SMG"
	_smg_node.position = Vector3(0.35, 1.0, 0.30)
	add_child(_smg_node)

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.20, 0.20, 0.22, 1)
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.07, 0.10, 0.30)
	body_mesh.material = body_mat
	var body_mi := MeshInstance3D.new()
	body_mi.mesh = body_mesh
	body_mi.position = Vector3(0.0, 0.02, 0.06)
	_smg_node.add_child(body_mi)

	var grip_mat := StandardMaterial3D.new()
	grip_mat.albedo_color = Color(0.12, 0.12, 0.12, 1)
	var grip_mesh := BoxMesh.new()
	grip_mesh.size = Vector3(0.06, 0.14, 0.08)
	grip_mesh.material = grip_mat
	var grip := MeshInstance3D.new()
	grip.mesh = grip_mesh
	grip.position = Vector3(0.0, -0.08, -0.02)
	_smg_node.add_child(grip)

	var mag_mat := StandardMaterial3D.new()
	mag_mat.albedo_color = Color(0.15, 0.15, 0.15, 1)
	var mag_mesh := BoxMesh.new()
	mag_mesh.size = Vector3(0.05, 0.16, 0.06)
	mag_mesh.material = mag_mat
	var mag := MeshInstance3D.new()
	mag.mesh = mag_mesh
	mag.position = Vector3(0.0, -0.12, 0.06)
	_smg_node.add_child(mag)

	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.10, 0.10, 0.10, 1)
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.02
	barrel_mesh.bottom_radius = 0.025
	barrel_mesh.height = 0.08
	barrel_mesh.material = barrel_mat
	var barrel := MeshInstance3D.new()
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0.0, 0.04, 0.24)
	barrel.rotation_degrees = Vector3(90, 0, 0)
	_smg_node.add_child(barrel)

# ------------------------------------------------------------------
# Grenade Launcher model
# ------------------------------------------------------------------

func _build_grenade_launcher() -> void:
	_grenade_launcher_node = Node3D.new()
	_grenade_launcher_node.name = "GrenadeLauncher"
	_grenade_launcher_node.position = Vector3(0.35, 0.95, 0.30)
	add_child(_grenade_launcher_node)

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.28, 0.30, 0.22, 1)
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.10, 0.10, 0.20)
	body_mesh.material = body_mat
	var body_mi := MeshInstance3D.new()
	body_mi.mesh = body_mesh
	body_mi.position = Vector3(0.0, 0.0, -0.02)
	_grenade_launcher_node.add_child(body_mi)

	var grip_mat := StandardMaterial3D.new()
	grip_mat.albedo_color = Color(0.35, 0.25, 0.14, 1)
	var grip_mesh := BoxMesh.new()
	grip_mesh.size = Vector3(0.08, 0.14, 0.08)
	grip_mesh.material = grip_mat
	var grip := MeshInstance3D.new()
	grip.mesh = grip_mesh
	grip.position = Vector3(0.0, -0.08, -0.06)
	_grenade_launcher_node.add_child(grip)

	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.15, 0.16, 0.14, 1)
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.04
	barrel_mesh.bottom_radius = 0.04
	barrel_mesh.height = 0.22
	barrel_mesh.material = barrel_mat
	var barrel := MeshInstance3D.new()
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0.0, 0.02, 0.14)
	barrel.rotation_degrees = Vector3(90, 0, 0)
	_grenade_launcher_node.add_child(barrel)

	var muzzle_mat := StandardMaterial3D.new()
	muzzle_mat.albedo_color = Color(0.10, 0.10, 0.10, 1)
	var muzzle_mesh := CylinderMesh.new()
	muzzle_mesh.top_radius = 0.045
	muzzle_mesh.bottom_radius = 0.045
	muzzle_mesh.height = 0.03
	muzzle_mesh.material = muzzle_mat
	var muzzle := MeshInstance3D.new()
	muzzle.mesh = muzzle_mesh
	muzzle.position = Vector3(0.0, 0.02, 0.26)
	muzzle.rotation_degrees = Vector3(90, 0, 0)
	_grenade_launcher_node.add_child(muzzle)

# ------------------------------------------------------------------
# Baseball Bat model
# ------------------------------------------------------------------

func _build_bat() -> void:
	_bat_node = Node3D.new()
	_bat_node.name = "Bat"
	_bat_node.position = Vector3(0.38, 0.95, 0.20)
	add_child(_bat_node)

	var handle_mat := StandardMaterial3D.new()
	handle_mat.albedo_color = Color(0.15, 0.12, 0.08, 1)
	handle_mat.roughness = 0.6
	var handle_mesh := CylinderMesh.new()
	handle_mesh.top_radius = 0.02
	handle_mesh.bottom_radius = 0.025
	handle_mesh.height = 0.25
	handle_mesh.material = handle_mat
	var handle := MeshInstance3D.new()
	handle.mesh = handle_mesh
	handle.position = Vector3(0.0, -0.05, 0.0)
	handle.rotation_degrees = Vector3(90, 0, 0)
	_bat_node.add_child(handle)

	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.50, 0.35, 0.18, 1)
	barrel_mat.roughness = 0.7
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.035
	barrel_mesh.bottom_radius = 0.025
	barrel_mesh.height = 0.45
	barrel_mesh.material = barrel_mat
	var barrel := MeshInstance3D.new()
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0.0, 0.0, 0.35)
	barrel.rotation_degrees = Vector3(90, 0, 0)
	_bat_node.add_child(barrel)

	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = Color(0.55, 0.38, 0.20, 1)
	tip_mat.roughness = 0.65
	var tip_mesh := SphereMesh.new()
	tip_mesh.radius = 0.035
	tip_mesh.height = 0.07
	tip_mesh.material = tip_mat
	var tip := MeshInstance3D.new()
	tip.mesh = tip_mesh
	tip.position = Vector3(0.0, 0.0, 0.58)
	_bat_node.add_child(tip)

# ------------------------------------------------------------------
# Aim line
# ------------------------------------------------------------------

func _build_aim_line() -> void:
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(1.0, 0.1, 0.1, 0.6)
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.no_depth_test = true
	line_mat.render_priority = 5

	_aim_line = MeshInstance3D.new()
	_aim_line.name = "AimLine"
	_aim_line.mesh = ImmediateMesh.new()
	_aim_line.material_override = line_mat
	_aim_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child.call_deferred(_aim_line)

	var dot_mat := StandardMaterial3D.new()
	dot_mat.albedo_color = Color(1.0, 0.05, 0.05, 0.9)
	dot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.no_depth_test = true
	dot_mat.render_priority = 6

	var dot_mesh := SphereMesh.new()
	dot_mesh.radius = 0.07
	dot_mesh.height = 0.14
	dot_mesh.material = dot_mat

	_aim_dot = MeshInstance3D.new()
	_aim_dot.name = "AimDot"
	_aim_dot.mesh = dot_mesh
	_aim_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aim_dot.visible = false
	get_tree().root.add_child.call_deferred(_aim_dot)

func _get_muzzle_world_pos() -> Vector3:
	var weapon_node: Node3D = null
	match _current_weapon:
		"pistol": weapon_node = _pistol_node
		"shotgun": weapon_node = _shotgun_node
		"smg": weapon_node = _smg_node
		"grenade_launcher": weapon_node = _grenade_launcher_node
		"bat": weapon_node = _bat_node

	if weapon_node == null:
		return global_position + Vector3(0, 1.0, 0)

	match _current_weapon:
		"shotgun":
			return weapon_node.global_transform * Vector3(0.0, 0.02, 0.34)
		"smg":
			return weapon_node.global_transform * Vector3(0.0, 0.04, 0.22)
		"grenade_launcher":
			return weapon_node.global_transform * Vector3(0.0, 0.04, 0.24)
		"bat":
			return weapon_node.global_transform * Vector3(0.0, 0.0, 0.5)
	return weapon_node.global_transform * Vector3(0.0, 0.06, 0.16)

func _cast_ray(origin: Vector3, end: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	if self is CollisionObject3D:
		query.exclude = [get_rid()]
	query.collision_mask = 0xFFFFFFFF
	return space.intersect_ray(query)

func _aim_raycast() -> Dictionary:
	var weapon_range: float = _weapon_stats.get("range", 30.0)
	var forward := _get_forward()
	var ray_origin := _get_muzzle_world_pos()
	var ray_end := ray_origin + forward * weapon_range

	var result := _cast_ray(ray_origin, ray_end)
	if result:
		return { "end": result.position, "hit": true }
	return { "end": ray_end, "hit": false }

func _update_aim_line() -> void:
	if _aim_line == null or not is_instance_valid(_aim_line):
		return

	var show := aim_line_enabled and _armed
	_aim_line.visible = show
	if _aim_dot and is_instance_valid(_aim_dot):
		_aim_dot.visible = false
	if not show:
		return

	var muzzle_pos := _get_muzzle_world_pos()
	var im: ImmediateMesh = _aim_line.mesh as ImmediateMesh
	im.clear_surfaces()

	var hit_mode: String = _weapon_stats.get("hit_mode", "single")

	match hit_mode:
		"fan":
			_draw_fan_aim(im, muzzle_pos)
		"melee":
			_draw_melee_aim(im, muzzle_pos)
		"explosive":
			_draw_single_aim(im, muzzle_pos)
		_:
			_draw_single_aim(im, muzzle_pos)

func _draw_single_aim(im: ImmediateMesh, muzzle_pos: Vector3) -> void:
	var aim := _aim_raycast()
	var aim_end: Vector3 = aim["end"]
	var did_hit: bool = aim["hit"]

	if muzzle_pos.distance_to(aim_end) < 0.05:
		_aim_line.visible = false
		return

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(muzzle_pos)
	im.surface_add_vertex(aim_end)
	im.surface_end()

	if did_hit and _aim_dot and is_instance_valid(_aim_dot):
		_aim_dot.visible = true
		_aim_dot.global_position = aim_end

func _draw_fan_aim(im: ImmediateMesh, muzzle_pos: Vector3) -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 12.0)
	var fan_angle: float = _weapon_stats.get("fan_angle", 35.0)
	var fan_rays: int = _weapon_stats.get("fan_rays", 7)

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(fan_rays):
		var t := float(i) / float(fan_rays - 1) if fan_rays > 1 else 0.5
		var angle := deg_to_rad(lerpf(-fan_angle, fan_angle, t))
		var dir := forward.rotated(Vector3.UP, angle)
		var ray_end := muzzle_pos + dir * weapon_range

		var result := _cast_ray(muzzle_pos, ray_end)
		var end_point: Vector3 = result.position if result else ray_end

		im.surface_add_vertex(muzzle_pos)
		im.surface_add_vertex(end_point)
	im.surface_end()

# ------------------------------------------------------------------
# Gun mechanics
# ------------------------------------------------------------------

func _update_gun(delta: float) -> void:
	if not _armed:
		return
	_shoot_timer = max(_shoot_timer - delta, 0.0)

	if _is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_is_reloading = false
			ammo = _weapon_stats.get("magazine_size", 8)

func _try_shoot() -> void:
	if not _armed or _is_reloading or _shoot_timer > 0.0:
		return

	var mag_size: int = _weapon_stats.get("magazine_size", 8)
	var is_melee := (mag_size < 0)

	if not is_melee and ammo <= 0:
		return

	if not is_melee:
		ammo -= 1
	_shoot_timer = WeaponData.shoot_cooldown(_current_weapon)
	_fire_bullet()

func _try_reload() -> void:
	if not _armed:
		return
	var mag_size: int = _weapon_stats.get("magazine_size", 8)
	if mag_size < 0:
		return
	if _is_reloading or ammo == mag_size:
		return
	_is_reloading = true
	_reload_timer = _weapon_stats.get("reload_time", 1.2)

func _fire_bullet() -> void:
	var hit_mode: String = _weapon_stats.get("hit_mode", "single")
	match hit_mode:
		"fan":
			_fire_fan()
			_spawn_muzzle_flash()
		"explosive":
			_fire_explosive()
			_spawn_muzzle_flash()
		"melee":
			_fire_melee()
		_:
			_fire_single()
			_spawn_muzzle_flash()

func _fire_single() -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 40.0)
	var damage: float = _weapon_stats.get("damage", 10.0)
	var tolerance: float = _weapon_stats.get("hit_tolerance", 1.2)
	var spread_deg: float = _weapon_stats.get("spread", 0.0)

	if spread_deg > 0.0:
		var spread_rad := deg_to_rad(spread_deg)
		var rand_yaw := randf_range(-spread_rad, spread_rad)
		var rand_pitch := randf_range(-spread_rad * 0.3, spread_rad * 0.3)
		forward = forward.rotated(Vector3.UP, rand_yaw)
		var right := forward.cross(Vector3.UP).normalized()
		forward = forward.rotated(right, rand_pitch)
		forward = forward.normalized()

	var ray_origin := _get_muzzle_world_pos()
	var ray_end := ray_origin + forward * weapon_range

	var result := _cast_ray(ray_origin, ray_end)
	var hit_enemy := false

	if result and result.collider is CharacterBody3D:
		var hit_body: CharacterBody3D = result.collider as CharacterBody3D
		if hit_body.has_method("take_damage"):
			hit_body.take_damage(damage)
			hit_enemy = true
			_spawn_hit_sparks(result.position)

	if not hit_enemy:
		var best_enemy: CharacterBody3D = null
		var best_dist := tolerance

		for node in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(node) or not node is CharacterBody3D:
				continue
			var enemy_body: CharacterBody3D = node as CharacterBody3D
			if not enemy_body.has_method("take_damage"):
				continue

			var enemy_pos: Vector3 = enemy_body.global_position + Vector3(0, 0.9, 0)
			var to_enemy := enemy_pos - ray_origin
			var proj := to_enemy.dot(forward)
			if proj < 0.0 or proj > weapon_range:
				continue

			var closest_on_ray := ray_origin + forward * proj
			var perp_dist := closest_on_ray.distance_to(enemy_pos)
			if perp_dist < best_dist:
				best_dist = perp_dist
				best_enemy = enemy_body

		if best_enemy != null:
			best_enemy.take_damage(damage)
			_spawn_hit_sparks(best_enemy.global_position + Vector3(0, 0.9, 0))

	_spawn_tracer(ray_origin, result.position if result else ray_end)

func _fire_fan() -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 12.0)
	var damage: float = _weapon_stats.get("damage", 15.0)
	var fan_angle: float = _weapon_stats.get("fan_angle", 20.0)
	var fan_rays: int = _weapon_stats.get("fan_rays", 5)
	var half_angle := deg_to_rad(fan_angle)

	var ray_origin := _get_muzzle_world_pos()

	# Visual tracers (for feedback only)
	for i in range(fan_rays):
		var t := float(i) / float(fan_rays - 1) if fan_rays > 1 else 0.5
		var angle := deg_to_rad(lerpf(-fan_angle, fan_angle, t))
		var dir := forward.rotated(Vector3.UP, angle)
		var ray_end := ray_origin + dir * weapon_range

		var result := _cast_ray(ray_origin, ray_end)
		var tracer_end: Vector3 = result.position if result else ray_end
		_spawn_tracer(ray_origin, tracer_end)

	# True AoE sector hit detection
	var hit_enemies: Array[CharacterBody3D] = []
	for node in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(node) or not node is CharacterBody3D:
			continue
		var enemy_body: CharacterBody3D = node as CharacterBody3D
		if not enemy_body.has_method("take_damage"):
			continue

		var to_enemy: Vector3 = enemy_body.global_position - global_position
		to_enemy.y = 0.0
		var dist: float = to_enemy.length()
		if dist > weapon_range or dist < 0.1:
			continue

		var angle_to: float = forward.angle_to(to_enemy.normalized())
		if angle_to <= half_angle:
			hit_enemies.append(enemy_body)

	for enemy_body in hit_enemies:
		if is_instance_valid(enemy_body):
			enemy_body.take_damage(damage)
			_spawn_hit_sparks(enemy_body.global_position + Vector3(0, 0.9, 0))

	_spawn_sector_flash(ray_origin, forward, weapon_range, half_angle)

func _spawn_sector_flash(origin: Vector3, forward: Vector3, sector_range: float, half_angle: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.6, 0.2, 0.25)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var im_mesh := ImmediateMesh.new()
	var steps := 8
	im_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(steps):
		var t0 := float(i) / float(steps)
		var t1 := float(i + 1) / float(steps)
		var a0: float = lerpf(-half_angle, half_angle, t0)
		var a1: float = lerpf(-half_angle, half_angle, t1)
		var d0 := forward.rotated(Vector3.UP, a0) * sector_range
		var d1 := forward.rotated(Vector3.UP, a1) * sector_range
		im_mesh.surface_add_vertex(origin)
		im_mesh.surface_add_vertex(origin + d0)
		im_mesh.surface_add_vertex(origin + d1)
	im_mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = im_mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child(mi)

	var tw := get_tree().create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.12)
	tw.tween_callback(mi.queue_free)

func _fire_explosive() -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 25.0)
	var damage: float = _weapon_stats.get("damage", 30.0)
	var radius: float = _weapon_stats.get("explosion_radius", 5.0)

	var ray_origin := _get_muzzle_world_pos()
	var ray_end := ray_origin + forward * weapon_range

	var result := _cast_ray(ray_origin, ray_end)
	var impact_pos: Vector3 = result.position if result else ray_end
	impact_pos.y = 0.5

	_spawn_tracer(ray_origin, impact_pos)
	_spawn_explosion(impact_pos, radius)

	for node in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(node) or not node is CharacterBody3D:
			continue
		var enemy_body: CharacterBody3D = node as CharacterBody3D
		if not enemy_body.has_method("take_damage"):
			continue
		var dist: float = enemy_body.global_position.distance_to(impact_pos)
		if dist <= radius:
			var falloff: float = 1.0 - (dist / radius) * 0.5
			enemy_body.take_damage(damage * falloff)

func _spawn_explosion(pos: Vector3, radius: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.5, 0.1, 0.6)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.05)
	mat.emission_energy_multiplier = 3.0

	var mesh := SphereMesh.new()
	mesh.radius = 0.3
	mesh.height = 0.6
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.global_position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child(mi)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.2)
	light.light_energy = 8.0
	light.omni_range = radius * 1.5
	light.global_position = pos + Vector3(0, 0.5, 0)
	get_tree().root.add_child(light)

	var tw := get_tree().create_tween()
	tw.tween_property(mi, "scale", Vector3.ONE * (radius / 0.3), 0.15)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.3)
	tw.parallel().tween_property(light, "light_energy", 0.0, 0.3)
	tw.tween_callback(mi.queue_free)
	tw.tween_callback(light.queue_free)

func _fire_melee() -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 2.5)
	var damage: float = _weapon_stats.get("damage", 20.0)
	var sweep_angle: float = _weapon_stats.get("sweep_angle", 90.0)
	var half_sweep := deg_to_rad(sweep_angle * 0.5)

	var origin := global_position + Vector3(0, 0.9, 0)
	var hit_count := 0

	for node in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(node) or not node is CharacterBody3D:
			continue
		var enemy_body: CharacterBody3D = node as CharacterBody3D
		if not enemy_body.has_method("take_damage"):
			continue

		var to_enemy: Vector3 = enemy_body.global_position - global_position
		to_enemy.y = 0.0
		var dist: float = to_enemy.length()
		if dist > weapon_range or dist < 0.1:
			continue

		var angle_to: float = forward.angle_to(to_enemy.normalized())
		if angle_to <= half_sweep:
			enemy_body.take_damage(damage)
			hit_count += 1
			_spawn_hit_sparks(enemy_body.global_position + Vector3(0, 0.9, 0))

	_spawn_swing_arc(origin, forward, weapon_range, half_sweep)

func _spawn_swing_arc(origin: Vector3, forward: Vector3, arc_range: float, half_angle: float) -> void:
	var arc_mat := StandardMaterial3D.new()
	arc_mat.albedo_color = Color(0.8, 0.6, 0.3, 0.4)
	arc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	arc_mat.no_depth_test = true

	var im_mesh := ImmediateMesh.new()
	var steps := 8
	im_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var a: float = lerpf(-half_angle, half_angle, t)
		var dir := forward.rotated(Vector3.UP, a)
		im_mesh.surface_add_vertex(origin)
		im_mesh.surface_add_vertex(origin + dir * arc_range)
	im_mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = im_mesh
	mi.material_override = arc_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child(mi)

	var tw := get_tree().create_tween()
	tw.tween_property(arc_mat, "albedo_color:a", 0.0, 0.15)
	tw.tween_callback(mi.queue_free)

func _draw_melee_aim(im: ImmediateMesh, muzzle_pos: Vector3) -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 2.5)
	var sweep_angle: float = _weapon_stats.get("sweep_angle", 90.0)
	var half_sweep := deg_to_rad(sweep_angle * 0.5)
	var origin := global_position + Vector3(0, 0.5, 0)

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var steps := 6
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var a: float = lerpf(-half_sweep, half_sweep, t)
		var dir := forward.rotated(Vector3.UP, a)
		im.surface_add_vertex(origin)
		im.surface_add_vertex(origin + dir * weapon_range)
	for i in range(steps):
		var t0 := float(i) / float(steps)
		var t1 := float(i + 1) / float(steps)
		var a0: float = lerpf(-half_sweep, half_sweep, t0)
		var a1: float = lerpf(-half_sweep, half_sweep, t1)
		im.surface_add_vertex(origin + forward.rotated(Vector3.UP, a0) * weapon_range)
		im.surface_add_vertex(origin + forward.rotated(Vector3.UP, a1) * weapon_range)
	im.surface_end()

func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	var dir := to - from
	var length := dir.length()

	if length < 0.01:
		return

	var mid := (from + to) * 0.5
	var tracer_color: Color = _weapon_stats.get("tracer_color", Color(1.0, 0.9, 0.3, 0.8))

	var mat := StandardMaterial3D.new()
	mat.albedo_color = tracer_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true

	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.015
	mesh.bottom_radius = 0.015
	mesh.height = length
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Tracer"

	get_tree().root.add_child(mi)
	mi.global_position = mid
	mi.look_at(to, Vector3.UP)
	mi.rotate_object_local(Vector3.RIGHT, PI * 0.5)

	var tw := get_tree().create_tween()
	tw.tween_interval(0.05)
	tw.tween_callback(mi.queue_free)

# ------------------------------------------------------------------
# Movement helpers
# ------------------------------------------------------------------

func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= GRAVITY * delta

func _get_input_vector() -> Vector2:
	var x := 0.0
	var y := 0.0
	if Input.is_action_pressed("move_left"):
		x -= 1.0
	if Input.is_action_pressed("move_right"):
		x += 1.0
	if Input.is_action_pressed("move_forward"):
		y -= 1.0
	if Input.is_action_pressed("move_backward"):
		y += 1.0
	var v := Vector2(x, y)
	return v.normalized() if v.length() > 1.0 else v

func _get_world_movement_direction() -> Vector3:
	var input := _get_input_vector()
	if input.length() < 0.05 or _camera == null:
		return Vector3.ZERO

	var cam_basis := _camera.global_transform.basis
	var cam_fwd   := -cam_basis.z
	var cam_right := cam_basis.x
	cam_fwd.y  = 0.0
	cam_right.y = 0.0

	if cam_fwd.length_squared() < 0.001:
		return Vector3.ZERO

	cam_fwd   = cam_fwd.normalized()
	cam_right = cam_right.normalized()

	return (cam_fwd * (-input.y) + cam_right * input.x)

func _update_sprint(move_dir: Vector3, delta: float) -> void:
	var wants_sprint := Input.is_action_pressed("sprint")
	var is_moving := move_dir.length() > 0.1

	if wants_sprint and is_moving and stamina > 0.0:
		_is_sprinting = true
		stamina = max(stamina - STAMINA_DRAIN * delta, 0.0)
		_sprint_cooldown = STAMINA_RECOVER_DELAY
	else:
		_is_sprinting = false
		_sprint_cooldown = max(_sprint_cooldown - delta, 0.0)
		if _sprint_cooldown <= 0.0:
			stamina = min(stamina + STAMINA_RECOVER * delta, STAMINA_MAX)

func _apply_movement(dir: Vector3, speed: float, delta: float) -> void:
	var target_xz := dir * speed
	velocity.x = move_toward(velocity.x, target_xz.x, ACCELERATION * delta)
	velocity.z = move_toward(velocity.z, target_xz.z, ACCELERATION * delta)

func _rotate_to_face_mouse(delta: float) -> void:
	if look_target == Vector3.INF:
		return
	var dir := look_target - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		return
	var target_angle := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, target_angle, ROTATION_SPEED * delta)

func _sync_hud() -> void:
	if hud:
		hud.set_stamina(stamina / STAMINA_MAX * 100.0)
		if _armed:
			var mag_size: int = _weapon_stats.get("magazine_size", 8)
			if mag_size < 0:
				hud.set_ammo(-1, -1)
			else:
				hud.set_ammo(ammo, mag_size)
			var display_name := _current_weapon.replace("_", " ").to_upper()
			hud.set_weapon_name(display_name)
		else:
			hud.set_ammo(0, 0)
			hud.set_weapon_name("UNARMED")
		hud.set_reloading(_is_reloading and _armed)

# ------------------------------------------------------------------
# VFX
# ------------------------------------------------------------------

func _spawn_muzzle_flash() -> void:
	var muzzle_pos := _get_muzzle_world_pos()

	var flash_light := OmniLight3D.new()
	flash_light.light_color = Color(1.0, 0.85, 0.4)
	flash_light.light_energy = 4.0
	flash_light.omni_range = 3.0
	flash_light.global_position = muzzle_pos
	get_tree().root.add_child(flash_light)

	var flash_mat := StandardMaterial3D.new()
	flash_mat.albedo_color = Color(1.0, 0.9, 0.4, 0.9)
	flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash_mat.emission_enabled = true
	flash_mat.emission = Color(1.0, 0.8, 0.3)
	flash_mat.emission_energy_multiplier = 2.0

	var flash_mesh := SphereMesh.new()
	flash_mesh.radius = 0.08
	flash_mesh.height = 0.16
	flash_mesh.material = flash_mat

	var flash_mi := MeshInstance3D.new()
	flash_mi.mesh = flash_mesh
	flash_mi.global_position = muzzle_pos
	flash_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().root.add_child(flash_mi)

	var tw := get_tree().create_tween()
	tw.tween_interval(0.05)
	tw.tween_callback(flash_light.queue_free)
	tw.tween_callback(flash_mi.queue_free)

func _spawn_hit_sparks(hit_pos: Vector3) -> void:
	var spark_mat := StandardMaterial3D.new()
	spark_mat.albedo_color = Color(1.0, 0.7, 0.2, 0.8)
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	for _i in range(3):
		var spark_mesh := SphereMesh.new()
		spark_mesh.radius = 0.04
		spark_mesh.height = 0.08
		spark_mesh.material = spark_mat

		var spark := MeshInstance3D.new()
		spark.mesh = spark_mesh
		spark.global_position = hit_pos + Vector3(
			randf_range(-0.15, 0.15),
			randf_range(0.0, 0.3),
			randf_range(-0.15, 0.15)
		)
		spark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().root.add_child(spark)

		var tw := get_tree().create_tween()
		tw.tween_property(spark, "global_position:y", spark.global_position.y + 0.3, 0.15)
		tw.parallel().tween_property(spark, "scale", Vector3.ZERO, 0.15)
		tw.tween_callback(spark.queue_free)
