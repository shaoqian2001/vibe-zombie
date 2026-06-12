extends CharacterBody3D

# Movement constants
const SPEED = 4.0
const SPRINT_SPEED = 6.5
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
var _ak47_node: Node3D = null
var _grenade_launcher_node: Node3D = null
var _bat_node: Node3D = null

# Recoil: world-unit/sec impulse pushed back along -forward each time we
# pull the trigger. Decays exponentially so even a strong shotgun kick
# settles in well under half a second. Pistol uses a value tiny enough
# to "barely" rock the player back.
const RECOIL_DECAY := 9.0
var _recoil_velocity: Vector3 = Vector3.ZERO

# Aim line
var _aim_line: MeshInstance3D = null
var _aim_dot: MeshInstance3D = null
var aim_line_enabled: bool = true

# Skeletal rig built in code — see _build_rig. The rig is two independent
# chains anchored at the player root:
#   • Hips: drives the legs (hip → thigh → knee → shin → foot per side)
#   • Spine: anchors the upper body. The torso itself is a procedural
#     soft mesh rebuilt each frame so it bends smoothly between the
#     hips (no twist) and the shoulders (full aim twist). Pelvis and belt
#     are rigid children of _spine; shoulders/neck/head live under
#     _torso_top, which sits at the upper end of the soft torso and
#     carries the full aim yaw — so the soft mesh's top ring and the
#     upper-body nodes share the same rotation and never separate.
var _hips: Node3D = null
var _spine: Node3D = null
var _hip_l: Node3D = null  # per-leg hip pivots (children of _hips)
var _hip_r: Node3D = null
var _knee_l: Node3D = null
var _knee_r: Node3D = null
var _neck: Node3D = null
var _head: Node3D = null
# Soft waist — a stack of small BoxMesh segments stacked between the
# rigid pelvis and the rigid chest. Each segment is a Node3D pivot
# rotated to its own angle so the stack approximates a smooth bend
# when the upper body twists. BoxMesh (not ArrayMesh / ImmediateMesh)
# is used so the segments inherit material handling from Godot's
# built-in mesh path — the same path the chest uses and is known to
# render correctly under the FOV-culler material overlay.
const WAIST_SEGMENTS := 8
var _waist_pivots: Array = []
# Upper-body anchor at the top of the waist. Holds the rigid chest,
# both shoulders and the neck/head as one rigid group; rotates by the
# full aim twist so it always matches the top ring of the waist.
var _torso_top: Node3D = null
# Shoulders + elbows. Shoulders are the animation pivots — rotating them
# swings the entire arm chain (upper arm → forearm → hand → weapon grip)
# as one. Elbows pivot the forearm independently for tight poses.
var _right_shoulder: Node3D = null
var _left_shoulder: Node3D = null
var _right_elbow: Node3D = null
var _left_elbow: Node3D = null
# Cached bone lengths so the IK solver doesn't have to read mesh meta data.
# Kept long enough for the two-handed poses to reach — the off-hand grips a
# forend that sits well forward of the trigger hand, and a short reach can't
# cross that distance — but trimmed so the arms don't dangle past the hips.
var _upper_arm_len: float = 0.30
var _forearm_len: float = 0.30
# Weapons are parented to this anchor on the right hand (dominant trigger
# hand) so they follow the full walk / kick animation without any extra
# bookkeeping.
var _weapon_grip: Node3D = null
# Rest-pose transforms captured at rig build so animation is relative to
# the constructed setup. Hips/spine rest is identity (built at known offset).
var _hip_l_rest := Transform3D.IDENTITY
var _hip_r_rest := Transform3D.IDENTITY
var _knee_l_rest := Transform3D.IDENTITY
var _knee_r_rest := Transform3D.IDENTITY
var _neck_rest := Transform3D.IDENTITY
var _right_shoulder_rest := Transform3D.IDENTITY
var _left_shoulder_rest := Transform3D.IDENTITY
var _right_elbow_rest := Transform3D.IDENTITY
var _left_elbow_rest := Transform3D.IDENTITY
# Pose mode for each arm. Drives walk-cycle amplitude and whether IK runs:
#   • "free"   — pendulum at the side, walks broadly
#   • "braced" — locked to the weapon, barely sways
#   • "ik"     — driven by 2-bone IK to grip the weapon's off-hand anchor
var _right_arm_mode: String = "free"
var _left_arm_mode: String = "free"
# IK target position (in weapon-local space) for the off-hand. Only used
# when an arm's mode is "ik" — see _solve_arm_ik.
var _off_hand_anchor_local: Vector3 = Vector3.ZERO
# Current pose's kick parameters, refreshed by _apply_weapon_pose.
var _kick_pitch_deg: float = 0.0
var _kick_elbow_deg: float = 0.0
var _kick_duration: float = 0.18
# Degrees the chest/waist lean BACK during the fire kick (recoil into the
# body). Per-weapon — a shotgun rocks the torso hard, an SMG barely nudges it.
var _chest_recoil_deg: float = 0.0
# Walk cycle phase (radians) — advances with horizontal speed so legs swing while moving.
var _walk_phase: float = 0.0
# Smoothed aim yaw delta — the angle between the player's facing and the
# look_target, low-passed so the spine/head twist eases in.
var _aim_yaw_smooth: float = 0.0
# Countdown timer driving the shooting arm kick-back animation (seconds).
var _shoot_anim_timer: float = 0.0
# Default duration when no weapon-specific kick is configured.
const SHOOT_ANIM_DURATION := 0.22

# Bare-hand brawling (only when no weapon is equipped). _punch_timer gates
# the strike rate; _punch_anim_timer drives the throw-and-recover animation;
# _punch_is_right alternates which fist leads so the player throws with both
# arms. Tuned so a held/spammed attack reads as a boxing combo.
var _punch_timer: float = 0.0
var _punch_anim_timer: float = 0.0
var _punch_is_right: bool = false
const PUNCH_DURATION := 0.26

# Footstep audio: sign of the walk-cycle sine on the previous frame. A foot
# plants each time the sine crosses zero (legs pass under the body), so a
# sign flip while moving triggers one footstep sound. 0 = "not stepping".
var _prev_step_sign: int = 0

# Skeleton geometry constants — referenced by both rig construction and
# the IK solver. Heights are in player local space (floor at y=0). Lengths
# add up so the foot's lower face lands exactly at y=0 when the leg is
# straight: foot (0.08) + shin (0.30) + thigh (0.40) = 0.78 = HIP_Y.
const HIP_Y := 0.78
const THIGH_LEN := 0.40
const SHIN_LEN := 0.30
const FOOT_HEIGHT := 0.08
# Torso geometry. The upper body is split into three vertical sections,
# all anchored at _spine (which never rotates itself):
#   • Pelvis — rigid box just below the spine origin. Width tapers from
#     0.34 at the bottom up to PELVIS_TOP_W where it meets the waist.
#   • Waist — short procedural mesh that smoothly bends from 0° at its
#     bottom (matching the pelvis) to the full aim twist at its top
#     (matching the chest). This is the only part that actually flexes.
#   • Chest — rigid box that sits above the waist, hanging off _torso_top
#     so it rotates as one rigid block with the shoulders/neck/head.
const WAIST_BOTTOM_Y := 0.02   # = top of the pelvis box, in spine-local
const WAIST_TOP_Y := 0.285     # = bottom of the chest box, in spine-local
const WAIST_BOTTOM_W := 0.34   # pelvis width (waist itself is rectangular)
const WAIST_TOP_W := 0.48      # waist + chest width (rectangular waist)
const WAIST_DEPTH := 0.28
const CHEST_HEIGHT := 0.265    # rigid chest. Sized so waist:chest ≈ 50/50
                               # of the upper-body height (0.265:0.265).
# Shoulders sit just outside the torso so the hanging upper arm clears the
# chest box (half-width WAIST_TOP_W/2 = 0.24) instead of overlapping it.
# 0.24 (body edge) + the upper-arm radius (~0.055) keeps the arm flush
# against the torso side without sinking into it.
const SHOULDER_X := 0.30
# Shoulder/neck Y in _torso_top-local — _torso_top sits at WAIST_TOP_Y in
# spine-local, so subtract that to convert old spine-local heights.
const SHOULDER_Y := 0.215
const SHOULDER_Z := 0.02
const NECK_Y := 0.265
# Maximum twist the upper body (chest + waist) can absorb relative to the
# legs before the whole body has to rotate to follow the aim. Lower values
# = the body chases the cursor sooner.
const MAX_TORSO_TWIST := deg_to_rad(30.0)

