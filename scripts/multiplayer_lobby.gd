extends Control

## Pre-game lobby — shown after creating or joining a multiplayer game.
##
## Displays:
##   - The game code prominently (so the host can share it)
##   - The current peer list
##   - The lobby configuration (map size / players / difficulty), editable by the host
##   - Start Game (host only) / Leave buttons

const MenuShared = preload("res://scripts/menu_shared.gd")

const PANEL_WIDTH := 640.0
const PANEL_HEIGHT := 560.0

var _center: CenterContainer
var _panel: PanelContainer
var _code_label: Label
var _peer_list_vbox: VBoxContainer
var _config_summary: Label
var _start_btn: Button
var _status_label: Label
var _difficulty_buttons: Array[Button] = []
var _map_size_label: Label = null
var _max_players_label: Label = null

func _ready() -> void:
	_build_ui()

	NetworkManager.peer_list_changed.connect(_refresh_peers)
	NetworkManager.lobby_config_changed.connect(_refresh_config)
	NetworkManager.game_ended.connect(_on_game_ended)
	NetworkManager.game_started.connect(_on_game_started)

	_refresh_peers()
	_refresh_config()

func _exit_tree() -> void:
	if NetworkManager.peer_list_changed.is_connected(_refresh_peers):
		NetworkManager.peer_list_changed.disconnect(_refresh_peers)
	if NetworkManager.lobby_config_changed.is_connected(_refresh_config):
		NetworkManager.lobby_config_changed.disconnect(_refresh_config)
	if NetworkManager.game_ended.is_connected(_on_game_ended):
		NetworkManager.game_ended.disconnect(_on_game_ended)
	if NetworkManager.game_started.is_connected(_on_game_started):
		NetworkManager.game_started.disconnect(_on_game_started)

func _build_ui() -> void:
	var s := MenuShared.ui_scale()

	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH * s, PANEL_HEIGHT * s)
	_panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	_center.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(12 * s))
	_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "GAME LOBBY"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(28 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	# --- Game code (big, prominent) ---
	var code_box := PanelContainer.new()
	var code_style := StyleBoxFlat.new()
	code_style.bg_color = Color(0.16, 0.13, 0.10, 0.95)
	code_style.border_color = Color(0.85, 0.65, 0.30, 0.7)
	var bw := int(max(1, 2 * s))
	code_style.border_width_left = bw
	code_style.border_width_right = bw
	code_style.border_width_top = bw
	code_style.border_width_bottom = bw
	var rd := int(8 * s)
	code_style.corner_radius_top_left = rd
	code_style.corner_radius_top_right = rd
	code_style.corner_radius_bottom_left = rd
	code_style.corner_radius_bottom_right = rd
	code_style.content_margin_left = int(20 * s)
	code_style.content_margin_right = int(20 * s)
	code_style.content_margin_top = int(12 * s)
	code_style.content_margin_bottom = int(12 * s)
	code_box.add_theme_stylebox_override("panel", code_style)
	vbox.add_child(code_box)

	var code_vbox := VBoxContainer.new()
	code_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	code_box.add_child(code_vbox)

	var code_caption := Label.new()
	code_caption.text = "GAME CODE"
	code_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_caption.add_theme_font_size_override("font_size", int(13 * s))
	code_caption.add_theme_color_override("font_color", Color(0.70, 0.65, 0.45))
	code_vbox.add_child(code_caption)

	_code_label = Label.new()
	_code_label.text = NetworkManager.game_code
	_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_label.add_theme_font_size_override("font_size", int(56 * s))
	_code_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.55))
	_code_label.add_theme_constant_override("outline_size", int(3 * s))
	_code_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	code_vbox.add_child(_code_label)

	var hint := Label.new()
	if NetworkManager.is_host:
		hint.text = "Share this code with friends on your network"
	else:
		hint.text = "Connected — waiting for the host to start"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", int(12 * s))
	hint.add_theme_color_override("font_color", Color(0.60, 0.60, 0.55))
	code_vbox.add_child(hint)

	# --- Two-column layout: peer list | config ---
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", int(16 * s))
	vbox.add_child(split)

	# Peer list (left)
	var peers_panel := PanelContainer.new()
	peers_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	peers_panel.custom_minimum_size = Vector2(260 * s, 220 * s)
	var peer_style := StyleBoxFlat.new()
	peer_style.bg_color = Color(0.08, 0.08, 0.10, 0.85)
	peer_style.content_margin_left = int(12 * s)
	peer_style.content_margin_right = int(12 * s)
	peer_style.content_margin_top = int(10 * s)
	peer_style.content_margin_bottom = int(10 * s)
	peer_style.corner_radius_top_left = int(6 * s)
	peer_style.corner_radius_top_right = int(6 * s)
	peer_style.corner_radius_bottom_left = int(6 * s)
	peer_style.corner_radius_bottom_right = int(6 * s)
	peers_panel.add_theme_stylebox_override("panel", peer_style)
	split.add_child(peers_panel)

	var peers_vbox := VBoxContainer.new()
	peers_vbox.add_theme_constant_override("separation", int(6 * s))
	peers_panel.add_child(peers_vbox)

	var peers_title := Label.new()
	peers_title.text = "PLAYERS"
	peers_title.add_theme_font_size_override("font_size", int(14 * s))
	peers_title.add_theme_color_override("font_color", Color(0.75, 0.72, 0.62))
	peers_vbox.add_child(peers_title)

	_peer_list_vbox = VBoxContainer.new()
	_peer_list_vbox.add_theme_constant_override("separation", int(4 * s))
	peers_vbox.add_child(_peer_list_vbox)

	# Config (right)
	var config_panel := PanelContainer.new()
	config_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	config_panel.add_theme_stylebox_override("panel", peer_style)
	split.add_child(config_panel)

	var config_vbox := VBoxContainer.new()
	config_vbox.add_theme_constant_override("separation", int(8 * s))
	config_panel.add_child(config_vbox)

	var cfg_title := Label.new()
	cfg_title.text = "GAME SETTINGS"
	cfg_title.add_theme_font_size_override("font_size", int(14 * s))
	cfg_title.add_theme_color_override("font_color", Color(0.75, 0.72, 0.62))
	config_vbox.add_child(cfg_title)

	if NetworkManager.is_host:
		_build_host_config_controls(config_vbox, s)
	else:
		_config_summary = Label.new()
		_config_summary.add_theme_font_size_override("font_size", int(14 * s))
		_config_summary.add_theme_color_override("font_color", Color(0.85, 0.85, 0.78))
		_config_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		config_vbox.add_child(_config_summary)

	# Status / footer
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", int(12 * s))
	_status_label.add_theme_color_override("font_color", Color(0.60, 0.60, 0.55))
	vbox.add_child(_status_label)

	# --- Action row ---
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(actions)

	var leave_btn := MenuShared.make_button("Leave", s, 160, 44, 16)
	leave_btn.pressed.connect(_on_leave)
	actions.add_child(leave_btn)

	if NetworkManager.is_host:
		_start_btn = MenuShared.make_button("Start Game", s, 240, 48, 18)
		_start_btn.pressed.connect(_on_start)
		actions.add_child(_start_btn)

