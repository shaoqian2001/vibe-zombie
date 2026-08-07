extends Node

## Autoloaded singleton that owns all multiplayer state.
##
## This is a high-level wrapper around the GD-Sync addon (https://www.gd-sync.com).
## It mirrors the architecture used by the sister project "vibe-holdem": every
## scene talks to THIS autoload and never to the GDSync node directly, so the
## addon's quirks stay in one place.
##
## Responsibilities:
##   - GD-Sync connect / lobby create / lobby join lifecycle
##   - Room ("game") code generation
##   - Lobby configuration (map size, player cap, difficulty, shared world seed)
##   - Peer roster (published through GD-Sync lobby data, the only channel that
##     reliably round-trips on every addon release)
##   - A generic host<->client event channel (`broadcast_event` / `send_event_to`
##     -> `net_event` signal) used by the gameplay scripts to replicate spawns,
##     transforms, damage, etc. — the GD-Sync equivalent of Godot's @rpc.
##
## The 6-character code is the room's access control: a public GD-Sync lobby is
## advertised by name, and the ~10^9 codes from a 32-char alphabet make guessing
## impractical. Players join purely by code; no port-forwarding or LAN discovery.

# ------------------------------------------------------------------
# Compatibility signals (consumed by the menu / lobby / main scenes)
# ------------------------------------------------------------------
signal peer_list_changed
signal lobby_config_changed
signal join_failed(reason: String)
signal join_succeeded                      # local client entered a room (host OR joiner)
signal game_started
signal game_ended

# Generic gameplay replication channel. Emitted on every peer when an event
# arrives (including locally-originated ones, mirroring GD-Sync call_func_all).
signal net_event(event_name: String, payload: Dictionary)

enum Difficulty { EASY, MEDIUM, TOUGH, NIGHTMARE }

## Game modes selectable when hosting.
##   CAMPAIGN — the co-op mission chain (procedural city, missions, hordes),
##              then reach the rescue point to escape.
##   SURVIVAL — hold a headquarters building against a calendar of zombie
##              assaults; clear the final one to win.
##   DUEL     — 1v1 PvP on a single 20×20 m barricaded arena; capped at two
##              players, and the round ends the moment one player dies.
enum GameMode { CAMPAIGN, SURVIVAL, DUEL }

## Player cap for the 1v1 Duel — the host plus exactly one challenger.
const DUEL_MAX_PLAYERS := 2

const BuildingCatalog = preload("res://scripts/building_catalog.gd")

const CODE_LENGTH := 6
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I
const MIN_PLAYERS := 2
const MAX_PLAYERS_HARD_CAP := 8
const CONNECT_TIMEOUT_SEC := 10.0
const ROSTER_POLL_INTERVAL_SEC := 1.5
# How often we re-measure round-trip latency to the other player(s). GD-Sync's
# get_client_ping is a real ~0.1-0.6s ping exchange, so we don't run it faster.
const PING_POLL_INTERVAL_SEC := 2.0

# GD-Sync lobby-data keys. Peer roster entries are "zpeer_<id>" = "<name>|<host>".
# Lobby config travels in dedicated keys so late joiners pick it up immediately.
const LOBBY_DATA_PEER_PREFIX := "zpeer_"
const CFG_MAP_KEY := "cfg_map"
const CFG_PLAYERS_KEY := "cfg_players"
const CFG_DIFF_KEY := "cfg_diff"
const CFG_SEED_KEY := "cfg_seed"
const CFG_STYLE_KEY := "cfg_style"
const CFG_MODE_KEY := "cfg_mode"

# GD-Sync enum mirrors (from addons/GD-Sync/Scripts/Enums/Enums.gd) so error
# messages are human-readable instead of "code 2".
const GDSYNC_INVALID_PUBLIC_KEY := 0
const GDSYNC_TIMEOUT := 1
const GDSYNC_LOCAL_PORT_ERROR := 2
const GDSYNC_LOBBY_DOES_NOT_EXIST := 0
const GDSYNC_LOBBY_IS_CLOSED := 1
const GDSYNC_LOBBY_IS_FULL := 2
const GDSYNC_LOBBY_INCORRECT_PASSWORD := 3
const GDSYNC_LOBBY_DUPLICATE_USERNAME := 4

enum State { OFFLINE, CONNECTING, IN_LOBBY, IN_ROOM, IN_GAME }

# ------------------------------------------------------------------
# Public state (read by the rest of the game)
# ------------------------------------------------------------------
var state: int = State.OFFLINE
var is_host: bool = false
var is_networked: bool = false             # true once we're in a room
var game_code: String = ""
var game_seed: int = 0
var map_size: int = 3                       # world.num_blocks (each block ~100×200m)
var max_players: int = 4                    # 2..8
var difficulty: int = Difficulty.MEDIUM
var map_style: int = BuildingCatalog.MapStyle.DOWNTOWN
var game_mode: int = GameMode.CAMPAIGN
var local_player_name: String = "Player"
var local_peer_id: int = -1

# peer_id (int) -> { "id": int, "name": String, "is_host": bool }
var peers: Dictionary = {}

