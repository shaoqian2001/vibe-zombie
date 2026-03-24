extends CharacterBody3D

# Movement constants
const SPEED = 6.0
const SPRINT_SPEED = 10.0
const ACCELERATION = 18.0
const GRAVITY = 24.0
const ROTATION_SPEED = 14.0

# Stamina
const STAMINA_MAX := 40.0
const STAMINA_DRAIN := 15.0   # per second while sprinting
const STAMINA_RECOVER := 10.0 # per second while not sprinting
const STAMINA_RECOVER_DELAY := 2.0  # seconds after stop sprinting before recovery

var stamina: float = STAMINA_MAX
var _sprint_cooldown: float = 0.0
var _is_sprinting: bool = false

# Current weapon (key into WeaponData.WEAPONS)
var _current_weapon: String = "pistol"
var _weapon_stats: Dictionary = {}

# Gun state
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

# Pistol mesh (built in code, attached to right hand area)
var _pistol_node: Node3D = null

# Aim line — togglable (will later be tied to accessories)
var _aim_line: MeshInstance3D = null
var _aim_dot: MeshInstance3D = null  # solid red dot at hit point
var aim_line_enabled: bool = true  # on by default for testing

func _ready() -> void:
	await get_tree().process_frame
	_camera = get_viewport().get_camera_3d()
	_equip_weapon(_current_weapon)
	_build_pistol()
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
	if event.is_action_pressed("shoot"):
		_try_shoot()
	elif event.is_action_pressed("reload"):
		_try_reload()

# ------------------------------------------------------------------
# Weapon system
# ------------------------------------------------------------------

func _equip_weapon(weapon_name: String) -> void:
	_current_weapon = weapon_name
	_weapon_stats = WeaponData.get_weapon(weapon_name)
	ammo = _weapon_stats.get("magazine_size", 8)

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
	# Position at right hand area (+Z is the model's visual front)
	_pistol_node.position = Vector3(0.35, 1.0, 0.30)
	add_child(_pistol_node)

	# Grip (handle)
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

	# Slide (barrel / top part, extends forward = +Z)
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

	# Muzzle (small cylinder at the front tip)
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
# Aim line — raycast-based, stops at first obstacle
# ------------------------------------------------------------------

func _build_aim_line() -> void:
	# Line mesh (ImmediateMesh redrawn each frame — always flat, no rotation)
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

	# Hit-point dot (small sphere, solid red)
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
	if _pistol_node == null:
		return global_position + Vector3(0, 1.0, 0)
	# Muzzle tip is just past the muzzle mesh (+Z = visual forward)
	return _pistol_node.global_transform * Vector3(0.0, 0.06, 0.16)

func _aim_raycast() -> Dictionary:
	# Cast a ray from the muzzle in the forward direction up to weapon range.
	# Returns { "end": Vector3, "hit": bool }
	var weapon_range: float = _weapon_stats.get("range", 30.0)
	var forward := _get_forward()
	var ray_origin := _get_muzzle_world_pos()
	var ray_end := ray_origin + forward * weapon_range

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	if self is CollisionObject3D:
		query.exclude = [get_rid()]
	query.collision_mask = 0xFFFFFFFF

	var result := space.intersect_ray(query)
	if result:
		return { "end": result.position, "hit": true }
	return { "end": ray_end, "hit": false }

func _update_aim_line() -> void:
	if _aim_line == null or not is_instance_valid(_aim_line):
		return

	_aim_line.visible = aim_line_enabled
	if _aim_dot and is_instance_valid(_aim_dot):
		_aim_dot.visible = false
	if not aim_line_enabled:
		return

	var muzzle_pos := _get_muzzle_world_pos()
	var aim := _aim_raycast()
	var aim_end: Vector3 = aim["end"]
	var did_hit: bool = aim["hit"]

	if muzzle_pos.distance_to(aim_end) < 0.05:
		_aim_line.visible = false
		return

	# Redraw the line as two vertices (flat, no rotation needed)
	var im: ImmediateMesh = _aim_line.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(muzzle_pos)
	im.surface_add_vertex(aim_end)
	im.surface_end()

	# Show red dot at hit point
	if did_hit and _aim_dot and is_instance_valid(_aim_dot):
		_aim_dot.visible = true
		_aim_dot.global_position = aim_end

# ------------------------------------------------------------------
# Gun mechanics
# ------------------------------------------------------------------

func _update_gun(delta: float) -> void:
	_shoot_timer = max(_shoot_timer - delta, 0.0)

	if _is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_is_reloading = false
			ammo = _weapon_stats.get("magazine_size", 8)

func _try_shoot() -> void:
	if _is_reloading or ammo <= 0 or _shoot_timer > 0.0:
		return

	ammo -= 1
	_shoot_timer = WeaponData.shoot_cooldown(_current_weapon)
	_fire_bullet()

func _try_reload() -> void:
	if _is_reloading or ammo == _weapon_stats.get("magazine_size", 8):
		return
	_is_reloading = true
	_reload_timer = _weapon_stats.get("reload_time", 1.2)

func _fire_bullet() -> void:
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 30.0)
	var damage: float = _weapon_stats.get("damage", 10.0)

	var ray_origin := _get_muzzle_world_pos()
	var ray_end := ray_origin + forward * weapon_range

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	if self is CollisionObject3D:
		query.exclude = [get_rid()]
	query.collision_mask = 0xFFFFFFFF

	var result := space.intersect_ray(query)
	if result and result.collider is CharacterBody3D:
		var hit_body: CharacterBody3D = result.collider as CharacterBody3D
		if hit_body.has_method("take_damage"):
			hit_body.take_damage(damage)

	_spawn_tracer(ray_origin, result.position if result else ray_end)

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
		hud.set_ammo(ammo, _weapon_stats.get("magazine_size", 8))
		hud.set_reloading(_is_reloading)
