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

# Health
const HEALTH_MAX := 100.0
var health: float = HEALTH_MAX
var is_dead: bool = false
var god_mode: bool = false

# Recoil: backward XZ impulse pushed onto the player every trigger pull,
# decayed exponentially in _physics_process so a single shot is barely a
# rock and rapid fire (SMG) accumulates into a real shove.
const RECOIL_DECAY := 9.0
var _recoil_velocity: Vector3 = Vector3.ZERO

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

# Body part references for procedural animation (walking, shooting kick).
# The right/left arms are skeletal rigs built in code (see _build_arm_rigs)
# so weapons can be parented to the hand and actually track arm motion.
var _leg_left: Node3D = null
var _leg_right: Node3D = null
var _torso: Node3D = null
# Shoulders are the animated pivots — rotating them swings the entire arm
# chain (upper arm → forearm → hand → weapon grip) as one. Elbows pivot
# the forearm independently for poses that need a tighter bend (chest-high
# rifle hold, cocked melee swing).
var _right_shoulder: Node3D = null
var _left_shoulder: Node3D = null
var _right_elbow: Node3D = null
var _left_elbow: Node3D = null
# Weapons are parented to this anchor on the left hand (dominant trigger
# hand) so they follow the full walk / kick animation without any extra
# bookkeeping.
var _weapon_grip: Node3D = null
# Rest-pose transforms captured at _ready so animation is relative to the scene setup.
var _leg_left_rest := Transform3D.IDENTITY
var _leg_right_rest := Transform3D.IDENTITY
var _torso_rest := Transform3D.IDENTITY
var _right_shoulder_rest := Transform3D.IDENTITY
var _left_shoulder_rest := Transform3D.IDENTITY
var _right_elbow_rest := Transform3D.IDENTITY
var _left_elbow_rest := Transform3D.IDENTITY
# Whether each arm is currently bracing the weapon. Drives walk-cycle
# amplitude — a free arm pendulums broadly, a braced arm barely moves.
var _right_arm_braced: bool = false
var _left_arm_braced: bool = false
# Current pose's kick parameters, refreshed by _apply_weapon_pose.
var _kick_pitch_deg: float = 0.0
var _kick_elbow_deg: float = 0.0
var _kick_duration: float = 0.18
# Walk cycle phase (radians) — advances with horizontal speed so legs swing while moving.
var _walk_phase: float = 0.0
# Countdown timer driving the shooting arm kick-back animation (seconds).
var _shoot_anim_timer: float = 0.0
# Default duration when no weapon-specific kick is configured.
const SHOOT_ANIM_DURATION := 0.22

