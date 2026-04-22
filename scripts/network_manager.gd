extends Node

## Autoloaded singleton that owns all multiplayer state.
##
## Responsibilities:
##   - ENet server / client lifecycle (High-Level Multiplayer API)
##   - Game code generation and LAN discovery (UDP broadcast)
##   - Lobby configuration (map size, player cap, difficulty, seed)
##   - Peer list / ready state
##   - Replication helpers for player state and enemy AI
##   - Parallel enemy AI processing on the host (WorkerThreadPool)
##
## The code is a short human-friendly identifier. When the host creates a game
## we start broadcasting `{code, port, ...}` packets on a well-known UDP port.
## The client, given a code, listens on the same port and connects to the first
## broadcaster matching the code. This works cleanly on a LAN without any
## central directory server.

const DEFAULT_PORT := 7777
const BROADCAST_PORT := 7778
const BROADCAST_INTERVAL := 1.25
const JOIN_TIMEOUT := 10.0
const CODE_LENGTH := 6
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I

signal peer_list_changed
signal lobby_config_changed
signal join_failed(reason: String)
signal join_succeeded
signal game_started
signal game_ended

enum Difficulty { EASY, MEDIUM, TOUGH, NIGHTMARE }

# Lobby / game config
var is_host: bool = false
var is_networked: bool = false
var game_code: String = ""
var game_seed: int = 0
var map_size: int = 9              # world.num_blocks
var max_players: int = 4           # 2..8
var difficulty: int = Difficulty.MEDIUM

# Peers (id -> {name: String, ready: bool})
var peers: Dictionary = {}

# Local player identity
var local_player_name: String = "Player"

# UDP broadcast (host) + discovery (client)
var _broadcast_peer: PacketPeerUDP = null
var _discovery_peer: PacketPeerUDP = null
var _broadcast_timer: float = 0.0
var _discovery_code: String = ""
var _discovery_timer: float = 0.0

# Parallel enemy AI (host only)
var _ai_task_id: int = -1
var _ai_snapshots: Array = []
var _ai_results: Array = []

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)

func _process(delta: float) -> void:
	if _broadcast_peer != null:
		_broadcast_timer -= delta
		if _broadcast_timer <= 0.0:
			_broadcast_timer = BROADCAST_INTERVAL
			_emit_broadcast()

	if _discovery_peer != null:
		_discovery_timer -= delta
		_poll_discovery()
		if _discovery_timer <= 0.0:
			_stop_discovery()
			join_failed.emit("No host found for code %s" % _discovery_code)

# ------------------------------------------------------------------
# Difficulty presets — drives enemy spawn density and horde frequency
# ------------------------------------------------------------------

static func difficulty_settings(d: int) -> Dictionary:
	match d:
		Difficulty.EASY:
			return {
				"enemies_per_block": 0.8,
				"horde_mult": 0.55,
				"starting_hordes": 0,
				"starting_horde_size": 0,
			}
		Difficulty.MEDIUM:
			return {
				"enemies_per_block": 2.0,
				"horde_mult": 1.0,
				"starting_hordes": 1,
				"starting_horde_size": 6,
			}
		Difficulty.TOUGH:
			return {
				"enemies_per_block": 3.5,
				"horde_mult": 1.5,
				"starting_hordes": 2,
				"starting_horde_size": 10,
			}
		Difficulty.NIGHTMARE:
			return {
				"enemies_per_block": 5.0,
				"horde_mult": 2.2,
				"starting_hordes": 4,
				"starting_horde_size": 14,
			}
	return {
		"enemies_per_block": 2.0,
		"horde_mult": 1.0,
		"starting_hordes": 1,
		"starting_horde_size": 6,
	}

static func difficulty_name(d: int) -> String:
	match d:
		Difficulty.EASY: return "Easy"
		Difficulty.MEDIUM: return "Medium"
		Difficulty.TOUGH: return "Tough"
		Difficulty.NIGHTMARE: return "Nightmare"
	return "Medium"

# ------------------------------------------------------------------
# Host / join lifecycle
# ------------------------------------------------------------------

