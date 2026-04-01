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

# Aim line
var _aim_line: MeshInstance3D = null
var _aim_dot: MeshInstance3D = null
var aim_line_enabled: bool = true

func _ready() -> void:
	await get_tree().process_frame
	_camera = get_viewport().get_camera_3d()
	_build_pistol()
	_build_shotgun()
	_pistol_node.visible = false
	_shotgun_node.visible = false
	_build_aim_line()

func _physics_process(delta: float) -> void:
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

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("weapon_1"):
		_switch_weapon(0)
	elif event.is_action_pressed("weapon_2"):
		_switch_weapon(1)
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
	if _current_weapon == "pistol":
		weapon_node = _pistol_node
	elif _current_weapon == "shotgun":
		weapon_node = _shotgun_node

	if weapon_node == null:
		return global_position + Vector3(0, 1.0, 0)

	if _current_weapon == "shotgun":
		return weapon_node.global_transform * Vector3(0.0, 0.02, 0.34)
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

	if hit_mode == "fan":
		_draw_fan_aim(im, muzzle_pos)
	else:
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
		var angle := deg_to_rad(lerp(-fan_angle, fan_angle, t))
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
	if not _armed or _is_reloading or ammo <= 0 or _shoot_timer > 0.0:
		return

	ammo -= 1
	_shoot_timer = WeaponData.shoot_cooldown(_current_weapon)
	_fire_bullet()

func _try_reload() -> void:
	if not _armed:
		return
	if _is_reloading or ammo == _weapon_stats.get("magazine_size", 8):
		return
	_is_reloading = true
	_reload_timer = _weapon_stats.get("reload_time", 1.2)

func _fire_bullet() -> void:
	var hit_mode: String = _weapon_stats.get("hit_mode", "single")
	if hit_mode == "fan":
		_fire_fan()
	else:
		_fire_single()

func _fire_single() -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 40.0)
	var damage: float = _weapon_stats.get("damage", 10.0)
	var tolerance: float = _weapon_stats.get("hit_tolerance", 1.2)

	var ray_origin := _get_muzzle_world_pos()
	var ray_end := ray_origin + forward * weapon_range

	var result := _cast_ray(ray_origin, ray_end)
	var hit_enemy := false

	if result and result.collider is CharacterBody3D:
		var hit_body: CharacterBody3D = result.collider as CharacterBody3D
		if hit_body.has_method("take_damage"):
			hit_body.take_damage(damage)
			hit_enemy = true

	# Relaxed hit detection: if the ray missed, check enemies near the ray line
	if not hit_enemy:
		var best_enemy: CharacterBody3D = null
		var best_dist := tolerance

		for enemy in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(enemy) or not enemy is CharacterBody3D:
				continue
			if not enemy.has_method("take_damage"):
				continue

			var enemy_pos: Vector3 = enemy.global_position + Vector3(0, 0.9, 0)
			var to_enemy := enemy_pos - ray_origin
			var proj := to_enemy.dot(forward)
			if proj < 0.0 or proj > weapon_range:
				continue

			var closest_on_ray := ray_origin + forward * proj
			var perp_dist := closest_on_ray.distance_to(enemy_pos)
			if perp_dist < best_dist:
				best_dist = perp_dist
				best_enemy = enemy

		if best_enemy != null:
			best_enemy.take_damage(damage)

	_spawn_tracer(ray_origin, result.position if result else ray_end)

func _fire_fan() -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 12.0)
	var damage: float = _weapon_stats.get("damage", 15.0)
	var fan_angle: float = _weapon_stats.get("fan_angle", 35.0)
	var fan_rays: int = _weapon_stats.get("fan_rays", 7)

	var ray_origin := _get_muzzle_world_pos()
	var hit_enemies: Array = []

	for i in range(fan_rays):
		var t := float(i) / float(fan_rays - 1) if fan_rays > 1 else 0.5
		var angle := deg_to_rad(lerp(-fan_angle, fan_angle, t))
		var dir := forward.rotated(Vector3.UP, angle)
		var ray_end := ray_origin + dir * weapon_range

		var result := _cast_ray(ray_origin, ray_end)
		var tracer_end: Vector3 = result.position if result else ray_end

		if result and result.collider is CharacterBody3D:
			var hit_body: CharacterBody3D = result.collider as CharacterBody3D
			if hit_body.has_method("take_damage") and hit_body not in hit_enemies:
				hit_enemies.append(hit_body)

		_spawn_tracer(ray_origin, tracer_end)

	for enemy in hit_enemies:
		if is_instance_valid(enemy):
			enemy.take_damage(damage)

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
			hud.set_ammo(ammo, _weapon_stats.get("magazine_size", 8))
			hud.set_weapon_name(_current_weapon.to_upper())
		else:
			hud.set_ammo(0, 0)
			hud.set_weapon_name("UNARMED")
		hud.set_reloading(_is_reloading and _armed)