## Per-weapon arm poses + kick parameters. Angles are in degrees.
## - shoulder_pitch: rotation around X. Negative pitches the arm forward/down.
## - shoulder_yaw:   rotation around Y. Negative pulls inward toward chest.
## - elbow_bend:     rotation around X at the elbow. Positive bends the forearm
##                   toward the body.
## - braced:         when true, walk cycle dampens this arm to a 4° sway. When
##                   false, the arm hangs and pendulums ~18° like a real gait.
## kick_pitch / kick_elbow describe the delta applied to the right arm during
## the fire animation (negative pitch raises the barrel; the bat uses a large
## negative pitch + elbow extension to chop forward from a cocked pose).
const WEAPON_POSES := {
	"unarmed": {
		"left":  { "shoulder_pitch": -8.0, "shoulder_yaw": 0.0, "elbow_bend": 12.0, "braced": false },
		"right": { "shoulder_pitch": -8.0, "shoulder_yaw": 0.0, "elbow_bend": 12.0, "braced": false },
		"kick_pitch": 0.0, "kick_elbow": 0.0, "kick_duration": 0.0,
	},
	"pistol": {
		# Left (dominant) hand extends forward at chest. Off-hand hangs
		# naturally at the side and pendulums while walking.
		"left":  { "shoulder_pitch": -75.0, "shoulder_yaw":  3.0, "elbow_bend": 8.0,  "braced": true },
		"right": { "shoulder_pitch": -8.0,  "shoulder_yaw":  0.0, "elbow_bend": 18.0, "braced": false },
		"kick_pitch": 14.0, "kick_elbow": 6.0, "kick_duration": 0.18,
	},
	"smg": {
		# SMG is one-handed in this game — left holds the trigger, right
		# arm hangs and pendulums.
		"left":  { "shoulder_pitch": -68.0, "shoulder_yaw":  3.0, "elbow_bend": 18.0, "braced": true },
		"right": { "shoulder_pitch": -8.0,  "shoulder_yaw":  0.0, "elbow_bend": 18.0, "braced": false },
		"kick_pitch": 8.0, "kick_elbow": 3.0, "kick_duration": 0.10,
	},
	"shotgun": {
		# Two-handed: the left hand grips the stock at chest level, the
		# right hand reaches diagonally across to the forend out in front.
		# Yaws pull both shoulders toward the centre line; the right elbow
		# bends deeply so the hand actually reaches the weapon body
		# instead of trailing alongside it.
		"left":  { "shoulder_pitch": -55.0, "shoulder_yaw":  12.0, "elbow_bend": 30.0, "braced": true },
		"right": { "shoulder_pitch": -65.0, "shoulder_yaw": -48.0, "elbow_bend": 60.0, "braced": true },
		"kick_pitch": 22.0, "kick_elbow": 9.0, "kick_duration": 0.28,
	},
	"grenade_launcher": {
		# Heavier than the shotgun — held a bit lower with more elbow flex.
		"left":  { "shoulder_pitch": -52.0, "shoulder_yaw":  12.0, "elbow_bend": 28.0, "braced": true },
		"right": { "shoulder_pitch": -62.0, "shoulder_yaw": -45.0, "elbow_bend": 56.0, "braced": true },
		"kick_pitch": 26.0, "kick_elbow": 10.0, "kick_duration": 0.32,
	},
	"bat": {
		# Cocked back over the left shoulder ready to swing. Off-hand hangs
		# at the side. Negative kick_pitch + elbow extension is the swing.
		# grip_align "along_arm" keeps the bat extending out of the wrist
		# along the arm direction (instead of aiming along player +Z like a
		# gun) so cocking back actually puts the bat over the shoulder.
		"left":  { "shoulder_pitch":  35.0, "shoulder_yaw":  22.0, "elbow_bend": 78.0, "braced": false },
		"right": { "shoulder_pitch":  -8.0, "shoulder_yaw":   0.0, "elbow_bend": 14.0, "braced": false },
		"kick_pitch": -110.0, "kick_elbow": -65.0, "kick_duration": 0.42,
		"grip_align": "along_arm",
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

func _cache_body_parts() -> void:
	_leg_left = get_node_or_null("LegLeft") as Node3D
	_leg_right = get_node_or_null("LegRight") as Node3D
	_torso = get_node_or_null("Torso") as Node3D
	if _leg_left: _leg_left_rest = _leg_left.transform
	if _leg_right: _leg_right_rest = _leg_right.transform
	if _torso: _torso_rest = _torso.transform
	_build_arm_rigs()

## Build a two-bone arm (shoulder → upper arm → elbow → forearm → hand) for
## each side, replacing the flat cylinder arms baked into Player.tscn. The
## right hand gets a WeaponGrip child — weapons parent to that and then
## follow every shoulder swing/kick frame-accurately.
func _build_arm_rigs() -> void:
	var old_left := get_node_or_null("ArmLeft")
	if old_left: old_left.queue_free()
	var old_right := get_node_or_null("ArmRight")
	if old_right: old_right.queue_free()

	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = Color(0.82, 0.68, 0.55, 1)
	skin_mat.roughness = 0.85
	var sleeve_mat := StandardMaterial3D.new()
	sleeve_mat.albedo_color = Color(0.22, 0.35, 0.18, 1)  # matches torso
	sleeve_mat.roughness = 0.85

	_right_shoulder = _build_arm_chain(
		"RightShoulder", Vector3(0.24, 1.32, 0.02), sleeve_mat, skin_mat, true
	)
	_left_shoulder = _build_arm_chain(
		"LeftShoulder", Vector3(-0.24, 1.32, 0.02), sleeve_mat, skin_mat, false
	)
	# Start in the unarmed pose — both arms hanging naturally. Equipping a
	# weapon will overwrite the rest transforms via _apply_weapon_pose.
	_apply_weapon_pose("unarmed")

## Returns the shoulder Node3D. The shoulder is the animation pivot; its
## child chain encodes the bone lengths and pre-pose. The weapon grip (for
## the right side) or hand anchor (left) is tagged in meta so callers can
## fetch it without hard-coding paths.
func _build_arm_chain(
	chain_name: String, shoulder_pos: Vector3,
	sleeve_mat: StandardMaterial3D, skin_mat: StandardMaterial3D,
	is_right: bool
) -> Node3D:
	var shoulder := Node3D.new()
	shoulder.name = chain_name
	shoulder.position = shoulder_pos
	# Rotation is set by _apply_weapon_pose so the rest pose matches the
	# weapon being held (or the unarmed default). Just leave it identity here.
	add_child(shoulder)

	var upper_len := 0.27
	var upper_mesh := CylinderMesh.new()
	upper_mesh.top_radius = 0.055
	upper_mesh.bottom_radius = 0.05
	upper_mesh.height = upper_len
	upper_mesh.material = sleeve_mat
	var upper := MeshInstance3D.new()
	upper.name = "UpperArm"
	upper.mesh = upper_mesh
	upper.position = Vector3(0, -upper_len * 0.5, 0)
	shoulder.add_child(upper)

	# Elbow: bend angle is set per pose by _apply_weapon_pose. The right
	# elbow is recorded for the WeaponGrip counter-rotation; both elbows
	# are referenced for the shoot animation.
	var elbow := Node3D.new()
	elbow.name = "Elbow"
	elbow.position = Vector3(0, -upper_len, 0)
	shoulder.add_child(elbow)
	if is_right:
		_right_elbow = elbow
	else:
		_left_elbow = elbow

	var fore_len := 0.26
	var fore_mesh := CylinderMesh.new()
	fore_mesh.top_radius = 0.05
	fore_mesh.bottom_radius = 0.045
	fore_mesh.height = fore_len
	fore_mesh.material = skin_mat
	var fore := MeshInstance3D.new()
	fore.name = "Forearm"
	fore.mesh = fore_mesh
	fore.position = Vector3(0, -fore_len * 0.5, 0)
	elbow.add_child(fore)

	var wrist := Node3D.new()
	wrist.name = "Wrist"
	wrist.position = Vector3(0, -fore_len, 0)
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

	if not is_right:
		# WeaponGrip lives on the LEFT hand — the dominant / trigger hand.
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
## _build_arm_rigs (initial unarmed pose) and from _equip_weapon. Falls
## back to the unarmed pose if the weapon name has no entry.
func _apply_weapon_pose(weapon_name: String) -> void:
	if _right_shoulder == null or _left_shoulder == null:
		return
	var pose: Dictionary = WEAPON_POSES.get(weapon_name, WEAPON_POSES["unarmed"])
	var right: Dictionary = pose["right"]
	var left: Dictionary = pose["left"]

	_pose_arm(_right_shoulder, _right_elbow, right)
	_pose_arm(_left_shoulder, _left_elbow, left)

	_right_shoulder_rest = _right_shoulder.transform
	_left_shoulder_rest = _left_shoulder.transform
	if _right_elbow:
		_right_elbow_rest = _right_elbow.transform
	if _left_elbow:
		_left_elbow_rest = _left_elbow.transform

	_right_arm_braced = right.get("braced", false)
	_left_arm_braced = left.get("braced", false)

	# Re-align the grip so the weapon sits naturally for the chosen pose:
	#   • "player_forward" (default, used by guns): basis = inverse of the
	#     accumulated shoulder + elbow rotation, so the muzzle aims along
	#     the player's +Z regardless of how the arm is posed.
	#   • "along_arm" (used by melee like the bat): basis = +90° rotation
	#     around X, mapping the weapon's +Z axis to the wrist's -Y, so the
	#     bat extends out of the wrist along the arm's direction. Cocking
	#     the arm back over the shoulder then naturally cocks the bat too.
	# Grip lives on the left arm, so we invert the left chain.
	if _weapon_grip and _left_elbow:
		var grip_align: String = pose.get("grip_align", "player_forward")
		if grip_align == "along_arm":
			_weapon_grip.basis = Basis(Vector3.RIGHT, PI * 0.5)
		else:
			var combined: Basis = _left_shoulder.basis * _left_elbow.basis
			_weapon_grip.basis = combined.inverse()

	_kick_pitch_deg = pose.get("kick_pitch", 0.0)
	_kick_elbow_deg = pose.get("kick_elbow", 0.0)
	_kick_duration = pose.get("kick_duration", SHOOT_ANIM_DURATION)

func _pose_arm(shoulder: Node3D, elbow: Node3D, pose: Dictionary) -> void:
	if shoulder:
		shoulder.rotation = Vector3(
			deg_to_rad(pose.get("shoulder_pitch", 0.0)),
			deg_to_rad(pose.get("shoulder_yaw", 0.0)),
			0.0,
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
	_build_grenade_launcher()
	_build_bat()
	_pistol_node.visible = false
	_shotgun_node.visible = false
	_smg_node.visible = false
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

func _apply_recoil() -> void:
	# Backward kick on the player's body for every trigger pull. Decays
	# exponentially in _physics_process so single shots barely rock and
	# rapid fire (SMG) accumulates into a noticeable shove.
	var strength: float = _weapon_stats.get("recoil", 0.0)
	if strength <= 0.0:
		return
	_recoil_velocity -= _get_forward() * strength

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
	_smg_node.visible = (_current_weapon == "smg")
	_grenade_launcher_node.visible = (_current_weapon == "grenade_launcher")
	_bat_node.visible = (_current_weapon == "bat")

	# Re-pose the arms so the body actually mimics holding this weapon —
	# pistol shooters extend the firing hand and let the off-hand hang,
	# rifle/shotgun shooters bring the support hand across, the bat sits
	# cocked back over the shoulder, and so on.
	_apply_weapon_pose(_current_weapon)

func _get_forward() -> Vector3:
	var fwd := global_transform.basis.z
	fwd.y = 0.0
	return fwd.normalized()

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
	# positioned so the pistol's grip mesh lines up with the hand.
	_pistol_node.position = Vector3(0.0, 0.04, 0.0)
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
# Grenade Launcher model
# ------------------------------------------------------------------

func _build_grenade_launcher() -> void:
	_grenade_launcher_node = Node3D.new()
	_grenade_launcher_node.name = "GrenadeLauncher"
	_grenade_launcher_node.position = Vector3(0.0, 0.06, 0.06)
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
	_bat_node.position = Vector3(0.0, 0.0, 0.10)
	_attach_weapon(_bat_node)

	var handle_mat := StandardMaterial3D.new()
	handle_mat.albedo_color = Color(0.15, 0.12, 0.08, 1)
	handle_mat.roughness = 0.6
	var handle_mesh := CylinderMesh.new()
	handle_mesh.top_radius = 0.02
	handle_mesh.bottom_radius = 0.025
	handle_mesh.height = 0.25
	handle_mesh.material = handle_mat
	var handle := MeshInstance3D.new()
	handle.mesh = handle_mesh
	handle.position = Vector3(0.0, -0.05, 0.0)
	handle.rotation_degrees = Vector3(90, 0, 0)
	_bat_node.add_child(handle)

	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.50, 0.35, 0.18, 1)
	barrel_mat.roughness = 0.7
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.035
	barrel_mesh.bottom_radius = 0.025
	barrel_mesh.height = 0.45
	barrel_mesh.material = barrel_mat
	var barrel := MeshInstance3D.new()
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0.0, 0.0, 0.35)
	barrel.rotation_degrees = Vector3(90, 0, 0)
	_bat_node.add_child(barrel)

	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = Color(0.55, 0.38, 0.20, 1)
	tip_mat.roughness = 0.65
	var tip_mesh := SphereMesh.new()
	tip_mesh.radius = 0.035
	tip_mesh.height = 0.07
	tip_mesh.material = tip_mat
	var tip := MeshInstance3D.new()
	tip.mesh = tip_mesh
	tip.position = Vector3(0.0, 0.0, 0.58)
	_bat_node.add_child(tip)

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
		"grenade_launcher": weapon_node = _grenade_launcher_node
		"bat": weapon_node = _bat_node

	if weapon_node == null:
		return global_position + Vector3(0, 1.0, 0)

	match _current_weapon:
		"shotgun":
			return weapon_node.global_transform * Vector3(0.0, 0.02, 0.34)
		"smg":
			return weapon_node.global_transform * Vector3(0.0, 0.04, 0.22)
		"grenade_launcher":
			return weapon_node.global_transform * Vector3(0.0, 0.04, 0.24)
		"bat":
			return weapon_node.global_transform * Vector3(0.0, 0.0, 0.5)
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
	var forward := _get_forward()
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
		return

	if not is_melee:
		ammo -= 1
	_shoot_timer = WeaponData.shoot_cooldown(_current_weapon)
	_fire_bullet()

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

func _fire_bullet() -> void:
	_apply_recoil()
	var hit_mode: String = _weapon_stats.get("hit_mode", "single")
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
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 40.0)
	var damage: float = _weapon_stats.get("damage", 10.0)
	var tolerance: float = _weapon_stats.get("hit_tolerance", 1.2)
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

	var result := _cast_ray(ray_origin, ray_end)
	var hit_enemy := false

	if result and result.collider is CharacterBody3D:
		var hit_body: CharacterBody3D = result.collider as CharacterBody3D
		if hit_body.has_method("take_damage"):
			hit_body.take_damage(damage, impulse)
			hit_enemy = true
			_spawn_hit_sparks(result.position)

	if not hit_enemy:
		var best_enemy: CharacterBody3D = null
		var best_dist := tolerance

		for node in get_tree().get_nodes_in_group("enemy"):
			if not is_instance_valid(node) or not node is CharacterBody3D:
				continue
			var enemy_body: CharacterBody3D = node as CharacterBody3D
			if not enemy_body.has_method("take_damage"):
				continue

			var enemy_pos: Vector3 = enemy_body.global_position + Vector3(0, 0.9, 0)
			var to_enemy := enemy_pos - ray_origin
			var proj := to_enemy.dot(forward)
			if proj < 0.0 or proj > weapon_range:
				continue

			var closest_on_ray := ray_origin + forward * proj
			var perp_dist := closest_on_ray.distance_to(enemy_pos)
			if perp_dist < best_dist:
				best_dist = perp_dist
				best_enemy = enemy_body

		if best_enemy != null:
			best_enemy.take_damage(damage, impulse)
			_spawn_hit_sparks(best_enemy.global_position + Vector3(0, 0.9, 0))

	_spawn_tracer(ray_origin, result.position if result else ray_end)

