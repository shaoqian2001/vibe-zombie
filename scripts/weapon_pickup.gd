extends Area3D

## A weapon pickup that floats and rotates on the ground.
## When the player walks into it, the weapon is added to their inventory.

var weapon_type: String = "pistol"

var _model: Node3D = null
var _glow: MeshInstance3D = null
var _bob_time: float = 0.0
var _base_y: float = 0.0

const BOB_SPEED := 2.0
const BOB_AMPLITUDE := 0.15
const ROTATE_SPEED := 1.5
const FLOAT_HEIGHT := 0.7
const PICKUP_RADIUS := 1.5

func _ready() -> void:
	_base_y = global_position.y + FLOAT_HEIGHT

	# Collision for trigger detection
	var shape := SphereShape3D.new()
	shape.radius = PICKUP_RADIUS
	var cs := CollisionShape3D.new()
	cs.shape = shape
	add_child(cs)

	monitoring = true
	monitorable = false
	collision_layer = 0
	collision_mask = 1

	body_entered.connect(_on_body_entered)

	_build_model()
	_build_glow()

func _process(delta: float) -> void:
	_bob_time += delta
	if _model:
		_model.position.y = _base_y + sin(_bob_time * BOB_SPEED) * BOB_AMPLITUDE
		_model.rotation.y += ROTATE_SPEED * delta

func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	# Only the body's owning peer collects — otherwise every peer would grant
	# the same pickup to their local copy.
	if NetworkManager.is_networked:
		if body.has_method("is_multiplayer_authority") and not body.is_multiplayer_authority():
			return
	if body.has_method("pickup_weapon"):
		body.pickup_weapon(weapon_type)
	# Tell every peer (including ourselves) to despawn this pickup node.
	if NetworkManager.is_networked:
		rpc("_despawn_pickup")
	queue_free()

@rpc("any_peer", "call_remote", "reliable")
func _despawn_pickup() -> void:
	queue_free()

# ------------------------------------------------------------------
# Procedural weapon model (miniature version for pickup display)
# ------------------------------------------------------------------

func _build_model() -> void:
	_model = Node3D.new()
	_model.name = "PickupModel"
	_model.position.y = _base_y
	add_child(_model)

	match weapon_type:
		"pistol": _build_pistol_model()
		"shotgun": _build_shotgun_model()
		"smg": _build_smg_model()
		"grenade_launcher": _build_grenade_launcher_model()
		"bat": _build_bat_model()

func _build_pistol_model() -> void:
	var grip_mat := StandardMaterial3D.new()
	grip_mat.albedo_color = Color(0.15, 0.15, 0.15, 1)
	var grip_mesh := BoxMesh.new()
	grip_mesh.size = Vector3(0.10, 0.22, 0.12)
	grip_mesh.material = grip_mat
	var grip := MeshInstance3D.new()
	grip.mesh = grip_mesh
	grip.position = Vector3(0.0, -0.06, 0.0)
	_model.add_child(grip)

	var slide_mat := StandardMaterial3D.new()
	slide_mat.albedo_color = Color(0.22, 0.22, 0.24, 1)
	var slide_mesh := BoxMesh.new()
	slide_mesh.size = Vector3(0.09, 0.09, 0.28)
	slide_mesh.material = slide_mat
	var slide := MeshInstance3D.new()
	slide.mesh = slide_mesh
	slide.position = Vector3(0.0, 0.08, 0.04)
	_model.add_child(slide)

	var muzzle_mat := StandardMaterial3D.new()
	muzzle_mat.albedo_color = Color(0.10, 0.10, 0.10, 1)
	var muzzle_mesh := CylinderMesh.new()
	muzzle_mesh.top_radius = 0.025
	muzzle_mesh.bottom_radius = 0.025
	muzzle_mesh.height = 0.05
	muzzle_mesh.material = muzzle_mat
	var muzzle := MeshInstance3D.new()
	muzzle.mesh = muzzle_mesh
	muzzle.position = Vector3(0.0, 0.08, 0.18)
	muzzle.rotation_degrees = Vector3(90, 0, 0)
	_model.add_child(muzzle)