func host_game(p_map_size: int, p_max_players: int, p_difficulty: int) -> String:
	reset()
	map_size = clampi(p_map_size, 5, 20)
	max_players = clampi(p_max_players, 2, 8)
	difficulty = clampi(p_difficulty, 0, 3)
	game_seed = int(Time.get_unix_time_from_system()) ^ (randi() << 1)
	game_code = _generate_code()

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(DEFAULT_PORT, max_players - 1)
	if err != OK:
		push_error("NetworkManager: failed to create server (err=%d)" % err)
		reset()
		return ""

	multiplayer.multiplayer_peer = peer
	is_host = true
	is_networked = true
	peers[1] = {"name": local_player_name + " (host)", "ready": true}
	peer_list_changed.emit()
	lobby_config_changed.emit()

	_start_broadcast()
	return game_code

func join_game(code: String) -> void:
	reset()
	_discovery_code = code.strip_edges().to_upper()
	if _discovery_code.is_empty():
		join_failed.emit("Enter a game code")
		return
	_start_discovery()

func leave_game() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	_stop_broadcast()
	_stop_discovery()
	reset()
	game_ended.emit()

func reset() -> void:
	is_host = false
	is_networked = false
	game_code = ""
	game_seed = 0
	peers.clear()
	_stop_broadcast()
	_stop_discovery()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	peer_list_changed.emit()

# ------------------------------------------------------------------
# Lobby config updates (host authority)
# ------------------------------------------------------------------

func set_map_size(v: int) -> void:
	if not is_host:
		return
	map_size = clampi(v, 5, 20)
	lobby_config_changed.emit()
	rpc("_sync_lobby_config", map_size, max_players, difficulty)

func set_max_players(v: int) -> void:
	if not is_host:
		return
	max_players = clampi(v, 2, 8)
	lobby_config_changed.emit()
	rpc("_sync_lobby_config", map_size, max_players, difficulty)

func set_difficulty(v: int) -> void:
	if not is_host:
		return
	difficulty = clampi(v, 0, 3)
	lobby_config_changed.emit()
	rpc("_sync_lobby_config", map_size, max_players, difficulty)

@rpc("authority", "call_remote", "reliable")
func _sync_lobby_config(p_map_size: int, p_max_players: int, p_difficulty: int) -> void:
	map_size = p_map_size
	max_players = p_max_players
	difficulty = p_difficulty
	lobby_config_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _sync_game_seed(p_seed: int, p_code: String) -> void:
	game_seed = p_seed
	game_code = p_code