func _fire_pellet() -> void:
	# Real shotguns fire a shell of ~12 buckshot pellets that spread in a
	# cone. Each pellet is its own raycast: damage is only applied to the
	# body the pellet directly hits, so total damage scales with how many
	# pellets land on a given target — point-blank is devastating, while a
	# target on the edge of the cone at max range might only get clipped
	# by one or two. One shell = one pull of the trigger = one ammo tick.
	var forward := _get_forward()
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
	var forward := _get_forward()
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
	var forward := _get_forward()
	var weapon_range: float = _weapon_stats.get("range", 2.5)
	var damage: float = _weapon_stats.get("damage", 20.0)
	var sweep_angle: float = _weapon_stats.get("sweep_angle", 90.0)
	var half_sweep := deg_to_rad(sweep_angle * 0.5)
	var knockback: float = _weapon_stats.get("knockback", 0.0)

	var origin := global_position + Vector3(0, 0.9, 0)
	var hit_count := 0

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
			# Bat shove is roughly in the swing direction (the player's
			# forward), with a touch of away-from-player so the zombie
			# stumbles back rather than into the swing.
			var swing_dir: Vector3 = (forward + to_enemy.normalized() * 0.5).normalized()
			enemy_body.take_damage(damage, swing_dir * knockback)
			hit_count += 1
			_spawn_hit_sparks(enemy_body.global_position + Vector3(0, 0.9, 0))

	_spawn_swing_arc(origin, forward, weapon_range, half_sweep)

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