func _build_host_config_controls(parent: VBoxContainer, s: float) -> void:
	# Map size
	var ms_row := HBoxContainer.new()
	ms_row.add_theme_constant_override("separation", int(8 * s))
	parent.add_child(ms_row)

	var ms_lbl := Label.new()
	ms_lbl.text = "Map size:"
	ms_lbl.custom_minimum_size = Vector2(120 * s, 0)
	ms_lbl.add_theme_font_size_override("font_size", int(13 * s))
	ms_row.add_child(ms_lbl)

	var ms_minus := MenuShared.make_button("-", s, 36, 32, 14)
	ms_minus.pressed.connect(func() -> void:
		NetworkManager.set_map_size(NetworkManager.map_size - 1)
	)
	ms_row.add_child(ms_minus)

	_map_size_label = Label.new()
	_map_size_label.custom_minimum_size = Vector2(110 * s, 32 * s)
	_map_size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_map_size_label.add_theme_font_size_override("font_size", int(15 * s))
	_map_size_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78))
	ms_row.add_child(_map_size_label)

	var ms_plus := MenuShared.make_button("+", s, 36, 32, 14)
	ms_plus.pressed.connect(func() -> void:
		NetworkManager.set_map_size(NetworkManager.map_size + 1)
	)
	ms_row.add_child(ms_plus)

	# Max players
	var mp_row := HBoxContainer.new()
	mp_row.add_theme_constant_override("separation", int(8 * s))
	parent.add_child(mp_row)

	var mp_lbl := Label.new()
	mp_lbl.text = "Players:"
	mp_lbl.custom_minimum_size = Vector2(120 * s, 0)
	mp_lbl.add_theme_font_size_override("font_size", int(13 * s))
	mp_row.add_child(mp_lbl)

	var mp_minus := MenuShared.make_button("-", s, 36, 32, 14)
	mp_minus.pressed.connect(func() -> void:
		NetworkManager.set_max_players(NetworkManager.max_players - 1)
	)
	mp_row.add_child(mp_minus)

	_max_players_label = Label.new()
	_max_players_label.custom_minimum_size = Vector2(110 * s, 32 * s)
	_max_players_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_max_players_label.add_theme_font_size_override("font_size", int(15 * s))
	_max_players_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78))
	mp_row.add_child(_max_players_label)

	var mp_plus := MenuShared.make_button("+", s, 36, 32, 14)
	mp_plus.pressed.connect(func() -> void:
		NetworkManager.set_max_players(NetworkManager.max_players + 1)
	)
	mp_row.add_child(mp_plus)

	# Difficulty
	var diff_lbl := Label.new()
	diff_lbl.text = "Difficulty:"
	diff_lbl.add_theme_font_size_override("font_size", int(13 * s))
	parent.add_child(diff_lbl)

	var diff_row := HBoxContainer.new()
	diff_row.add_theme_constant_override("separation", int(4 * s))
	parent.add_child(diff_row)

	var labels := ["Easy", "Med", "Tough", "Night"]
	for i in range(labels.size()):
		var btn := MenuShared.make_button(labels[i], s, 78, 36, 13)
		var idx := i
		btn.pressed.connect(func() -> void:
			NetworkManager.set_difficulty(idx)
		)
		_difficulty_buttons.append(btn)
		diff_row.add_child(btn)