## Per-weapon arm poses + kick parameters. Angles are in degrees.
##
## Hand convention: the RIGHT arm is the dominant / weapon hand. It holds the
## weapon grip (the weapon mesh is parented to the right hand) — for guns this
## is the trigger hand at the rear of the receiver, tucked near the right
## shoulder; for the bat it is the top hand on the handle. The LEFT arm is the
## support hand, solved by IK onto the weapon's `off_hand_anchor` (the forend
## for long guns, the lower handle for the bat) so it reaches forward/under and
## tracks the weapon as the right hand moves it.
##
## Each arm carries either:
##   • a static rest pose with `shoulder_pitch / shoulder_yaw / elbow_bend`
##     (+ optional `shoulder_roll`, which tilts the arm sideways — negative on
##     the right arm pulls a held weapon inboard of the shoulder) and
##     `mode` ∈ ["free", "braced"]. Free arms pendulum; braced arms barely
##     sway.
##   • `mode: "ik"` — the arm is solved by 2-bone IK to grip the weapon at
##     its `off_hand_anchor` (defined in WeaponData). The rest angles are
##     ignored and the IK runs after the right arm has moved the weapon (so
##     the support hand always follows the trigger hand).
##
## Sign convention for `elbow_bend`:
##   • NEGATIVE = forearm folds toward the shoulder's *front* (natural bicep
##     curl). Use this for relaxed arms-at-side and any front-facing grip.
##   • POSITIVE = forearm folds toward the shoulder's *back* (the kind of
##     fold needed to bring a hand up behind the shoulder).
##
## kick_pitch / kick_elbow describe the delta applied to the trigger (right)
## arm during the fire animation. They must add in the same direction as the
## rest bend (i.e. share its sign) so recoil tightens the fold instead of
## unfolding the arm. `chest_recoil` (degrees) leans the whole upper body
## backward during the kick.
const WEAPON_POSES := {
	"unarmed": {
		# Combat-ready guard: shoulders slightly forward and the elbows bent
		# so the forearms come up and the fists sit in front of the chest —
		# a boxer's "hands up" stance rather than arms dangling at the side.
		# Bare-hand punches throw from here (see the punch animation), and a
		# small inward yaw brings the fists toward the centreline.
		"left":  { "shoulder_pitch": -16.0, "shoulder_yaw":  10.0, "elbow_bend": -58.0, "mode": "free" },
		"right": { "shoulder_pitch": -16.0, "shoulder_yaw": -10.0, "elbow_bend": -58.0, "mode": "free" },
		"kick_pitch": 0.0, "kick_elbow": 0.0, "kick_duration": 0.0, "chest_recoil": 0.0,
	},
	"pistol": {
		# One-handed pistol carry — dominant RIGHT hand extends forward at
		# chest level. Off-hand (left) hangs and pendulums while walking.
		# Negative elbow_bend tucks the elbow DOWN (forearm comes up off the
		# extended upper arm); positive bend chicken-wings the elbow.
		"right": { "shoulder_pitch": -75.0, "shoulder_yaw": -3.0, "shoulder_roll": -16.0, "elbow_bend": -10.0, "mode": "braced" },
		"left":  { "shoulder_pitch": -8.0,  "shoulder_yaw":  0.0, "elbow_bend": -14.0, "mode": "free" },
		"kick_pitch": 14.0, "kick_elbow": -6.0, "kick_duration": 0.18, "chest_recoil": 3.0,
	},
	"smg": {
		# Compact SMG tucked against the chest — the RIGHT (trigger) hand grips
		# the receiver in front of the chest, slightly inboard of the right
		# shoulder (negative shoulder_roll pulls it toward the centreline so the
		# weapon sits in the hands rather than jammed up on the shoulder). The
		# LEFT support hand IKs forward onto the rail just ahead of the grip.
		# Shared stance for all the two-handed guns; only the kick/recoil differs.
		"right": { "shoulder_pitch": -12.0, "shoulder_yaw": -10.0, "shoulder_roll": -22.0, "elbow_bend": -95.0, "mode": "braced" },
		"left":  { "mode": "ik" },
		"kick_pitch": 8.0, "kick_elbow": -3.0, "kick_duration": 0.10, "chest_recoil": 2.5,
	},
	"ak47": {
		# Long rifle held at the chest (see "smg" for the stance), the support
		# hand reaching forward onto the forend. Stiffer kick than the SMG, but
		# without the shotgun's big shoulder rock.
		"right": { "shoulder_pitch": -13.0, "shoulder_yaw": -11.0, "shoulder_roll": -22.0, "elbow_bend": -98.0, "mode": "braced" },
		"left":  { "mode": "ik" },
		"kick_pitch": 11.0, "kick_elbow": -4.0, "kick_duration": 0.12, "chest_recoil": 4.0,
	},
	"shotgun": {
		# Long shotgun held at the chest (see "smg" for the stance), with a
		# heavy kick and chest rock.
		"right": { "shoulder_pitch": -15.0, "shoulder_yaw": -12.0, "shoulder_roll": -22.0, "elbow_bend": -98.0, "mode": "braced" },
		"left":  { "mode": "ik" },
		"kick_pitch": 22.0, "kick_elbow": -9.0, "kick_duration": 0.28, "chest_recoil": 8.0,
	},
	"grenade_launcher": {
		# Heavy launcher held at the chest (see "smg" for the stance), with
		# the heaviest kick and chest rock.
		"right": { "shoulder_pitch": -18.0, "shoulder_yaw": -14.0, "shoulder_roll": -22.0, "elbow_bend": -95.0, "mode": "braced" },
		"left":  { "mode": "ik" },
		"kick_pitch": 26.0, "kick_elbow": -10.0, "kick_duration": 0.32, "chest_recoil": 9.0,
	},
	"bat": {
		# TWO-HANDED baseball stance, held VERTICAL at rest. The RIGHT arm —
		# the main hand — grips the upper handle (the weapon mesh is parented
		# to the right hand). The LEFT arm is solved by IK onto a point LOWER
		# on the handle (off_hand_anchor in WeaponData), so the right hand
		# stacks ON TOP of the left for a right-handed swing. The default
		# "player_forward" grip cancels the arm rotation, so the bat (built
		# along +Y) points straight up regardless of these arm angles — the
		# right-arm pose just positions the hands in front of the chest.
		# POSITIVE kick_pitch rotates that up-pointing bat forward and down
		# through a swing; the IK'd left hand re-solves onto the moving bat
		# each frame so both hands stay on it through the arc.
		"right": { "shoulder_pitch": -55.0, "shoulder_yaw": -30.0, "shoulder_roll": -12.0, "elbow_bend": -75.0, "mode": "braced" },
		"left":  { "mode": "ik" },
		"kick_pitch": 120.0, "kick_elbow": 30.0, "kick_duration": 0.42, "chest_recoil": 0.0,
	},
}

# Network state — true if this peer owns this player (or in single-player).
var _owns_input: bool = true

# Network sync (for non-authority peers we just receive position updates)
const NET_SYNC_HZ := 20.0
const NET_SYNC_INTERVAL := 1.0 / NET_SYNC_HZ
var _net_sync_timer := 0.0

# Derived on receivers to drive animation (authority's `velocity` isn't synced).
var _remote_last_pos: Vector3 = Vector3.ZERO
var _remote_last_sync_time: float = 0.0

func _ready() -> void:
	# In MP, the player node has multiplayer_authority set by the spawner code
	# in main.gd to the owning peer's id. In single-player the default
	# (server-only) authority applies and _owns_input stays true.
	if NetworkManager.is_networked:
		_owns_input = is_multiplayer_authority()
	_cache_body_parts()
	# Single-player has no main.gd handoff that would call refresh_authority(),
	# so camera lookup and weapon/aim-line building wouldn't otherwise run —
	# which previously left _camera null and froze movement input.
	if not NetworkManager.is_networked:
		refresh_authority()

## Sweep away any legacy body parts that an older Player.tscn might still
## ship (the current scene is bare CharacterBody3D + collision, but cleaning
## up here keeps the rig consistent if the .tscn ever regresses) and build
## the full procedural skeleton from code.
func _cache_body_parts() -> void:
	for legacy in ["Torso", "LegLeft", "LegRight", "ArmLeft", "ArmRight",
				   "Head", "Hair", "EyeLeft", "EyeRight", "Belt",
				   "Hips", "Spine", "Chest", "Abdomen"]:
		var n := get_node_or_null(legacy)
		if n != null:
			n.queue_free()
	_build_rig()

