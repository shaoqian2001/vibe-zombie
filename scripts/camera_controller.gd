extends Camera3D

## Isometric-style camera that follows a target node.
##
## The camera stays at a fixed angular offset (yaw + pitch) relative to the
## target and smoothly interpolates position each frame.
## Q / E rotate the viewing angle around the player.

@export var follow_speed: float   = 7.0   ## Smoothing factor (higher = snappier)
@export var distance: float       = 22.0  ## Distance from target
@export var pitch_deg: float      = 42.0  ## Vertical tilt (degrees above horizon)
@export var yaw_deg: float        = 45.0  ## Horizontal angle (degrees)
@export var look_offset: Vector3  = Vector3(0.0, 1.0, 0.0)  ## Point to look at offset

const YAW_SPEED := 90.0  # Degrees per second when holding Q/E

var target: Node3D = null

# Cached offset recalculated when yaw/pitch/distance change
var _offset: Vector3

func _ready() -> void:
	_update_offset()

func set_target(node: Node3D) -> void:
	target = node
	if target:
		# Snap to position on first frame to avoid visible jump
		global_position = target.global_position + _offset
		look_at(target.global_position + look_offset, Vector3.UP)

func _process(delta: float) -> void:
	# Handle Q/E yaw rotation
	var yaw_input := 0.0
	if Input.is_action_pressed("rotate_left"):
		yaw_input -= 1.0
	if Input.is_action_pressed("rotate_right"):
		yaw_input += 1.0

	if yaw_input != 0.0:
		yaw_deg += yaw_input * YAW_SPEED * delta
		_update_offset()

	if not target:
		return
	var desired_pos := target.global_position + _offset
	global_position = global_position.lerp(desired_pos, follow_speed * delta)
	look_at(target.global_position + look_offset, Vector3.UP)

# ------------------------------------------------------------------

func _update_offset() -> void:
	var pitch := deg_to_rad(pitch_deg)
	var yaw   := deg_to_rad(yaw_deg)
	_offset = Vector3(
		sin(yaw)  * cos(pitch),
		sin(pitch),
		cos(yaw)  * cos(pitch)
	) * distance