# Latest measured round-trip latency in milliseconds to the other player(s):
# a client measures to the host, the host averages over its clients. -1 means
# "not measured yet / unavailable". Read by the HUD for the on-screen readout.
var ping_ms: float = -1.0
var _ping_in_flight: bool = false

# ------------------------------------------------------------------
# Internal GD-Sync plumbing
# ------------------------------------------------------------------
var _gdsync: Node = null
var _addon_available: bool = false
var _gdsync_connected: bool = false
var _pending_action: String = ""           # "host" or "join" while connecting
var _pending_max_players: int = 0
var _did_dispatch: bool = false
var _self_hosting: bool = false
var _awaiting_self_join: bool = false
var _connect_timeout_timer: SceneTreeTimer = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_init_gdsync()
	if not _addon_available:
		# The GDSync autoload may simply be ordered after us in the autoload list
		# (so it doesn't exist yet during our _ready). Retry once after all
		# autoloads have been added before declaring multiplayer unavailable.
		call_deferred("_init_gdsync")

func _init_gdsync() -> void:
	if _addon_available:
		return
	_gdsync = _resolve_gdsync()
	_addon_available = _gdsync != null
	if not _addon_available:
		push_warning("[NetworkManager] GD-Sync addon not detected — multiplayer disabled. Enable the GD-Sync plugin and configure its API key in Project → Tools → GD-Sync (and make sure the GDSync autoload loads before NetworkManager).")
		return
	_wire_gdsync_signals()
	# Safety net: GD-Sync's client_joined / lobby_data_changed signals don't fire
	# reliably on every release, so we re-snapshot the lobby roster periodically.
	var poll := Timer.new()
	poll.name = "RosterPoll"
	poll.wait_time = ROSTER_POLL_INTERVAL_SEC
	poll.autostart = true
	poll.one_shot = false
	poll.timeout.connect(_on_roster_poll_tick)
	add_child(poll)
	# Separate, slower timer for latency measurement (get_client_ping is async
	# and comparatively expensive, so it gets its own cadence + in-flight guard).
	var ping_poll := Timer.new()
	ping_poll.name = "PingPoll"
	ping_poll.wait_time = PING_POLL_INTERVAL_SEC
	ping_poll.autostart = true
	ping_poll.one_shot = false
	ping_poll.timeout.connect(_on_ping_poll_tick)
	add_child(ping_poll)

# ------------------------------------------------------------------
# Difficulty presets — drives enemy spawn density and horde frequency
# ------------------------------------------------------------------

static func difficulty_settings(d: int) -> Dictionary:
	# Density values are tuned for the 100×200 m block size — each block
	# can comfortably hold a dozen+ enemies before things feel cramped.
	match d:
		Difficulty.EASY:
			return {"enemies_per_block": 6.0, "horde_mult": 0.55, "starting_hordes": 0, "starting_horde_size": 0}
		Difficulty.MEDIUM:
			return {"enemies_per_block": 14.0, "horde_mult": 1.0, "starting_hordes": 1, "starting_horde_size": 6}
		Difficulty.TOUGH:
			return {"enemies_per_block": 22.0, "horde_mult": 1.5, "starting_hordes": 2, "starting_horde_size": 10}
		Difficulty.NIGHTMARE:
			return {"enemies_per_block": 32.0, "horde_mult": 2.2, "starting_hordes": 4, "starting_horde_size": 14}
	return {"enemies_per_block": 14.0, "horde_mult": 1.0, "starting_hordes": 1, "starting_horde_size": 6}

static func difficulty_name(d: int) -> String:
	match d:
		Difficulty.EASY: return "Easy"
		Difficulty.MEDIUM: return "Medium"
		Difficulty.TOUGH: return "Tough"
		Difficulty.NIGHTMARE: return "Nightmare"
	return "Medium"

# ------------------------------------------------------------------
# Game modes
# ------------------------------------------------------------------

static func game_mode_name(m: int) -> String:
	match m:
		GameMode.CAMPAIGN: return "Campaign"
		GameMode.SURVIVAL: return "Survival"
		GameMode.DUEL: return "1v1 Duel"
	return "Campaign"

static func game_mode_description(m: int) -> String:
	match m:
		GameMode.CAMPAIGN:
			return "Run a chain of missions across the city, then reach the rescue point to escape."
		GameMode.SURVIVAL:
			return "Hold a headquarters building against scheduled zombie assaults. Waves land on day 7 and day 12; survive the final assault on day 15 to win. Craft barricades and traps with B."
		GameMode.DUEL:
			return "1v1 PvP on a single barricaded arena. Capped at two players; the round ends the moment one of you goes down."
	return ""

# ------------------------------------------------------------------
# Host / join lifecycle (public API consumed by the menu)
# ------------------------------------------------------------------