func _rotate_to_face_mouse(delta: float) -> void:
	if look_target == Vector3.INF:
		return
	var dir := look_target - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		return
	var target_angle := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, target_angle, ROTATION_SPEED * delta)

func _update_animation(delta: float) -> void:
	# Horizontal speed drives the walk cycle; scale the cycle faster and bigger
	# when sprinting so sprint visibly reads.
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	var speed_ratio := clampf(horiz_speed / SPEED, 0.0, 2.0)
	# Cycle frequency in radians/sec — ~2 full swings/sec at walking speed.
	var cycle_rate := 10.0 * speed_ratio
	_walk_phase = fposmod(_walk_phase + cycle_rate * delta, TAU)

	var clamped_ratio: float = clampf(speed_ratio, 0.0, 1.5)
	var leg_swing_amp := deg_to_rad(lerpf(3.0, 38.0, clamped_ratio))
	# A free arm hangs and pendulums broadly with the gait; a braced arm is
	# locked to the weapon and barely moves.
	var braced_arm_amp := deg_to_rad(lerpf(0.5, 4.0, clamped_ratio))
	var free_arm_amp := deg_to_rad(lerpf(2.0, 18.0, clamped_ratio))
	var bob_amp := lerpf(0.0, 0.04, clamped_ratio)

	var leg_swing := sin(_walk_phase) * leg_swing_amp
	var bob := absf(sin(_walk_phase)) * bob_amp
	# In a real walking gait, the arm on each side swings 180° out of phase
	# with the leg on the same side (left arm forward when left leg is back).
	# Left leg uses +sin → left arm uses -sin; right leg uses -sin → right
	# arm uses +sin.
	var right_amp := braced_arm_amp if _right_arm_braced else free_arm_amp
	var left_amp := braced_arm_amp if _left_arm_braced else free_arm_amp
	var left_sway := -sin(_walk_phase) * left_amp
	var right_sway :=  sin(_walk_phase) * right_amp

	# Legs still pivot at the hip on their scene-baked transform (origin at
	# leg center, mesh height 0.65 → hip offset 0.325).
	_set_pivoted_rotation(_leg_left, _leg_left_rest, 0.325, leg_swing)
	_set_pivoted_rotation(_leg_right, _leg_right_rest, 0.325, -leg_swing)

	# Fire animation: the LEFT shoulder + elbow drive the kick (it holds the
	# trigger). For guns this is a small barrel-rise + brief return; for the
	# bat it's a large negative pitch (swing forward from cocked) plus elbow
	# extension. The right (support) arm absorbs half the kick only when
	# it's bracing the weapon.
	_shoot_anim_timer = max(_shoot_anim_timer - delta, 0.0)
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

	if _left_shoulder:
		_left_shoulder.transform = _left_shoulder_rest * Transform3D(
			Basis(Vector3.RIGHT, left_sway + kick_pitch), Vector3.ZERO
		)
	if _left_elbow:
		_left_elbow.transform = _left_elbow_rest * Transform3D(
			Basis(Vector3.RIGHT, kick_elbow), Vector3.ZERO
		)
	if _right_shoulder:
		var right_kick: float = kick_pitch * (0.5 if _right_arm_braced else 0.0)
		_right_shoulder.transform = _right_shoulder_rest * Transform3D(
			Basis(Vector3.RIGHT, right_sway + right_kick), Vector3.ZERO
		)
	if _right_elbow and _right_arm_braced:
		# The support hand follows roughly half the elbow extension during
		# kick so the off-hand stays glued to the weapon's forend.
		_right_elbow.transform = _right_elbow_rest * Transform3D(
			Basis(Vector3.RIGHT, kick_elbow * 0.5), Vector3.ZERO
		)

	if _torso:
		var torso_xf := _torso_rest
		torso_xf.origin.y = _torso_rest.origin.y + bob
		_torso.transform = torso_xf

func _set_pivoted_rotation(node: Node3D, rest: Transform3D, pivot_y: float, angle: float) -> void:
	# Rotate `node` around the local point (0, pivot_y, 0) — e.g. the shoulder on
	# an arm mesh whose origin is at its midpoint. Formula: T(P) · R · T(-P).
	if node == null:
		return
	var rot := Basis(Vector3.RIGHT, angle)
	var pivot := Vector3(0.0, pivot_y, 0.0)
	node.transform = rest * Transform3D(rot, pivot - rot * pivot)

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
			hud.set_ammo(0, 0)
			hud.set_weapon_name("UNARMED")
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