# ------------------------------------------------------------------
# Refresh handlers
# ------------------------------------------------------------------

func _refresh_peers() -> void:
	if _peer_list_vbox == null:
		return
	for child in _peer_list_vbox.get_children():
		child.queue_free()

	var s := MenuShared.ui_scale()
	var ids := NetworkManager.peers.keys()
	ids.sort()
	for id in ids:
		var info: Dictionary = NetworkManager.peers[id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", int(8 * s))
		_peer_list_vbox.add_child(row)

		var dot := ColorRect.new()
		dot.color = Color(0.30, 0.80, 0.35) if id == 1 else Color(0.40, 0.60, 0.85)
		dot.custom_minimum_size = Vector2(10 * s, 10 * s)
		row.add_child(dot)

		var lbl := Label.new()
		lbl.text = "%s%s" % [info.get("name", "Player"), "  (you)" if id == multiplayer.get_unique_id() else ""]
		lbl.add_theme_font_size_override("font_size", int(14 * s))
		lbl.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
		row.add_child(lbl)

	# Bump status if we hit player cap
	if _status_label:
		var n := NetworkManager.peers.size()
		var cap := NetworkManager.max_players
		_status_label.text = "%d / %d players in lobby" % [n, cap]

func _refresh_config() -> void:
	_code_label.text = NetworkManager.game_code

	if _map_size_label:
		_map_size_label.text = "%d x %d" % [NetworkManager.map_size, NetworkManager.map_size]
	if _max_players_label:
		_max_players_label.text = "%d" % NetworkManager.max_players

	# Highlight selected difficulty button (host)
	for i in range(_difficulty_buttons.size()):
		var btn := _difficulty_buttons[i]
		var s := MenuShared.ui_scale()
		if i == NetworkManager.difficulty:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(_difficulty_color(i), s))
			btn.add_theme_color_override("font_color", Color(1, 1, 1))
		else:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
			btn.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))

	# Client-side summary
	if _config_summary:
		_config_summary.text = "Map: %dx%d\nPlayers: up to %d\nDifficulty: %s" % [
			NetworkManager.map_size,
			NetworkManager.map_size,
			NetworkManager.max_players,
			NetworkManager.difficulty_name(NetworkManager.difficulty),
		]

func _difficulty_color(d: int) -> Color:
	match d:
		0: return Color(0.30, 0.65, 0.30)
		1: return Color(0.55, 0.65, 0.30)
		2: return Color(0.75, 0.55, 0.20)
		3: return Color(0.80, 0.20, 0.20)
	return Color(0.5, 0.5, 0.5)

# ------------------------------------------------------------------
# Buttons
# ------------------------------------------------------------------

func _on_start() -> void:
	if not NetworkManager.is_host:
		return
	if NetworkManager.peers.size() < 1:
		return
	NetworkManager.start_game()

func _on_leave() -> void:
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://scenes/TitleMenu.tscn")

func _on_game_started() -> void:
	# Scene change is handled by NetworkManager
	pass

func _on_game_ended() -> void:
	get_tree().change_scene_to_file("res://scenes/TitleMenu.tscn")
