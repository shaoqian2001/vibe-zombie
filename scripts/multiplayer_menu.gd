extends Control

## Multiplayer menu — user enters here from the title screen "Multiplayer" button.
##
## Two top-level actions:
##   - Create Game: configure map size / number of players / difficulty, then host.
##   - Join Game:   enter a 6-character code to connect to a host on the LAN.
##
## After hosting or joining, control transfers to the lobby (multiplayer_lobby.gd).

const MenuShared = preload("res://scripts/menu_shared.gd")

const BUTTON_WIDTH := 320.0
const BUTTON_HEIGHT := 50.0
const SECTION_GAP := 16.0

enum View { ROOT, CREATE, JOIN }

var _center: CenterContainer
var _root_panel: PanelContainer = null
var _create_panel: PanelContainer = null
var _join_panel: PanelContainer = null
var _join_status_label: Label = null

# Create-game working state (mirrors NetworkManager defaults)
var _create_map_size: int = 9
var _create_max_players: int = 4
var _create_difficulty: int = NetworkManager.Difficulty.MEDIUM

func _ready() -> void:
	_build_root()

	# Hook up join feedback so we can show errors / push to lobby on success.
	if not NetworkManager.join_succeeded.is_connected(_on_join_succeeded):
		NetworkManager.join_succeeded.connect(_on_join_succeeded)
	if not NetworkManager.join_failed.is_connected(_on_join_failed):
		NetworkManager.join_failed.connect(_on_join_failed)

func _build_root() -> void:
	var s := MenuShared.ui_scale()

	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var vignette := ColorRect.new()
	vignette.color = Color(0.0, 0.0, 0.0, 0.3)
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vignette)

	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	_show_root_panel(s)

func _show_root_panel(s: float) -> void:
	_root_panel = PanelContainer.new()
	_root_panel.custom_minimum_size = Vector2(480 * s, 420 * s)
	_root_panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	_center.add_child(_root_panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", int(14 * s))
	_root_panel.add_child(vbox)

	var title := Label.new()
	title.text = "MULTIPLAYER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(34 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Survive the apocalypse with friends"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", int(14 * s))
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.55, 0.50))
	vbox.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20 * s)
	vbox.add_child(spacer)

	var create_btn := MenuShared.make_button("Create Game", s, BUTTON_WIDTH, BUTTON_HEIGHT, 22)
	create_btn.pressed.connect(_show_create)
	vbox.add_child(create_btn)

	var join_btn := MenuShared.make_button("Join Game", s, BUTTON_WIDTH, BUTTON_HEIGHT, 22)
	join_btn.pressed.connect(_show_join)
	vbox.add_child(join_btn)

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 12 * s)
	vbox.add_child(spacer2)

	var back_btn := MenuShared.make_button("Back", s, 160, 38, 16)
	back_btn.pressed.connect(_back_to_title)
	vbox.add_child(back_btn)

func _back_to_title() -> void:
	get_tree().change_scene_to_file("res://scenes/TitleMenu.tscn")

# ------------------------------------------------------------------
# Create-game panel
# ------------------------------------------------------------------

