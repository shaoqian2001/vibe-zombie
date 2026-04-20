extends CharacterBody3D

## A zombie enemy that wanders, chases and attacks the player.

const SPEED := 2.0
const CHASE_SPEED := 3.5
const ACCELERATION := 8.0
const GRAVITY := 24.0
const WANDER_INTERVAL_MIN := 1.5
const WANDER_INTERVAL_MAX := 4.0

# Detection & attack
const DETECT_RANGE := 12.0
const ATTACK_RANGE := 1.8
const ATTACK_DAMAGE := 8.0
const ATTACK_COOLDOWN := 1.5

# HP
var max_hp := 30.0
var hp := 30.0

# Wander state
var _wander_dir := Vector3.ZERO
var _wander_timer := 0.0
var _rng := RandomNumberGenerator.new()

# Attack state
var _attack_timer := 0.0
var _player_ref: CharacterBody3D = null

# HP bar references
var _hp_bar_bg: MeshInstance3D
var _hp_bar_fg: MeshInstance3D

func _ready() -> void:
	add_to_group("enemy")
	_rng.randomize()
	_pick_new_wander()
	_build_model()
	_build_hp_bar()
	await get_tree().process_frame
	_player_ref = _find_player()

func _physics_process(delta: float) -> void:
	# Gravity
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= GRAVITY * delta

	_attack_timer = max(_attack_timer - delta, 0.0)

	var move_dir := Vector3.ZERO
	var current_speed := SPEED

	if _player_ref and is_instance_valid(_player_ref):
		var dist := global_position.distance_to(_player_ref.global_position)

		if dist < ATTACK_RANGE:
			# In attack range — stop and attack
			move_dir = Vector3.ZERO
			_try_attack()
		elif dist < DETECT_RANGE:
			# Chase player
			var to_player := _player_ref.global_position - global_position
			to_player.y = 0.0
			if to_player.length() > 0.1:
				move_dir = to_player.normalized()
			current_speed = CHASE_SPEED
		else:
			# Wander
			_wander_timer -= delta
			if _wander_timer <= 0.0:
				_pick_new_wander()
			move_dir = _wander_dir
	else:
		# No player found — just wander
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_pick_new_wander()
		move_dir = _wander_dir

	# Movement
	var target_xz := move_dir * current_speed
	velocity.x = move_toward(velocity.x, target_xz.x, ACCELERATION * delta)
	velocity.z = move_toward(velocity.z, target_xz.z, ACCELERATION * delta)

	# Rotate to face movement
	if move_dir.length() > 0.1:
		var target_angle := atan2(move_dir.x, move_dir.z)
		rotation.y = lerp_angle(rotation.y, target_angle, 6.0 * delta)

	move_and_slide()

	# Keep HP bar updated
	_update_hp_bar()

func take_damage(amount: float) -> void:
	hp = max(hp - amount, 0.0)
	if hp <= 0.0:
		queue_free()

func _try_attack() -> void:
	if _attack_timer > 0.0:
		return
	if _player_ref == null or not is_instance_valid(_player_ref):
		return
	_attack_timer = ATTACK_COOLDOWN
	if _player_ref.has_method("take_damage"):
		_player_ref.take_damage(ATTACK_DAMAGE)

func _find_player() -> CharacterBody3D:
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0] as CharacterBody3D
	# Fallback: search by name
	var root := get_tree().root
	var main := root.get_child(root.get_child_count() - 1) if root.get_child_count() > 0 else null
	if main and main.has_node("Player"):
		return main.get_node("Player") as CharacterBody3D
	return null

func _pick_new_wander() -> void:
	# 30% chance to idle, 70% chance to walk in a random direction
	if _rng.randf() < 0.3:
		_wander_dir = Vector3.ZERO
	else:
		var angle := _rng.randf_range(0.0, TAU)
		_wander_dir = Vector3(sin(angle), 0.0, cos(angle))
	_wander_timer = _rng.randf_range(WANDER_INTERVAL_MIN, WANDER_INTERVAL_MAX)