@rpc("any_peer", "call_local", "reliable")
func _register_peer(peer_name: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	peers[sender] = {"name": peer_name, "ready": false}
	peer_list_changed.emit()
	if is_host:
		# Push the canonical peer list back to every client.
		var dump: Dictionary = {}
		for k in peers.keys():
			dump[k] = peers[k]
		rpc("_sync_peer_list", dump)
		# Push current lobby config + seed so the new peer is in sync.
		rpc_id(sender, "_sync_lobby_config", map_size, max_players, difficulty)
		rpc_id(sender, "_sync_game_seed", game_seed, game_code)

@rpc("authority", "call_remote", "reliable")
func _sync_peer_list(dump: Dictionary) -> void:
	peers = dump.duplicate(true)
	peer_list_changed.emit()

# ------------------------------------------------------------------
# Game start (host triggers, everyone changes scene)
# ------------------------------------------------------------------

func start_game() -> void:
	if not is_host:
		return
	_stop_broadcast()
	rpc("_client_start_game")
	_enter_game_scene()

@rpc("authority", "call_remote", "reliable")
func _client_start_game() -> void:
	_enter_game_scene()

func _enter_game_scene() -> void:
	game_started.emit()
	# Deferred so RPC dispatch doesn't race with scene change.
	call_deferred("_do_scene_change")

func _do_scene_change() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

# ------------------------------------------------------------------
# Peer callbacks
# ------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if is_host:
		# Peer connected but hasn't registered yet — add a placeholder so UI shows count.
		peers[id] = {"name": "Player %d" % id, "ready": false}
		peer_list_changed.emit()

func _on_peer_disconnected(id: int) -> void:
	peers.erase(id)
	peer_list_changed.emit()

func _on_connected_to_server() -> void:
	peers[1] = {"name": "Host", "ready": true}
	peers[multiplayer.get_unique_id()] = {"name": local_player_name, "ready": false}
	peer_list_changed.emit()
	rpc_id(1, "_register_peer", local_player_name)
	join_succeeded.emit()

func _on_connection_failed() -> void:
	reset()
	join_failed.emit("Connection failed")

func _on_server_disconnected() -> void:
	reset()
	game_ended.emit()

# ------------------------------------------------------------------
# LAN discovery — UDP broadcast of {code, port, map_size, ...}
# ------------------------------------------------------------------

func _start_broadcast() -> void:
	_broadcast_peer = PacketPeerUDP.new()
	_broadcast_peer.set_broadcast_enabled(true)
	var err := _broadcast_peer.set_dest_address("255.255.255.255", BROADCAST_PORT)
	if err != OK:
		push_warning("NetworkManager: broadcast setup failed (%d)" % err)
	_broadcast_timer = 0.0

func _stop_broadcast() -> void:
	if _broadcast_peer != null:
		_broadcast_peer.close()
		_broadcast_peer = null

func _emit_broadcast() -> void:
	if _broadcast_peer == null:
		return
	var payload := {
		"vibe_zombie": 1,
		"code": game_code,
		"port": DEFAULT_PORT,
		"map_size": map_size,
		"max_players": max_players,
		"difficulty": difficulty,
		"players": peers.size(),
	}
	var data := JSON.stringify(payload).to_utf8_buffer()
	_broadcast_peer.put_packet(data)

func _start_discovery() -> void:
	_discovery_peer = PacketPeerUDP.new()
	_discovery_peer.set_broadcast_enabled(true)
	var err := _discovery_peer.bind(BROADCAST_PORT, "0.0.0.0")
	if err != OK:
		_discovery_peer = null
		join_failed.emit("Cannot listen on port %d (err=%d)" % [BROADCAST_PORT, err])
		return
	_discovery_timer = JOIN_TIMEOUT

func _stop_discovery() -> void:
	if _discovery_peer != null:
		_discovery_peer.close()
		_discovery_peer = null

func _poll_discovery() -> void:
	if _discovery_peer == null:
		return
	while _discovery_peer.get_available_packet_count() > 0:
		var packet := _discovery_peer.get_packet()
		var sender_ip := _discovery_peer.get_packet_ip()
		var json_str := packet.get_string_from_utf8()
		var parsed = JSON.parse_string(json_str)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		if not parsed.get("vibe_zombie", 0):
			continue
		var code_from_packet: String = str(parsed.get("code", "")).to_upper()
		if code_from_packet != _discovery_code:
			continue
		var port: int = int(parsed.get("port", DEFAULT_PORT))
		_stop_discovery()
		_connect_to_host(sender_ip, port)
		return

func _connect_to_host(ip: String, port: int) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		join_failed.emit("Client create failed (err=%d)" % err)
		return
	multiplayer.multiplayer_peer = peer
	is_host = false
	is_networked = true
	game_code = _discovery_code

# ------------------------------------------------------------------
# Code generation
# ------------------------------------------------------------------

func _generate_code() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for _i in range(CODE_LENGTH):
		s += CODE_ALPHABET[rng.randi() % CODE_ALPHABET.length()]
	return s

# ------------------------------------------------------------------
# Parallel enemy AI — host-side batched computation
# ------------------------------------------------------------------

## Executes `task_fn` on every element of `snapshots` in parallel via Godot's
## WorkerThreadPool, writing the result for each index into `results`.
## The caller provides pre-sized arrays to avoid reallocation on the hot path.
func run_parallel_enemy_ai(snapshots: Array, results: Array, task_fn: Callable) -> void:
	_ai_snapshots = snapshots
	_ai_results = results
	if snapshots.is_empty():
		return
	var count := snapshots.size()
	_ai_task_id = WorkerThreadPool.add_group_task(task_fn, count, -1, true)
	WorkerThreadPool.wait_for_group_task_completion(_ai_task_id)
	_ai_task_id = -1
