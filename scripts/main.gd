extends Node3D

## Main scene controller.
## Manages the mission system: pick up a package from one building, deliver to another.
## Wires up the camera → player link, handles player spawn near map rim,
## spawns enemies with density hotspots, sets up the HUD,
## and manages seamless building enter / exit transitions.
##
## Press F near a door to open / close it (works from both sides).
## When a door is open the player can walk freely in and out.
## Closing the door from inside keeps the player inside.
## The view switches automatically between exterior and interior.

const BuildingInterior = preload("res://scripts/building_interior.gd")
const WeaponPickup = preload("res://scripts/weapon_pickup.gd")
const ItemPickup = preload("res://scripts/item_pickup.gd")
const MapView = preload("res://scripts/map_view.gd")
const FovOverlay = preload("res://scripts/fov_overlay.gd")
const FovCuller = preload("res://scripts/fov_culler.gd")
const MissionSystem = preload("res://scripts/mission_system.gd")
const DebugPanel = preload("res://scripts/debug_panel.gd")

const DEV_MODE := true

const BUILDING_TYPE_NAMES := [
	"Convenience Store",
	"Apartment",
	"Office",
	"Warehouse",
	"Diner",
	"Shop",
	"Factory",
	"Bank",
	"Police Station",
	"Hospital",
	"School",
]

const DOOR_ANIM_DURATION := 0.4
const OCCLUDE_ALPHA := 0.25  # transparency when building blocks player view

# Enemy spawning — per-block density comes from the chosen difficulty
# (NetworkManager.difficulty_settings), tuned for the 100×200m blocks.
# DEV_MODE keeps the count tiny for fast playtesting.
const ENEMIES_PER_BLOCK_DEV := 2.0
# Hard cap on initial spawn count regardless of (block × density) maths.
# Stops Open World 9×9 + Nightmare from instantiating thousands of
# zombies at scene-load time; the mission system still adds wave hordes
# as missions progress.
const MAX_INITIAL_ENEMIES := 400

# Weapon pickup spawning — density scales with map size as well
const WEAPON_PICKUPS_PER_BLOCK := 2.5
const WEAPON_PICKUP_MIN_DIST := 20.0
# Same idea for pickups — keeps the static-collision count tractable.
const MAX_INITIAL_PICKUPS := 80

# Item / equipment pickup spawning. Items spawn MOSTLY inside buildings (loot to
# find while exploring) with a smaller share dropped out on the streets.
const ITEMS_PER_BLOCK := 2.0
const ITEM_MIN_DIST := 6.0
const ITEM_INDOOR_CHANCE := 0.8  # fraction placed inside building footprints
const MAX_INITIAL_ITEMS := 90

const PlayerScene = preload("res://scenes/Player.tscn")

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D        = $Camera3D
@onready var world: Node3D           = $World

# Networking
var _is_mp: bool = false
var _is_host: bool = true
var _local_peer_id: int = 1
# Map of peer_id -> Player node (includes self).
var _player_nodes: Dictionary = {}
# Counter for unique enemy names emitted by the host.
var _next_enemy_id: int = 0
# Counter for unique weapon-pickup names.
var _next_pickup_id: int = 0
# Counter for unique item-pickup names.
var _next_item_id: int = 0
# Host -> client replication cadence (GD-Sync event channel).
const NET_ENEMY_SYNC_HZ := 20.0
const NET_PICKUP_SYNC_HZ := 1.0
var _net_enemy_timer: float = 0.0
var _net_pickup_timer: float = 0.0
var _net_item_timer: float = 0.0

# UI
var _prompt_label: Label = null
var _hud = null
var _game_manual: CanvasLayer = null
var _inventory: CanvasLayer = null
var _manual_open: bool = false
var _inventory_open: bool = false
var _map_view: CanvasLayer = null
var _map_open: bool = false
var _fov_overlay: CanvasLayer = null
var _fov_culler: Node = null

# State
var _nearby_building: Dictionary = {}   # building whose door area the player overlaps
var _active_building: Dictionary = {}   # building with active interior (door may be open or closed)
var _current_interior: Node3D = null    # interior node for the active building
var _player_inside: bool = false        # whether the player is inside the active building
var _showing_interior: bool = false     # whether we are showing interior view
var _door_tween: Tween = null           # active door animation tween
var _occluded_buildings: Array = []     # buildings currently made transparent

# Mission system
enum GameState { PLAYING, WON, LOST }
var _game_state: int = GameState.PLAYING
var _mission_system: Node = null
var _debug_panel: CanvasLayer = null
var _objective_label: Label = null
var _overlay_canvas: CanvasLayer = null

const MISSION_COUNT := 4

