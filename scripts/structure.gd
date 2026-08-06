extends StaticBody3D

## A player-crafted structure — barricade, spike trap, floodlight.
##
## Placement mirrors the pickup pattern: the host owns the authoritative set,
## assigns ids, and broadcasts the full list as "structure_state" (~2 Hz);
## clients reconcile (create unseen, update known, drop absent), which
## propagates both placements and destructions without explicit despawns.
##
## The mesh is built by the static `build_visual()` helper so the translucent
## placement ghost in main.gd renders exactly the same geometry as the finished
## structure — what you preview is what you get.

const FovCuller = preload("res://scripts/fov_culler.gd")
const CraftDataRef = preload("res://scripts/craft_data.gd")

var structure_id: String = "barricade"
## GD-Sync replication id assigned by main.gd (matches node name "Structure_<id>").
var network_id: int = -1
## Negative until _ready fills them from CraftData. main.gd overrides both when
## a client materialises a structure from the host's snapshot.
var hp: float = -1.0
var max_hp: float = -1.0

var _is_authority: bool = true
var _data: Dictionary = {}
var _hp_bar_bg: MeshInstance3D = null
var _hp_bar_fg: MeshInstance3D = null

const HP_BAR_WIDTH := 1.2
const HP_BAR_HEIGHT := 0.1

func _ready() -> void:
	add_to_group("structure")
	_is_authority = (not NetworkManager.is_networked) or NetworkManager.is_host
	_data = CraftDataRef.get_structure(structure_id)
	if _data.is_empty():
		_data = CraftDataRef.get_structure("barricade")
	if max_hp <= 0.0:
		max_hp = float(_data.get("hp", 100.0))
	if hp <= 0.0:
		hp = max_hp

	var size: Vector3 = _data.get("size", Vector3(3.0, 1.5, 0.35))
	# Only blocking structures get a collider; a spike trap is walked over.
	if bool(_data.get("blocks", true)):
		var cs := CollisionShape3D.new()
		var shp := BoxShape3D.new()
		shp.size = size
		cs.shape = shp
		cs.position.y = size.y * 0.5
		add_child(cs)

	add_child(build_visual(structure_id))
	_build_hp_bar(size)

	add_to_group(&"fov_cullable")
	set_meta(&"fov_cull_radius", maxf(size.x, size.z) * 0.6 + 0.5)
	FovCuller.apply_shader_to_subtree(self)

func _physics_process(delta: float) -> void:
	_update_hp_bar()
	if not _is_authority:
		return
	if _data.has("damage_per_second"):
		_process_trap(delta)

## Spike-trap tick: every zombie standing on the pad bleeds, and the trap wears
## down by the same clock so it eventually breaks and despawns.
func _process_trap(delta: float) -> void:
	var radius: float = float(_data.get("damage_radius", 1.6))
	var dps: float = float(_data.get("damage_per_second", 20.0))
	var hit_any := false
	for n in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(n):
			continue
		var e := n as Node3D
		var d := Vector2(e.global_position.x - global_position.x, e.global_position.z - global_position.z)
		if d.length() > radius:
			continue
		hit_any = true
		if e.has_method("take_damage"):
			e.take_damage(dps * delta)
	if hit_any:
		_apply_damage(float(_data.get("wear_per_second", 6.0)) * delta)

## Damage entry point. Clients forward to the host (which owns structure HP);
## the result comes back on the next structure_state broadcast.
func take_damage(amount: float) -> void:
	if NetworkManager.is_networked and not NetworkManager.is_host:
		NetworkManager.send_event_to(NetworkManager.host_peer_id(), "structure_damage", {
			"id": network_id, "amount": amount,
		})
		return
	_apply_damage(amount)

func apply_remote_damage(amount: float) -> void:
	_apply_damage(amount)

func _apply_damage(amount: float) -> void:
	hp = maxf(hp - amount, 0.0)
	_update_hp_bar()
	if hp <= 0.0:
		# Host frees it locally; clients drop their copy when it stops appearing
		# in the next structure_state broadcast (main.gd reconcile).
		queue_free()

