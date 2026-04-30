extends CanvasLayer

## FOV parameter holder.
##
## This used to render a dark fog-of-war overlay around the player's view
## sector. The visual fog has been retired in favour of an *implicit* FOV:
## scenery and zombies fade or disappear based on whether they fall inside
## the sector (see scripts/fov_culler.gd), but the screen itself is no
## longer darkened. The player reads "I can / can't see this" purely from
## per-object opacity changes.
##
## The script remains so that FovCuller has one well-known node to read
## the sector parameters from. It also still exposes head_height because
## the culler classifies entities at head level.
##
## Human-eyesight defaults: 145° horizontal FOV, ~25 world units (~100 m
## at the game's approximate 1 unit = 4 m scale).

@export var fov_degrees: float = 145.0
@export var view_distance: float = 25.0
## World-unit height of the character's eyes above the player's root.
## Kept here so the culler can classify entities at head level even
## though the visual sector polygon is no longer drawn.
@export var head_height: float = 1.6

func configure(_player: Node3D, _camera: Camera3D) -> void:
	# Kept for API compatibility — main.gd still calls configure(player, camera).
	pass
