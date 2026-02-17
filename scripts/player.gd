extends CharacterBody3D

# Movement constants
const SPEED = 6.0
const ACCELERATION = 18.0
const GRAVITY = 24.0

# Reference to the isometric camera
var _camera: Camera3D = null

func _ready() -> void:
	# Wait one frame so the scene tree is fully set up before finding the camera
	await get_tree().process_frame
	_camera = get_viewport().get_camera_3d()

func _physics_process(delta: float) -> void:
	_apply_gravity(delta)
	var move_dir := _get_world_movement_direction()
	_apply_movement(move_dir, delta)
	_rotate_to_face(move_dir, delta)
	move_and_slide()

# ------------------------------------------------------------------
# Private helpers
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

	# Project camera axes onto the XZ plane so movement is always horizontal
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

func _apply_movement(dir: Vector3, delta: float) -> void:
	var target_xz := dir * SPEED
	velocity.x = move_toward(velocity.x, target_xz.x, ACCELERATION * delta)
	velocity.z = move_toward(velocity.z, target_xz.z, ACCELERATION * delta)

func _rotate_to_face(dir: Vector3, delta: float) -> void:
	if dir.length() < 0.1:
		return
	var target_angle := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, target_angle, 12.0 * delta)