func _build_rig() -> void:
	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = Color(0.82, 0.68, 0.55, 1)
	skin_mat.roughness = 0.85
	var sleeve_mat := StandardMaterial3D.new()
	sleeve_mat.albedo_color = Color(0.22, 0.35, 0.18, 1)
	sleeve_mat.roughness = 0.85
	var pants_mat := StandardMaterial3D.new()
	pants_mat.albedo_color = Color(0.20, 0.22, 0.28, 1)
	pants_mat.roughness = 0.9
	var boot_mat := StandardMaterial3D.new()
	boot_mat.albedo_color = Color(0.14, 0.10, 0.07, 1)
	boot_mat.roughness = 0.6
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.89, 0.73, 0.58, 1)
	head_mat.roughness = 0.8
	var hair_mat := StandardMaterial3D.new()
	hair_mat.albedo_color = Color(0.18, 0.14, 0.10, 1)
	hair_mat.roughness = 0.95
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.08, 0.08, 0.10, 1)

	# --- Hips: parent of both legs only. The visible pelvis/belt have moved
	# onto _spine so the whole torso silhouette rotates as one block;
	# _hips just carries the per-leg hip pivots and the walk-cycle hip
	# swivel.
	_hips = Node3D.new()
	_hips.name = "Hips"
	_hips.position = Vector3(0, HIP_Y, 0)
	add_child(_hips)

	_hip_l = _build_leg(true, pants_mat, boot_mat)
	_hip_r = _build_leg(false, pants_mat, boot_mat)
	_hip_l_rest = _hip_l.transform
	_hip_r_rest = _hip_r.transform

	# --- Spine: unified torso pivot. Pelvis, belt, the main torso box,
	# both shoulders and the neck/head all hang off this node, so when the
	# spine twists toward the aim direction the entire upper body rotates
	# together as a single rigid block — no seams between chest, waist
	# and lower body.
	_spine = Node3D.new()
	_spine.name = "Spine"
	_spine.position = Vector3(0, HIP_Y, 0)
	add_child(_spine)

	# Pelvis — rigid lower-torso box. Top edge sits at WAIST_BOTTOM_Y so
	# the waist mesh can dock flush onto it.
	var pelvis_height: float = 0.16
	var pelvis_mesh := BoxMesh.new()
	pelvis_mesh.size = Vector3(WAIST_BOTTOM_W, pelvis_height, WAIST_DEPTH)
	pelvis_mesh.material = pants_mat
	var pelvis := MeshInstance3D.new()
	pelvis.name = "Pelvis"
	pelvis.position = Vector3(0, WAIST_BOTTOM_Y - pelvis_height * 0.5, 0)
	pelvis.mesh = pelvis_mesh
	pelvis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_spine.add_child(pelvis)

	# Soft waist — WAIST_SEGMENTS thin BoxMesh slices between the rigid
	# pelvis and the rigid chest, each on its own Node3D pivot. Per
	# frame _update_waist_segments rotates each pivot to a smoothstep
	# fraction of the total twist/pitch, so the stack reads as a smooth
	# bend with the heaviest bend concentrated mid-waist. Pivots are
	# direct children of _spine (siblings, not chained), but since
	# Y-rotation is invariant under Y-translation, the slices still
	# rotate around a shared vertical axis. The slices share one mesh
	# resource and material — identical setup to the chest box, which
	# guarantees the same rendering path (no transparent ArrayMesh
	# surprises under the FOV shadow overlay).
	var waist_mat := StandardMaterial3D.new()
	waist_mat.albedo_color = Color(0.22, 0.35, 0.18, 1)
	waist_mat.roughness = 0.85

	var waist_seg_h: float = (WAIST_TOP_Y - WAIST_BOTTOM_Y) / float(WAIST_SEGMENTS)
	var waist_box_mesh := BoxMesh.new()
	# Box is slightly taller than the slice spacing so neighbours
	# overlap a touch and the small angular mismatch between adjacent
	# pivots reads as a continuous surface instead of stepped slabs.
	waist_box_mesh.size = Vector3(WAIST_TOP_W, waist_seg_h * 1.15, WAIST_DEPTH)
	waist_box_mesh.material = waist_mat
	for i in WAIST_SEGMENTS:
		var pivot := Node3D.new()
		pivot.name = "WaistSeg%d" % i
		pivot.position = Vector3(0, WAIST_BOTTOM_Y + (float(i) + 0.5) * waist_seg_h, 0)
		_spine.add_child(pivot)
		var seg_mi := MeshInstance3D.new()
		seg_mi.mesh = waist_box_mesh
		seg_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		pivot.add_child(seg_mi)
		_waist_pivots.append(pivot)
	# Seed the rest pose so the slices start aligned with the pelvis /
	# chest before _update_animation runs.
	_update_waist_segments(0.0, 0.0, 0.0)

	# Upper-body anchor at the top of the waist. Takes the full aim
	# twist + pitch; the rigid chest, shoulders, neck and head all hang
	# off it as one block, so the chest does NOT bend with the waist —
	# it just rotates rigidly.
	_torso_top = Node3D.new()
	_torso_top.name = "TorsoTop"
	_torso_top.position = Vector3(0, WAIST_TOP_Y, 0)
	_spine.add_child(_torso_top)

	# Chest — rigid box. Sits on top of the waist and rotates with
	# _torso_top, never flexing internally.
	var chest_mat := StandardMaterial3D.new()
	chest_mat.albedo_color = Color(0.22, 0.35, 0.18, 1)
	chest_mat.roughness = 0.85
	var chest_mesh := BoxMesh.new()
	chest_mesh.size = Vector3(WAIST_TOP_W, CHEST_HEIGHT, WAIST_DEPTH)
	chest_mesh.material = chest_mat
	var chest := MeshInstance3D.new()
	chest.name = "Chest"
	chest.mesh = chest_mesh
	chest.position = Vector3(0, CHEST_HEIGHT * 0.5, 0)
	chest.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_torso_top.add_child(chest)

	# Shoulders hang off _torso_top so they share the chest's rotation.
	_right_shoulder = _build_arm_chain(
		"RightShoulder", Vector3(SHOULDER_X, SHOULDER_Y, SHOULDER_Z),
		sleeve_mat, skin_mat, true, _torso_top,
	)
	_left_shoulder = _build_arm_chain(
		"LeftShoulder", Vector3(-SHOULDER_X, SHOULDER_Y, SHOULDER_Z),
		sleeve_mat, skin_mat, false, _torso_top,
	)

	# Neck + head + hair + eyes also off _torso_top.
	_neck = Node3D.new()
	_neck.name = "Neck"
	_neck.position = Vector3(0, NECK_Y, 0)
	_torso_top.add_child(_neck)
	_neck_rest = _neck.transform

	_head = Node3D.new()
	_head.name = "HeadPivot"
	_head.position = Vector3(0, 0.06, 0)
	_neck.add_child(_head)

	var head_geo := MeshInstance3D.new()
	head_geo.name = "Head"
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.18
	head_mesh.height = 0.36
	head_mesh.material = head_mat
	head_geo.mesh = head_mesh
	head_geo.position = Vector3(0, 0.18, 0)
	head_geo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_head.add_child(head_geo)

	var hair_geo := MeshInstance3D.new()
	hair_geo.name = "Hair"
	var hair_mesh := SphereMesh.new()
	hair_mesh.radius = 0.19
	hair_mesh.height = 0.20
	hair_mesh.material = hair_mat
	hair_geo.mesh = hair_mesh
	hair_geo.position = Vector3(0, 0.30, -0.02)
	hair_geo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_head.add_child(hair_geo)

	for side in [-1.0, 1.0]:
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.035
		eye_mesh.height = 0.07
		eye_mesh.material = eye_mat
		var eye := MeshInstance3D.new()
		eye.mesh = eye_mesh
		eye.position = Vector3(side * 0.07, 0.20, 0.16)
		_head.add_child(eye)

	# Start in the unarmed pose — both arms hang naturally.
	_apply_weapon_pose("unarmed")

## Pose every waist slice for this frame. Each pivot is rotated to a
## smoothstep fraction of the total twist/pitch, so the stack starts at
## 0° at the pelvis seam and ends at the full angle just under the
## chest, with the steepest change concentrated mid-waist. Pivots are
## also lifted by a smoothstep fraction of the walk-cycle bob so the
## top of the waist tracks _torso_top.
func _update_waist_segments(twist_radians: float, pitch_radians: float, bob_y: float) -> void:
	var n := _waist_pivots.size()
	if n == 0:
		return
	var seg_h: float = (WAIST_TOP_Y - WAIST_BOTTOM_Y) / float(n)
	for i in n:
		var pivot: Node3D = _waist_pivots[i]
		if pivot == null:
			continue
		# Use the centre of each slice for its blend value — gives the
		# top slice ~0.98 of the full angle, the bottom slice ~0.02.
		var t: float = (float(i) + 0.5) / float(n)
		var blend: float = smoothstep(0.0, 1.0, t)
		var slice_y: float = WAIST_BOTTOM_Y + (float(i) + 0.5) * seg_h + blend * bob_y
		var basis_yaw := Basis(Vector3.UP, blend * twist_radians)
		# Positive pitch around RIGHT = forward lean (the rig faces +Z),
		# matching _torso_top's convention.
		var basis_pitch := Basis(Vector3.RIGHT, blend * pitch_radians)
		pivot.transform = Transform3D(basis_yaw * basis_pitch, Vector3(0, slice_y, 0))

## Build one leg chain — hip pivot → thigh → knee pivot → shin → foot.
## Returns the hip pivot so the caller can stash it for animation.
func _build_leg(is_left: bool, pants_mat: StandardMaterial3D, boot_mat: StandardMaterial3D) -> Node3D:
	var side := -1.0 if is_left else 1.0

	var hip := Node3D.new()
	hip.name = "HipLeft" if is_left else "HipRight"
	hip.position = Vector3(side * 0.13, 0.0, 0.0)
	_hips.add_child(hip)

	var thigh_mesh := BoxMesh.new()
	thigh_mesh.size = Vector3(0.17, THIGH_LEN, 0.20)
	thigh_mesh.material = pants_mat
	var thigh := MeshInstance3D.new()
	thigh.name = "Thigh"
	thigh.mesh = thigh_mesh
	thigh.position = Vector3(0, -THIGH_LEN * 0.5, 0)
	thigh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	hip.add_child(thigh)

	var knee := Node3D.new()
	knee.name = "Knee"
	knee.position = Vector3(0, -THIGH_LEN, 0)
	hip.add_child(knee)
	# Capture the knee's rest transform *here* — the walk-cycle animation
	# composes onto _knee_l_rest each frame, so leaving it at IDENTITY
	# (Vector3.ZERO origin) would snap the knee up to the hip's position
	# and collapse the entire shin/foot into the upper thigh, leaving
	# the feet floating ~40 cm above the floor.
	if is_left:
		_knee_l = knee
		_knee_l_rest = knee.transform
	else:
		_knee_r = knee
		_knee_r_rest = knee.transform

	var shin_mesh := BoxMesh.new()
	shin_mesh.size = Vector3(0.15, SHIN_LEN, 0.18)
	shin_mesh.material = pants_mat
	var shin := MeshInstance3D.new()
	shin.name = "Shin"
	shin.mesh = shin_mesh
	shin.position = Vector3(0, -SHIN_LEN * 0.5, 0)
	shin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	knee.add_child(shin)

	var foot_mesh := BoxMesh.new()
	foot_mesh.size = Vector3(0.16, FOOT_HEIGHT, 0.26)
	foot_mesh.material = boot_mat
	var foot := MeshInstance3D.new()
	foot.name = "Foot"
	foot.mesh = foot_mesh
	# Foot top meets the shin's bottom; foot bottom rests at y=0 (floor).
	# In shin-local coords the shin mesh center is at the origin (extends
	# ±SHIN_LEN/2), so the foot center sits a half-foot below the shin
	# mesh and shifted forward so the toes lead the heel.
	foot.position = Vector3(0, -SHIN_LEN * 0.5 - FOOT_HEIGHT * 0.5, 0.06)
	foot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	shin.add_child(foot)

	return hip

## Returns the shoulder Node3D. The shoulder is the animation pivot; its
## child chain encodes the bone lengths and pre-pose. The weapon grip (for
## the right side) or hand anchor (left) is tagged in meta so callers can
## fetch it without hard-coding paths.
func _build_arm_chain(
	chain_name: String, shoulder_pos: Vector3,
	sleeve_mat: StandardMaterial3D, skin_mat: StandardMaterial3D,
	is_right: bool, parent: Node3D,
) -> Node3D:
	var shoulder := Node3D.new()
	shoulder.name = chain_name
	shoulder.position = shoulder_pos
	# Rotation is set by _apply_weapon_pose so the rest pose matches the
	# weapon being held (or the unarmed default). Just leave it identity here.
	parent.add_child(shoulder)

	var upper_mesh := CylinderMesh.new()
	upper_mesh.top_radius = 0.055
	upper_mesh.bottom_radius = 0.05
	upper_mesh.height = _upper_arm_len
	upper_mesh.material = sleeve_mat
	var upper := MeshInstance3D.new()
	upper.name = "UpperArm"
	upper.mesh = upper_mesh
	upper.position = Vector3(0, -_upper_arm_len * 0.5, 0)
	shoulder.add_child(upper)

	# Elbow: bend angle is set per pose by _apply_weapon_pose, or driven by
	# the IK solver for the support hand on two-handed weapons.
	var elbow := Node3D.new()
	elbow.name = "Elbow"
	elbow.position = Vector3(0, -_upper_arm_len, 0)
	shoulder.add_child(elbow)
	if is_right:
		_right_elbow = elbow
	else:
		_left_elbow = elbow

	var fore_mesh := CylinderMesh.new()
	fore_mesh.top_radius = 0.05
	fore_mesh.bottom_radius = 0.045
	fore_mesh.height = _forearm_len
	fore_mesh.material = skin_mat
	var fore := MeshInstance3D.new()
	fore.name = "Forearm"
	fore.mesh = fore_mesh
	fore.position = Vector3(0, -_forearm_len * 0.5, 0)
	elbow.add_child(fore)

	var wrist := Node3D.new()
	wrist.name = "Wrist"
	wrist.position = Vector3(0, -_forearm_len, 0)
	elbow.add_child(wrist)

	var hand_mesh := BoxMesh.new()
	hand_mesh.size = Vector3(0.09, 0.12, 0.07)
	hand_mesh.material = skin_mat
	var hand := MeshInstance3D.new()
	hand.name = "Hand"
	hand.mesh = hand_mesh
	# Drop the hand slightly along the forearm axis so its top meets the wrist.
	hand.position = Vector3(0, -0.05, 0)
	wrist.add_child(hand)

	if is_right:
		# WeaponGrip lives on the RIGHT hand — the dominant / trigger hand.
		# Weapons are designed with +Z as the muzzle direction, so the
		# grip's basis must invert the cumulative shoulder + elbow rotation
		# (for guns) to keep the muzzle aimed along the player's +Z axis.
		# _apply_weapon_pose recomputes this whenever the equipped weapon
		# (and therefore the rest pose) changes.
		var grip := Node3D.new()
		grip.name = "WeaponGrip"
		grip.position = Vector3(0, -0.02, 0.02)
		wrist.add_child(grip)
		_weapon_grip = grip

	return shoulder

