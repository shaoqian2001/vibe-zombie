extends Control

## Title / main menu screen.
## Entry point of the game with Single Player, Multiplayer, Settings, and Exit.

const MenuShared = preload("res://scripts/menu_shared.gd")

var _center: CenterContainer
var _main_panel: PanelContainer
var _settings_panel: PanelContainer = null
var _multiplayer_panel: PanelContainer = null

const BASE_TITLE_FONT := 48
const BASE_SUBTITLE_FONT := 16
const BASE_BUTTON_WIDTH := 320.0
const BASE_BUTTON_HEIGHT := 54.0
const BASE_BUTTON_GAP := 14.0

func _ready() -> void:
	_build_ui()

func _build_ui() -> void:
	var s := MenuShared.ui_scale()

	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Subtle vignette overlay
	var vignette := ColorRect.new()
	vignette.color = Color(0.0, 0.0, 0.0, 0.3)
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vignette)

	# Centre container
	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	_build_main_panel(s)

func _build_main_panel(s: float) -> void:
	# Main panel
	_main_panel = PanelContainer.new()
	_main_panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	_center.add_child(_main_panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", int(BASE_BUTTON_GAP * s))
	_main_panel.add_child(vbox)

	# Game title
	var title := Label.new()
	title.text = "VIBE ZOMBIE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(BASE_TITLE_FONT * s))
	title.add_theme_color_override("font_color", Color(0.85, 0.30, 0.20))
	vbox.add_child(title)

	# Subtitle
	var subtitle := Label.new()
	subtitle.text = "Survive the undead"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", int(BASE_SUBTITLE_FONT * s))
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.55, 0.50))
	vbox.add_child(subtitle)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 18 * s)
	vbox.add_child(spacer)

	# Menu buttons
	var sp_btn := MenuShared.make_button("Single Player", s, BASE_BUTTON_WIDTH, BASE_BUTTON_HEIGHT)
	sp_btn.pressed.connect(_on_single_player)
	vbox.add_child(sp_btn)

	var mp_btn := MenuShared.make_button("Multiplayer", s, BASE_BUTTON_WIDTH, BASE_BUTTON_HEIGHT)
	mp_btn.pressed.connect(_on_multiplayer)
	vbox.add_child(mp_btn)

	var settings_btn := MenuShared.make_button("Settings", s, BASE_BUTTON_WIDTH, BASE_BUTTON_HEIGHT)
	settings_btn.pressed.connect(_on_settings)
	vbox.add_child(settings_btn)

	var exit_btn := MenuShared.make_button("Exit Game", s, BASE_BUTTON_WIDTH, BASE_BUTTON_HEIGHT)
	exit_btn.pressed.connect(_on_exit)
	vbox.add_child(exit_btn)

# ------------------------------------------------------------------
# Button handlers
# ------------------------------------------------------------------

func _on_single_player() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_multiplayer() -> void:
	_show_multiplayer_menu()

func _on_settings() -> void:
	_show_settings()

func _on_exit() -> void:
	get_tree().quit()

# ------------------------------------------------------------------
# Settings sub-panel (reuses shared settings builder)
# ------------------------------------------------------------------

func _show_settings() -> void:
	if _settings_panel:
		return
	_main_panel.visible = false
	_settings_panel = MenuShared.build_settings_panel(
		_center,
		_close_settings,
		_on_resolution_changed,
	)

func _close_settings() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
		_settings_panel = null
	_main_panel.visible = true

func _on_resolution_changed() -> void:
	# Tear down everything and rebuild at new scale
	_settings_panel = null
	_main_panel = null
	_multiplayer_panel = null
	for child in get_children():
		child.queue_free()
	call_deferred("_build_ui")
	call_deferred("_show_settings")

# ------------------------------------------------------------------
# Multiplayer sub-panel
# ------------------------------------------------------------------

func _show_multiplayer_menu() -> void:
	if _multiplayer_panel:
		return
	var s := MenuShared.ui_scale()
	_main_panel.visible = false

	_multiplayer_panel = PanelContainer.new()
	_multiplayer_panel.custom_minimum_size = Vector2(480 * s, 400 * s)
	_multiplayer_panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	_center.add_child(_multiplayer_panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", int(14 * s))
	_multiplayer_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "MULTIPLAYER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(28 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8 * s)
	vbox.add_child(spacer)

	# Host game
	var host_btn := MenuShared.make_button("Host Game", s, 280, 46, 18)
	host_btn.pressed.connect(func() -> void: pass)  # placeholder
	vbox.add_child(host_btn)

	# Join game
	var join_btn := MenuShared.make_button("Join Game", s, 280, 46, 18)
	join_btn.pressed.connect(func() -> void: pass)  # placeholder
	vbox.add_child(join_btn)

	# Server browser
	var browse_btn := MenuShared.make_button("Server Browser", s, 280, 46, 18)
	browse_btn.pressed.connect(func() -> void: pass)  # placeholder
	vbox.add_child(browse_btn)

	# Placeholder notice
	var notice := Label.new()
	notice.text = "Coming soon..."
	notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notice.add_theme_font_size_override("font_size", int(13 * s))
	notice.add_theme_color_override("font_color", Color(0.50, 0.50, 0.45))
	vbox.add_child(notice)

	# Spacer before back button
	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 4 * s)
	vbox.add_child(spacer2)

	# Back button
	var back_btn := MenuShared.make_button("Back", s, 140, 40, 18)
	back_btn.pressed.connect(_close_multiplayer)
	vbox.add_child(back_btn)

func _close_multiplayer() -> void:
	if _multiplayer_panel:
		_multiplayer_panel.queue_free()
		_multiplayer_panel = null
	_main_panel.visible = true