# ------------------------------------------------------------------
# Model construction (same shape as player, but zombie-coloured)
# ------------------------------------------------------------------

const ENEMY_WEAPON_SCENES := [
	preload("res://assets/weapons/Skeleton_Blade.gltf"),
	preload("res://assets/weapons/Skeleton_Axe.gltf"),
	preload("res://assets/weapons/Skeleton_Staff.gltf"),
]
const ENEMY_SHIELD_SCENES := [
	preload("res://assets/weapons/Skeleton_Shield_Small_A.gltf"),
	preload("res://assets/weapons/Skeleton_Shield_Small_B.gltf"),
]

func _build_model() -> void:
	var skin_tint := _rng.randf_range(-0.06, 0.06)
	var scale_var := _rng.randf_range(0.9, 1.1)

	# Skin palette for undead look
	var skin_r := clampf(0.48 + skin_tint, 0.35, 0.60)
	var skin_g := clampf(0.52 + skin_tint, 0.38, 0.62)
	var skin_b := clampf(0.38 + skin_tint, 0.28, 0.50)

	# Torso — blocky box style
	var torso_mat := StandardMaterial3D.new()
	torso_mat.albedo_color = Color(skin_r * 0.7, skin_g * 0.7, skin_b * 0.7, 1)
	torso_mat.roughness = 0.9
	var torso_mesh := BoxMesh.new()
	torso_mesh.size = Vector3(0.50 * scale_var, 0.42, 0.28 * scale_var)
	torso_mesh.material = torso_mat
	var torso := MeshInstance3D.new()
	torso.name = "Torso"
	torso.mesh = torso_mesh
	torso.position = Vector3(0, 1.05, 0)
	torso.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(torso)

	# Ragged shirt/vest overlay
	var cloth_colors := [
		Color(0.30, 0.15, 0.12), Color(0.18, 0.22, 0.15),
		Color(0.35, 0.30, 0.22), Color(0.20, 0.18, 0.25),
		Color(0.15, 0.15, 0.20), Color(0.28, 0.12, 0.10),
	]
	var shirt_mat := StandardMaterial3D.new()
	shirt_mat.albedo_color = cloth_colors[_rng.randi() % cloth_colors.size()]
	shirt_mat.roughness = 0.95
	var shirt_mesh := BoxMesh.new()
	shirt_mesh.size = Vector3(0.52 * scale_var, 0.36, 0.30 * scale_var)
	shirt_mesh.material = shirt_mat
	var shirt := MeshInstance3D.new()
	shirt.mesh = shirt_mesh
	shirt.position = Vector3(0, 1.08, 0)
	shirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(shirt)

	# Legs — box style
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = Color(0.18, 0.17, 0.15, 1)
	leg_mat.roughness = 0.9
	for side in [-1.0, 1.0]:
		var leg_mesh := BoxMesh.new()
		leg_mesh.size = Vector3(0.19 * scale_var, 0.44, 0.20 * scale_var)
		leg_mesh.material = leg_mat
		var leg := MeshInstance3D.new()
		leg.mesh = leg_mesh
		leg.position = Vector3(side * 0.12 * scale_var, 0.58, 0)
		leg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(leg)

	# Feet — dark blocky shoes
	var boot_mat := StandardMaterial3D.new()
	boot_mat.albedo_color = Color(0.10, 0.09, 0.08, 1)
	boot_mat.roughness = 0.8
	for side in [-1.0, 1.0]:
		var boot_mesh := BoxMesh.new()
		boot_mesh.size = Vector3(0.21 * scale_var, 0.16, 0.26 * scale_var)
		boot_mesh.material = boot_mat
		var boot := MeshInstance3D.new()
		boot.mesh = boot_mesh
		boot.position = Vector3(side * 0.12 * scale_var, 0.28, 0.02)
		boot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(boot)

	# Arms — box style with slight zombie slouch
	var arm_mat := StandardMaterial3D.new()
	arm_mat.albedo_color = Color(skin_r, skin_g, skin_b, 1)
	arm_mat.roughness = 0.9
	for side in [-1.0, 1.0]:
		var arm_mesh := BoxMesh.new()
		arm_mesh.size = Vector3(0.13 * scale_var, 0.42, 0.13 * scale_var)
		arm_mesh.material = arm_mat
		var arm := MeshInstance3D.new()
		arm.mesh = arm_mesh
		arm.position = Vector3(side * 0.33 * scale_var, 0.95, 0.06)
		arm.rotation_degrees = Vector3(_rng.randf_range(8, 30), 0, side * _rng.randf_range(-5, 15))
		arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(arm)

	# Hands — bony fists
	var hand_mat := StandardMaterial3D.new()
	hand_mat.albedo_color = Color(skin_r * 0.85, skin_g * 0.85, skin_b * 0.8, 1)
	hand_mat.roughness = 0.85
	for side in [-1.0, 1.0]:
		var hand_mesh := BoxMesh.new()
		hand_mesh.size = Vector3(0.14 * scale_var, 0.12, 0.14 * scale_var)
		hand_mesh.material = hand_mat
		var hand := MeshInstance3D.new()
		hand.mesh = hand_mesh
		hand.position = Vector3(side * 0.33 * scale_var, 0.70, 0.08)
		hand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(hand)

	# Head — large blocky head (chibi proportions)
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(skin_r, skin_g, skin_b, 1)
	head_mat.roughness = 0.8
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.40 * scale_var, 0.40 * scale_var, 0.38 * scale_var)
	head_mesh.material = head_mat
	var head := MeshInstance3D.new()
	head.name = "Head"
	head.mesh = head_mesh
	head.position = Vector3(0, 1.48, 0)
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(head)

	# Eyes: glowing red/yellow
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.9, 0.2, 0.05, 1)
	eye_mat.emission_enabled = true
	eye_mat.emission = Color(0.6, 0.08, 0.02)
	eye_mat.emission_energy_multiplier = 0.5
	for side in [-1.0, 1.0]:
		var eye_mesh := BoxMesh.new()
		eye_mesh.size = Vector3(0.10, 0.06, 0.04)
		eye_mesh.material = eye_mat
		var eye := MeshInstance3D.new()
		eye.mesh = eye_mesh
		eye.position = Vector3(side * 0.10, 1.52, 0.18)
		add_child(eye)

	# Mouth — dark gash
	var mouth_mat := StandardMaterial3D.new()
	mouth_mat.albedo_color = Color(0.15, 0.05, 0.05, 1)
	var mouth_mesh := BoxMesh.new()
	mouth_mesh.size = Vector3(0.18, 0.04, 0.03)
	mouth_mesh.material = mouth_mat
	var mouth := MeshInstance3D.new()
	mouth.mesh = mouth_mesh
	mouth.position = Vector3(0, 1.38, 0.18)
	add_child(mouth)

	# Torn clothing patches on torso
	for _i in range(_rng.randi_range(1, 3)):
		var patch_mat := StandardMaterial3D.new()
		patch_mat.albedo_color = cloth_colors[_rng.randi() % cloth_colors.size()]
		patch_mat.roughness = 0.95
		var patch_mesh := BoxMesh.new()
		patch_mesh.size = Vector3(
			_rng.randf_range(0.10, 0.22),
			_rng.randf_range(0.10, 0.22),
			0.01
		)
		patch_mesh.material = patch_mat
		var patch := MeshInstance3D.new()
		patch.mesh = patch_mesh
		patch.position = Vector3(
			_rng.randf_range(-0.18, 0.18),
			_rng.randf_range(0.9, 1.2),
			0.15
		)
		patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(patch)

	# Blood splatters
	for _i in range(_rng.randi_range(2, 4)):
		_add_blood_splat(
			Vector3(
				_rng.randf_range(-0.20, 0.20),
				_rng.randf_range(0.5, 1.4),
				_rng.randf_range(0.12, 0.25)
			),
			_rng.randf_range(0.04, 0.10)
		)

	# Skeleton weapon accessory — 70% chance to carry one
	if _rng.randf() < 0.7:
		var weapon_scene: PackedScene = ENEMY_WEAPON_SCENES[_rng.randi() % ENEMY_WEAPON_SCENES.size()]
		var weapon_inst := weapon_scene.instantiate()
		weapon_inst.scale = Vector3(0.3, 0.3, 0.3)
		weapon_inst.position = Vector3(0.35, 0.75, 0.0)
		weapon_inst.rotation_degrees = Vector3(0, _rng.randf_range(-30, 30), -90)
		add_child(weapon_inst)

	# Shield on left side — 30% chance
	if _rng.randf() < 0.3:
		var shield_scene: PackedScene = ENEMY_SHIELD_SCENES[_rng.randi() % ENEMY_SHIELD_SCENES.size()]
		var shield_inst := shield_scene.instantiate()
		shield_inst.scale = Vector3(0.35, 0.35, 0.35)
		shield_inst.position = Vector3(-0.38, 0.95, 0.05)
		shield_inst.rotation_degrees = Vector3(0, 90, 0)
		add_child(shield_inst)

	# Collision shape
	var coll_shape := CapsuleShape3D.new()
	coll_shape.radius = 0.34
	coll_shape.height = 1.8
	var cs := CollisionShape3D.new()
	cs.shape = coll_shape
	cs.position = Vector3(0, 0.9, 0)
	add_child(cs)