## Set both arms to a weapon-specific rest pose and refresh the WeaponGrip
## so the muzzle keeps pointing along the player's +Z. Called from
## _build_rig (initial unarmed pose) and from _equip_weapon. Falls back to
## the unarmed pose if the weapon name has no entry. For arms in "ik" mode
## the IK solver overwrites the rest each frame in _update_animation.
func _apply_weapon_pose(weapon_name: String) -> void:
	if _right_shoulder == null or _left_shoulder == null:
		return
	var pose: Dictionary = WEAPON_POSES.get(weapon_name, WEAPON_POSES["unarmed"])
	var right: Dictionary = pose["right"]
	var left: Dictionary = pose["left"]

	_right_arm_mode = right.get("mode", "free")
	_left_arm_mode = left.get("mode", "free")

	_pose_arm(_right_shoulder, _right_elbow, right)
	_pose_arm(_left_shoulder, _left_elbow, left)

	_right_shoulder_rest = _right_shoulder.transform
	_left_shoulder_rest = _left_shoulder.transform
	if _right_elbow:
		_right_elbow_rest = _right_elbow.transform
	if _left_elbow:
		_left_elbow_rest = _left_elbow.transform

	# Cache the off-hand IK anchor (in weapon-local space) from WeaponData
	# so the animation step doesn't have to look it up every frame.
	var weapon_stats: Dictionary = WeaponData.get_weapon(weapon_name)
	_off_hand_anchor_local = weapon_stats.get("off_hand_anchor", Vector3.ZERO)

	# Re-align the grip so the weapon sits naturally for the chosen pose:
	#   • "player_forward" (default, used by guns): basis = inverse of the
	#     accumulated shoulder + elbow rotation, so the muzzle aims along
	#     the player's +Z regardless of how the arm is posed.
	#   • "along_arm" (used by melee like the bat): basis = +90° rotation
	#     around X, mapping the weapon's +Z axis to the wrist's -Y, so the
	#     bat extends out of the wrist along the arm's direction. Cocking
	#     the arm back over the shoulder then naturally cocks the bat too.
	# Grip lives on the right arm, so we invert the right chain.
	if _weapon_grip and _right_elbow:
		var grip_align: String = pose.get("grip_align", "player_forward")
		if grip_align == "along_arm":
			_weapon_grip.basis = Basis(Vector3.RIGHT, PI * 0.5)
		else:
			var combined: Basis = _right_shoulder.basis * _right_elbow.basis
			_weapon_grip.basis = combined.inverse()

	_kick_pitch_deg = pose.get("kick_pitch", 0.0)
	_kick_elbow_deg = pose.get("kick_elbow", 0.0)
	_kick_duration = pose.get("kick_duration", SHOOT_ANIM_DURATION)
	_chest_recoil_deg = pose.get("chest_recoil", 0.0)

func _pose_arm(shoulder: Node3D, elbow: Node3D, pose: Dictionary) -> void:
	# IK-driven arms are placed each frame in _update_animation; here we
	# just clear the rotation so the IK pass starts from a clean slate and
	# doesn't carry over angles from the previous weapon.
	if pose.get("mode", "free") == "ik":
		if shoulder: shoulder.transform = Transform3D(Basis.IDENTITY, shoulder.position)
		if elbow: elbow.transform = Transform3D(Basis.IDENTITY, elbow.position)
		return
	if shoulder:
		# shoulder_roll (rotation around the shoulder's forward axis) tilts the
		# whole arm sideways in the frontal plane. A NEGATIVE roll on the right
		# (weapon) arm swings the elbow + hand INWARD toward the body
		# centreline, so a held weapon rests slightly inside the right shoulder
		# rather than straight out from it — which shortens the left support
		# arm's reach to the off-hand anchor.
		shoulder.rotation = Vector3(
			deg_to_rad(pose.get("shoulder_pitch", 0.0)),
			deg_to_rad(pose.get("shoulder_yaw", 0.0)),
			deg_to_rad(pose.get("shoulder_roll", 0.0)),
		)
	if elbow:
		elbow.rotation = Vector3(deg_to_rad(pose.get("elbow_bend", 0.0)), 0.0, 0.0)

## Called by main.gd after it sets set_multiplayer_authority() on this player,
## to make sure `_owns_input` matches the authoritative state (in case Player._ready
## ran with the default authority before main had a chance to override it).
func refresh_authority() -> void:
	if NetworkManager.is_networked:
		_owns_input = is_multiplayer_authority()

	await get_tree().process_frame
	_camera = get_viewport().get_camera_3d()
	_build_pistol()
	_build_shotgun()
	_build_smg()
	_build_ak47()
	_build_grenade_launcher()
	_build_bat()
	_pistol_node.visible = false
	_shotgun_node.visible = false
	_smg_node.visible = false
	_ak47_node.visible = false
	_grenade_launcher_node.visible = false
	_bat_node.visible = false
	# Only the local (input-owning) player needs an aim line.
	if _owns_input:
		_build_aim_line()

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	# Remote players: just consume synced transform — animate limbs from the
	# synced horizontal velocity so they're not frozen mid-stride.
	if not _owns_input:
		_update_animation(delta)
		return

	_apply_gravity(delta)
	var move_dir := _get_world_movement_direction()
	_update_sprint(move_dir, delta)
	var current_speed := SPRINT_SPEED if _is_sprinting else SPEED
	_apply_movement(move_dir, current_speed, delta)
	# Layer recoil on top of input-driven movement and let it decay so
	# the kick is a brief shove, not a sustained push.
	velocity.x += _recoil_velocity.x
	velocity.z += _recoil_velocity.z
	var decay := exp(-RECOIL_DECAY * delta)
	_recoil_velocity.x *= decay
	_recoil_velocity.z *= decay
	_rotate_to_face_mouse(delta)
	move_and_slide()
	_update_gun(delta)
	_handle_auto_fire()
	_update_aim_line()
	_update_animation(delta)
	_sync_hud()

	# Push transform to remote peers (client-authoritative on own player).
	if NetworkManager.is_networked:
		_net_sync_timer -= delta
		if _net_sync_timer <= 0.0:
			_net_sync_timer = NET_SYNC_INTERVAL
			rpc("_sync_player_transform", global_position, rotation.y, _is_sprinting)

@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_player_transform(pos: Vector3, yaw: float, sprinting: bool) -> void:
	# Smooth on the receiving side. Big distance = teleport.
	if global_position.distance_to(pos) > 5.0:
		global_position = pos
	else:
		global_position = global_position.lerp(pos, 0.5)
	rotation.y = yaw
	_is_sprinting = sprinting
	# Estimate horizontal velocity from the position stream so the animation
	# rig on remote copies can drive the walk cycle at the right cadence.
	var now := Time.get_ticks_msec() / 1000.0
	if _remote_last_sync_time > 0.0:
		var dt: float = max(now - _remote_last_sync_time, 0.001)
		velocity.x = (pos.x - _remote_last_pos.x) / dt
		velocity.z = (pos.z - _remote_last_pos.z) / dt
	_remote_last_pos = pos
	_remote_last_sync_time = now

# ------------------------------------------------------------------
# Audio. The local (input-owning) player hears their own actions as crisp
# non-positional 2D sounds; in multiplayer those same events are broadcast so
# every other peer plays them as positional 3D voices on this player's remote
# copy. Footsteps are handled separately (driven by the walk animation, which
# already runs on every peer's copy — see _handle_footsteps).
# ------------------------------------------------------------------

func _emit_player_sound(sound: String, pitch: float = 1.0, volume_db: float = 0.0) -> void:
	SoundManager.play_2d(sound, pitch, volume_db)
	if NetworkManager.is_networked:
		rpc("_remote_player_sound", sound, pitch, volume_db)

@rpc("authority", "call_remote", "unreliable")
func _remote_player_sound(sound: String, pitch: float, volume_db: float) -> void:
	SoundManager.play_on(self, sound, pitch, volume_db)

## Map the equipped weapon to its gunshot timbre.
func _gun_sound_name() -> String:
	match _current_weapon:
		"smg": return "gun_smg"
		"ak47": return "gun_ak47"
		"shotgun": return "gun_shotgun"
		"grenade_launcher": return "gun_grenade"
		_: return "gun_pistol"

## Called from the walk animation each frame. Fires one footstep on each zero
## crossing of the gait sine while the player is moving, so step cadence tracks
## the animation (and therefore walk vs. sprint) automatically.
func _handle_footsteps(horiz_speed: float, swing_sin: float) -> void:
	if is_dead or horiz_speed < 0.6:
		_prev_step_sign = 0
		return
	var sign_now: int = 1 if swing_sin >= 0.0 else -1
	if _prev_step_sign != 0 and sign_now != _prev_step_sign:
		var sprint := _is_sprinting
		var pitch := randf_range(0.9, 1.08) * (1.12 if sprint else 1.0)
		var vol := -13.0 if sprint else -19.0
		# Owner hears 2D; remote copies of other players play positional 3D.
		if _owns_input:
			SoundManager.play_2d("footstep", pitch, vol)
		else:
			SoundManager.play_on(self, "footstep", pitch, vol + 8.0)
	_prev_step_sign = sign_now

