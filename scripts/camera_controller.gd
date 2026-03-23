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

var target: Node3D = null

# Cached offset (computed once)
var _offset: Vector3

func _ready() -> void:
	_update_offset()

func set_target(node: Node3D) -> void:
	target = node
	if target:
		global_position = target.global_position + _offset
		look_at(target.global_position + look_offset, Vector3.UP)

func _process(delta: float) -> void:
	if not target:
		return
	var desired_pos := target.global_position + _offset
	global_position = global_position.lerp(desired_pos, follow_speed * delta)
	look_at(target.global_position + look_offset, Vector3.UP)

func _update_offset() -> void:
	var pitch := deg_to_rad(pitch_deg)
	var yaw   := deg_to_rad(yaw_deg)
	_offset = Vector3(
		sin(yaw)  * cos(pitch),
		sin(pitch),
		cos(yaw)  * cos(pitch)
	) * distance
