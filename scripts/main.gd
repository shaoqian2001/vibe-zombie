extends Node

## Main scene controller.
## Wires up the camera → player link and handles player spawn position.

# Spawn point: far from map centre (near the rim of the 5×5 block grid).
# The grid spans roughly -44 to +44 on both axes; rim is around ±38.
const SPAWN_CANDIDATES := [
	Vector3( 38.0, 0.5,  38.0),
	Vector3(-38.0, 0.5,  38.0),
	Vector3( 38.0, 0.5, -38.0),
	Vector3(-38.0, 0.5, -38.0),
]

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D        = $Camera3D

func _ready() -> void:
	# Pick a random rim spawn
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var spawn_pos: Vector3 = SPAWN_CANDIDATES[rng.randi() % SPAWN_CANDIDATES.size()]
	player.global_position = spawn_pos

	# Connect camera to player
	camera.set_target(player)