func host_game(p_map_size: int, p_max_players: int, p_difficulty: int, p_map_style: int = -1, p_game_mode: int = GameMode.CAMPAIGN) -> String:
	## Kicks off an asynchronous GD-Sync host. Returns the generated room code
	## immediately (so the menu can show it); success/failure arrives later via
	## the join_succeeded / join_failed signals.
	if not _ensure_addon():
		return ""
	reset()
	game_mode = clampi(p_game_mode, 0, GameMode.size() - 1)
	if p_map_style >= 0:
		map_style = p_map_style
	# Map size is a property of the chosen style; the caller passes the
	# style's preset and we just snap it to safe bounds.
	map_size = clampi(p_map_size, 2, 12)
	# The 1v1 Duel is hard-capped at two players regardless of the requested cap.
	if game_mode == GameMode.DUEL:
		max_players = DUEL_MAX_PLAYERS
	else:
		max_players = clampi(p_max_players, MIN_PLAYERS, MAX_PLAYERS_HARD_CAP)
	difficulty = clampi(p_difficulty, 0, 3)
	game_seed = int(Time.get_unix_time_from_system()) ^ (randi() << 1)
	game_code = _generate_code()
	local_player_name = local_player_name.strip_edges()
	if local_player_name.is_empty():
		local_player_name = "Player"
	_pending_action = "host"
	_pending_max_players = max_players
	_self_hosting = true
	_did_dispatch = false
	_set_state(State.CONNECTING)
	_arm_connect_timeout()
	if _gdsync_connected and _safe_get_client_id() >= 0:
		_did_dispatch = true
		_pending_action = ""
		_do_host()
	else:
		_start_connection()
	return game_code

func join_game(code: String) -> void:
	if not _ensure_addon():
		return
	reset()
	var normalized := code.strip_edges().to_upper()
	if normalized.length() != CODE_LENGTH:
		join_failed.emit("Game code must be %d characters" % CODE_LENGTH)
		return
	game_code = normalized
	local_player_name = local_player_name.strip_edges()
	if local_player_name.is_empty():
		local_player_name = "Player"
	_pending_action = "join"
	_self_hosting = false
	_did_dispatch = false
	_set_state(State.CONNECTING)
	_arm_connect_timeout()
	if _gdsync_connected and _safe_get_client_id() >= 0:
		_did_dispatch = true
		_pending_action = ""
		_do_join()
	else:
		_start_connection()

func leave_game() -> void:
	if not _addon_available:
		reset()
		game_ended.emit()
		return
	if local_peer_id >= 0 and _gdsync.has_method("lobby_erase_data"):
		_gdsync.call("lobby_erase_data", "%s%d" % [LOBBY_DATA_PEER_PREFIX, local_peer_id])
	var leave_method := _first_method(["lobby_leave", "leave_lobby"])
	if leave_method != "":
		_gdsync.call(leave_method)
	reset()
	game_ended.emit()

func reset() -> void:
	is_host = false
	is_networked = false
	game_code = ""
	game_seed = 0
	local_peer_id = -1
	peers.clear()
	_pending_action = ""
	_did_dispatch = false
	_self_hosting = false
	_awaiting_self_join = false
	_clear_connect_timeout()
	if state == State.IN_GAME or state == State.IN_ROOM:
		_set_state(State.IN_LOBBY if (_addon_available and _gdsync_connected) else State.OFFLINE)
	peer_list_changed.emit()

# ------------------------------------------------------------------
# Lobby config updates (host authority)
# ------------------------------------------------------------------

func set_map_size(v: int) -> void:
	if not is_host: return
	map_size = clampi(v, 2, 12)
	lobby_config_changed.emit()
	_publish_config()

func set_max_players(v: int) -> void:
	if not is_host: return
	max_players = clampi(v, MIN_PLAYERS, MAX_PLAYERS_HARD_CAP)
	lobby_config_changed.emit()
	_publish_config()

func set_difficulty(v: int) -> void:
	if not is_host: return
	difficulty = clampi(v, 0, 3)
	lobby_config_changed.emit()
	_publish_config()

func set_map_style(v: int) -> void:
	if not is_host: return
	map_style = v
	# Style controls map size — snap to the style's preset.
	map_size = BuildingCatalog.map_size_for(v)
	lobby_config_changed.emit()
	_publish_config()

func set_game_mode(v: int) -> void:
	if not is_host: return
	game_mode = clampi(v, 0, GameMode.size() - 1)
	# The duel is always 2-player; the co-op modes keep the host's chosen cap.
	if game_mode == GameMode.DUEL:
		max_players = DUEL_MAX_PLAYERS
	lobby_config_changed.emit()
	_publish_config()

func _publish_config() -> void:
	if _gdsync == null or not _gdsync.has_method("lobby_set_data"):
		return
	_gdsync.call("lobby_set_data", CFG_MAP_KEY, str(map_size))
	_gdsync.call("lobby_set_data", CFG_PLAYERS_KEY, str(max_players))
	_gdsync.call("lobby_set_data", CFG_DIFF_KEY, str(difficulty))
	_gdsync.call("lobby_set_data", CFG_SEED_KEY, str(game_seed))
	_gdsync.call("lobby_set_data", CFG_STYLE_KEY, str(map_style))
	_gdsync.call("lobby_set_data", CFG_MODE_KEY, str(game_mode))
	# Belt-and-braces: broadcast as an event too, for builds whose
	# lobby_data_changed signal is unreliable.
	broadcast_event("cfg_sync", {
		"map": map_size, "players": max_players, "diff": difficulty,
		"seed": game_seed, "style": map_style, "mode": game_mode,
	})