func _apply_recoil() -> void:
	# Backward kick on the player's body for every trigger pull. Decays
	# exponentially in _physics_process so single shots barely rock and
	# rapid fire (SMG) accumulates into a noticeable shove.
	var strength: float = _weapon_stats.get("recoil", 0.0)
	if strength <= 0.0:
		return
	_recoil_velocity -= _get_forward() * strength

## Full-auto fire. The initial shot is fired on the press event in _input;
## while the trigger stays held, this poll keeps firing automatic weapons each
## physics frame. _try_shoot's own _shoot_timer gate enforces the weapon's
## fire_rate (so this respects cadence and won't double-fire on the press
## frame), and semi-automatic weapons simply lack the "automatic" flag and so
## still require one click per shot.
func _handle_auto_fire() -> void:
	if not _armed or is_dead:
		return
	if not _weapon_stats.get("automatic", false):
		return
	if Input.is_action_pressed("shoot"):
		_try_shoot()

func take_damage(amount: float) -> void:
	# In MP, damage is applied on the player's owning peer so health/HUD stay
	# authoritative for that player. Forward if we're not the authority.
	if NetworkManager.is_networked and not is_multiplayer_authority():
		rpc_id(get_multiplayer_authority(), "_take_damage_rpc", amount)
		return
	_apply_damage(amount)

@rpc("any_peer", "call_remote", "reliable")
func _take_damage_rpc(amount: float) -> void:
	if not is_multiplayer_authority():
		return
	_apply_damage(amount)

func _apply_damage(amount: float) -> void:
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
	# Only the owning peer (or single-player) consumes input.
	if not _owns_input:
		return
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
		if _armed:
			_try_shoot()
		else:
			_try_punch()
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
	_ak47_node.visible = (_current_weapon == "ak47")
	_grenade_launcher_node.visible = (_current_weapon == "grenade_launcher")
	_bat_node.visible = (_current_weapon == "bat")

	# Re-pose the arms so the body actually mimics holding this weapon —
	# pistol shooters extend the firing hand and let the off-hand hang,
	# rifle/shotgun shooters bring the support hand across, the bat sits
	# cocked back over the shoulder, and so on.
	_apply_weapon_pose(_current_weapon)

## Forward direction used for shooting, recoil, and melee. Tracks the
## mouse aim — the player aims with the upper body / cursor, so bullets
## must travel toward where the camera shows them sighting at, not toward
## the lower body which follows movement. Falls back to body forward if
## look_target hasn't been set yet (e.g. first frame, networked clones).
func _get_forward() -> Vector3:
	if look_target != Vector3.INF:
		var aim := look_target - global_position
		aim.y = 0.0
		if aim.length_squared() > 0.01:
			return aim.normalized()
	var fwd := global_transform.basis.z
	fwd.y = 0.0
	return fwd.normalized()

## Aim direction shared by the laser sight AND the bullet raycasts so the
## red line, the visible gun barrel, and where rounds actually travel are
## all the same vector. Reads the equipped weapon's world +Z (its muzzle
## axis), so the aim tracks the gun exactly — including the brief lag while
## the torso twists to follow the cursor — instead of snapping to the mouse
## ahead of the gun (which made the line look like it was leading the
## weapon). Flattened to the horizontal plane since zombies stand on the
## ground; falls back to the cursor/body forward when there's no weapon mesh
## (unarmed, or before the rig finishes building). Only meaningful for
## ranged weapons whose +Z is the muzzle — melee uses _get_forward() for its
## sweep instead.
func _get_aim_direction() -> Vector3:
	var weapon_node := _current_weapon_node()
	if weapon_node != null and is_instance_valid(weapon_node):
		var dir := weapon_node.global_transform.basis.z
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			return dir.normalized()
	return _get_forward()

# ------------------------------------------------------------------
# Weapon attachment — anchors every weapon mesh to the right hand so it
# rides the arm rig during walk/kick/recoil animation. Falls back to the
# player root if the rig hasn't been built yet (edge case on early bring-up).
# ------------------------------------------------------------------

func _attach_weapon(weapon: Node3D) -> void:
	var parent: Node = _weapon_grip if _weapon_grip != null else self
	parent.add_child(weapon)

# ------------------------------------------------------------------
# Pistol model
# ------------------------------------------------------------------

func _build_pistol() -> void:
	_pistol_node = Node3D.new()
	_pistol_node.name = "Pistol"
	# Parent to the hand so the pistol follows walk/kick animation. Origin is
	# positioned so the pistol's grip mesh lines up with the hand. Scale up
	# the whole weapon so it reads at the isometric camera distance — every
	# child mesh, the muzzle anchor and the off-hand anchor scale together.
	_pistol_node.position = Vector3(0.0, 0.04, 0.0)
	_pistol_node.scale = Vector3.ONE * 1.35
	_attach_weapon(_pistol_node)

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
	_shotgun_node.position = Vector3(0.0, 0.0, 0.02)
	_shotgun_node.scale = Vector3.ONE * 1.4
	_attach_weapon(_shotgun_node)

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
	_smg_node.position = Vector3(0.0, 0.07, 0.02)
	_smg_node.scale = Vector3.ONE * 1.4
	_attach_weapon(_smg_node)

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
# AK-47 model — longer than the SMG, with a wooden stock/forend, a
# distinctive curved (banana) magazine and a long barrel.
# ------------------------------------------------------------------

func _build_ak47() -> void:
	_ak47_node = Node3D.new()
	_ak47_node.name = "AK47"
	_ak47_node.position = Vector3(0.0, 0.07, 0.02)
	_ak47_node.scale = Vector3.ONE * 1.35
	_attach_weapon(_ak47_node)

	# Steel receiver
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.18, 0.18, 0.20, 1)
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.07, 0.11, 0.34)
	body_mesh.material = body_mat
	var body_mi := MeshInstance3D.new()
	body_mi.mesh = body_mesh
	body_mi.position = Vector3(0.0, 0.02, 0.04)
	_ak47_node.add_child(body_mi)

	# Wooden forend (front handguard). Sits just AHEAD of the steel receiver
	# (which spans z -0.13..0.21) so the two read as separate parts rather
	# than overlapping — the handguard wraps the barrel forward of the body.
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.42, 0.27, 0.13, 1)
	var forend_mesh := BoxMesh.new()
	forend_mesh.size = Vector3(0.072, 0.08, 0.14)
	forend_mesh.material = wood_mat
	var forend := MeshInstance3D.new()
	forend.mesh = forend_mesh
	forend.position = Vector3(0.0, 0.02, 0.28)
	_ak47_node.add_child(forend)

	# Wooden stock (rear)
	var stock_mesh := BoxMesh.new()
	stock_mesh.size = Vector3(0.06, 0.10, 0.18)
	stock_mesh.material = wood_mat
	var stock := MeshInstance3D.new()
	stock.mesh = stock_mesh
	stock.position = Vector3(0.0, 0.0, -0.20)
	_ak47_node.add_child(stock)

	# Pistol grip
	var grip_mat := StandardMaterial3D.new()
	grip_mat.albedo_color = Color(0.12, 0.12, 0.12, 1)
	var grip_mesh := BoxMesh.new()
	grip_mesh.size = Vector3(0.06, 0.14, 0.07)
	grip_mesh.material = grip_mat
	var grip := MeshInstance3D.new()
	grip.mesh = grip_mesh
	grip.position = Vector3(0.0, -0.08, -0.06)
	_ak47_node.add_child(grip)

	# Curved "banana" magazine — three tilted segments stepping forward and
	# down so the silhouette reads as the AK's signature curve.
	var mag_mat := StandardMaterial3D.new()
	mag_mat.albedo_color = Color(0.20, 0.16, 0.10, 1)
	for i in range(3):
		var seg_mesh := BoxMesh.new()
		seg_mesh.size = Vector3(0.05, 0.09, 0.06)
		seg_mesh.material = mag_mat
		var seg := MeshInstance3D.new()
		seg.mesh = seg_mesh
		seg.position = Vector3(0.0, -0.10 - i * 0.06, 0.06 + i * 0.03)
		seg.rotation_degrees = Vector3(-18.0 * (i + 1), 0, 0)
		_ak47_node.add_child(seg)

	# Long barrel
	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.10, 0.10, 0.10, 1)
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.02
	barrel_mesh.bottom_radius = 0.022
	barrel_mesh.height = 0.16
	barrel_mesh.material = barrel_mat
	var barrel := MeshInstance3D.new()
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0.0, 0.04, 0.34)
	barrel.rotation_degrees = Vector3(90, 0, 0)
	_ak47_node.add_child(barrel)

# ------------------------------------------------------------------
# Grenade Launcher model
# ------------------------------------------------------------------