func _show_create() -> void:
	if _root_panel:
		_root_panel.visible = false
	if _create_panel:
		_create_panel.visible = true
		return

	var s := MenuShared.ui_scale()
	_create_panel = PanelContainer.new()
	_create_panel.custom_minimum_size = Vector2(540 * s, 540 * s)
	_create_panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	_center.add_child(_create_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(12 * s))
	_create_panel.add_child(vbox)

	var title := Label.new()
	title.text = "CREATE GAME"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(28 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	# --- Map size (5..20) ---
	vbox.add_child(_make_section_label("Map Size (NxN city blocks)", s))
	var map_size_row := _make_stepper_row(s,
		_create_map_size, 5, 20,
		func(v: int) -> void: _create_map_size = v,
		func(v: int) -> String: return "%d x %d  (%d blocks)" % [v, v, v * v]
	)
	vbox.add_child(map_size_row)

	# --- Number of players (2..8) ---
	vbox.add_child(_make_section_label("Number of Players", s))
	var players_row := _make_stepper_row(s,
		_create_max_players, 2, 8,
		func(v: int) -> void: _create_max_players = v,
		func(v: int) -> String: return "%d players" % v
	)
	vbox.add_child(players_row)

	# --- Difficulty ---
	vbox.add_child(_make_section_label("Difficulty", s))
	vbox.add_child(_make_difficulty_row(s))

	# --- Difficulty description ---
	var desc := Label.new()
	desc.name = "DifficultyDesc"
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.add_theme_font_size_override("font_size", int(13 * s))
	desc.add_theme_color_override("font_color", Color(0.60, 0.62, 0.55))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 48 * s)
	vbox.add_child(desc)
	_update_difficulty_desc(desc)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8 * s)
	vbox.add_child(spacer)

	# --- Action row (Host + Back) ---
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(actions)

	var back_btn := MenuShared.make_button("Back", s, 140, 42, 16)
	back_btn.pressed.connect(_close_subpanel)
	actions.add_child(back_btn)

	var host_btn := MenuShared.make_button("Host Game", s, 220, 46, 18)
	host_btn.pressed.connect(_on_host_pressed)
	actions.add_child(host_btn)

func _make_section_label(text: String, s: float) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(15 * s))
	lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	return lbl

func _make_stepper_row(s: float, start_val: int, lo: int, hi: int, on_change: Callable, format: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(12 * s))

	var minus := MenuShared.make_button("-", s, 50, 38, 18)
	row.add_child(minus)

	var lbl := Label.new()
	lbl.text = format.call(start_val)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(220 * s, 38 * s)
	lbl.add_theme_font_size_override("font_size", int(18 * s))
	lbl.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78))
	row.add_child(lbl)

	var plus := MenuShared.make_button("+", s, 50, 38, 18)
	row.add_child(plus)

	var current := [start_val]
	minus.pressed.connect(func() -> void:
		var v: int = max(lo, current[0] - 1)
		current[0] = v
		lbl.text = format.call(v)
		on_change.call(v)
	)
	plus.pressed.connect(func() -> void:
		var v: int = min(hi, current[0] + 1)
		current[0] = v
		lbl.text = format.call(v)
		on_change.call(v)
	)
	return row

func _make_difficulty_row(s: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(8 * s))

	var labels := ["Easy", "Medium", "Tough", "Nightmare"]
	var colors := [
		Color(0.30, 0.65, 0.30),
		Color(0.55, 0.65, 0.30),
		Color(0.75, 0.55, 0.20),
		Color(0.80, 0.20, 0.20),
	]
	var buttons: Array[Button] = []

	for i in range(labels.size()):
		var btn := MenuShared.make_button(labels[i], s, 110, 42, 16)
		var idx := i
		btn.pressed.connect(func() -> void:
			_create_difficulty = idx
			_refresh_difficulty_buttons(buttons, colors)
			var desc := _create_panel.find_child("DifficultyDesc", true, false) as Label
			if desc:
				_update_difficulty_desc(desc)
		)
		buttons.append(btn)
		row.add_child(btn)

	_refresh_difficulty_buttons(buttons, colors)
	return row

func _refresh_difficulty_buttons(buttons: Array[Button], colors: Array) -> void:
	var s := MenuShared.ui_scale()
	for i in range(buttons.size()):
		var btn := buttons[i]
		if i == _create_difficulty:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(colors[i], s))
			btn.add_theme_color_override("font_color", Color(1, 1, 1))
		else:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
			btn.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))

func _update_difficulty_desc(desc: Label) -> void:
	var settings := NetworkManager.difficulty_settings(_create_difficulty)
	desc.text = "Zombie density x%.1f  •  Horde size x%.1f  •  %d starting hordes" % [
		settings.enemies_per_block / 2.0,
		settings.horde_mult,
		settings.starting_hordes,
	]