func _ingest_config_from_lobby_data() -> void:
	if _gdsync == null or not _gdsync.has_method("lobby_get_all_data"):
		return
	var data: Variant = _gdsync.call("lobby_get_all_data")
	if not (data is Dictionary):
		return
	var changed := false
	var d: Dictionary = data
	if d.has(CFG_MAP_KEY):
		var vm := int(str(d[CFG_MAP_KEY]))
		if vm != map_size: map_size = vm; changed = true
	if d.has(CFG_PLAYERS_KEY):
		var vp := int(str(d[CFG_PLAYERS_KEY]))
		if vp != max_players: max_players = vp; changed = true
	if d.has(CFG_DIFF_KEY):
		var vd := int(str(d[CFG_DIFF_KEY]))
		if vd != difficulty: difficulty = vd; changed = true
	if d.has(CFG_SEED_KEY):
		var vs := int(str(d[CFG_SEED_KEY]))
		if vs != game_seed: game_seed = vs; changed = true
	if d.has(CFG_STYLE_KEY):
		var vst := int(str(d[CFG_STYLE_KEY]))
		if vst != map_style: map_style = vst; changed = true
	if d.has(CFG_MODE_KEY):
		var vmo := int(str(d[CFG_MODE_KEY]))
		if vmo != game_mode: game_mode = vmo; changed = true
	if changed:
		lobby_config_changed.emit()

# ------------------------------------------------------------------
# Game start (host triggers, everyone changes scene)
# ------------------------------------------------------------------

func start_game() -> void:
	if not is_host:
		return
	if peers.size() < 1:
		return
	_set_state(State.IN_GAME)
	# Carry the world seed + config in the start event so every client builds the
	# exact same procedural city / difficulty even if lobby-data sync lagged.
	broadcast_event("game_started", {
		"seed": game_seed, "map": map_size, "players": max_players,
		"diff": difficulty, "style": map_style, "mode": game_mode,
	})
	_enter_game_scene()

func _enter_game_scene() -> void:
	game_started.emit()
	call_deferred("_do_scene_change")

func _do_scene_change() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

# ------------------------------------------------------------------
# Generic event channel (the GD-Sync equivalent of @rpc)
# ------------------------------------------------------------------

func broadcast_event(event_name: String, payload: Dictionary, reliable: bool = true) -> void:
	## Host -> all / any -> all. Delivered to every peer in the lobby, including
	## the local one (so senders see their own event, matching GD-Sync semantics).
	##
	## `reliable` defaults to true (guaranteed, ordered, retransmitted). Pass
	## false for high-frequency state (transforms, sound) — GD-Sync's reliable
	## calls "reattempt until successful", so flooding them at 20-30Hz builds a
	## retransmit backlog that shows up as lag. Unreliable drops the odd packet
	## instead, which the receiver's interpolation hides.
	if not _addon_available or not is_networked:
		# Single-player or pre-room: still surface locally so listeners are uniform.
		net_event.emit(event_name, payload)
		return
	var includes_self := false
	if reliable:
		if _gdsync.has_method("call_func_all"):
			_gdsync.callv("call_func_all", [_on_event_received, event_name, payload])
			includes_self = true
		elif _gdsync.has_method("call_func"):
			_gdsync.callv("call_func", [_on_event_received, event_name, payload])
	else:
		# Unreliable variants only target *other* clients, so we re-invoke locally.
		if _gdsync.has_method("call_func_unreliable"):
			_gdsync.callv("call_func_unreliable", [_on_event_received, event_name, payload])
		elif _gdsync.has_method("call_func_all"):
			_gdsync.callv("call_func_all", [_on_event_received, event_name, payload])
			includes_self = true
		elif _gdsync.has_method("call_func"):
			_gdsync.callv("call_func", [_on_event_received, event_name, payload])
	if not includes_self:
		_on_event_received(event_name, payload)

func send_event_to(peer_id: int, event_name: String, payload: Dictionary, reliable: bool = true) -> void:
	## Targeted delivery to a single peer (e.g. client -> host). See broadcast_event
	## for the meaning of `reliable`.
	if not _addon_available or not is_networked:
		if peer_id == local_peer_id:
			net_event.emit(event_name, payload)
		return
	if peer_id == local_peer_id:
		_on_event_received(event_name, payload)
		return
	if not reliable and _gdsync.has_method("call_func_on_unreliable"):
		_gdsync.callv("call_func_on_unreliable", [peer_id, _on_event_received, event_name, payload])
	elif _gdsync.has_method("call_func_on"):
		_gdsync.callv("call_func_on", [peer_id, _on_event_received, event_name, payload])

func host_peer_id() -> int:
	for pid in peers.keys():
		if peers[pid].is_host:
			return pid
	if is_host:
		return local_peer_id
	return -1