func _build_grenade_launcher() -> void:
	_grenade_launcher_node = Node3D.new()
	_grenade_launcher_node.name = "GrenadeLauncher"
	_grenade_launcher_node.position = Vector3(0.0, 0.06, 0.06)
	_grenade_launcher_node.scale = Vector3.ONE * 1.4
	_attach_weapon(_grenade_launcher_node)

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
	# Shift the bat DOWN so the right (top / main) hand — which holds the
	# weapon grip — wraps the UPPER handle. The left (support) hand then IKs
	# onto the lower handle (the bat's off_hand_anchor), so the right hand
	# stacks ON TOP of the left for a right-handed swing. The handle mesh
	# spans bat-local y 0.04..0.30; offsetting by -0.24 puts the grip hand at
	# ~0.24 (upper handle). With the default "player_forward" grip the arm
	# rotation is cancelled, so the bat's +Y maps to torso-up and it reads
	# VERTICAL at rest no matter how the arm is posed.
	_bat_node.position = Vector3(0.0, -0.24, 0.0)
	_bat_node.scale = Vector3.ONE * 1.25
	_attach_weapon(_bat_node)

	# A real baseball bat is one smooth piece: flared knob → thin taped
	# handle → swelling barrel → rounded end, all on the same x=z=0 axis so
	# nothing steps off-centre. Built bottom-up the +Y axis.
	var grip_mat := StandardMaterial3D.new()
	grip_mat.albedo_color = Color(0.12, 0.10, 0.08, 1)  # dark grip tape
	grip_mat.roughness = 0.7
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.62, 0.44, 0.24, 1)  # ash / maple wood
	wood_mat.roughness = 0.55

	# Knob — flared base at the very bottom.
	var knob_mesh := CylinderMesh.new()
	knob_mesh.top_radius = 0.018
	knob_mesh.bottom_radius = 0.030
	knob_mesh.height = 0.04
	knob_mesh.material = grip_mat
	var knob := MeshInstance3D.new()
	knob.name = "Knob"
	knob.mesh = knob_mesh
	knob.position = Vector3(0.0, 0.02, 0.0)
	_bat_node.add_child(knob)

	# Handle — thin, taped section the hands wrap.
	var handle_mesh := CylinderMesh.new()
	handle_mesh.top_radius = 0.021
	handle_mesh.bottom_radius = 0.018
	handle_mesh.height = 0.26
	handle_mesh.material = grip_mat
	var handle := MeshInstance3D.new()
	handle.name = "Handle"
	handle.mesh = handle_mesh
	handle.position = Vector3(0.0, 0.17, 0.0)  # spans y 0.04 .. 0.30
	_bat_node.add_child(handle)

	# Barrel — tapers out from the handle to the fat hitting end.
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.041
	barrel_mesh.bottom_radius = 0.021
	barrel_mesh.height = 0.34
	barrel_mesh.material = wood_mat
	var barrel := MeshInstance3D.new()
	barrel.name = "Barrel"
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0.0, 0.47, 0.0)  # spans y 0.30 .. 0.64
	_bat_node.add_child(barrel)

	# Rounded end cap.
	var end_mesh := SphereMesh.new()
	end_mesh.radius = 0.041
	end_mesh.height = 0.082
	end_mesh.material = wood_mat
	var end_cap := MeshInstance3D.new()
	end_cap.name = "EndCap"
	end_cap.mesh = end_mesh
	end_cap.position = Vector3(0.0, 0.64, 0.0)
	_bat_node.add_child(end_cap)

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
		"ak47": weapon_node = _ak47_node
		"grenade_launcher": weapon_node = _grenade_launcher_node
		"bat": weapon_node = _bat_node

	if weapon_node == null:
		return global_position + Vector3(0, 1.0, 0)

	match _current_weapon:
		"shotgun":
			return weapon_node.global_transform * Vector3(0.0, 0.02, 0.34)
		"smg":
			return weapon_node.global_transform * Vector3(0.0, 0.04, 0.22)
		"ak47":
			return weapon_node.global_transform * Vector3(0.0, 0.04, 0.30)
		"grenade_launcher":
			return weapon_node.global_transform * Vector3(0.0, 0.04, 0.24)
		"bat":
			return weapon_node.global_transform * Vector3(0.0, 0.47, 0.0)
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
	var forward := _get_aim_direction()
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
		"pellet":
			_draw_pellet_aim(im, muzzle_pos)
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

func _draw_pellet_aim(im: ImmediateMesh, muzzle_pos: Vector3) -> void:
	# Show the outer edges of the pellet cone plus a central aim line so
	# the player can judge both where the tightest grouping will land and
	# how wide the spread is.
	var forward := _get_aim_direction()
	var weapon_range: float = _weapon_stats.get("range", 15.0)
	var spread_deg: float = _weapon_stats.get("pellet_spread", 8.0)
	var spread_rad := deg_to_rad(spread_deg)

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(3):
		var t := float(i) * 0.5  # 0.0 (-edge), 0.5 (centre), 1.0 (+edge)
		var angle: float = lerpf(-spread_rad, spread_rad, t)
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
		# Empty magazine — dry-fire click. Throttle so a held trigger doesn't
		# machine-gun the click sound.
		_emit_player_sound("dry_fire", randf_range(0.95, 1.05), -8.0)
		_shoot_timer = 0.25
		return

	if not is_melee:
		ammo -= 1
	_shoot_timer = WeaponData.shoot_cooldown(_current_weapon)
	_fire_bullet()

## Bare-hand attack — available only while unarmed. Alternates the leading
## fist each strike so the player throws with both arms, and lands the hit
## immediately (the animation is a visual flourish on top).
func _try_punch() -> void:
	if _armed or _is_reloading or _punch_timer > 0.0 or is_dead:
		return
	_punch_timer = WeaponData.shoot_cooldown("fists")
	_punch_anim_timer = PUNCH_DURATION
	_punch_is_right = not _punch_is_right
	_fire_punch()

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
	_emit_player_sound("reload", 1.0, -7.0)

func _fire_bullet() -> void:
	var hit_mode: String = _weapon_stats.get("hit_mode", "single")
	# Gunfire sound (melee weapons handle their own whoosh in _melee_strike).
	if hit_mode != "melee":
		var gun_vol := -3.0
		if _current_weapon == "smg":
			gun_vol = -8.0
		elif _current_weapon == "ak47":
			gun_vol = -5.0
		_emit_player_sound(_gun_sound_name(), randf_range(0.95, 1.05), gun_vol)
	match hit_mode:
		"pellet":
			_fire_pellet()
			_spawn_muzzle_flash()
		"explosive":
			_fire_explosive()
			_spawn_muzzle_flash()
		"melee":
			_fire_melee()
		_:
			_fire_single()
			_spawn_muzzle_flash()

	# Visual kick on the arms — melee still gets a swing cue. Each weapon's
	# pose sets its own kick duration (the bat needs a longer arc than a
	# pistol shot) so use that instead of the default.
	_shoot_anim_timer = max(_kick_duration, 0.05)

	# Physical recoil — accumulates backward into _recoil_velocity, which
	# the physics step layers onto velocity and decays. Melee has zero
	# recoil in WeaponData so this is effectively a gun-only effect.
	_apply_recoil()

func _fire_single() -> void:
	var forward := _get_aim_direction()
	var weapon_range: float = _weapon_stats.get("range", 40.0)
	var damage: float = _weapon_stats.get("damage", 10.0)
	var spread_deg: float = _weapon_stats.get("spread", 0.0)
	var knockback: float = _weapon_stats.get("knockback", 0.0)

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
	var impulse := forward * knockback

	# Damage is applied ONLY to the body the ray physically strikes. An enemy
	# is hurt when the shot actually connects along the visible aim line —
	# never for merely standing near the line of fire, and never through a
	# wall the ray hit first (the raycast stops at the closest collider).
	var result := _cast_ray(ray_origin, ray_end)
	if result and result.collider is CharacterBody3D:
		var hit_body: CharacterBody3D = result.collider as CharacterBody3D
		if hit_body.has_method("take_damage"):
			hit_body.take_damage(damage, impulse)
			_spawn_hit_sparks(result.position)

	_spawn_tracer(ray_origin, result.position if result else ray_end)

func _fire_pellet() -> void:
	# Real shotguns fire a shell of ~12 buckshot pellets that spread in a
	# cone. Each pellet is its own raycast: damage is only applied to the
	# body the pellet directly hits, so total damage scales with how many
	# pellets land on a given target — point-blank is devastating, while a
	# target on the edge of the cone at max range might only get clipped
	# by one or two. One shell = one pull of the trigger = one ammo tick.
	var forward := _get_aim_direction()
	var weapon_range: float = _weapon_stats.get("range", 15.0)
	var damage_per_pellet: float = _weapon_stats.get("damage", 5.0)
	var spread_deg: float = _weapon_stats.get("pellet_spread", 4.0)
	var pellet_count: int = _weapon_stats.get("pellet_count", 12)
	var knockback_per_pellet: float = _weapon_stats.get("knockback", 0.0)
	var spread_rad := deg_to_rad(spread_deg)

	var ray_origin := _get_muzzle_world_pos()

	# Deduplicate the spark VFX per victim so a zombie absorbing a dozen
	# pellets gets one meaty spark burst instead of a dozen overlapping
	# ones. Damage itself is still applied per-pellet.
	var spark_points: Dictionary = {}

	for i in range(pellet_count):
		# Yaw (horizontal "spread") sweeps the full cone since the game's
		# top-down camera makes lateral dispersion the visible one. Pitch
		# (vertical "recoil" off the aim line) is kept very small so
		# pellets stay on the plane the zombies actually occupy rather
		# than punching into the ground or flying over their heads.
		var rand_yaw := randf_range(-spread_rad, spread_rad)
		var rand_pitch := randf_range(-spread_rad * 0.1, spread_rad * 0.1)
		var dir := forward.rotated(Vector3.UP, rand_yaw)
		var right := dir.cross(Vector3.UP)
		if right.length_squared() > 0.0001:
			right = right.normalized()
			dir = dir.rotated(right, rand_pitch)
		dir = dir.normalized()

		var ray_end := ray_origin + dir * weapon_range
		var result := _cast_ray(ray_origin, ray_end)
		var tracer_end: Vector3 = result.position if result else ray_end

		if result and result.collider is CharacterBody3D:
			var hit_body: CharacterBody3D = result.collider as CharacterBody3D
			if hit_body.has_method("take_damage"):
				hit_body.take_damage(damage_per_pellet, dir * knockback_per_pellet)
				spark_points[hit_body] = result.position

		_spawn_tracer(ray_origin, tracer_end)

	for pos: Vector3 in spark_points.values():
		_spawn_hit_sparks(pos)

func _fire_explosive() -> void:
	var forward := _get_aim_direction()
	var weapon_range: float = _weapon_stats.get("range", 25.0)
	var damage: float = _weapon_stats.get("damage", 30.0)
	var radius: float = _weapon_stats.get("explosion_radius", 5.0)
	var knockback: float = _weapon_stats.get("knockback", 0.0)

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
			# Radial knockback away from the impact, scaled the same way
			# as damage so close zombies fly further than ones near the
			# blast edge.
			var away := enemy_body.global_position - impact_pos
			away.y = 0.0
			if away.length_squared() > 0.0001:
				away = away.normalized()
			else:
				away = Vector3.ZERO
			enemy_body.take_damage(damage * falloff, away * knockback * falloff)

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
	# Bat swing — full weapon stats, with the golden swing-arc VFX.
	_melee_strike(_weapon_stats, true)