func _on_host_pressed() -> void:
	var code := NetworkManager.host_game(_create_map_size, _create_max_players, _create_difficulty)
	if code.is_empty():
		_show_temporary_message("Failed to create server (port in use?)")
		return
	_open_lobby()

# ------------------------------------------------------------------
# Join-game panel
# ------------------------------------------------------------------

func _show_join() -> void:
	if _root_panel:
		_root_panel.visible = false
	if _join_panel:
		_join_panel.visible = true
		_join_status_label.text = ""
		return

	var s := MenuShared.ui_scale()
	_join_panel = PanelContainer.new()
	_join_panel.custom_minimum_size = Vector2(480 * s, 360 * s)
	_join_panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	_center.add_child(_join_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(14 * s))
	_join_panel.add_child(vbox)

	var title := Label.new()
	title.text = "JOIN GAME"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(28 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	var prompt := Label.new()
	prompt.text = "Enter the host's 6-character game code"
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.add_theme_font_size_override("font_size", int(14 * s))
	prompt.add_theme_color_override("font_color", Color(0.65, 0.65, 0.60))
	vbox.add_child(prompt)

	var code_input := LineEdit.new()
	code_input.placeholder_text = "ABCD23"
	code_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_input.max_length = NetworkManager.CODE_LENGTH
	code_input.custom_minimum_size = Vector2(280 * s, 56 * s)
	code_input.add_theme_font_size_override("font_size", int(28 * s))
	code_input.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78))

	var input_row := HBoxContainer.new()
	input_row.alignment = BoxContainer.ALIGNMENT_CENTER
	input_row.add_child(code_input)
	vbox.add_child(input_row)

	_join_status_label = Label.new()
	_join_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_join_status_label.add_theme_font_size_override("font_size", int(13 * s))
	_join_status_label.add_theme_color_override("font_color", Color(0.85, 0.55, 0.45))
	_join_status_label.custom_minimum_size = Vector2(0, 40 * s)
	vbox.add_child(_join_status_label)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(actions)

	var back_btn := MenuShared.make_button("Back", s, 140, 42, 16)
	back_btn.pressed.connect(_close_subpanel)
	actions.add_child(back_btn)

	var connect_btn := MenuShared.make_button("Connect", s, 220, 46, 18)
	connect_btn.pressed.connect(func() -> void:
		var code := code_input.text.strip_edges().to_upper()
		if code.length() == 0:
			_join_status_label.text = "Please enter a code"
			return
		_join_status_label.text = "Searching for host on LAN..."
		_join_status_label.add_theme_color_override("font_color", Color(0.70, 0.85, 0.55))
		NetworkManager.join_game(code)
	)
	actions.add_child(connect_btn)

	# Pressing Enter in the field triggers Connect.
	code_input.text_submitted.connect(func(_t: String) -> void: connect_btn.emit_signal("pressed"))

func _on_join_succeeded() -> void:
	if _join_status_label:
		_join_status_label.text = "Connected!"
	_open_lobby()

func _on_join_failed(reason: String) -> void:
	if _join_status_label:
		_join_status_label.add_theme_color_override("font_color", Color(0.85, 0.55, 0.45))
		_join_status_label.text = reason

# ------------------------------------------------------------------
# Sub-panel housekeeping
# ------------------------------------------------------------------

func _close_subpanel() -> void:
	if _create_panel:
		_create_panel.queue_free()
		_create_panel = null
	if _join_panel:
		_join_panel.queue_free()
		_join_panel = null
	if _root_panel:
		_root_panel.visible = true

func _show_temporary_message(text: String) -> void:
	push_warning(text)

func _open_lobby() -> void:
	get_tree().change_scene_to_file("res://scenes/MultiplayerLobby.tscn")