func _add_blood_splat(pos: Vector3, size: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.08, 0.06, 1)

	var mesh := SphereMesh.new()
	mesh.radius = size
	mesh.height = size * 1.4
	mesh.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)

# ------------------------------------------------------------------
# HP bar (billboard above head)
# ------------------------------------------------------------------

const HP_BAR_WIDTH := 0.8
const HP_BAR_HEIGHT := 0.08
const HP_BAR_Y := 2.2

func _build_hp_bar() -> void:
	# Background (dark)
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.15, 0.15, 0.15, 0.9)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.no_depth_test = true
	bg_mat.render_priority = 10

	var bg_mesh := QuadMesh.new()
	bg_mesh.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	bg_mesh.material = bg_mat

	_hp_bar_bg = MeshInstance3D.new()
	_hp_bar_bg.name = "HPBarBG"
	_hp_bar_bg.mesh = bg_mesh
	_hp_bar_bg.position = Vector3(0, HP_BAR_Y, 0)
	add_child(_hp_bar_bg)

	# Foreground (red)
	var fg_mat := StandardMaterial3D.new()
	fg_mat.albedo_color = Color(0.8, 0.15, 0.1, 0.95)
	fg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fg_mat.no_depth_test = true
	fg_mat.render_priority = 11

	var fg_mesh := QuadMesh.new()
	fg_mesh.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	fg_mesh.material = fg_mat

	_hp_bar_fg = MeshInstance3D.new()
	_hp_bar_fg.name = "HPBarFG"
	_hp_bar_fg.mesh = fg_mesh
	_hp_bar_fg.position = Vector3(0, HP_BAR_Y, 0)
	add_child(_hp_bar_fg)

func _update_hp_bar() -> void:
	if _hp_bar_fg == null:
		return
	var ratio := hp / max_hp
	# Resize the quad mesh directly so billboard doesn't fight with scale
	var fg_mesh := _hp_bar_fg.mesh as QuadMesh
	fg_mesh.size.x = HP_BAR_WIDTH * ratio
	# Shift left so the bar shrinks from right to left
	_hp_bar_fg.position.x = -HP_BAR_WIDTH * (1.0 - ratio) * 0.5