## Shared melee hit resolution for both the bat and bare fists: damage every
## enemy inside a forward cone within reach, shoving them along the swing.
## `draw_arc` toggles the bat's sweep-arc VFX (off for punches).
func _melee_strike(stats: Dictionary, draw_arc: bool) -> void:
	var forward := _get_forward()
	var weapon_range: float = stats.get("range", 2.5)
	var damage: float = stats.get("damage", 20.0)
	var sweep_angle: float = stats.get("sweep_angle", 90.0)
	var half_sweep := deg_to_rad(sweep_angle * 0.5)
	var knockback: float = stats.get("knockback", 0.0)

	var origin := global_position + Vector3(0, 0.9, 0)

	# Swing whoosh — heavier for the bat, lighter for bare fists.
	_emit_player_sound("swing_bat" if draw_arc else "swing_fist", randf_range(0.94, 1.06), -10.0)
	var hit_played := false

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
			# Shove roughly in the swing direction (the player's forward) with
			# a touch of away-from-player so the zombie stumbles back rather
			# than into the strike.
			var swing_dir: Vector3 = (forward + to_enemy.normalized() * 0.5).normalized()
			enemy_body.take_damage(damage, swing_dir * knockback)
			_spawn_hit_sparks(enemy_body.global_position + Vector3(0, 0.9, 0))
			if not hit_played:
				hit_played = true
				_emit_player_sound("melee_hit", randf_range(0.92, 1.08), -5.0)

	if draw_arc:
		_spawn_swing_arc(origin, forward, weapon_range, half_sweep)

## Bare-hand strike — same forward-cone hit as the bat but with the lighter
## "fists" stats and no weapon arc.
func _fire_punch() -> void:
	_melee_strike(WeaponData.get_weapon("fists"), false)

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

## Lower-body yaw tracks the direction the player is moving (or holds steady
## when not moving). The upper body (chest + waist) twists toward the mouse
## independently in _update_animation. Body only chases the aim once the
## offset between aim and the desired body yaw exceeds ±45° — then we clamp
## body yaw to that boundary so the waist can cover the remaining angle.
##
## Net effect: walking forward while flicking the mouse left/right looks
## like a person twisting their torso to aim, not a top spinning in place.
func _rotate_to_face_mouse(delta: float) -> void:
	if look_target == Vector3.INF:
		return
	var aim_dir := look_target - global_position
	aim_dir.y = 0.0
	if aim_dir.length_squared() < 0.01:
		return
	var aim_yaw := atan2(aim_dir.x, aim_dir.z)

	var move_dir := _get_world_movement_direction()
	var desired_body_yaw: float
	if move_dir.length() > 0.1:
		desired_body_yaw = atan2(move_dir.x, move_dir.z)
	else:
		desired_body_yaw = rotation.y

	var aim_offset := wrapf(aim_yaw - desired_body_yaw, -PI, PI)
	var target_body_yaw: float
	if absf(aim_offset) > MAX_TORSO_TWIST:
		# Aim is past the torso's max twist — snap body to the nearest
		# boundary so the waist can still cover the remaining angle.
		target_body_yaw = aim_yaw - signf(aim_offset) * MAX_TORSO_TWIST
	else:
		target_body_yaw = desired_body_yaw
	rotation.y = lerp_angle(rotation.y, target_body_yaw, ROTATION_SPEED * delta)

func _update_animation(delta: float) -> void:
	# Horizontal speed drives the walk cycle; scale the cycle faster and bigger
	# when sprinting so sprint visibly reads.
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	var speed_ratio := clampf(horiz_speed / SPEED, 0.0, 2.0)
	# Cycle frequency in radians/sec — ~2 full swings/sec at walking speed.
	var cycle_rate := 10.0 * speed_ratio
	_walk_phase = fposmod(_walk_phase + cycle_rate * delta, TAU)

	var clamped_ratio: float = clampf(speed_ratio, 0.0, 1.5)
	var leg_swing_amp := deg_to_rad(lerpf(2.0, 32.0, clamped_ratio))
	var knee_amp := deg_to_rad(lerpf(2.0, 48.0, clamped_ratio))
	# A free arm hangs and pendulums broadly with the gait; a braced/IK arm
	# is locked to the weapon and barely moves.
	var braced_arm_amp := deg_to_rad(lerpf(0.5, 4.0, clamped_ratio))
	var free_arm_amp := deg_to_rad(lerpf(2.0, 18.0, clamped_ratio))
	var bob_amp := lerpf(0.0, 0.04, clamped_ratio)
	# Pelvis swivel is disabled: any non-zero yaw here rotates each hip's
	# swing plane off the sagittal axis, so the swinging foot traces a slight
	# outward arc and the legs read as bowing out. Keep it at 0 so the legs
	# swing straight forward/back and stay parallel.
	var hip_yaw_amp := 0.0
	var spine_counter_yaw_amp := deg_to_rad(lerpf(0.3, 4.0, clamped_ratio))

	var swing_sin := sin(_walk_phase)
	var bob := absf(swing_sin) * bob_amp
	# Footstep audio is driven off the same gait sine, so steps land in sync
	# with the legs and the cadence scales with walk/sprint speed for free.
	_handle_footsteps(horiz_speed, swing_sin)
	# In a real walking gait, the arm on each side swings 180° out of phase
	# with the leg on the same side (left arm forward when left leg is back).
	var right_braced := _right_arm_mode != "free"
	var left_braced := _left_arm_mode != "free"
	var right_amp := braced_arm_amp if right_braced else free_arm_amp
	var left_amp := braced_arm_amp if left_braced else free_arm_amp
	var left_sway := -swing_sin * left_amp
	var right_sway :=  swing_sin * right_amp

	# --- Legs ---
	# Left leg swings forward at swing_sin=+1, right leg opposite. Both knees
	# bend most during their leg's forward swing (foot lifts to clear the
	# ground). Bend uses the positive half of sin so the planted leg stays
	# nearly straight while the swinging leg lifts.
	var left_lift: float = max(0.0, swing_sin)
	var right_lift: float = max(0.0, -swing_sin)
	if _hip_l:
		_hip_l.transform = _hip_l_rest * Transform3D(
			Basis(Vector3.RIGHT, swing_sin * leg_swing_amp), Vector3.ZERO
		)
	if _hip_r:
		_hip_r.transform = _hip_r_rest * Transform3D(
			Basis(Vector3.RIGHT, -swing_sin * leg_swing_amp), Vector3.ZERO
		)
	# Knees bend backward (heel toward butt) during the leg's forward swing.
	# In hip-local space the shin extends along -Y, and a *positive* rotation
	# around the knee's +X axis tilts -Y toward -Z, which is the player's
	# backward direction — exactly what we want for a heel-lift.
	if _knee_l:
		_knee_l.transform = _knee_l_rest * Transform3D(
			Basis(Vector3.RIGHT, left_lift * knee_amp), Vector3.ZERO
		)
	if _knee_r:
		_knee_r.transform = _knee_r_rest * Transform3D(
			Basis(Vector3.RIGHT, right_lift * knee_amp), Vector3.ZERO
		)

	# --- Hips and spine: subtle counter-rotation around Y so the upper body
	# twists against the hips in time with the gait, plus an aim-driven
	# offset that lets the upper body face roughly toward the look target.
	var aim_yaw: float = 0.0
	if look_target != Vector3.INF and not is_dead:
		var to_target := look_target - global_position
		to_target.y = 0.0
		if to_target.length_squared() > 0.04:
			var target_yaw := atan2(to_target.x, to_target.z)
			# Difference between desired aim yaw and player body yaw.
			# Player body yaw is `rotation.y`; we want the delta in [-π, π].
			aim_yaw = wrapf(target_yaw - rotation.y, -PI, PI)
	# Low-pass the aim yaw so the spine twist eases rather than snapping.
	_aim_yaw_smooth = lerpf(_aim_yaw_smooth, aim_yaw, clampf(delta * 10.0, 0.0, 1.0))
	# Total upper-body twist (relative to the lower body). The body yaw is
	# already kept within ±90° of the aim by _rotate_to_face_mouse, so the
	# soft torso covers the rest. _spine itself stays unrotated so the
	# bottom ring of the soft torso stays aligned with the belt/pelvis —
	# the twist is applied per-vertex inside the mesh and as a full
	# rotation on _torso_top (which carries the shoulders/neck/head).
	var torso_twist: float = clampf(_aim_yaw_smooth, -MAX_TORSO_TWIST, MAX_TORSO_TWIST)
	var counter_yaw: float = -swing_sin * spine_counter_yaw_amp
	var twist_total: float = torso_twist + counter_yaw

	# Hips strictly follow the body yaw — the legs should face the
	# direction of movement without any aim-driven counter-rotation.
	if _hips:
		_hips.transform = Transform3D(
			Basis(Vector3.UP, swing_sin * hip_yaw_amp),
			Vector3(0, HIP_Y, 0),
		)

	# --- Fire kick envelope. Computed up here (before the torso pose) so the
	# chest recoil can fold into the upper-body lean. The kick drives the
	# RIGHT (weapon/trigger) arm; the LEFT support arm follows it via IK.
	_shoot_anim_timer = max(_shoot_anim_timer - delta, 0.0)
	_punch_timer = max(_punch_timer - delta, 0.0)
	_punch_anim_timer = max(_punch_anim_timer - delta, 0.0)
	var kick_env := 0.0
	if _kick_duration > 0.0 and _shoot_anim_timer > 0.0:
		var elapsed: float = _kick_duration - _shoot_anim_timer
		var t: float = clampf(elapsed / _kick_duration, 0.0, 1.0)
		# Fast snap to peak at ~25% of the cycle, slower return.
		var peak_t := 0.25
		if t < peak_t:
			kick_env = t / peak_t
		else:
			kick_env = 1.0 - (t - peak_t) / (1.0 - peak_t)
	var kick_pitch := kick_env * deg_to_rad(_kick_pitch_deg)
	var kick_elbow := kick_env * deg_to_rad(_kick_elbow_deg)

	# Forward lean. Sprint adds a base lean; twisting the upper body adds
	# a small "shoulder-into-aim" lean on top so the chest feels active
	# while it rotates with the waist. Firing leans the torso BACK (negative
	# pitch) by the weapon's chest_recoil scaled by the kick envelope — a
	# shotgun rocks the body, an SMG barely nudges it. The combined pitch is
	# shared by the waist's top ring AND _torso_top so the seam stays closed.
	var sprint_pitch: float = deg_to_rad(lerpf(0.0, 9.0, clampf((speed_ratio - 1.0), 0.0, 1.0)))
	var twist_lean: float = absf(torso_twist) * 0.10  # 10% of twist as fwd lean
	var recoil_lean: float = kick_env * deg_to_rad(_chest_recoil_deg)
	var torso_pitch: float = sprint_pitch + twist_lean - recoil_lean

	# Pose the waist slices. Each slice rotates by a smoothstep fraction
	# of the total twist/pitch so the bottom slice stays glued to the
	# rigid pelvis (blend → 0) and the top slice matches _torso_top
	# (blend → 1), giving a smooth bend through the middle.
	_update_waist_segments(twist_total, torso_pitch, bob)

	# Upper-body anchor — same twist as the top ring of the waist, plus
	# a small "chest follow-through" twist (5% extra) so the chest leads
	# the rotation slightly, the way human shoulders naturally do. The
	# pitch matches the waist top exactly so the seam stays closed; the
	# tiny twist offset is small enough not to open a visible gap once
	# the material is two-sided (CULL_DISABLED). Pitch is positive around
	# RIGHT, matching the player's +Z forward — a forward lean.
	if _torso_top:
		var chest_twist: float = twist_total * 1.05
		var top_basis := Basis(Vector3.UP, chest_twist) * Basis(Vector3.RIGHT, torso_pitch)
		_torso_top.transform = Transform3D(top_basis, Vector3(0, WAIST_TOP_Y + bob, 0))

	# --- Neck/head: the upper-body anchor already carries the full twist,
	# so the neck stays at its rest pose.
	if _neck:
		_neck.transform = _neck_rest

	# --- Fire animation: the RIGHT shoulder + elbow drive the kick (right is
	# the trigger / weapon hand). For guns this is a small barrel-rise + brief
	# return; for the bat it's a large pitch swing plus elbow extension. The
	# LEFT (support) arm IKs onto the weapon's off-hand anchor afterward, so
	# the kick naturally propagates through the moving weapon to the off-hand.
	if _right_shoulder:
		_right_shoulder.transform = _right_shoulder_rest * Transform3D(
			Basis(Vector3.RIGHT, right_sway + kick_pitch), Vector3.ZERO
		)
	if _right_elbow:
		_right_elbow.transform = _right_elbow_rest * Transform3D(
			Basis(Vector3.RIGHT, kick_elbow), Vector3.ZERO
		)

	# Left (support) arm: pendulum at the side (free), brace-with-sway
	# (braced — static pose with tiny sway), or IK-locked onto the weapon's
	# off-hand anchor (two-handed weapons). IK re-solves onto the already-
	# kicked weapon, so the support hand stays glued through recoil.
	if _left_arm_mode == "ik":
		_solve_off_hand_ik()
	else:
		if _left_shoulder:
			var left_kick: float = kick_pitch * (0.5 if left_braced else 0.0)
			_left_shoulder.transform = _left_shoulder_rest * Transform3D(
				Basis(Vector3.RIGHT, left_sway + left_kick), Vector3.ZERO
			)
		if _left_elbow and left_braced:
			_left_elbow.transform = _left_elbow_rest * Transform3D(
				Basis(Vector3.RIGHT, kick_elbow * 0.5), Vector3.ZERO
			)

	# --- Bare-hand punch: when unarmed and a strike is in flight, drive the
	# leading fist straight out from the guard — shoulder rotates the upper
	# arm forward, elbow snaps from its bent rest to nearly straight — then
	# recovers. Overrides whichever arm is throwing (set above); the other
	# stays in its combat-ready guard. Fists alternate per strike.
	if not _armed and _punch_anim_timer > 0.0:
		var pt: float = clampf(
			(PUNCH_DURATION - _punch_anim_timer) / PUNCH_DURATION, 0.0, 1.0
		)
		# Fast snap out to full extension at ~35%, slower pull back.
		var punch_env: float = (pt / 0.35) if pt < 0.35 else (1.0 - (pt - 0.35) / 0.65)
		punch_env = clampf(punch_env, 0.0, 1.0)
		# Negative pitch drives the upper arm forward; positive elbow delta
		# unfolds the bent guard toward a straight jab.
		var punch_pitch: float = punch_env * deg_to_rad(-62.0)
		var punch_elbow: float = punch_env * deg_to_rad(58.0)
		var p_sh: Node3D = _right_shoulder if _punch_is_right else _left_shoulder
		var p_sh_rest: Transform3D = _right_shoulder_rest if _punch_is_right else _left_shoulder_rest
		var p_el: Node3D = _right_elbow if _punch_is_right else _left_elbow
		var p_el_rest: Transform3D = _right_elbow_rest if _punch_is_right else _left_elbow_rest
		if p_sh:
			p_sh.transform = p_sh_rest * Transform3D(
				Basis(Vector3.RIGHT, punch_pitch), Vector3.ZERO
			)
		if p_el:
			p_el.transform = p_el_rest * Transform3D(
				Basis(Vector3.RIGHT, punch_elbow), Vector3.ZERO
			)