func sorted_peers() -> Array:
	# Stable order: host first, then by peer_id ascending.
	var ids: Array = peers.keys()
	ids.sort_custom(func(a, b):
		var ha: bool = peers[a].is_host
		var hb: bool = peers[b].is_host
		if ha != hb:
			return ha
		return a < b
	)
	var out: Array = []
	for pid in ids:
		out.append(peers[pid])
	return out

func _on_event_received(event_name: String, payload: Dictionary) -> void:
	# Roster / config bookkeeping handled here; everything else is forwarded
	# to gameplay listeners via net_event.
	match event_name:
		"hello":
			_on_hello_received(payload)
		"roster_sync":
			_apply_roster_sync(payload.get("peers", []))
		"cfg_sync":
			var changed := false
			if payload.has("map") and int(payload["map"]) != map_size: map_size = int(payload["map"]); changed = true
			if payload.has("players") and int(payload["players"]) != max_players: max_players = int(payload["players"]); changed = true
			if payload.has("diff") and int(payload["diff"]) != difficulty: difficulty = int(payload["diff"]); changed = true
			if payload.has("seed") and int(payload["seed"]) != game_seed: game_seed = int(payload["seed"]); changed = true
			if payload.has("style") and int(payload["style"]) != map_style: map_style = int(payload["style"]); changed = true
			if payload.has("mode") and int(payload["mode"]) != game_mode: game_mode = int(payload["mode"]); changed = true
			if changed:
				lobby_config_changed.emit()
		"game_started":
			if state != State.IN_GAME:
				# Adopt the host's world seed / config before loading the scene so
				# procedural generation matches across peers.
				if payload.has("seed"): game_seed = int(payload["seed"])
				if payload.has("map"): map_size = int(payload["map"])
				if payload.has("players"): max_players = int(payload["players"])
				if payload.has("diff"): difficulty = int(payload["diff"])
				if payload.has("style"): map_style = int(payload["style"])
				if payload.has("mode"): game_mode = int(payload["mode"])
				_set_state(State.IN_GAME)
				_enter_game_scene()
	net_event.emit(event_name, payload)

# ------------------------------------------------------------------
# GD-Sync signal wiring
# ------------------------------------------------------------------

func _wire_gdsync_signals() -> void:
	_connect_first(_gdsync, ["connected", "connection_succesful"], _on_connected)
	_connect_first(_gdsync, ["connection_failed"], _on_connection_failed)
	_connect_first(_gdsync, ["disconnected"], _on_disconnected)
	_connect_first(_gdsync, ["lobby_created"], _on_lobby_created)
	_connect_first(_gdsync, ["lobby_creation_failed"], _on_lobby_creation_failed)
	_connect_first(_gdsync, ["lobby_joined"], _on_lobby_joined)
	_connect_first(_gdsync, ["lobby_join_failed"], _on_lobby_join_failed)
	_connect_first(_gdsync, ["lobby_left"], _on_lobby_left)
	_connect_first(_gdsync, ["client_joined"], _on_client_joined)
	_connect_first(_gdsync, ["client_left"], _on_client_left)
	_connect_first(_gdsync, ["client_id_changed"], _on_client_id_changed)
	_connect_first(_gdsync, ["lobby_data_changed"], _on_lobby_data_changed)
	_connect_first(_gdsync, ["host_changed"], _on_host_changed)
	if _gdsync.has_method("expose_func"):
		_gdsync.expose_func(_on_event_received)

