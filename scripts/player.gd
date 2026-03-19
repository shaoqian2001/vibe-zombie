extends CharacterBody3D

# Movement constants
const SPEED = 6.0
const SPRINT_SPEED = 10.0
const ACCELERATION = 18.0
const GRAVITY = 24.0

# Stamina
const STAMINA_MAX := 40.0
const STAMINA_DRAIN := 15.0   # per second while sprinting
const STAMINA_RECOVER := 10.0 # per second while not sprinting
const STAMINA_RECOVER_DELAY := 2.0  # seconds after stop sprinting before recovery

# Gun
const MAGAZINE_SIZE := 8
const BULLET_DAMAGE := 10.0
const SHOOT_COOLDOWN := 0.25   # seconds between shots
const RELOAD_TIME := 1.2       # seconds to reload
const SHOOT_RANGE := 30.0      # max shooting distance

var stamina: float = STAMINA_MAX
var _sprint_cooldown: float = 0.0  # time remaining before stamina recovers
var _is_sprinting: bool = false

# Gun state
var ammo: int = MAGAZINE_SIZE
var _shoot_timer: float = 0.0
var _reload_timer: float = 0.0
var _is_reloading: bool = false

# Reference to the isometric camera
var _camera: Camera3D = null

# Reference to the HUD (set by main.gd)
var hud = null

# Pistol mesh (built in code, attached to right hand area)
var _pistol_node: Node3D = null

# Aim line (always visible, shows shooting direction + range)
var _aim_line: MeshInstance3D = null

func _ready() -> void:
	# Wait one frame so the scene tree is fully set up before finding the camera
	await get_tree().process_frame
	_camera = get_viewport().get_camera_3d()
	_build_pistol()
	_build_aim_line()

func _physics_process(delta: float) -> void:
	_apply_gravity(delta)
	var move_dir := _get_world_movement_direction()
	_update_sprint(move_dir, delta)
	var current_speed := SPRINT_SPEED if _is_sprinting else SPEED
	_apply_movement(move_dir, current_speed, delta)
	_rotate_to_face(move_dir, delta)
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
# Pistol model
# ------------------------------------------------------------------

func _build_pistol() -> void:
	_pistol_node = Node3D.new()
	_pistol_node.name = "Pistol"
	# Position at right hand area (offset from body centre)
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

	# Slide (barrel / top part)
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

	# Muzzle (small cylinder at the front)
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
# Aim line (persistent laser-sight style indicator)
# ------------------------------------------------------------------

func _build_aim_line() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.2, 0.15, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 5

	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.02
	mesh.bottom_radius = 0.02
	mesh.height = SHOOT_RANGE
	mesh.material = mat

	_aim_line = MeshInstance3D.new()
	_aim_line.name = "AimLine"
	_aim_line.mesh = mesh
	_aim_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_aim_line)

func _update_aim_line() -> void:
	if _aim_line == null:
		return
	# The aim line extends forward from chest height along the player's facing direction
	var forward := -global_transform.basis.z
	var origin := Vector3(0, 1.0, 0)
	var line_center := origin + forward * (SHOOT_RANGE * 0.5)

	_aim_line.position = line_center
	# Align the cylinder along the forward direction
	_aim_line.look_at(global_position + origin + forward * SHOOT_RANGE, Vector3.UP)
	_aim_line.rotate_object_local(Vector3.RIGHT, PI * 0.5)

# ------------------------------------------------------------------
# Gun mechanics
# ------------------------------------------------------------------

func _update_gun(delta: float) -> void:
	_shoot_timer = max(_shoot_timer - delta, 0.0)

	if _is_reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_is_reloading = false
			ammo = MAGAZINE_SIZE

func _try_shoot() -> void:
	if _is_reloading:
		return
	if ammo <= 0:
		return
	if _shoot_timer > 0.0:
		return

	ammo -= 1
	_shoot_timer = SHOOT_COOLDOWN
	_fire_bullet()

func _try_reload() -> void:
	if _is_reloading:
		return
	if ammo == MAGAZINE_SIZE:
		return
	_is_reloading = true
	_reload_timer = RELOAD_TIME

func _fire_bullet() -> void:
	# Cast a ray from the player in the direction they're facing
	var forward := -global_transform.basis.z
	var ray_origin := global_position + Vector3(0, 1.0, 0)  # chest height
	var ray_end := ray_origin + forward * SHOOT_RANGE

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.exclude = [get_rid()]
	query.collision_mask = 0xFFFFFFFF

	var result := space.intersect_ray(query)
	if result and result.collider is CharacterBody3D:
		var hit_body: CharacterBody3D = result.collider as CharacterBody3D
		if hit_body.has_method("take_damage"):
			hit_body.take_damage(BULLET_DAMAGE)

	# Visual bullet tracer
	_spawn_tracer(ray_origin, result.position if result else ray_end)

func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	var mid := (from + to) * 0.5
	var dir := to - from
	var length := dir.length()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.3, 0.8)
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

	# Position at midpoint, orient along the ray direction
	mi.global_position = mid
	if dir.length() > 0.01:
		mi.look_at(to, Vector3.UP)
		mi.rotate_object_local(Vector3.RIGHT, PI * 0.5)

	get_tree().root.add_child(mi)

	# Fade out and remove after a short time
	var tw := get_tree().create_tween()
	tw.tween_interval(0.05)
	tw.tween_callback(mi.queue_free)

# ------------------------------------------------------------------
# Movement helpers
# ------------------------------------------------------------------

func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		velocity.y = -0.5  # small value to keep floor detection happy
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

	# Movement is relative to the camera orientation (fixed isometric view)
	var cam_basis := _camera.global_transform.basis
	var cam_fwd   := -cam_basis.z
	var cam_right := cam_basis.x
	cam_fwd.y  = 0.0
	cam_right.y = 0.0

	# Guard against degenerate camera orientation
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

func _rotate_to_face(dir: Vector3, delta: float) -> void:
	if dir.length() < 0.1:
		return
	var target_angle := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, target_angle, 12.0 * delta)

func _sync_hud() -> void:
	if hud:
		hud.set_stamina(stamina / STAMINA_MAX * 100.0)
		hud.set_ammo(ammo, MAGAZINE_SIZE)
		hud.set_reloading(_is_reloading)
