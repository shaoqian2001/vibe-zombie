extends Camera3D

## Isometric-style camera that follows a target node.
##
## The camera stays at a fixed angular offset (yaw + pitch) relative to the
## target and smoothly interpolates position each frame.

@export var follow_speed: float   = 7.0   ## Smoothing factor (higher = snappier)
@export var distance: float       = 22.0  ## Distance from target
@export var pitch_deg: float      = 42.0  ## Vertical tilt (degrees above horizon)
@export var yaw_deg: float        = 45.0  ## Horizontal angle (degrees, fixed)
@export var look_offset: Vector3  = Vector3(0.0, 1.0, 0.0)  ## Point to look at offset

# Scroll-wheel zoom bounds. Tuned so the player can pull in tight enough
# to read facial detail and back out far enough to scout a city block,
# without ever clipping into the player or losing them off-screen.
const ZOOM_MIN := 8.0
const ZOOM_MAX := 40.0
const ZOOM_STEP := 1.5  # world-units per wheel notch

var target: Node3D = null

# Cached offset (computed once)
var _offset: Vector3

func _ready() -> void:
	# Push the near plane well out from Godot's 0.05 m default. Depth-buffer
	# precision is dominated by the near/far ratio, and the tight default
	# starved the far ground of resolution — the near-coplanar road/paint/
	# crosswalk quads z-fought and flickered. This camera always sits at
	# least ZOOM_MIN (8 m) back from the player and never approaches world
	# geometry, so a 0.5 m near plane clips nothing visible while giving the
	# ground layers far more depth headroom.
	near = 0.5
	_update_offset()

func set_target(node: Node3D) -> void:
	target = node
	if target:
		global_position = target.global_position + _offset
		look_at(target.global_position + look_offset, Vector3.UP)

const ROTATE_SPEED := 90.0  # degrees per second

func _unhandled_input(event: InputEvent) -> void:
	# Mouse wheel zoom — forward (up) zooms in, backward (down) zooms out.
	# Adjust `distance` and refresh the cached offset so the next frame's
	# follow lerp moves the camera to the new pull-back length.
	if event is InputEventMouseButton and event.pressed:
		var btn := event as InputEventMouseButton
		if btn.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			_update_offset()
		elif btn.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			_update_offset()

func _process(delta: float) -> void:
	if not target:
		return

	if Input.is_action_pressed("rotate_left"):
		yaw_deg += ROTATE_SPEED * delta
		_update_offset()
	# E rotates right — unless the followed player is holding a usable item, in
	# which case E is claimed as "use item" (see Player.wants_use_key) so the
	# camera yields the key.
	if Input.is_action_pressed("rotate_right") and not _use_key_claimed():
		yaw_deg -= ROTATE_SPEED * delta
		_update_offset()

	var desired_pos := target.global_position + _offset
	global_position = global_position.lerp(desired_pos, follow_speed * delta)
	look_at(target.global_position + look_offset, Vector3.UP)

## True when the followed player is holding a usable item, so E should be
## consumed as "use" rather than rotating the camera.
func _use_key_claimed() -> bool:
	return target != null and target.has_method("wants_use_key") and target.wants_use_key()

func _update_offset() -> void:
	var pitch := deg_to_rad(pitch_deg)
	var yaw   := deg_to_rad(yaw_deg)
	_offset = Vector3(
		sin(yaw)  * cos(pitch),
		sin(pitch),
		cos(yaw)  * cos(pitch)
	) * distance
