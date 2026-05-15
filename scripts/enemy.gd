extends CharacterBody3D

## A zombie enemy that wanders, chases and attacks the player.
##
## Networking model:
##   - The server (peer 1) is the authority for every enemy. Only the host
##     runs movement, AI and damage application.
##   - Clients receive transform updates via _sync_transform() pushed from the
##     host (host-side push, ~20Hz, unreliable_ordered).
##   - Damage from a client weapon is forwarded to the host via _request_damage.
##   - On death, the host calls _despawn() on every peer, so all copies of the
##     node disappear in lockstep.

const FovCuller = preload("res://scripts/fov_culler.gd")

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

# Network sync
const NET_SYNC_HZ := 20.0
const NET_SYNC_INTERVAL := 1.0 / NET_SYNC_HZ

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

# Knockback: short-lived velocity impulse applied on top of AI movement
# whenever take_damage(amount, impulse) is called. Decays exponentially
# so even a small kick lasts only a fraction of a second.
const KNOCKBACK_DECAY := 8.0
var _knockback: Vector3 = Vector3.ZERO

# HP bar references
var _hp_bar_bg: MeshInstance3D
var _hp_bar_fg: MeshInstance3D

# Network state
var _net_sync_timer := 0.0
var _is_authority_cached := true

# Cached target supplied by main.gd's parallel AI coordinator (host only).
# Vector3.INF means "no cached value, fall back to the single-threaded search".
var cached_target_pos: Vector3 = Vector3.INF

func _ready() -> void:
	add_to_group("enemy")
	# Host (peer id 1) owns every enemy. In single-player this is just self.
	if NetworkManager.is_networked:
		set_multiplayer_authority(1)
	_is_authority_cached = (not NetworkManager.is_networked) or is_multiplayer_authority()
	# FOV culling: enemies are "moving" entities. They fade to a ghosted
	# snapshot as soon as they leave the player's sector and disappear
	# entirely once they're more than ~6 units past it ("a few meters
	# behind you"). We do NOT freeze _physics_process — the enemy must
	# keep moving while off-screen, just with a different behaviour mode
	# (wander instead of chase, see _physics_process below) so the world
	# isn't full of statues whenever the player turns their head.
	add_to_group(&"fov_cullable")
	set_meta(&"fov_cull_radius", 0.6)
	set_meta(&"fov_cull_entity_type", "moving")
	set_meta(&"fov_cull_memory_range", 6.0)
	_rng.randomize()
	_pick_new_wander()
	_build_model()
	_build_hp_bar()
	# Drape every body part in the same vision-shadow overlay the world
	# uses, so a zombie smoothly darkens as it leaves the player's sector
	# instead of snapping. The HP bar opts out via its own material_overlay
	# set in _build_hp_bar (see apply_shader_to_subtree's idempotent check).
	FovCuller.apply_shader_to_subtree(self)
	await get_tree().process_frame
	_player_ref = _find_player()

func _physics_process(delta: float) -> void:
	if not _is_authority_cached:
		# Client copy — host pushes transform updates via RPC. Just refresh
		# the HP bar (HP is replicated separately) and exit.
		_update_hp_bar()
		return

	# Gravity
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= GRAVITY * delta

	_attack_timer = max(_attack_timer - delta, 0.0)

	# Prefer the position computed by main.gd's parallel AI coordinator
	# (host only). Fall back to a direct lookup when no cache is available
	# — single-player, the first frame, or when the host hasn't filled it
	# in yet for this enemy. Zombie AI is independent of player FOV — the
	# zombie tracks by ear/smell, so it always chases/attacks/wanders
	# regardless of whether the player is looking at it. The FOV culler
	# only changes how the zombie is *drawn*.
	var target_pos: Vector3 = cached_target_pos
	if target_pos == Vector3.INF:
		if _player_ref == null or not is_instance_valid(_player_ref):
			_player_ref = _find_player()
		if _player_ref:
			target_pos = _player_ref.global_position

	var move_dir := Vector3.ZERO
	var current_speed := SPEED

	if target_pos != Vector3.INF:
		var dist := global_position.distance_to(target_pos)

		if dist < ATTACK_RANGE:
			# In attack range — stop and attack
			move_dir = Vector3.ZERO
			_try_attack_at(target_pos)
		elif dist < DETECT_RANGE:
			# Chase the player — zombie always chases, FOV doesn't gate.
			var to_target := target_pos - global_position
			to_target.y = 0.0
			if to_target.length() > 0.1:
				move_dir = to_target.normalized()
			current_speed = CHASE_SPEED
		else:
			# Too far — wander
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

	# AI-driven horizontal velocity
	var target_xz := move_dir * current_speed
	velocity.x = move_toward(velocity.x, target_xz.x, ACCELERATION * delta)
	velocity.z = move_toward(velocity.z, target_xz.z, ACCELERATION * delta)

	# Knockback impulse (decays exponentially). Added on top so a hit
	# briefly shoves the zombie even mid-chase, but never overwhelms
	# normal locomotion for long.
	velocity.x += _knockback.x
	velocity.z += _knockback.z
	var decay := exp(-KNOCKBACK_DECAY * delta)
	_knockback.x *= decay
	_knockback.z *= decay

	# Rotate to face movement
	if move_dir.length() > 0.1:
		var target_angle := atan2(move_dir.x, move_dir.z)
		rotation.y = lerp_angle(rotation.y, target_angle, 6.0 * delta)

	move_and_slide()

	# Keep HP bar updated
	_update_hp_bar()

	# Push transform to remote peers at a fixed rate (host only).
	if NetworkManager.is_networked:
		_net_sync_timer -= delta
		if _net_sync_timer <= 0.0:
			_net_sync_timer = NET_SYNC_INTERVAL
			rpc("_sync_transform", global_position, rotation.y)