func _on_connected(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
	_gdsync_connected = true
	_try_dispatch_pending()

func _on_client_id_changed(_a: Variant = null, _b: Variant = null) -> void:
	_try_dispatch_pending()

func _try_dispatch_pending() -> void:
	if _did_dispatch or not _gdsync_connected:
		return
	if _safe_get_client_id() < 0 or _pending_action == "":
		return
	_did_dispatch = true
	await get_tree().process_frame
	var pending := _pending_action
	_pending_action = ""
	match pending:
		"host": _do_host()
		"join": _do_join()

func _on_connection_failed(a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
	_pending_action = ""
	_clear_connect_timeout()
	_set_state(State.OFFLINE)
	var code := int(a) if a != null else -1
	join_failed.emit("GD-Sync connection failed: %s" % _connection_failed_label(code))

func _connection_failed_label(code: int) -> String:
	match code:
		GDSYNC_INVALID_PUBLIC_KEY: return "invalid / missing API public key (configure it in Project → Tools → GD-Sync)"
		GDSYNC_TIMEOUT: return "timeout — couldn't reach the relay (check your connection / firewall)"
		GDSYNC_LOCAL_PORT_ERROR: return "local port error"
	return "error %d" % code

func _on_disconnected(_a: Variant = null, _b: Variant = null) -> void:
	_gdsync_connected = false
	var was_in_room := is_networked
	reset()
	_set_state(State.OFFLINE)
	if was_in_room:
		game_ended.emit()

func _on_lobby_created(_a: Variant = null, _b: Variant = null) -> void:
	# GD-Sync's lobby_create only registers the lobby; the creator must follow up
	# with lobby_join within ~5s or the lobby is auto-deleted (and a racing joiner
	# would become host). Issue the host self-join immediately.
	_pending_action = ""
	is_host = true
	_awaiting_self_join = true
	_clear_connect_timeout()
	_arm_connect_timeout()
	_do_self_join()

func _do_self_join() -> void:
	var method := _first_method(["lobby_join", "join_lobby", "join_multiplayer_lobby"])
	if method == "":
		_fail_host("installed GD-Sync version exposes no known join-lobby method")
		return
	_gdsync.callv(method, _trim_args_for(method, [game_code, ""]))

func _on_lobby_creation_failed(a: Variant = null, _b: Variant = null) -> void:
	_self_hosting = false
	_awaiting_self_join = false
	_pending_action = ""
	_clear_connect_timeout()
	_set_state(State.IN_LOBBY)
	join_failed.emit("Could not create room: %s" % str(a))

func _on_lobby_joined(_a: Variant = null, _b: Variant = null) -> void:
	_pending_action = ""
	_awaiting_self_join = false
	_clear_connect_timeout()
	# Host self-join preserves is_host (set in _on_lobby_created); real joiners
	# arrive with _self_hosting=false.
	is_host = _self_hosting
	is_networked = true
	local_peer_id = _safe_get_client_id()
	_set_state(State.IN_ROOM)
	if not local_player_name.is_empty():
		_set_username_safe(local_player_name)
	if is_host:
		_publish_config()
	else:
		_ingest_config_from_lobby_data()
		if _gdsync.has_method("lobby_get_player_limit"):
			var lim: Variant = _gdsync.call("lobby_get_player_limit")
			if lim is int and int(lim) > 0:
				max_players = int(lim)
	_register_local_peer()
	_publish_self_to_lobby_data()
	_refresh_roster_from_lobby()
	join_succeeded.emit()
	_send_hello()

func _on_lobby_join_failed(a: Variant = null, b: Variant = null, _c: Variant = null) -> void:
	var code := int(b) if b != null else -1
	var label := _lobby_join_error_label(code)
	_clear_connect_timeout()
	if _awaiting_self_join:
		_awaiting_self_join = false
		_self_hosting = false
		_pending_action = ""
		_set_state(State.IN_LOBBY)
		join_failed.emit("Hosting failed: created room %s but couldn't join it (%s)." % [game_code, label])
		return
	_pending_action = ""
	_set_state(State.IN_LOBBY)
	var hint := ""
	if code == GDSYNC_LOBBY_DOES_NOT_EXIST:
		hint = " — check the code, or ask the host to recreate the room (empty rooms expire quickly)."
	join_failed.emit("Could not join room %s: %s%s" % [game_code, label, hint])

func _lobby_join_error_label(code: int) -> String:
	match code:
		GDSYNC_LOBBY_DOES_NOT_EXIST: return "room does not exist"
		GDSYNC_LOBBY_IS_CLOSED: return "room is closed"
		GDSYNC_LOBBY_IS_FULL: return "room is full"
		GDSYNC_LOBBY_INCORRECT_PASSWORD: return "incorrect password"
		GDSYNC_LOBBY_DUPLICATE_USERNAME: return "name already taken"
	return "error %d" % code

func _on_lobby_left(_a: Variant = null, _b: Variant = null) -> void:
	reset()
	game_ended.emit()

func _on_client_joined(_peer_id: Variant = -1, _b: Variant = null) -> void:
	_refresh_roster_from_lobby()
	if is_host:
		broadcast_event("roster_sync", {"host_id": host_peer_id(), "peers": sorted_peers()})

func _on_client_left(peer_id: Variant = -1, _b: Variant = null) -> void:
	var pid := int(peer_id)
	if pid >= 0 and peers.has(pid):
		peers.erase(pid)
		peer_list_changed.emit()
	_refresh_roster_from_lobby()
	if is_host:
		broadcast_event("roster_sync", {"host_id": host_peer_id(), "peers": sorted_peers()})

func _on_lobby_data_changed(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
	if state == State.IN_ROOM or state == State.IN_GAME:
		_ingest_config_from_lobby_data()
		_ingest_peers_from_lobby_data()
		_refresh_roster_from_lobby()

func _on_host_changed(_a: Variant = null, _b: Variant = null) -> void:
	if state == State.IN_ROOM or state == State.IN_GAME:
		_refresh_roster_from_lobby()

# ------------------------------------------------------------------
# Roster (via shared lobby data + hello handshake)
# ------------------------------------------------------------------

func _on_roster_poll_tick() -> void:
	if state != State.IN_ROOM and state != State.IN_GAME or _gdsync == null:
		return
	var changed := _ingest_peers_from_lobby_data()
	_publish_self_to_lobby_data()
	if changed:
		_refresh_roster_from_lobby()
		if is_host:
			broadcast_event("roster_sync", {"host_id": host_peer_id(), "peers": sorted_peers()})

## Measure round-trip latency to the other player(s) and cache it in `ping_ms`.
## Async — GD-Sync's get_client_ping runs a short ping exchange and awaits the
## replies — so a re-entry guard stops overlapping measurements from stacking.
func _on_ping_poll_tick() -> void:
	if _ping_in_flight:
		return
	if not is_networked or _gdsync == null or not _gdsync.has_method("get_client_ping"):
		_set_ping(-1.0)
		return
	# Client → host; host → average over its clients. This gives every peer a
	# single "my latency" number without needing to know the topology.
	var targets: Array = []
	if is_host:
		for pid in peers.keys():
			if pid != local_peer_id:
				targets.append(pid)
	else:
		var h := host_peer_id()
		if h >= 0:
			targets.append(h)
	if targets.is_empty():
		_set_ping(-1.0)
		return

	_ping_in_flight = true
	var total := 0.0
	var count := 0
	for t in targets:
		# get_client_ping returns the RTT in seconds (or -1 on failure).
		var rtt: Variant = await _gdsync.get_client_ping(int(t))
		var secs := float(rtt) if (rtt is float or rtt is int) else -1.0
		if secs >= 0.0:
			total += secs
			count += 1
	_ping_in_flight = false
	_set_ping(total / float(count) * 1000.0 if count > 0 else -1.0)

func _set_ping(ms: float) -> void:
	ping_ms = ms

func _publish_self_to_lobby_data() -> void:
	if _gdsync == null or not _gdsync.has_method("lobby_set_data") or local_peer_id < 0:
		return
	var key := "%s%d" % [LOBBY_DATA_PEER_PREFIX, local_peer_id]
	_gdsync.call("lobby_set_data", key, "%s|%d" % [local_player_name, 1 if is_host else 0])

func _ingest_peers_from_lobby_data() -> bool:
	if _gdsync == null or not _gdsync.has_method("lobby_get_all_data"):
		return false
	var data: Variant = _gdsync.call("lobby_get_all_data")
	if not (data is Dictionary):
		return false
	var changed := false
	for raw_key in (data as Dictionary).keys():
		var key := String(raw_key)
		if not key.begins_with(LOBBY_DATA_PEER_PREFIX):
			continue
		var pid := int(key.substr(LOBBY_DATA_PEER_PREFIX.length()))
		if pid < 0:
			continue
		var parts := String(data[raw_key]).split("|")
		var uname := parts[0] if parts.size() > 0 else "Player %d" % pid
		var p_is_host := parts.size() > 1 and parts[1] == "1"
		var existing: Dictionary = peers.get(pid, {})
		if existing.is_empty() or String(existing.get("name", "")) != uname or bool(existing.get("is_host", false)) != p_is_host:
			peers[pid] = {"id": pid, "name": uname, "is_host": p_is_host}
			changed = true
	if changed:
		peer_list_changed.emit()
	return changed

func _refresh_roster_from_lobby() -> void:
	_ingest_peers_from_lobby_data()
	if _gdsync != null and _gdsync.has_method("lobby_get_all_clients"):
		var raw_ids: Variant = _gdsync.call("lobby_get_all_clients")
		if raw_ids is Array:
			var resolved_host := host_peer_id()
			for raw in raw_ids:
				var pid := int(raw)
				if pid < 0 or peers.has(pid):
					continue
				peers[pid] = {
					"id": pid,
					"name": local_player_name if pid == local_peer_id else _peer_username(pid),
					"is_host": pid == resolved_host,
				}
	if local_peer_id >= 0 and not peers.has(local_peer_id):
		peers[local_peer_id] = {"id": local_peer_id, "name": local_player_name, "is_host": is_host}
	peer_list_changed.emit()

func _register_local_peer() -> void:
	peers.clear()
	peers[local_peer_id] = {"id": local_peer_id, "name": local_player_name, "is_host": is_host}
	peer_list_changed.emit()

func _send_hello() -> void:
	broadcast_event("hello", {"peer_id": local_peer_id, "name": local_player_name, "is_host": is_host})

func _on_hello_received(payload: Dictionary) -> void:
	var pid := int(payload.get("peer_id", -1))
	if pid < 0 or pid == local_peer_id:
		return
	var was_known := peers.has(pid)
	peers[pid] = {
		"id": pid,
		"name": String(payload.get("name", "Player %d" % pid)),
		"is_host": bool(payload.get("is_host", false)),
	}
	peer_list_changed.emit()
	if is_host:
		# Reply with the canonical roster + config so newcomers sync up.
		broadcast_event("roster_sync", {"host_id": host_peer_id(), "peers": sorted_peers()})
		broadcast_event("cfg_sync", {"map": map_size, "players": max_players, "diff": difficulty, "seed": game_seed, "style": map_style, "mode": game_mode})
		broadcast_event("hello", {"peer_id": local_peer_id, "name": local_player_name, "is_host": true})

func _apply_roster_sync(remote_peers: Array) -> void:
	peers.clear()
	for entry in remote_peers:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var pid := int(entry.get("id", -1))
		if pid < 0:
			continue
		peers[pid] = {
			"id": pid,
			"name": String(entry.get("name", "Player %d" % pid)),
			"is_host": bool(entry.get("is_host", false)),
		}
	if peers.has(local_peer_id):
		peers[local_peer_id].name = local_player_name
	peer_list_changed.emit()

# ------------------------------------------------------------------
# Internals
# ------------------------------------------------------------------

func _do_host() -> void:
	var method := _first_method(["lobby_create", "create_lobby", "host_lobby"])
	if method == "":
		_fail_host("installed GD-Sync version exposes no known create-lobby method")
		return
	# lobby_create(name, password, public, player_limit, tags, data). public=true
	# so the lobby resolves by name on join; the room code is the real privacy.
	var full_args: Array = [
		game_code, "", true, _pending_max_players,
		{}, {"game": "vibe-zombie", "max_players": _pending_max_players},
	]
	var result: Variant = _gdsync.callv(method, _trim_args_for(method, full_args))
	if result == false:
		_fail_host("%s returned false — check addon configuration" % method)

func _do_join() -> void:
	var method := _first_method(["lobby_join", "join_lobby", "join_multiplayer_lobby"])
	if method == "":
		_pending_action = ""
		_clear_connect_timeout()
		_set_state(State.IN_LOBBY)
		join_failed.emit("Installed GD-Sync version exposes no known join-lobby method.")
		return
	var result: Variant = _gdsync.callv(method, _trim_args_for(method, [game_code, ""]))
	if result == false:
		_pending_action = ""
		_clear_connect_timeout()
		_set_state(State.IN_LOBBY)
		join_failed.emit("Join failed — make sure the code is correct.")

func _fail_host(reason: String) -> void:
	_pending_action = ""
	_self_hosting = false
	_awaiting_self_join = false
	_clear_connect_timeout()
	_set_state(State.IN_LOBBY if _gdsync_connected else State.OFFLINE)
	join_failed.emit("Hosting failed: %s." % reason)

func _start_connection() -> void:
	if _gdsync == null:
		return
	for m in ["start_multiplayer", "connect_to_server", "start"]:
		if _gdsync.has_method(m):
			_gdsync.call(m)
			return

func _arm_connect_timeout() -> void:
	_clear_connect_timeout()
	_connect_timeout_timer = get_tree().create_timer(CONNECT_TIMEOUT_SEC)
	_connect_timeout_timer.timeout.connect(_on_connect_timeout)

func _clear_connect_timeout() -> void:
	_connect_timeout_timer = null

func _on_connect_timeout() -> void:
	if _connect_timeout_timer == null or state != State.CONNECTING:
		_connect_timeout_timer = null
		return
	_connect_timeout_timer = null
	_pending_action = ""
	_set_state(State.OFFLINE if not _gdsync_connected else State.IN_LOBBY)
	join_failed.emit("Timed out reaching GD-Sync. Check the addon's API key (Project → Tools → GD-Sync) and your connection.")

func _set_state(s: int) -> void:
	state = s
	is_networked = (s == State.IN_ROOM or s == State.IN_GAME)

func _ensure_addon() -> bool:
	if _addon_available:
		return true
	join_failed.emit("GD-Sync addon is not installed/enabled. Enable the plugin and set its API key in Project → Tools → GD-Sync.")
	return false

func _resolve_gdsync() -> Node:
	# GD-Sync registers an autoload named "GDSync" under the scene-tree root.
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	if tree.root.has_node("GDSync"):
		return tree.root.get_node("GDSync")
	return null

func _connect_first(obj: Object, signal_names: Array, callable: Callable) -> void:
	if obj == null:
		return
	for sn in signal_names:
		if obj.has_signal(sn):
			if not obj.is_connected(sn, callable):
				obj.connect(sn, callable)
			return

func _first_method(method_names: Array) -> String:
	if _gdsync == null:
		return ""
	for m in method_names:
		if _gdsync.has_method(m):
			return m
	return ""

func _trim_args_for(method_name: String, candidate_args: Array) -> Array:
	# callv errors if too many args are passed; slice to the method's arity.
	if _gdsync == null:
		return candidate_args
	for entry in _gdsync.get_method_list():
		if String(entry.name) != method_name:
			continue
		var param_count: int = (entry.args as Array).size()
		if param_count >= candidate_args.size():
			return candidate_args
		return candidate_args.slice(0, param_count)
	return candidate_args

func _set_username_safe(uname: String) -> void:
	if _gdsync == null:
		return
	if _gdsync.has_method("player_set_username"):
		_gdsync.call("player_set_username", uname)
	elif _gdsync.has_method("set_player_data"):
		_gdsync.call("set_player_data", "username", uname)

func _safe_get_client_id() -> int:
	if _gdsync == null:
		return -1
	for m in ["get_client_id", "get_my_id"]:
		if _gdsync.has_method(m):
			return int(_gdsync.call(m))
	return -1

func _peer_username(peer_id: int) -> String:
	if _gdsync != null:
		if _gdsync.has_method("player_get_username"):
			var v: Variant = _gdsync.call("player_get_username", peer_id)
			if v is String and not String(v).is_empty():
				return v
	return "Player %d" % peer_id

func _generate_code() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for _i in range(CODE_LENGTH):
		s += CODE_ALPHABET[rng.randi() % CODE_ALPHABET.length()]
	return s
