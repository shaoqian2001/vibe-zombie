extends Control

## Single-player setup screen — pick difficulty and map style before
## launching the game. Map size is no longer user-configurable; each
## style ships with a pre-tuned grid size (see BuildingCatalog.STYLE_MAP_SIZE).
##
## Writes the chosen settings to NetworkManager (which world.gd reads on
## scene load) and then transitions to Main.tscn. The same NetworkManager
## fields back multiplayer config, so the in-game scripts don't need to
## care which mode they were launched from.

const MenuShared = preload("res://scripts/menu_shared.gd")
const BuildingCatalog = preload("res://scripts/building_catalog.gd")

var _center: CenterContainer
var _create_panel: PanelContainer = null
var _map_size_label: Label = null

var _difficulty: int = NetworkManager.Difficulty.MEDIUM
var _map_style: int = BuildingCatalog.MapStyle.DOWNTOWN
var _game_mode: int = NetworkManager.GameMode.CAMPAIGN

func _ready() -> void:
	_build_ui()

func _build_ui() -> void:
	var s := MenuShared.ui_scale()

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

	_create_panel = PanelContainer.new()
	_create_panel.custom_minimum_size = Vector2(580 * s, 740 * s)
	_create_panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	_center.add_child(_create_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(12 * s))
	_create_panel.add_child(vbox)

	var title := Label.new()
	title.text = "SINGLE PLAYER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(30 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Configure your run"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", int(13 * s))
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.55, 0.50))
	vbox.add_child(subtitle)

	# --- Game mode ---
	vbox.add_child(_make_section_label("Game Mode", s))
	var mode_desc := Label.new()
	mode_desc.name = "GameModeDesc"
	mode_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mode_desc.add_theme_font_size_override("font_size", int(13 * s))
	mode_desc.add_theme_color_override("font_color", Color(0.60, 0.62, 0.55))
	mode_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mode_desc.custom_minimum_size = Vector2(0, 56 * s)
	vbox.add_child(_make_game_mode_row(s, mode_desc))
	vbox.add_child(mode_desc)
	mode_desc.text = NetworkManager.game_mode_description(_game_mode)

	# --- Map style ---
	vbox.add_child(_make_section_label("Map Style", s))
	var style_desc := Label.new()
	style_desc.name = "MapStyleDesc"
	style_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	style_desc.add_theme_font_size_override("font_size", int(13 * s))
	style_desc.add_theme_color_override("font_color", Color(0.60, 0.62, 0.55))
	style_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	style_desc.custom_minimum_size = Vector2(0, 48 * s)
	vbox.add_child(_make_map_style_row(s, style_desc))
	vbox.add_child(style_desc)

	# Tells the player what grid size the selected style will use. Map
	# size itself isn't configurable; it's a property of the style.
	_map_size_label = Label.new()
	_map_size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_map_size_label.add_theme_font_size_override("font_size", int(12 * s))
	_map_size_label.add_theme_color_override("font_color", Color(0.55, 0.60, 0.50))
	vbox.add_child(_map_size_label)
	_update_map_style_desc(style_desc)

	# --- Difficulty ---
	vbox.add_child(_make_section_label("Difficulty", s))
	vbox.add_child(_make_difficulty_row(s))

	var diff_desc := Label.new()
	diff_desc.name = "DifficultyDesc"
	diff_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	diff_desc.add_theme_font_size_override("font_size", int(13 * s))
	diff_desc.add_theme_color_override("font_color", Color(0.60, 0.62, 0.55))
	diff_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	diff_desc.custom_minimum_size = Vector2(0, 44 * s)
	vbox.add_child(diff_desc)
	_update_difficulty_desc(diff_desc)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8 * s)
	vbox.add_child(spacer)

	# --- Actions ---
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", int(20 * s))
	vbox.add_child(actions)

	var back_btn := MenuShared.make_button("Back", s, 140, 42, 16)
	back_btn.pressed.connect(_back_to_title)
	actions.add_child(back_btn)

	var start_btn := MenuShared.make_button("Start Game", s, 240, 46, 18)
	start_btn.pressed.connect(_on_start_pressed)
	actions.add_child(start_btn)

func _back_to_title() -> void:
	get_tree().change_scene_to_file("res://scenes/TitleMenu.tscn")