@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_transform(pos: Vector3, yaw: float) -> void:
	# Smooth-snap on the client side. Distance check avoids visible jumps from
	# packet jitter while keeping us in sync over time.
	if global_position.distance_to(pos) > 4.0:
		global_position = pos
	else:
		global_position = global_position.lerp(pos, 0.5)
	rotation.y = yaw

@rpc("authority", "call_remote", "reliable")
func _sync_hp(new_hp: float) -> void:
	hp = new_hp
	_update_hp_bar()

@rpc("authority", "call_remote", "reliable")
func _despawn() -> void:
	queue_free()


func take_damage(amount: float, knockback: Vector3 = Vector3.ZERO) -> void:
	# In multiplayer, only the authority (host) mutates state. Clients
	# forward the request via RPC so the host can apply, replicate and
	# despawn. The impulse rides along so knockback stays consistent.
	if NetworkManager.is_networked and not is_multiplayer_authority():
		rpc_id(1, "_request_damage", amount, knockback)
		return
	_apply_damage(amount, knockback)

@rpc("any_peer", "call_remote", "reliable")
func _request_damage(amount: float, knockback: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	_apply_damage(amount, knockback)

func _apply_damage(amount: float, knockback: Vector3 = Vector3.ZERO) -> void:
	hp = max(hp - amount, 0.0)
	if NetworkManager.is_networked:
		rpc("_sync_hp", hp)
	# Apply the bullet's impulse on the XZ plane only — getting shot
	# shouldn't lift a zombie off the ground.
	if knockback.length_squared() > 0.0:
		_knockback.x += knockback.x
		_knockback.z += knockback.z
	if hp <= 0.0:
		# Notify mission system of kill (host only — mission system is host-side)
		var mission_nodes := get_tree().get_nodes_in_group("mission_system")
		for ms in mission_nodes:
			if ms.has_method("notify_enemy_killed"):
				ms.notify_enemy_killed()
		if NetworkManager.is_networked:
			rpc("_despawn")
		queue_free()

func _try_attack() -> void:
	_try_attack_at(_player_ref.global_position if _player_ref else Vector3.INF)

func _try_attack_at(target_pos: Vector3) -> void:
	if _attack_timer > 0.0 or target_pos == Vector3.INF:
		return
	# Prefer the cached _player_ref. If it isn't current (the closest player
	# changed mid-tick), refresh from the player group.
	if _player_ref == null or not is_instance_valid(_player_ref) \
			or _player_ref.global_position.distance_to(target_pos) > 0.5:
		_player_ref = _find_closest_player(target_pos)
	if _player_ref == null:
		return
	_attack_timer = ATTACK_COOLDOWN
	if _player_ref.has_method("take_damage"):
		_player_ref.take_damage(ATTACK_DAMAGE)

func _find_closest_player(near: Vector3) -> CharacterBody3D:
	var best: CharacterBody3D = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(n):
			continue
		var p: CharacterBody3D = n as CharacterBody3D
		var d: float = p.global_position.distance_squared_to(near)
		if d < best_d:
			best_d = d
			best = p
	return best

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

func _build_model() -> void:
	var skin_tint := _rng.randf_range(-0.06, 0.06)
	var scale_var := _rng.randf_range(0.9, 1.1)

	# Torso (upper body)
	var torso_mat := StandardMaterial3D.new()
	torso_mat.albedo_color = Color(0.35 + skin_tint, 0.40 + skin_tint, 0.30 + skin_tint, 1)
	torso_mat.roughness = 0.9
	var torso_mesh := BoxMesh.new()
	torso_mesh.size = Vector3(0.52 * scale_var, 0.7, 0.30 * scale_var)
	torso_mesh.material = torso_mat
	var torso := MeshInstance3D.new()
	torso.name = "Torso"
	torso.mesh = torso_mesh
	torso.position = Vector3(0, 1.15, 0)
	torso.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(torso)

	# Legs
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = Color(0.22, 0.22, 0.20, 1)
	leg_mat.roughness = 0.9
	for side in [-1.0, 1.0]:
		var leg_mesh := BoxMesh.new()
		leg_mesh.size = Vector3(0.18 * scale_var, 0.7, 0.20 * scale_var)
		leg_mesh.material = leg_mat
		var leg := MeshInstance3D.new()
		leg.mesh = leg_mesh
		leg.position = Vector3(side * 0.13 * scale_var, 0.35, 0)
		leg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(leg)

	# Arms
	var arm_mat := StandardMaterial3D.new()
	arm_mat.albedo_color = Color(0.38 + skin_tint, 0.42 + skin_tint, 0.32 + skin_tint, 1)
	arm_mat.roughness = 0.9
	for side in [-1.0, 1.0]:
		var arm_mesh := CylinderMesh.new()
		arm_mesh.top_radius = 0.06 * scale_var
		arm_mesh.bottom_radius = 0.07 * scale_var
		arm_mesh.height = 0.65
		arm_mesh.material = arm_mat
		var arm := MeshInstance3D.new()
		arm.mesh = arm_mesh
		arm.position = Vector3(side * 0.34 * scale_var, 1.0, 0.05)
		arm.rotation_degrees = Vector3(_rng.randf_range(5, 25), 0, side * _rng.randf_range(-10, 10))
		arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(arm)

	# Head
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.55 + skin_tint, 0.50 + skin_tint, 0.40 + skin_tint, 1)
	head_mat.roughness = 0.85
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.22 * scale_var
	head_mesh.height = 0.44 * scale_var
	head_mesh.material = head_mat
	var head := MeshInstance3D.new()
	head.name = "Head"
	head.mesh = head_mesh
	head.position = Vector3(0, 1.65, 0)
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(head)

	# Eyes: bloodshot red/yellow
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.7, 0.15, 0.08, 1)
	eye_mat.emission_enabled = true
	eye_mat.emission = Color(0.4, 0.05, 0.02)
	eye_mat.emission_energy_multiplier = 0.3
	var eye_mesh := SphereMesh.new()
	eye_mesh.radius = 0.05
	eye_mesh.height = 0.10
	eye_mesh.material = eye_mat
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		eye.mesh = eye_mesh
		eye.position = Vector3(side * 0.08, 1.68, 0.18)
		add_child(eye)

	# Torn clothing patches
	var cloth_colors := [
		Color(0.30, 0.15, 0.12), Color(0.18, 0.22, 0.15),
		Color(0.35, 0.30, 0.22), Color(0.20, 0.18, 0.25),
	]
	var cloth_mat := StandardMaterial3D.new()
	cloth_mat.albedo_color = cloth_colors[_rng.randi() % cloth_colors.size()]
	cloth_mat.roughness = 0.95
	for _i in range(_rng.randi_range(1, 3)):
		var patch_mesh := BoxMesh.new()
		patch_mesh.size = Vector3(
			_rng.randf_range(0.12, 0.25),
			_rng.randf_range(0.15, 0.30),
			_rng.randf_range(0.08, 0.15)
		)
		patch_mesh.material = cloth_mat
		var patch := MeshInstance3D.new()
		patch.mesh = patch_mesh
		patch.position = Vector3(
			_rng.randf_range(-0.20, 0.20),
			_rng.randf_range(0.8, 1.4),
			_rng.randf_range(0.10, 0.22)
		)
		patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(patch)

	# Blood splatters (randomized placement)
	var splat_count := _rng.randi_range(2, 5)
	for _i in range(splat_count):
		_add_blood_splat(
			Vector3(
				_rng.randf_range(-0.22, 0.22),
				_rng.randf_range(0.5, 1.5),
				_rng.randf_range(0.12, 0.28)
			),
			_rng.randf_range(0.05, 0.14)
		)

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
	# HP bars use no_depth_test billboards; the shadow overlay's depth
	# state would fight that and produce flicker against far geometry.
	_hp_bar_bg.set_meta(FovCuller.META_SHADOW_EXEMPT, true)
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
	_hp_bar_fg.set_meta(FovCuller.META_SHADOW_EXEMPT, true)
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