func _ready() -> void:
	# Network state snapshot for this scene
	_is_mp = NetworkManager.is_networked
	_is_host = (not _is_mp) or NetworkManager.is_host
	_local_peer_id = NetworkManager.local_peer_id if _is_mp else 1

	# GD-Sync replication runs through NetworkManager's generic event channel
	# (the @rpc replacement). Subscribe once; main is the single dispatcher that
	# routes events to the right player / enemy / pickup node by id.
	if _is_mp:
		NetworkManager.net_event.connect(_on_net_event)
		NetworkManager.peer_list_changed.connect(_on_roster_changed)
		NetworkManager.game_ended.connect(_on_net_game_ended)

	# In MP we want a deterministic shared RNG so spawn positions match across
	# peers. The world is already seeded from NetworkManager.game_seed.
	var rng := RandomNumberGenerator.new()
	if _is_mp:
		rng.seed = NetworkManager.game_seed ^ 0xC0FFEE
	else:
		rng.randomize()

	# FOV overlay added first so it renders below the HUD/UI CanvasLayers
	_fov_overlay = CanvasLayer.new()
	_fov_overlay.set_script(FovOverlay)
	_fov_overlay.name = "FovOverlay"
	add_child(_fov_overlay)

	# Spawn player near map rim — positions derived from the world's actual size.
	# Rim candidates are fixed points at the map edges; any of them can fall
	# inside a building once the procedural grid fills blocks out to the rim,
	# which would leave the player wedged between walls at start. Drop any
	# overlapping candidates; if every rim point is blocked, scan for a
	# fallback walkable position.
	var rim_candidates := _build_rim_spawn_candidates()
	var valid_rim: Array = []
	for cand in rim_candidates:
		if not _pos_inside_building(cand):
			valid_rim.append(cand)
	if valid_rim.is_empty():
		valid_rim.append(_find_clear_fallback_spawn(rng, rim_candidates[0]))

	# Pick spawn slots. In MP, every peer evaluates the same RNG against the
	# same sorted peer list, so each one places the others identically.
	var spawn_assignments: Dictionary = {}  # peer_id -> Vector3
	if _is_mp:
		var ids := NetworkManager.peers.keys()
		ids.sort()
		# Shuffle so spawn points look random without being correlated to peer
		# id ordering (shared seed makes this deterministic across peers).
		_shuffle_array(valid_rim, rng)
		for i in range(ids.size()):
			spawn_assignments[ids[i]] = valid_rim[i % valid_rim.size()]
	else:
		valid_rim.shuffle()
		spawn_assignments[1] = valid_rim[0]

	# The Player node baked into Main.tscn becomes the LOCAL player.
	player.add_to_group("player")
	if _is_mp:
		# Ownership is decided by peer_id (GD-Sync client id) rather than Godot's
		# multiplayer authority, since GD-Sync runs its own networking layer.
		player.peer_id = _local_peer_id
		player.is_local_player = true
		if player.has_method("refresh_authority"):
			player.refresh_authority()
		player.name = "Player_%d" % _local_peer_id
		player.global_position = spawn_assignments.get(_local_peer_id, valid_rim[0])
		_player_nodes[_local_peer_id] = player

		# Spawn a representation for every other peer we already know about.
		for peer_id in spawn_assignments.keys():
			if peer_id == _local_peer_id:
				continue
			_spawn_remote_player(peer_id, spawn_assignments[peer_id])
	else:
		player.global_position = spawn_assignments[1]
		_player_nodes[1] = player

	camera.set_target(player)
	_fov_overlay.configure(player, camera)

	# FOV culler hides everything (buildings, enemies, pickups, mission
	# markers, zone rings) that falls outside the FOV sector used by the
	# overlay. This avoids wasted draw calls — entities are fully skipped
	# by the renderer rather than drawn and then shaded black by the fog.
	# The culler must be created after the overlay, before gameplay
	# entities spawn, so the first visibility pass runs against a fully
	# populated world.
	_fov_culler = Node.new()
	_fov_culler.set_script(FovCuller)
	_fov_culler.name = "FovCuller"
	add_child(_fov_culler)
	_fov_culler.configure(player, _fov_overlay)

	_create_ui()
	_setup_hud()

	# Show game code top-right when networked.
	if _is_mp and _hud and _hud.has_method("show_game_code"):
		_hud.show_game_code(NetworkManager.game_code, NetworkManager.peers.size())

	if DEV_MODE and not _is_mp:
		# In MP, god mode is opt-in via debug only; off by default for fairness.
		player.god_mode = true
		if _hud and _hud.has_method("show_dev_mode"):
			_hud.show_dev_mode()
		_setup_debug_panel()
	elif DEV_MODE and _is_mp:
		_setup_debug_panel()

	await get_tree().process_frame

	# Mission system runs only on the host. Clients see hordes via networked
	# enemy spawns; mission UI for clients is a TODO (objective text comes
	# from the host's mission system in this iteration).
	if _is_host:
		_setup_mission_system(rng)
		_spawn_enemies(rng)
		_spawn_weapon_pickups(rng)
		_spawn_items(rng)

	_connect_entrance_areas()

	player.died.connect(_on_player_died)

	# MP only: clients ask the host for the current world snapshot once their
	# scene is up, so late-joiners receive any already-spawned state. Ongoing
	# enemy/pickup state is reconciled from the host's periodic broadcasts.
	if _is_mp and not _is_host:
		var hid := NetworkManager.host_peer_id()
		if hid >= 0:
			NetworkManager.send_event_to(hid, "client_ready", {"peer_id": _local_peer_id})