func _on_start_pressed() -> void:
	# Single-player still routes config through NetworkManager so world.gd
	# and main.gd can read the same fields for both modes. Map size is a
	# property of the style; world.gd resolves it via BuildingCatalog.
	NetworkManager.is_networked = false
	NetworkManager.is_host = true
	NetworkManager.map_size = BuildingCatalog.map_size_for(_map_style)
	NetworkManager.difficulty = _difficulty
	NetworkManager.map_style = _map_style
	NetworkManager.game_mode = _game_mode
	NetworkManager.game_seed = int(Time.get_unix_time_from_system()) ^ (randi() << 1)
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

# ------------------------------------------------------------------
# Shared widget builders (parallel to the multiplayer create-game panel)
# ------------------------------------------------------------------

func _make_section_label(text: String, s: float) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(15 * s))
	lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	return lbl

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
			_difficulty = idx
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
		if i == _difficulty:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(colors[i], s))
			btn.add_theme_color_override("font_color", Color(1, 1, 1))
		else:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
			btn.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))

func _update_difficulty_desc(desc: Label) -> void:
	var settings := NetworkManager.difficulty_settings(_difficulty)
	desc.text = "Zombie density x%.1f  •  Horde size x%.1f  •  %d starting hordes" % [
		settings.enemies_per_block / 14.0,
		settings.horde_mult,
		settings.starting_hordes,
	]

## Survival works solo too — one defender, a smaller horde (waves scale with
## the party size), same day-7 / day-12 / day-15 calendar.
func _make_game_mode_row(s: float, desc_label: Label) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(10 * s))

	var modes := [NetworkManager.GameMode.CAMPAIGN, NetworkManager.GameMode.SURVIVAL]
	var accent := Color(0.30, 0.55, 0.70)
	var buttons: Array[Button] = []

	for m in modes:
		var idx: int = m
		var btn := MenuShared.make_button(NetworkManager.game_mode_name(idx), s, 150, 44, 16)
		btn.pressed.connect(func() -> void:
			_game_mode = idx
			_refresh_game_mode_buttons(buttons, modes, accent)
			desc_label.text = NetworkManager.game_mode_description(_game_mode)
		)
		buttons.append(btn)
		row.add_child(btn)

	_refresh_game_mode_buttons(buttons, modes, accent)
	return row

func _refresh_game_mode_buttons(buttons: Array[Button], modes: Array, accent: Color) -> void:
	var s := MenuShared.ui_scale()
	for i in range(buttons.size()):
		var btn := buttons[i]
		if modes[i] == _game_mode:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(accent, s))
			btn.add_theme_color_override("font_color", Color(1, 1, 1))
		else:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
			btn.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))

func _make_map_style_row(s: float, desc_label: Label) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(8 * s))

	var styles := [
		BuildingCatalog.MapStyle.DOWNTOWN,
		BuildingCatalog.MapStyle.METROPOLIS,
		BuildingCatalog.MapStyle.INDUSTRIAL,
		BuildingCatalog.MapStyle.SUBURBAN,
		BuildingCatalog.MapStyle.CIVIC_CENTER,
		BuildingCatalog.MapStyle.OPEN_WORLD,
	]
	var accent := Color(0.55, 0.55, 0.65)
	var buttons: Array[Button] = []

	for st in styles:
		var idx: int = st
		var btn := MenuShared.make_button(BuildingCatalog.style_name(idx), s, 100, 40, 13)
		btn.pressed.connect(func() -> void:
			_map_style = idx
			_refresh_map_style_buttons(buttons, styles, accent)
			_update_map_style_desc(desc_label)
		)
		buttons.append(btn)
		row.add_child(btn)

	_refresh_map_style_buttons(buttons, styles, accent)
	return row

func _refresh_map_style_buttons(buttons: Array[Button], styles: Array, accent: Color) -> void:
	var s := MenuShared.ui_scale()
	for i in range(buttons.size()):
		var btn := buttons[i]
		if styles[i] == _map_style:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(accent, s))
			btn.add_theme_color_override("font_color", Color(1, 1, 1))
		else:
			btn.add_theme_stylebox_override("normal", MenuShared.make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
			btn.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))

func _update_map_style_desc(desc: Label) -> void:
	desc.text = BuildingCatalog.style_description(_map_style)
	if _map_size_label:
		var sz: int = BuildingCatalog.map_size_for(_map_style)
		_map_size_label.text = "Map size: %d × %d blocks  (%d total)" % [sz, sz, sz * sz]
