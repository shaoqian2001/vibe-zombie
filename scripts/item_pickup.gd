extends Area3D

## A consumable / equipment pickup that floats and rotates on the ground.
## The item-system counterpart to weapon_pickup.gd: when the local player walks
## into it, the item is applied via Player.pickup_item() and the pickup despawns
## across all peers. Items spawn mostly inside buildings (see main._spawn_items).

const FovCuller = preload("res://scripts/fov_culler.gd")

var item_id: String = "apple"
# GD-Sync replication id, assigned by main.gd (matches node name "ItemPickup_<id>").
var network_id: int = -1

var _model: Node3D = null
var _glow: MeshInstance3D = null
var _bob_time: float = 0.0
var _base_y: float = 0.0

const BOB_SPEED := 2.0
const BOB_AMPLITUDE := 0.12
const ROTATE_SPEED := 1.2
const FLOAT_HEIGHT := 0.55
const PICKUP_RADIUS := 1.3

func _ready() -> void:
	_base_y = global_position.y + FLOAT_HEIGHT

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

	# FOV culling: hidden while outside the player's view sector (process stays
	# active so body_entered still fires on an unseen pickup). Mirrors the
	# weapon-pickup treatment.
	add_to_group(&"fov_cullable")
	set_meta(&"fov_cull_radius", 0.8)

	_build_model()
	_build_glow()
	FovCuller.apply_shader_to_subtree(self)

func _process(delta: float) -> void:
	_bob_time += delta
	if _model:
		_model.position.y = _base_y + sin(_bob_time * BOB_SPEED) * BOB_AMPLITUDE
		_model.rotation.y += ROTATE_SPEED * delta

func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return
	# Only the locally-controlled player collects, otherwise every peer would
	# grant the same pickup to their own copy.
	if NetworkManager.is_networked and not bool(body.get("is_local_player")):
		return
	if body.has_method("pickup_item"):
		body.pickup_item(item_id)
	# Tell every peer (including the host) to drop this pickup so it stops
	# appearing in item_state.
	if NetworkManager.is_networked:
		NetworkManager.broadcast_event("item_despawn", {"id": network_id})
	queue_free()

# ------------------------------------------------------------------
# Procedural item model (miniature display version)
# ------------------------------------------------------------------

func _build_model() -> void:
	_model = Node3D.new()
	_model.name = "PickupModel"
	_model.position.y = _base_y
	add_child(_model)

	match item_id:
		"apple": _build_apple_model()
		"medkit": _build_medkit_model()
		"energy_drink": _build_energy_drink_model()
		"body_armor": _build_body_armor_model()
		"backpack": _build_backpack_model()
		"tactical_shoes": _build_shoes_model()
		"wood": _build_wood_model()
		"scrap": _build_scrap_model()
		_: _build_apple_model()

func _mat(color: Color, rough: float = 0.7) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m

func _box(size: Vector3, color: Color, pos: Vector3, rough: float = 0.7) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _mat(color, rough)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	_model.add_child(mi)