func _shuffle_array(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

func _spawn_remote_player(peer_id: int, pos: Vector3) -> CharacterBody3D:
	if _player_nodes.has(peer_id):
		return _player_nodes[peer_id]
	var p := PlayerScene.instantiate() as CharacterBody3D
	p.name = "Player_%d" % peer_id
	# Tag ownership BEFORE add_child so Player._ready sees the correct value.
	p.peer_id = peer_id
	p.is_local_player = false
	add_child(p)
	if p.has_method("refresh_authority"):
		p.refresh_authority()
	p.global_position = pos
	p.add_to_group("player")
	# Remote players are visible-but-far-away characters from this peer's
	# point of view, so they should darken with the FOV like zombies do.
	# (The local player skips this in FovCuller.configure().)
	FovCuller.apply_shader_to_subtree(p)
	_player_nodes[peer_id] = p
	return p

func _on_roster_changed() -> void:
	# Reconcile remote player nodes against the GD-Sync roster: drop anyone who
	# left. (New peers are spawned lazily the first time their transform arrives,
	# which is robust against roster-propagation lag.)
	for peer_id in _player_nodes.keys():
		if peer_id == _local_peer_id:
			continue
		if not NetworkManager.peers.has(peer_id):
			var p: Node = _player_nodes[peer_id]
			_player_nodes.erase(peer_id)
			if is_instance_valid(p):
				p.queue_free()
	if _hud and _hud.has_method("update_peer_count"):
		_hud.update_peer_count(NetworkManager.peers.size())

func _on_net_game_ended() -> void:
	# Host left / disconnected mid-game — bail back to the title screen.
	get_tree().change_scene_to_file("res://scenes/TitleMenu.tscn")

func _process(delta: float) -> void:
	if _game_state != GameState.PLAYING:
		return
	_update_mouse_look()
	_update_player_inside()
	_update_prompt()
	_update_interior_wall_visibility()
	_update_building_occlusion()
	# Host: distribute enemy AI target lookup over WorkerThreadPool. Each
	# enemy then reads its cached_target_pos in _physics_process — no per-tick
	# O(N*M) search on the main thread.
	if _is_host:
		_update_enemy_ai_parallel()
		if _is_mp:
			_host_net_sync(delta)
	if _mission_system:
		_mission_system.process(delta)
		_update_objective_label()

# ------------------------------------------------------------------
# GD-Sync replication (host broadcast + event dispatch)
# ------------------------------------------------------------------

func _host_net_sync(delta: float) -> void:
	# Host broadcasts the FULL enemy / pickup set; clients reconcile (create
	# unseen, update known, drop absent). This self-heals for late joiners and
	# makes deaths / pickups propagate without separate despawn messages.
	_net_enemy_timer -= delta
	if _net_enemy_timer <= 0.0:
		_net_enemy_timer = 1.0 / NET_ENEMY_SYNC_HZ
		NetworkManager.broadcast_event("enemy_state", {"e": _build_enemy_state()})
	_net_pickup_timer -= delta
	if _net_pickup_timer <= 0.0:
		_net_pickup_timer = 1.0 / NET_PICKUP_SYNC_HZ
		NetworkManager.broadcast_event("pickup_state", {"p": _build_pickup_state()})
	_net_item_timer -= delta
	if _net_item_timer <= 0.0:
		_net_item_timer = 1.0 / NET_PICKUP_SYNC_HZ
		NetworkManager.broadcast_event("item_state", {"i": _build_item_state()})

func _build_enemy_state() -> Array:
	var out: Array = []
	for n in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(n):
			continue
		var e := n as Node3D
		out.append([
			int(e.get("network_id")), e.global_position.x, e.global_position.y,
			e.global_position.z, e.rotation.y, float(e.get("hp")),
		])
	return out

func _build_pickup_state() -> Array:
	var out: Array = []
	for child in get_children():
		if not (child is Area3D) or not String(child.name).begins_with("WeaponPickup_"):
			continue
		var pos: Vector3 = (child as Node3D).global_position
		out.append([int(child.get("network_id")), String(child.get("weapon_type")), pos.x, pos.y, pos.z])
	return out

func _build_item_state() -> Array:
	var out: Array = []
	for child in get_children():
		if not (child is Area3D) or not String(child.name).begins_with("ItemPickup_"):
			continue
		var pos: Vector3 = (child as Node3D).global_position
		out.append([int(child.get("network_id")), String(child.get("item_id")), pos.x, pos.y, pos.z])
	return out

func _on_net_event(event_name: String, payload: Dictionary) -> void:
	match event_name:
		"player_xform":
			_apply_player_xform(payload)
		"player_sound":
			# Play another player's action sound positionally on their remote copy.
			var spid := int(payload.get("peer_id", -1))
			if spid != _local_peer_id:
				var sp = _player_nodes.get(spid)
				if sp and sp.has_method("play_remote_sound"):
					sp.play_remote_sound(
						String(payload.get("sound", "")),
						float(payload.get("pitch", 1.0)),
						float(payload.get("vol", 0.0)),
					)
		"player_damage":
			# Sent to this peer because our local player took a hit on the host.
			var lp = _player_nodes.get(_local_peer_id)
			if lp and lp.has_method("apply_remote_damage"):
				lp.apply_remote_damage(float(payload.get("amount", 0.0)))
		"enemy_state":
			if not _is_host:
				_apply_enemy_state(payload.get("e", []))
		"pickup_state":
			if not _is_host:
				_apply_pickup_state(payload.get("p", []))
		"pickup_despawn":
			var pid := int(payload.get("id", -1))
			var pn := get_node_or_null("WeaponPickup_%d" % pid)
			if pn:
				pn.queue_free()
		"item_state":
			if not _is_host:
				_apply_item_state(payload.get("i", []))
		"item_despawn":
			var iid := int(payload.get("id", -1))
			var inode := get_node_or_null("ItemPickup_%d" % iid)
			if inode:
				inode.queue_free()
		"enemy_damage":
			# Client -> host damage request.
			if _is_host:
				var en := get_node_or_null("Enemy_%d" % int(payload.get("id", -1)))
				if en and en.has_method("apply_remote_damage"):
					en.apply_remote_damage(
						float(payload.get("amount", 0.0)),
						Vector3(float(payload.get("kx", 0.0)), 0.0, float(payload.get("kz", 0.0))),
					)
		"client_ready":
			# Host replies with the current world snapshot so the joiner catches up.
			if _is_host:
				var who := int(payload.get("peer_id", -1))
				if who >= 0:
					NetworkManager.send_event_to(who, "enemy_state", {"e": _build_enemy_state()})
					NetworkManager.send_event_to(who, "pickup_state", {"p": _build_pickup_state()})
					NetworkManager.send_event_to(who, "item_state", {"i": _build_item_state()})
		"player_sound":
			# A peer fired a weapon / footstep / etc. Play it positionally on
			# their remote copy. Skip if it's our own broadcast bouncing back.
			var spid := int(payload.get("peer_id", -1))
			if spid == _local_peer_id:
				pass
			else:
				var sn = _player_nodes.get(spid)
				if sn and sn.has_method("play_remote_sound"):
					sn.play_remote_sound(
						String(payload.get("sound", "")),
						float(payload.get("pitch", 1.0)),
						float(payload.get("vol_db", 0.0)),
					)
		"enemy_sound":
			# Host broadcasts when a zombie lunges/attacks; play on the local
			# copy of that enemy. The host already played it locally before
			# broadcasting, so skip if we're the host.
			if not _is_host:
				var en := get_node_or_null("Enemy_%d" % int(payload.get("id", -1)))
				if en and en.has_method("play_remote_sound"):
					en.play_remote_sound(
						String(payload.get("sound", "")),
						float(payload.get("pitch", 1.0)),
						float(payload.get("vol_db", 0.0)),
					)

func _apply_player_xform(payload: Dictionary) -> void:
	var pid := int(payload.get("peer_id", -1))
	if pid < 0 or pid == _local_peer_id:
		return
	var node = _player_nodes.get(pid)
	if node == null or not is_instance_valid(node):
		# Lazily materialise a peer we haven't been told about yet.
		node = _spawn_remote_player(pid, Vector3(
			float(payload.get("x", 0.0)), float(payload.get("y", 0.5)), float(payload.get("z", 0.0))))
		if _hud and _hud.has_method("update_peer_count"):
			_hud.update_peer_count(NetworkManager.peers.size())
	if node.has_method("apply_remote_transform"):
		node.apply_remote_transform(
			Vector3(float(payload.get("x", 0.0)), float(payload.get("y", 0.5)), float(payload.get("z", 0.0))),
			float(payload.get("yaw", 0.0)),
			bool(payload.get("sprinting", false)),
			String(payload.get("weapon", "")),
		)

func _apply_enemy_state(list: Array) -> void:
	var seen: Dictionary = {}
	for entry in list:
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 6:
			continue
		var id := int(entry[0])
		seen[id] = true
		var pos := Vector3(float(entry[1]), float(entry[2]), float(entry[3]))
		var yaw := float(entry[4])
		var hp := float(entry[5])
		var node := get_node_or_null("Enemy_%d" % id)
		if node == null:
			node = _create_enemy(id, pos)
		if node.has_method("net_apply_transform"):
			node.net_apply_transform(pos, yaw)
		if node.has_method("net_set_hp"):
			node.net_set_hp(hp)
	# Remove enemies the host no longer reports (deaths / culling).
	for n in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(n):
			continue
		if not seen.has(int(n.get("network_id"))):
			n.queue_free()

func _apply_pickup_state(list: Array) -> void:
	var seen: Dictionary = {}
	for entry in list:
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 5:
			continue
		var id := int(entry[0])
		seen[id] = true
		if get_node_or_null("WeaponPickup_%d" % id) == null:
			_create_pickup(id, String(entry[1]), Vector3(float(entry[2]), float(entry[3]), float(entry[4])))
	for child in get_children():
		if not (child is Area3D) or not String(child.name).begins_with("WeaponPickup_"):
			continue
		if not seen.has(int(child.get("network_id"))):
			child.queue_free()

func _apply_item_state(list: Array) -> void:
	var seen: Dictionary = {}
	for entry in list:
		if typeof(entry) != TYPE_ARRAY or (entry as Array).size() < 5:
			continue
		var id := int(entry[0])
		seen[id] = true
		if get_node_or_null("ItemPickup_%d" % id) == null:
			_create_item_pickup(id, String(entry[1]), Vector3(float(entry[2]), float(entry[3]), float(entry[4])))
	for child in get_children():
		if not (child is Area3D) or not String(child.name).begins_with("ItemPickup_"):
			continue
		if not seen.has(int(child.get("network_id"))):
			child.queue_free()

# ------------------------------------------------------------------
# Parallel enemy AI (host only)
# ------------------------------------------------------------------

# Snapshots reused frame-to-frame to avoid per-tick allocation.
var _ai_enemies: Array = []
var _ai_enemy_positions: Array = []
var _ai_player_positions: Array = []
var _ai_results: Array = []

func _update_enemy_ai_parallel() -> void:
	_ai_enemies.clear()
	_ai_enemy_positions.clear()
	for n in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(n):
			continue
		_ai_enemies.append(n)
		_ai_enemy_positions.append((n as Node3D).global_position)
	if _ai_enemies.is_empty():
		return

	_ai_player_positions.clear()
	for n in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(n):
			continue
		_ai_player_positions.append((n as Node3D).global_position)
	if _ai_player_positions.is_empty():
		return

	_ai_results.resize(_ai_enemies.size())
	var task := WorkerThreadPool.add_group_task(
		Callable(self, "_ai_compute_target"),
		_ai_enemies.size(), -1, true
	)
	WorkerThreadPool.wait_for_group_task_completion(task)

	for i in range(_ai_enemies.size()):
		var e: Node = _ai_enemies[i]
		if is_instance_valid(e):
			e.cached_target_pos = _ai_results[i]

# Worker-thread function — must NOT touch nodes; only reads from snapshot
# arrays (`_ai_enemy_positions`, `_ai_player_positions`) and writes a unique
# index into `_ai_results`.
func _ai_compute_target(idx: int) -> void:
	var ep: Vector3 = _ai_enemy_positions[idx]
	var best_pos := Vector3.INF
	var best_d := INF
	for pp in _ai_player_positions:
		var d: float = (pp as Vector3).distance_squared_to(ep)
		if d < best_d:
			best_d = d
			best_pos = pp
	_ai_results[idx] = best_pos

func _unhandled_input(event: InputEvent) -> void:
	# Debug panel toggle (always available in dev mode)
	if DEV_MODE and event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		if _debug_panel:
			_debug_panel.toggle()
		return

	if _game_state != GameState.PLAYING:
		return
	if event.is_action_pressed("game_manual"):
		_toggle_game_manual()
		return
	if event.is_action_pressed("inventory"):
		_toggle_inventory()
		return
	if event.is_action_pressed("map"):
		_toggle_map()
		return
	if _manual_open or _inventory_open or _map_open:
		return  # block other input while overlay is open
	if event.is_action_pressed("interact"):
		_handle_interact()

# ------------------------------------------------------------------
# HUD (armor / health / stamina bars)
# ------------------------------------------------------------------

func _setup_hud() -> void:
	var hud_script := preload("res://scripts/hud.gd")
	_hud = CanvasLayer.new()
	_hud.set_script(hud_script)
	_hud.name = "HUD"
	add_child(_hud)
	player.hud = _hud

func _rebuild_hud() -> void:
	if _hud:
		_hud.queue_free()
		_hud = null
	# Defer so the old HUD is freed first
	call_deferred("_setup_hud")

# ------------------------------------------------------------------
# Game Manual (ESC) & Inventory (I)
# ------------------------------------------------------------------

func _toggle_game_manual() -> void:
	if _inventory_open:
		_close_inventory()
	if _map_open:
		_close_map()
	if _manual_open:
		_close_game_manual()
	else:
		_open_game_manual()

func _open_game_manual() -> void:
	_manual_open = true
	var manual_script := preload("res://scripts/game_manual.gd")
	_game_manual = CanvasLayer.new()
	_game_manual.set_script(manual_script)
	_game_manual.name = "GameManual"
	_game_manual.manual_closed.connect(_close_game_manual)
	add_child(_game_manual)

func _close_game_manual() -> void:
	_manual_open = false
	if _game_manual:
		_game_manual.queue_free()
		_game_manual = null
	# Rebuild the HUD so it picks up any resolution change from settings
	_rebuild_hud()

func _toggle_inventory() -> void:
	if _manual_open:
		return  # don't open inventory while manual is open
	if _inventory_open:
		_close_inventory()
	else:
		_open_inventory()

func _open_inventory() -> void:
	_inventory_open = true
	var inv_script := preload("res://scripts/inventory.gd")
	_inventory = CanvasLayer.new()
	_inventory.set_script(inv_script)
	_inventory.name = "Inventory"
	add_child(_inventory)

func _close_inventory() -> void:
	_inventory_open = false
	if _inventory:
		_inventory.queue_free()
		_inventory = null

# ------------------------------------------------------------------
# Map overlay (M)
# ------------------------------------------------------------------

func _toggle_map() -> void:
	if _manual_open or _inventory_open:
		return
	if _map_open:
		_close_map()
	else:
		_open_map()

func _open_map() -> void:
	_map_open = true
	_map_view = CanvasLayer.new()
	_map_view.set_script(MapView)
	_map_view.name = "MapView"
	add_child(_map_view)
	_map_view.configure(world, player, _mission_system)

func _close_map() -> void:
	_map_open = false
	if _map_view:
		_map_view.queue_free()
		_map_view = null

# ------------------------------------------------------------------
# Rim spawn candidates — positions just inside each edge of the map
# ------------------------------------------------------------------

func _build_rim_spawn_candidates() -> Array:
	# Blocks are rectangular now, so use each axis half-extent separately
	# and pull the spawn slightly in from the boundary wall.
	var ex: float = world.num_blocks * world.CELL_WIDTH * 0.5 - 4.0
	var ez: float = world.num_blocks * world.CELL_DEPTH * 0.5 - 4.0
	var dx := ex * 0.9
	var dz := ez * 0.9
	return [
		Vector3( ex,  0.5,  0.0),
		Vector3(-ex,  0.5,  0.0),
		Vector3(  0.0, 0.5,  ez),
		Vector3(  0.0, 0.5, -ez),
		Vector3( dx,  0.5,  dz),
		Vector3(-dx,  0.5,  dz),
		Vector3( dx,  0.5, -dz),
		Vector3(-dx,  0.5, -dz),
	]

## Random-sample a nearby spawn point that isn't wedged inside a building.
## Used when every hand-placed rim candidate happens to land inside a
## procedurally generated block — rare, but possible on larger maps.
func _find_clear_fallback_spawn(rng: RandomNumberGenerator, hint: Vector3) -> Vector3:
	for _i in range(60):
		var jitter := Vector3(rng.randf_range(-10.0, 10.0), 0.0, rng.randf_range(-10.0, 10.0))
		var cand := Vector3(hint.x + jitter.x, 0.5, hint.z + jitter.z)
		if not _pos_inside_building(cand):
			return cand
	# Last resort: world origin. The ground plane is at y=0, so 0.5 keeps
	# the capsule off it. The caller has already warned in logs if we
	# reach this path.
	push_warning("main.gd: could not find a building-free spawn near rim; defaulting to origin")
	return Vector3(0, 0.5, 0)

# ------------------------------------------------------------------
# Enemy spawning
# ------------------------------------------------------------------

func _spawn_enemies(rng: RandomNumberGenerator) -> void:
	var nb: int = world.num_blocks

	# Single-player honours the difficulty picked in the setup menu (which
	# writes to NetworkManager just like the multiplayer host does). DEV
	# mode keeps things sparse for playtesting.
	var per_block: float
	if DEV_MODE and not _is_mp:
		per_block = ENEMIES_PER_BLOCK_DEV
	else:
		var diff := NetworkManager.difficulty_settings(NetworkManager.difficulty)
		per_block = diff.enemies_per_block

	var base_count := mini(int(per_block * nb * nb), MAX_INITIAL_ENEMIES)

	for i in range(base_count):
		var pos := _random_walkable_pos(rng)
		if pos.distance_to(player.global_position) < 12.0:
			pos = _random_walkable_pos(rng)
		_spawn_enemy_at(pos)

func _spawn_enemy_at(pos: Vector3) -> CharacterBody3D:
	var enemy_id := _next_enemy_id
	_next_enemy_id += 1
	return _create_enemy(enemy_id, pos)

## Instantiates an enemy node locally. The host calls this for every spawn; each
## client creates its own copy on demand when the host's `enemy_state` broadcast
## first reports an id it hasn't seen. The host owns AI; clients only animate and
## apply synced transform/HP (see enemy.gd).
func _create_enemy(enemy_id: int, pos: Vector3) -> CharacterBody3D:
	var existing := get_node_or_null("Enemy_%d" % enemy_id)
	if existing:
		return existing as CharacterBody3D
	var enemy_script := preload("res://scripts/enemy.gd")
	var enemy := CharacterBody3D.new()
	enemy.set_script(enemy_script)
	enemy.name = "Enemy_%d" % enemy_id
	# network_id is set BEFORE add_child so enemy._ready can read it.
	enemy.set("network_id", enemy_id)
	enemy.global_position = pos
	add_child(enemy)
	if enemy_id >= _next_enemy_id:
		_next_enemy_id = enemy_id + 1
	return enemy

func _random_walkable_pos(rng: RandomNumberGenerator) -> Vector3:
	# Pick a random block, then a random spot inside the block area or on
	# one of the adjacent roads. Pulls block dimensions straight from the
	# world so enemy distribution matches whatever block geometry it picks.
	var nb: int = world.num_blocks
	var block_w: float = world.BLOCK_WIDTH
	var block_d: float = world.BLOCK_DEPTH
	var road_w: float = world.ROAD_WIDTH
	var cell_w: float = world.CELL_WIDTH
	var cell_d: float = world.CELL_DEPTH
	var grid_origin_x := -nb * cell_w * 0.5
	var grid_origin_z := -nb * cell_d * 0.5

	var block_col := rng.randi_range(0, nb - 1)
	var block_row := rng.randi_range(0, nb - 1)
	var bx := grid_origin_x + block_col * cell_w
	var bz := grid_origin_z + block_row * cell_d

	if rng.randf() < 0.4:
		# On a road
		if rng.randf() < 0.5:
			var x := bx + block_w + rng.randf_range(0.5, road_w - 0.5)
			var z := bz + rng.randf_range(0.0, cell_d)
			return Vector3(x, 0.5, z)
		else:
			var x := bx + rng.randf_range(0.0, cell_w)
			var z := bz + block_d + rng.randf_range(0.5, road_w - 0.5)
			return Vector3(x, 0.5, z)
	else:
		# Inside / on the block
		var x := bx + rng.randf_range(1.0, block_w - 1.0)
		var z := bz + rng.randf_range(1.0, block_d - 1.0)
		return Vector3(x, 0.5, z)

# ------------------------------------------------------------------
# Weapon pickup spawning
# ------------------------------------------------------------------

func _spawn_weapon_pickups(rng: RandomNumberGenerator) -> void:
	var nb: int = world.num_blocks
	var placed_positions: Array[Vector3] = []
	var weapon_types := ["pistol", "shotgun", "smg", "ak47", "grenade_launcher", "bat"]

	var pickup_count := mini(int(WEAPON_PICKUPS_PER_BLOCK * nb * nb), MAX_INITIAL_PICKUPS)

	for i in range(pickup_count):
		var pos := Vector3.ZERO
		var valid := false

		for _attempt in range(20):
			pos = _random_walkable_pos(rng)
			pos.y = 0.0

			if pos.distance_to(player.global_position) < 10.0:
				continue

			var too_close := false
			for prev in placed_positions:
				if pos.distance_to(prev) < WEAPON_PICKUP_MIN_DIST:
					too_close = true
					break
			if too_close:
				continue

			if _pos_inside_building(pos):
				continue

			valid = true
			break

		if not valid:
			continue

		placed_positions.append(pos)

		var weapon_type: String = weapon_types[i % weapon_types.size()]
		var pickup_id := _next_pickup_id
		_next_pickup_id += 1
		_create_pickup(pickup_id, weapon_type, pos)

## Instantiates a weapon pickup locally. Host spawns them; clients create their
## copies from the host's `pickup_state` broadcast.
func _create_pickup(pickup_id: int, weapon_type: String, pos: Vector3) -> void:
	var node_name := "WeaponPickup_%d" % pickup_id
	if has_node(node_name):
		return
	var pickup := Area3D.new()
	pickup.set_script(WeaponPickup)
	pickup.name = node_name
	pickup.set("network_id", pickup_id)
	pickup.weapon_type = weapon_type
	pickup.global_position = pos
	add_child(pickup)
	if pickup_id >= _next_pickup_id:
		_next_pickup_id = pickup_id + 1

# ------------------------------------------------------------------
# Item / equipment pickup spawning (host only). Items spawn mostly inside
# building footprints — loot to discover while exploring rooms — with the
# remainder scattered on the streets. The weighted item id comes from
# ItemData.random_id so common consumables outnumber equipment.
# ------------------------------------------------------------------

func _spawn_items(rng: RandomNumberGenerator) -> void:
	var nb: int = world.num_blocks
	var item_count := mini(int(ITEMS_PER_BLOCK * nb * nb), MAX_INITIAL_ITEMS)
	var placed_positions: Array[Vector3] = []
	var has_buildings: bool = not world.buildings.is_empty()

	for _i in range(item_count):
		var pos := Vector3.ZERO
		var valid := false

		for _attempt in range(20):
			if has_buildings and rng.randf() < ITEM_INDOOR_CHANCE:
				# Inside a random building's footprint (pulled in from the walls).
				var binfo = world.buildings[rng.randi() % world.buildings.size()]
				var bpos: Vector3 = binfo.node.position
				var hw: float = binfo.width * 0.5 - 1.5
				var hd: float = binfo.depth * 0.5 - 1.5
				if hw < 0.5 or hd < 0.5:
					continue
				pos = Vector3(bpos.x + rng.randf_range(-hw, hw), 0.0, bpos.z + rng.randf_range(-hd, hd))
			else:
				# Out on the streets — reuse the walkable sampler and skip any
				# spot that lands inside a building footprint.
				pos = _random_walkable_pos(rng)
				pos.y = 0.0
				if _pos_inside_building(pos):
					continue

			if pos.distance_to(player.global_position) < 8.0:
				continue

			var too_close := false
			for prev in placed_positions:
				if pos.distance_to(prev) < ITEM_MIN_DIST:
					too_close = true
					break
			if too_close:
				continue

			valid = true
			break

		if not valid:
			continue

		placed_positions.append(pos)
		var item_id := ItemData.random_id(rng)
		var item_pickup_id := _next_item_id
		_next_item_id += 1
		_create_item_pickup(item_pickup_id, item_id, pos)

## Instantiates an item pickup locally. Host spawns them; clients create their
## copies from the host's `item_state` broadcast (mirrors _create_pickup).
func _create_item_pickup(item_pickup_id: int, item_id: String, pos: Vector3) -> void:
	var node_name := "ItemPickup_%d" % item_pickup_id
	if has_node(node_name):
		return
	var pickup := Area3D.new()
	pickup.set_script(ItemPickup)
	pickup.name = node_name
	pickup.set("network_id", item_pickup_id)
	pickup.item_id = item_id
	pickup.global_position = pos
	add_child(pickup)
	if item_pickup_id >= _next_item_id:
		_next_item_id = item_pickup_id + 1

func _pos_inside_building(pos: Vector3) -> bool:
	for binfo in world.buildings:
		var bpos: Vector3 = binfo.node.position
		var hw: float = binfo.width * 0.5 + 1.0
		var hd: float = binfo.depth * 0.5 + 1.0
		if pos.x > bpos.x - hw and pos.x < bpos.x + hw \
			and pos.z > bpos.z - hd and pos.z < bpos.z + hd:
			return true
	return false

# ------------------------------------------------------------------
# UI (interaction prompts)
# ------------------------------------------------------------------

func _create_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	_prompt_label = Label.new()
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt_label.add_theme_font_size_override("font_size", 24)
	_prompt_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_prompt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_prompt_label.add_theme_constant_override("shadow_offset_x", 2)
	_prompt_label.add_theme_constant_override("shadow_offset_y", 2)
	# True centre of the screen
	_prompt_label.anchor_left = 0.0
	_prompt_label.anchor_top = 0.4
	_prompt_label.anchor_right = 1.0
	_prompt_label.anchor_bottom = 0.6
	_prompt_label.offset_left = 0
	_prompt_label.offset_top = 0
	_prompt_label.offset_right = 0
	_prompt_label.offset_bottom = 0
	_prompt_label.visible = false
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_prompt_label)

	# Mission objective label (top center)
	_objective_label = Label.new()
	_objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_objective_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_objective_label.add_theme_font_size_override("font_size", 18)
	_objective_label.add_theme_color_override("font_color", Color(1, 1, 0.7))
	_objective_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_objective_label.add_theme_constant_override("shadow_offset_x", 1)
	_objective_label.add_theme_constant_override("shadow_offset_y", 1)
	_objective_label.anchor_left = 0.1
	_objective_label.anchor_top = 0.02
	_objective_label.anchor_right = 0.9
	_objective_label.anchor_bottom = 0.1
	_objective_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_objective_label)