func _build_shotgun_model() -> void:
	var stock_mat := StandardMaterial3D.new()
	stock_mat.albedo_color = Color(0.40, 0.26, 0.13, 1)
	var stock_mesh := BoxMesh.new()
	stock_mesh.size = Vector3(0.11, 0.12, 0.22)
	stock_mesh.material = stock_mat
	var stock := MeshInstance3D.new()
	stock.mesh = stock_mesh
	stock.position = Vector3(0.0, -0.02, -0.18)
	_model.add_child(stock)

	var receiver_mat := StandardMaterial3D.new()
	receiver_mat.albedo_color = Color(0.18, 0.18, 0.20, 1)
	var receiver_mesh := BoxMesh.new()
	receiver_mesh.size = Vector3(0.10, 0.10, 0.14)
	receiver_mesh.material = receiver_mat
	var receiver := MeshInstance3D.new()
	receiver.mesh = receiver_mesh
	receiver.position = Vector3(0.0, 0.0, -0.02)
	_model.add_child(receiver)

	var forend_mat := StandardMaterial3D.new()
	forend_mat.albedo_color = Color(0.45, 0.30, 0.15, 1)
	var forend_mesh := BoxMesh.new()
	forend_mesh.size = Vector3(0.11, 0.08, 0.12)
	forend_mesh.material = forend_mat
	var forend := MeshInstance3D.new()
	forend.mesh = forend_mesh
	forend.position = Vector3(0.0, -0.02, 0.12)
	_model.add_child(forend)

	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.12, 0.12, 0.14, 1)
	for i in range(2):
		var offset_x := -0.03 + i * 0.06
		var barrel_mesh := CylinderMesh.new()
		barrel_mesh.top_radius = 0.03
		barrel_mesh.bottom_radius = 0.03
		barrel_mesh.height = 0.34
		barrel_mesh.material = barrel_mat
		var barrel := MeshInstance3D.new()
		barrel.mesh = barrel_mesh
		barrel.position = Vector3(offset_x, 0.02, 0.22)
		barrel.rotation_degrees = Vector3(90, 0, 0)
		_model.add_child(barrel)

func _build_smg_model() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.20, 0.20, 0.22, 1)
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.09, 0.12, 0.36)
	body_mesh.material = body_mat
	var body_mi := MeshInstance3D.new()
	body_mi.mesh = body_mesh
	body_mi.position = Vector3(0.0, 0.04, 0.06)
	_model.add_child(body_mi)

	var mag_mat := StandardMaterial3D.new()
	mag_mat.albedo_color = Color(0.15, 0.15, 0.15, 1)
	var mag_mesh := BoxMesh.new()
	mag_mesh.size = Vector3(0.06, 0.18, 0.08)
	mag_mesh.material = mag_mat
	var mag := MeshInstance3D.new()
	mag.mesh = mag_mesh
	mag.position = Vector3(0.0, -0.10, 0.06)
	_model.add_child(mag)

func _build_grenade_launcher_model() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.28, 0.30, 0.22, 1)
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.12, 0.12, 0.24)
	body_mesh.material = body_mat
	var body_mi := MeshInstance3D.new()
	body_mi.mesh = body_mesh
	body_mi.position = Vector3(0.0, 0.0, -0.02)
	_model.add_child(body_mi)

	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.15, 0.16, 0.14, 1)
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.05
	barrel_mesh.bottom_radius = 0.05
	barrel_mesh.height = 0.26
	barrel_mesh.material = barrel_mat
	var barrel := MeshInstance3D.new()
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0.0, 0.02, 0.18)
	barrel.rotation_degrees = Vector3(90, 0, 0)
	_model.add_child(barrel)

func _build_bat_model() -> void:
	var handle_mat := StandardMaterial3D.new()
	handle_mat.albedo_color = Color(0.15, 0.12, 0.08, 1)
	var handle_mesh := CylinderMesh.new()
	handle_mesh.top_radius = 0.025
	handle_mesh.bottom_radius = 0.03
	handle_mesh.height = 0.30
	handle_mesh.material = handle_mat
	var handle := MeshInstance3D.new()
	handle.mesh = handle_mesh
	handle.position = Vector3(0.0, -0.05, 0.0)
	_model.add_child(handle)

	var barrel_mat := StandardMaterial3D.new()
	barrel_mat.albedo_color = Color(0.50, 0.35, 0.18, 1)
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.04
	barrel_mesh.bottom_radius = 0.03
	barrel_mesh.height = 0.50
	barrel_mesh.material = barrel_mat
	var barrel := MeshInstance3D.new()
	barrel.mesh = barrel_mesh
	barrel.position = Vector3(0.0, 0.30, 0.0)
	_model.add_child(barrel)

func _build_glow() -> void:
	var glow_mat := StandardMaterial3D.new()
	var glow_colors := {
		"pistol": Color(0.3, 0.6, 1.0, 0.35),
		"shotgun": Color(1.0, 0.5, 0.2, 0.35),
		"smg": Color(0.4, 1.0, 0.4, 0.35),
		"grenade_launcher": Color(1.0, 0.3, 0.1, 0.35),
		"bat": Color(0.8, 0.6, 0.2, 0.35),
	}
	glow_mat.albedo_color = glow_colors.get(weapon_type, Color(0.5, 0.5, 0.5, 0.35))
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.no_depth_test = false

	var glow_mesh := CylinderMesh.new()
	glow_mesh.top_radius = 0.6
	glow_mesh.bottom_radius = 0.6
	glow_mesh.height = 0.02
	glow_mesh.material = glow_mat

	_glow = MeshInstance3D.new()
	_glow.mesh = glow_mesh
	_glow.position = Vector3(0, 0.01, 0)
	_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_glow)