func _cyl(radius: float, height: float, color: Color, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.material = _mat(color)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot_deg
	_model.add_child(mi)

func _build_apple_model() -> void:
	var body_mesh := SphereMesh.new()
	body_mesh.radius = 0.12
	body_mesh.height = 0.22
	body_mesh.material = _mat(Color(0.85, 0.18, 0.16, 1), 0.4)
	var body := MeshInstance3D.new()
	body.mesh = body_mesh
	body.position = Vector3(0.0, 0.0, 0.0)
	_model.add_child(body)
	# Stem.
	_cyl(0.012, 0.08, Color(0.32, 0.22, 0.12, 1), Vector3(0.0, 0.13, 0.0))
	# Leaf.
	_box(Vector3(0.09, 0.012, 0.05), Color(0.30, 0.62, 0.22, 1), Vector3(0.06, 0.15, 0.0))

func _build_medkit_model() -> void:
	_box(Vector3(0.26, 0.18, 0.18), Color(0.92, 0.92, 0.92, 1), Vector3(0.0, 0.0, 0.0), 0.5)
	# Red cross on the front face.
	_box(Vector3(0.13, 0.04, 0.02), Color(0.85, 0.15, 0.12, 1), Vector3(0.0, 0.0, 0.10))
	_box(Vector3(0.04, 0.13, 0.02), Color(0.85, 0.15, 0.12, 1), Vector3(0.0, 0.0, 0.10))

func _build_energy_drink_model() -> void:
	# Slim can body.
	_cyl(0.07, 0.26, Color(0.18, 0.18, 0.22, 1), Vector3(0.0, 0.0, 0.0))
	# Bright label band.
	_cyl(0.072, 0.10, Color(0.95, 0.80, 0.15, 1), Vector3(0.0, 0.0, 0.0))
	# Lid.
	_cyl(0.055, 0.02, Color(0.70, 0.70, 0.74, 1), Vector3(0.0, 0.14, 0.0))

func _build_body_armor_model() -> void:
	# Vest torso plate.
	_box(Vector3(0.24, 0.26, 0.10), Color(0.22, 0.30, 0.42, 1), Vector3(0.0, 0.0, 0.0), 0.5)
	# Shoulder straps.
	_box(Vector3(0.07, 0.10, 0.12), Color(0.16, 0.22, 0.32, 1), Vector3(-0.11, 0.16, 0.0))
	_box(Vector3(0.07, 0.10, 0.12), Color(0.16, 0.22, 0.32, 1), Vector3(0.11, 0.16, 0.0))

func _build_backpack_model() -> void:
	# Main compartment.
	_box(Vector3(0.24, 0.28, 0.16), Color(0.40, 0.28, 0.16, 1), Vector3(0.0, 0.0, 0.0), 0.7)
	# Top lid pocket.
	_box(Vector3(0.22, 0.10, 0.15), Color(0.34, 0.24, 0.14, 1), Vector3(0.0, 0.17, 0.01))
	# Front pouch.
	_box(Vector3(0.16, 0.12, 0.05), Color(0.30, 0.20, 0.12, 1), Vector3(0.0, -0.05, 0.10))

func _build_shoes_model() -> void:
	for side in [-1.0, 1.0]:
		# Sole.
		_box(Vector3(0.11, 0.04, 0.24), Color(0.10, 0.10, 0.12, 1), Vector3(side * 0.075, -0.06, 0.0))
		# Upper.
		_box(Vector3(0.10, 0.10, 0.18), Color(0.20, 0.24, 0.20, 1), Vector3(side * 0.075, 0.0, -0.02))

func _build_wood_model() -> void:
	# A small stack of salvaged planks, cross-tied at the top.
	for i in range(3):
		_box(Vector3(0.42, 0.05, 0.13), Color(0.56, 0.39, 0.22, 1).lightened(0.05 * float(i)),
			Vector3(0.0, -0.06 + float(i) * 0.06, 0.0))
	_box(Vector3(0.13, 0.05, 0.36), Color(0.48, 0.33, 0.19, 1), Vector3(0.0, 0.15, 0.0))

func _build_scrap_model() -> void:
	# A jumble of bent plate and a length of pipe.
	_box(Vector3(0.30, 0.06, 0.22), Color(0.55, 0.58, 0.62, 1), Vector3(0.0, -0.06, 0.0), 0.4)
	_box(Vector3(0.22, 0.05, 0.26), Color(0.46, 0.44, 0.42, 1), Vector3(0.03, 0.01, 0.02), 0.4)
	_cyl(0.035, 0.34, Color(0.62, 0.64, 0.68, 1), Vector3(-0.02, 0.09, 0.0), Vector3(0.0, 0.0, 78.0))

func _build_glow() -> void:
	var glow_mat := StandardMaterial3D.new()
	var data := ItemData.get_item(item_id)
	glow_mat.albedo_color = data.get("glow_color", Color(0.6, 0.6, 0.6, 0.4))
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.no_depth_test = false

	var glow_mesh := CylinderMesh.new()
	glow_mesh.top_radius = 0.5
	glow_mesh.bottom_radius = 0.5
	glow_mesh.height = 0.02
	glow_mesh.material = glow_mat

	_glow = MeshInstance3D.new()
	_glow.mesh = glow_mesh
	_glow.position = Vector3(0, 0.01, 0)
	_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Keep the glow disc readable rather than muddied by the shadow overlay.
	_glow.set_meta(FovCuller.META_SHADOW_EXEMPT, true)
	add_child(_glow)