func _update_prompt() -> void:
	if _prompt_label == null:
		return

	# Near a door (from either side) — show open/close prompt
	if not _nearby_building.is_empty():
		var is_open: bool = _nearby_building.get("door_open", false)
		if is_open:
			_prompt_label.text = "Press 'F' to close the door"
		else:
			_prompt_label.text = "Press 'F' to open the door"
		_prompt_label.visible = true
	elif _player_inside and not _active_building.is_empty():
		var btype: int = _active_building.get("type", 0)
		var type_name: String = BUILDING_TYPE_NAMES[btype] if btype < BUILDING_TYPE_NAMES.size() else "Building"
		_prompt_label.text = "Inside: " + type_name
		_prompt_label.visible = true
	else:
		_prompt_label.visible = false

# ------------------------------------------------------------------
# Mission system (multi-mission with sequential unlocking)
# ------------------------------------------------------------------

func _setup_mission_system(rng: RandomNumberGenerator) -> void:
	_mission_system = Node.new()
	_mission_system.set_script(MissionSystem)
	_mission_system.name = "MissionSystem"
	add_child(_mission_system)
	_mission_system.add_to_group("mission_system")

	_mission_system.setup(self, world, player, rng)
	_mission_system.generate_missions(MISSION_COUNT)

	_mission_system.mission_started.connect(_on_mission_started)
	_mission_system.mission_completed.connect(_on_mission_completed)
	_mission_system.all_missions_completed.connect(_on_all_missions_completed)
	_mission_system.player_rescued.connect(_on_player_rescued)

	# Start first mission
	_mission_system.start_next_mission()