## Host-pushed HP on client copies (called by main.gd).
func net_set_hp(new_hp: float) -> void:
	if is_equal_approx(hp, new_hp):
		return
	hp = new_hp
	_update_hp_bar()

# ------------------------------------------------------------------
# HP bar — same floating-quad treatment the zombies use.
# ------------------------------------------------------------------

func _build_hp_bar(size: Vector3) -> void:
	var bar_y: float = size.y + 0.35

	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.1, 0.1, 0.1, 0.75)
	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var bg_mesh := QuadMesh.new()
	bg_mesh.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	bg_mesh.material = bg_mat
	_hp_bar_bg = MeshInstance3D.new()
	_hp_bar_bg.mesh = bg_mesh
	_hp_bar_bg.position = Vector3(0, bar_y, 0)
	_hp_bar_bg.set_meta(FovCuller.META_SHADOW_EXEMPT, true)
	add_child(_hp_bar_bg)

	var fg_mat := StandardMaterial3D.new()
	fg_mat.albedo_color = Color(0.45, 0.75, 0.95, 0.95)
	fg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var fg_mesh := QuadMesh.new()
	fg_mesh.size = Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT)
	fg_mesh.material = fg_mat
	_hp_bar_fg = MeshInstance3D.new()
	_hp_bar_fg.mesh = fg_mesh
	_hp_bar_fg.position = Vector3(0, bar_y, 0.01)
	_hp_bar_fg.set_meta(FovCuller.META_SHADOW_EXEMPT, true)
	add_child(_hp_bar_fg)

func _update_hp_bar() -> void:
	if _hp_bar_fg == null or max_hp <= 0.0:
		return
	var ratio := clampf(hp / max_hp, 0.0, 1.0)
	# A structure at full health reads as clutter — only show the bar once it
	# has actually been chewed on.
	var damaged := ratio < 0.999
	_hp_bar_fg.visible = damaged
	if _hp_bar_bg:
		_hp_bar_bg.visible = damaged
	_hp_bar_fg.scale.x = maxf(ratio, 0.001)
	_hp_bar_fg.position.x = -HP_BAR_WIDTH * 0.5 * (1.0 - ratio)

# ------------------------------------------------------------------
# Procedural geometry — shared with the placement ghost.
# ------------------------------------------------------------------

## Builds the visual subtree for `structure_id`. Returns a fresh Node3D the
## caller parents wherever it likes (real structure, or ghost preview).
static func build_visual(sid: String) -> Node3D:
	var data: Dictionary = CraftDataRef.get_structure(sid)
	var root := Node3D.new()
	root.name = "StructureModel"
	if data.is_empty():
		return root
	match sid:
		"barricade":
			_build_plank_wall(root, data, false)
		"reinforced_barricade":
			_build_plank_wall(root, data, true)
		"spike_trap":
			_build_spike_trap(root, data)
		"watch_light":
			_build_watch_light(root, data)
		_:
			_build_plank_wall(root, data, false)
	return root