## Resolve the LEFT (support) arm so its hand reaches the equipped weapon's
## off-hand anchor (the forend on guns, lower handle on the bat). Runs each
## frame for two-handed weapons; the right (trigger) arm has already been
## animated, so reading the weapon's current world transform here gives us a
## target that already includes the trigger-hand kick.
func _solve_off_hand_ik() -> void:
	if _torso_top == null or _left_shoulder == null or _left_elbow == null:
		return
	var weapon_node := _current_weapon_node()
	if weapon_node == null:
		return
	# Target in WORLD space → convert into _torso_top-local since the
	# left shoulder is a direct child of the upper-body anchor.
	var target_world: Vector3 = weapon_node.global_transform * _off_hand_anchor_local
	var target_local: Vector3 = _torso_top.global_transform.affine_inverse() * target_world
	# Left shoulder pivot lives at -SHOULDER_X inside _torso_top.
	var shoulder_pos := Vector3(-SHOULDER_X, SHOULDER_Y, SHOULDER_Z)
	# Pole vector — defines which way the elbow bulges. We want the elbow
	# to drop straight down (and a hair inward, toward the body centerline,
	# which is +X for the left arm) so the support arm looks tucked rather
	# than chicken-winged outward.
	var pole_pos := shoulder_pos + Vector3(0.08, -1.0, 0.0)
	_solve_arm_ik(
		_left_shoulder, _left_elbow,
		shoulder_pos, target_local, pole_pos,
		_upper_arm_len, _forearm_len,
	)

## Two-bone IK solver. Sets `shoulder.transform` so the upper arm points
## toward `target_local` (in `shoulder`'s parent frame), and the elbow
## bends so the forearm tip reaches the target. `pole_local` is a
## point in the parent frame on the side the elbow should bulge toward.
##
## Both bones are oriented along their local -Y axis (the same convention
## used by _build_arm_chain), and the elbow lies at (0, -upper_len, 0) in
## the shoulder's local frame.
func _solve_arm_ik(
	shoulder: Node3D, elbow: Node3D,
	shoulder_local_pos: Vector3,
	target_local: Vector3, pole_local: Vector3,
	upper_len: float, forearm_len: float,
) -> void:
	var to_target: Vector3 = target_local - shoulder_local_pos
	var d: float = to_target.length()
	if d < 0.0001:
		return
	var min_d: float = absf(upper_len - forearm_len) + 0.01
	var max_d: float = upper_len + forearm_len - 0.001
	d = clampf(d, min_d, max_d)
	var to_target_dir: Vector3 = to_target.normalized()

	# Project the pole offset perpendicular to the shoulder→target axis so
	# the elbow plane is well-defined.
	var pole_offset: Vector3 = pole_local - shoulder_local_pos
	var pole_perp: Vector3 = pole_offset - to_target_dir * pole_offset.dot(to_target_dir)
	if pole_perp.length_squared() < 0.0001:
		pole_perp = Vector3.DOWN - to_target_dir * to_target_dir.dot(Vector3.DOWN)
		if pole_perp.length_squared() < 0.0001:
			pole_perp = Vector3.FORWARD - to_target_dir * to_target_dir.dot(Vector3.FORWARD)
	pole_perp = pole_perp.normalized()

	# Law of cosines: angle at the shoulder between upper arm and
	# shoulder→target axis.
	var cos_sh: float = clampf(
		(upper_len * upper_len + d * d - forearm_len * forearm_len) / (2.0 * upper_len * d),
		-1.0, 1.0,
	)
	var sh_angle: float = acos(cos_sh)
	var upper_dir: Vector3 = (to_target_dir * cos(sh_angle) + pole_perp * sin(sh_angle)).normalized()

	# Shoulder basis: local -Y aligns with the upper arm direction; local +Z
	# lies in the IK plane (projection of the shoulder→target direction).
	var local_y: Vector3 = -upper_dir
	var local_z: Vector3 = to_target_dir - local_y * local_y.dot(to_target_dir)
	if local_z.length_squared() < 0.0001:
		local_z = Vector3.FORWARD - local_y * local_y.dot(Vector3.FORWARD)
	local_z = local_z.normalized()
	var local_x: Vector3 = local_y.cross(local_z).normalized()

	shoulder.transform = Transform3D(Basis(local_x, local_y, local_z), shoulder_local_pos)

	# Elbow bend: rotate around the elbow's local +X so the forearm points
	# from the elbow toward the target. Compute the desired direction in
	# shoulder-local coords and read off the rotation angle.
	var elbow_pos_local: Vector3 = shoulder_local_pos + upper_len * upper_dir
	var forearm_dir_local: Vector3 = (target_local - elbow_pos_local).normalized()
	var f: Vector3 = shoulder.basis.inverse() * forearm_dir_local
	var theta: float = atan2(-f.z, -f.y)
	elbow.transform = Transform3D(Basis(Vector3.RIGHT, theta), Vector3(0, -upper_len, 0))

func _current_weapon_node() -> Node3D:
	match _current_weapon:
		"pistol": return _pistol_node
		"shotgun": return _shotgun_node
		"smg": return _smg_node
		"ak47": return _ak47_node
		"grenade_launcher": return _grenade_launcher_node
		"bat": return _bat_node
	return null

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
			# Bare hands are a real attack now, so label them as a weapon and
			# show the melee dash for ammo (same as the bat).
			hud.set_ammo(-1, -1)
			hud.set_weapon_name("FISTS")
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