func _on_mission_started(_index: int, _data: Dictionary) -> void:
	_update_objective_label()

func _on_mission_completed(_index: int) -> void:
	if _objective_label:
		_objective_label.text = "Mission complete! Next mission incoming..."

func _on_all_missions_completed() -> void:
	if _objective_label:
		_objective_label.text = "All missions done! Get to the rescue point! (green marker)"

func _on_player_rescued() -> void:
	_game_state = GameState.WON
	_show_overlay("RESCUED!", Color(0.1, 0.8, 0.2))
	if _objective_label:
		_objective_label.text = "You survived!"

func _on_player_died() -> void:
	_game_state = GameState.LOST
	_show_overlay("YOU DIED", Color(0.7, 0.1, 0.05))
	if _objective_label:
		_objective_label.text = ""

func _update_objective_label() -> void:
	if _objective_label == null or _mission_system == null:
		return
	_objective_label.text = _mission_system.get_objective_text()

	# Check rescue point proximity
	if _mission_system.is_rescue_active():
		if _mission_system.check_rescue(player.global_position):
			pass  # handled by area trigger in mission_system

# ------------------------------------------------------------------
# Debug panel (DEV_MODE only, toggled with F3)
# ------------------------------------------------------------------

func _setup_debug_panel() -> void:
	_debug_panel = CanvasLayer.new()
	_debug_panel.set_script(DebugPanel)
	_debug_panel.name = "DebugPanel"
	add_child(_debug_panel)

	_debug_panel.set_god_mode(player.god_mode)
	_debug_panel.density_changed.connect(_on_debug_density_changed)
	_debug_panel.god_mode_changed.connect(_on_debug_god_mode_changed)
	_debug_panel.spawn_horde_requested.connect(_on_debug_spawn_horde)
	_debug_panel.spawn_weapon_requested.connect(_on_debug_spawn_weapon)
	_debug_panel.spawn_item_requested.connect(_on_debug_spawn_item)
	_debug_panel.dominant_hand_changed.connect(_on_debug_dominant_hand_changed)