static func _mat(color: Color, rough: float = 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m

static func _box(parent: Node3D, size: Vector3, color: Color, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _mat(color)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi

## Horizontal planks on two posts, optionally with a scrap-metal plate bolted on.
static func _build_plank_wall(root: Node3D, data: Dictionary, reinforced: bool) -> void:
	var size: Vector3 = data.get("size", Vector3(3.0, 1.5, 0.35))
	var wood: Color = data.get("color", Color(0.52, 0.36, 0.20))
	var accent: Color = data.get("accent", Color(0.34, 0.24, 0.14))
	var post_w: float = 0.18

	# Uprights at each end.
	for side in [-1.0, 1.0]:
		_box(root, Vector3(post_w, size.y, size.z),
			accent if reinforced else wood.darkened(0.25),
			Vector3(side * (size.x * 0.5 - post_w * 0.5), size.y * 0.5, 0.0))

	# Horizontal planks, slightly staggered so the wall reads as hand-built.
	var plank_count := 3 if not reinforced else 4
	var plank_h: float = size.y / (plank_count * 1.6)
	for i in range(plank_count):
		var y: float = size.y * (float(i) + 0.7) / float(plank_count)
		var tilt: float = (-2.5 if i % 2 == 0 else 2.0)
		_box(root, Vector3(size.x * 0.98, plank_h, size.z * 0.7),
			wood.lightened(0.06 * float(i % 3)),
			Vector3(0.0, y, 0.0), Vector3(0.0, 0.0, tilt))

	# Diagonal brace.
	_box(root, Vector3(size.x * 0.95, plank_h * 0.7, size.z * 0.5),
		wood.darkened(0.15), Vector3(0.0, size.y * 0.5, -size.z * 0.25),
		Vector3(0.0, 0.0, 22.0))

	if reinforced:
		# Bolted scrap plate across the middle.
		_box(root, Vector3(size.x * 0.6, size.y * 0.42, size.z * 0.35),
			accent, Vector3(0.0, size.y * 0.5, size.z * 0.3))
		for bx in [-1.0, 1.0]:
			for by in [-1.0, 1.0]:
				_box(root, Vector3(0.08, 0.08, 0.08), accent.darkened(0.3),
					Vector3(bx * size.x * 0.24, size.y * 0.5 + by * size.y * 0.15, size.z * 0.48))

## A low wooden pad bristling with metal spikes.
static func _build_spike_trap(root: Node3D, data: Dictionary) -> void:
	var size: Vector3 = data.get("size", Vector3(2.2, 0.35, 2.2))
	var wood: Color = data.get("color", Color(0.40, 0.30, 0.18))
	var metal: Color = data.get("accent", Color(0.62, 0.64, 0.68))

	_box(root, Vector3(size.x, 0.08, size.z), wood, Vector3(0.0, 0.04, 0.0))

	var spike_mat := _mat(metal, 0.35)
	spike_mat.metallic = 0.6
	var rows := 3
	var step: float = size.x * 0.62 / float(rows - 1)
	for ix in range(rows):
		for iz in range(rows):
			var mesh := CylinderMesh.new()
			mesh.top_radius = 0.0
			mesh.bottom_radius = 0.055
			mesh.height = 0.30
			mesh.material = spike_mat
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.position = Vector3(
				-size.x * 0.31 + float(ix) * step,
				0.23,
				-size.z * 0.31 + float(iz) * step)
			root.add_child(mi)

## A scrap mast with a lit head that actually casts light at night.
static func _build_watch_light(root: Node3D, data: Dictionary) -> void:
	var size: Vector3 = data.get("size", Vector3(0.5, 2.6, 0.5))
	var metal: Color = data.get("color", Color(0.40, 0.42, 0.46))
	var bulb: Color = data.get("accent", Color(1.0, 0.94, 0.72))

	_box(root, Vector3(size.x * 1.5, 0.12, size.z * 1.5), metal.darkened(0.3), Vector3(0.0, 0.06, 0.0))
	_box(root, Vector3(0.14, size.y, 0.14), metal, Vector3(0.0, size.y * 0.5, 0.0))

	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = bulb
	head_mat.emission_enabled = true
	head_mat.emission = bulb
	head_mat.emission_energy_multiplier = 2.0
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.42, 0.28, 0.30)
	head_mesh.material = head_mat
	var head := MeshInstance3D.new()
	head.mesh = head_mesh
	head.position = Vector3(0.0, size.y - 0.1, 0.05)
	root.add_child(head)

	var light := OmniLight3D.new()
	light.name = "FloodLight"
	light.position = Vector3(0.0, size.y - 0.1, 0.2)
	light.omni_range = float(data.get("light_range", 16.0))
	light.light_energy = 2.2
	light.light_color = bulb
	light.shadow_enabled = false
	root.add_child(light)
