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

const _CharacterScene := preload("res://assets/characters/db87f3b8fab54264877c86937fa42b22.gltf")
const _NUM_VARIANTS := 6

func _build_model() -> void:
	var variant_idx := _rng.randi() % _NUM_VARIANTS
	var scale_var := _rng.randf_range(0.85, 1.05)

	var scene_inst := _CharacterScene.instantiate()
	var mesh_parent := _find_mesh_parent(scene_inst)
	if mesh_parent:
		var idx := 0
		for child in mesh_parent.get_children():
			if child is Node3D:
				if idx == variant_idx:
					(child as Node3D).position = Vector3.ZERO
					child.visible = true
				else:
					child.visible = false
				idx += 1

	scene_inst.scale = Vector3.ONE * scale_var
	scene_inst.position = Vector3(0.0, 0.0, 0.0)
	add_child(scene_inst)

	# Collision shape
	var coll_shape := CapsuleShape3D.new()
	coll_shape.radius = 0.34
	coll_shape.height = 1.8
	var cs := CollisionShape3D.new()
	cs.shape = coll_shape
	cs.position = Vector3(0, 0.9, 0)
	add_child(cs)

static func _find_mesh_parent(node: Node) -> Node:
	var child_count := 0
	for child in node.get_children():
		if child is Node3D:
			child_count += 1
	if child_count >= 6:
		return node
	for child in node.get_children():
		var result := _find_mesh_parent(child)
		if result:
			return result
	return null

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