func _on_debug_density_changed(multiplier: float) -> void:
	if _mission_system:
		_mission_system.zombie_density_multiplier = multiplier

func _on_debug_god_mode_changed(enabled: bool) -> void:
	player.god_mode = enabled

func _on_debug_dominant_hand_changed(is_right: bool) -> void:
	if player and player.has_method("set_dominant_hand"):
		player.set_dominant_hand(is_right)

func _on_debug_spawn_horde(count: int) -> void:
	if _mission_system:
		_mission_system.spawn_horde_at(player.global_position + Vector3(10, 0, 10), count)

## Debug: drop a weapon pickup just in front of the player so it can be grabbed
## and tested. Reuses the same networked pickup spawn path as world generation.
func _on_debug_spawn_weapon(weapon_name: String) -> void:
	if player == null:
		return
	# Place it a couple of metres ahead — beyond the pickup's collect radius so
	# it lands on the ground rather than being auto-collected on spawn.
	var fwd := player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	var pos := player.global_position + fwd.normalized() * 2.5
	pos.y = 0.0

	var pickup_id := _next_pickup_id
	_next_pickup_id += 1
	# Under GD-Sync there's no per-spawn RPC — the host instantiates the
	# pickup locally and the next periodic pickup_state broadcast covers
	# joining clients (see _build_pickup_state + _apply_pickup_state).
	_create_pickup(pickup_id, weapon_name, pos)

## Debug: drop an item / equipment pickup just in front of the player. Mirrors
## the weapon-drop path (host instantiates locally; item_state covers clients).
func _on_debug_spawn_item(item_id: String) -> void:
	if player == null:
		return
	var fwd := player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	var pos := player.global_position + fwd.normalized() * 2.5
	pos.y = 0.0

	var item_pickup_id := _next_item_id
	_next_item_id += 1
	_create_item_pickup(item_pickup_id, item_id, pos)

# ------------------------------------------------------------------
# Game Over / Win overlay
# ------------------------------------------------------------------

func _show_overlay(title_text: String, title_color: Color) -> void:
	_overlay_canvas = CanvasLayer.new()
	_overlay_canvas.name = "OverlayUI"
	_overlay_canvas.layer = 10
	add_child(_overlay_canvas)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_canvas.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.anchor_left = 0.2
	vbox.anchor_right = 0.8
	vbox.anchor_top = 0.25
	vbox.anchor_bottom = 0.75
	vbox.offset_left = 0
	vbox.offset_right = 0
	vbox.offset_top = 0
	vbox.offset_bottom = 0
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 30)
	_overlay_canvas.add_child(vbox)

	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", title_color)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	vbox.add_child(title)

	var restart_btn := Button.new()
	restart_btn.text = "Restart" if _game_state == GameState.LOST else "Play Again"
	restart_btn.custom_minimum_size = Vector2(200, 50)
	restart_btn.add_theme_font_size_override("font_size", 24)
	restart_btn.pressed.connect(func() -> void:
		get_tree().reload_current_scene()
	)
	vbox.add_child(restart_btn)

	var exit_btn := Button.new()
	exit_btn.text = "Exit Game"
	exit_btn.custom_minimum_size = Vector2(200, 50)
	exit_btn.add_theme_font_size_override("font_size", 24)
	exit_btn.pressed.connect(func() -> void:
		get_tree().quit()
	)
	vbox.add_child(exit_btn)

# ------------------------------------------------------------------
# Mouse look — raycast mouse to ground plane, set player facing
# ------------------------------------------------------------------

func _update_mouse_look() -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	# Intersect with Y=0 ground plane
	if absf(ray_dir.y) < 0.001:
		return
	var t := -ray_origin.y / ray_dir.y
	if t < 0.0:
		return
	var ground_point := ray_origin + ray_dir * t
	player.look_target = ground_point

# ------------------------------------------------------------------
# Entrance area connections (proximity detection only)
# ------------------------------------------------------------------

func _connect_entrance_areas() -> void:
	for binfo in world.buildings:
		var area: Area3D = binfo.entrance_area
		area.body_entered.connect(func(body: Node3D) -> void:
			if body == player:
				_nearby_building = binfo
		)
		area.body_exited.connect(func(body: Node3D) -> void:
			if body == player and _nearby_building == binfo:
				_nearby_building = {}
		)

# ------------------------------------------------------------------
# Interact (F key) — works from both inside and outside
# ------------------------------------------------------------------

func _handle_interact() -> void:
	if _nearby_building.is_empty():
		return

	var is_open: bool = _nearby_building.get("door_open", false)
	if is_open:
		_close_door()
	else:
		_open_door(_nearby_building)

# ------------------------------------------------------------------
# Open door
# ------------------------------------------------------------------

func _open_door(binfo: Dictionary) -> void:
	var need_interior := (_active_building != binfo)

	# Close/cleanup any other active building first
	if not _active_building.is_empty() and _active_building != binfo:
		_full_cleanup()

	binfo.door_open = true
	_active_building = binfo

	# Animate the door open
	_animate_door(binfo, true)

	# Disable exterior collision — interior walls provide collision instead
	_set_exterior_collision(binfo.node, false)

	# Create interior if needed (skip if re-opening same building from inside)
	if need_interior:
		_create_interior(binfo)

	# Set initial view based on player position
	_update_player_inside()
	if _player_inside:
		_switch_to_interior_view()
	else:
		_switch_to_exterior_view()

# ------------------------------------------------------------------
# Close door
# ------------------------------------------------------------------

func _close_door() -> void:
	if _active_building.is_empty():
		return

	_active_building.door_open = false

	# Animate the door closed
	_animate_door(_active_building, false)

	# Re-enable exterior collision
	_set_exterior_collision(_active_building.node, true)

	if _player_inside:
		# Player is inside: keep interior, keep active building
		# They can press F again to re-open and leave
		pass
	else:
		# Player is outside: full cleanup
		_destroy_interior()
		var building_node: MeshInstance3D = _active_building.node
		building_node.visible = true
		_active_building = {}
		_showing_interior = false

# ------------------------------------------------------------------
# Door animation
# ------------------------------------------------------------------

func _animate_door(binfo: Dictionary, opening: bool) -> void:
	if _door_tween and _door_tween.is_valid():
		_door_tween.kill()

	var pivot: Node3D = binfo.door_pivot
	var base_angle: float = binfo.door_base_angle
	var target: float
	if opening:
		target = base_angle - PI * 0.5
	else:
		target = base_angle

	_door_tween = create_tween()
	_door_tween.tween_property(pivot, "rotation:y", target, DOOR_ANIM_DURATION) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_QUAD)

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

func _set_exterior_collision(building_node: MeshInstance3D, enabled: bool) -> void:
	for child in building_node.get_children():
		if child is StaticBody3D:
			child.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
			for sub in child.get_children():
				if sub is CollisionShape3D:
					(sub as CollisionShape3D).disabled = not enabled

func _create_interior(binfo: Dictionary) -> void:
	var building_node: MeshInstance3D = binfo.node
	var bpos: Vector3 = building_node.position
	var building_ground := Vector3(bpos.x, 0.0, bpos.z)

	_current_interior = Node3D.new()
	_current_interior.name = "BuildingInterior"
	_current_interior.set_script(BuildingInterior)
	add_child(_current_interior)

	var facing: Vector3 = binfo.entrance_facing
	var iw: float = binfo.width
	var id: float = binfo.depth
	if absf(facing.x) > 0.5:
		iw = binfo.depth
		id = binfo.width
	_current_interior.setup(
		binfo.type as BuildingInterior.BuildingType,
		iw, id, binfo.height,
		building_ground, facing, binfo.color
	)
	# Drape interior walls and props in the same FOV-shadow overlay so
	# the player's vision sector reads consistently from outdoors to
	# indoors (otherwise the room would suddenly snap to fully bright).
	FovCuller.apply_shader_to_subtree(_current_interior)

func _destroy_interior() -> void:
	if _current_interior:
		_current_interior.queue_free()
		_current_interior = null

func _full_cleanup() -> void:
	if _active_building.is_empty():
		return

	# Close door if open
	if _active_building.door_open:
		_active_building.door_open = false
		var pivot: Node3D = _active_building.door_pivot
		var base_angle: float = _active_building.door_base_angle
		pivot.rotation.y = base_angle

	# Re-enable exterior collision
	_set_exterior_collision(_active_building.node, true)

	# Restore exterior visibility
	_active_building.node.visible = true

	_destroy_interior()
	_active_building = {}
	_player_inside = false
	_showing_interior = false

# ------------------------------------------------------------------
# Position-based inside detection + auto view switching
# ------------------------------------------------------------------

func _update_player_inside() -> void:
	if _active_building.is_empty():
		if _player_inside:
			_player_inside = false
			_showing_interior = false
		return

	var bpos: Vector3 = _active_building.node.position
	var hw: float = _active_building.width * 0.5
	var hd: float = _active_building.depth * 0.5
	var px: float = player.global_position.x
	var pz: float = player.global_position.z
	var now_inside := (px > bpos.x - hw and px < bpos.x + hw
		and pz > bpos.z - hd and pz < bpos.z + hd)

	if now_inside and not _player_inside:
		_player_inside = true
		if _active_building.door_open:
			_switch_to_interior_view()
	elif not now_inside and _player_inside:
		_player_inside = false
		if _active_building.door_open:
			_switch_to_exterior_view()

# ------------------------------------------------------------------
# View switching
# ------------------------------------------------------------------

func _switch_to_interior_view() -> void:
	if _showing_interior:
		return
	_showing_interior = true
	var building_node: MeshInstance3D = _active_building.node
	building_node.visible = false
	if _current_interior:
		_current_interior.visible = true

func _switch_to_exterior_view() -> void:
	if not _showing_interior:
		return
	_showing_interior = false
	var building_node: MeshInstance3D = _active_building.node
	building_node.visible = true
	# Keep door mesh hidden (it's part of the pivot, not the exterior)
	if _current_interior:
		_current_interior.visible = false

# ------------------------------------------------------------------
# Interior wall visibility based on camera angle
# ------------------------------------------------------------------

func _update_interior_wall_visibility() -> void:
	if not _showing_interior or _current_interior == null:
		return
	var cam_dir := camera.global_position - player.global_position
	cam_dir.y = 0.0
	if cam_dir.length_squared() < 0.001:
		return
	cam_dir = cam_dir.normalized()
	var local_dir := _current_interior.global_transform.basis.inverse() * cam_dir
	_current_interior.update_wall_visibility(local_dir)

# ------------------------------------------------------------------
# Building occlusion — make buildings between camera and player transparent
# ------------------------------------------------------------------

func _update_building_occlusion() -> void:
	var cam_pos := camera.global_position
	var player_pos := player.global_position

	# Find buildings that occlude the camera→player ray. Occlusion no
	# longer cares about the FOV: with the shader-driven shadow system
	# the FOV culler doesn't write alpha, so this code fully owns the
	# transparency lifecycle. Letting buildings behind the player's
	# sector also fade-out-when-occluding means the player can still
	# see themselves through walls the camera angle puts in the way.
	var now_occluded: Array = []
	for binfo in world.buildings:
		var node: MeshInstance3D = binfo.node
		if not node.is_visible_in_tree():
			continue
		if _building_occludes(binfo, cam_pos, player_pos):
			now_occluded.append(binfo)

	# Restore alpha for any building that has stopped occluding. We
	# always restore — gating on FOV here used to leak buildings that
	# rotated out of the sector mid-occlusion, which left them stuck at
	# 0.25 alpha and blinking as occlusion thrashed at the FOV edge.
	for binfo in _occluded_buildings:
		if binfo not in now_occluded:
			_set_building_alpha(binfo, 1.0)

	# Make newly occluding buildings transparent
	for binfo in now_occluded:
		_set_building_alpha(binfo, OCCLUDE_ALPHA)

	_occluded_buildings = now_occluded

func _building_occludes(binfo: Dictionary, cam_pos: Vector3, player_pos: Vector3) -> bool:
	var bpos: Vector3 = binfo.node.position
	var hw: float = binfo.width * 0.5
	var hh: float = binfo.height * 0.5
	var hd: float = binfo.depth * 0.5

	# AABB min/max
	var aabb_min := Vector3(bpos.x - hw, bpos.y - hh, bpos.z - hd)
	var aabb_max := Vector3(bpos.x + hw, bpos.y + hh, bpos.z + hd)

	# Ray-AABB intersection (slab method)
	var dir := player_pos - cam_pos
	var inv_dir := Vector3(
		1.0 / dir.x if absf(dir.x) > 0.0001 else 1e10,
		1.0 / dir.y if absf(dir.y) > 0.0001 else 1e10,
		1.0 / dir.z if absf(dir.z) > 0.0001 else 1e10,
	)

	var t1 := (aabb_min.x - cam_pos.x) * inv_dir.x
	var t2 := (aabb_max.x - cam_pos.x) * inv_dir.x
	var tmin := minf(t1, t2)
	var tmax := maxf(t1, t2)

	t1 = (aabb_min.y - cam_pos.y) * inv_dir.y
	t2 = (aabb_max.y - cam_pos.y) * inv_dir.y
	tmin = maxf(tmin, minf(t1, t2))
	tmax = minf(tmax, maxf(t1, t2))

	t1 = (aabb_min.z - cam_pos.z) * inv_dir.z
	t2 = (aabb_max.z - cam_pos.z) * inv_dir.z
	tmin = maxf(tmin, minf(t1, t2))
	tmax = minf(tmax, maxf(t1, t2))

	# Hit if slab overlap is valid AND the intersection is between camera and player
	return tmax >= tmin and tmax > 0.0 and tmin < 1.0

func _set_building_alpha(binfo: Dictionary, alpha: float) -> void:
	# The rooftop ledge, windows, trim and awning are separate MeshInstance3D
	# siblings of the building body, so fading just binfo.node leaves the
	# roof fully opaque and still blocking the player. Walk the whole
	# container subtree and fade every mesh's material together.
	var root: Node3D = binfo.get("container", binfo.node)
	if root == null:
		return
	_fade_mesh_tree(root, alpha)

func _fade_mesh_tree(node: Node, alpha: float) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var prim := mi.mesh as PrimitiveMesh
		if prim != null:
			var mat := prim.material as StandardMaterial3D
			if mat != null:
				if alpha < 1.0:
					mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					mat.albedo_color.a = alpha
				else:
					mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
					mat.albedo_color.a = 1.0
	for child in node.get_children():
		_fade_mesh_tree(child, alpha)
