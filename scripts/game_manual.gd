extends CanvasLayer

## Game Manual (ESC menu) — overlay with Continue, Settings, and Exit buttons.
## The game view is dimmed when the manual is open.
## The game continues running underneath (no pause).
## Settings opens a secondary panel with a Resolution tab.

signal manual_closed

var _panel: PanelContainer
var _dim_overlay: ColorRect
var _center: CenterContainer
var _settings_panel: PanelContainer = null
var _main_vbox: VBoxContainer

const BUTTON_WIDTH := 260.0
const BUTTON_HEIGHT := 50.0
const BUTTON_GAP := 16.0
const TITLE_FONT_SIZE := 32
const BUTTON_FONT_SIZE := 20
const SETTINGS_WIDTH := 500.0
const SETTINGS_HEIGHT := 420.0

const RESOLUTIONS := [
	Vector2i(1280, 720),
	Vector2i(1366, 768),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

func _ready() -> void:
	layer = 100
	_build_ui()
	visible = true

func _build_ui() -> void:
	# Full-screen dim overlay
	_dim_overlay = ColorRect.new()
	_dim_overlay.color = Color(0.0, 0.0, 0.0, 0.55)
	_dim_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim_overlay)

	# Centre container
	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	# Panel
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _make_panel_style())
	_center.add_child(_panel)

	# Vertical layout
	_main_vbox = VBoxContainer.new()
	_main_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_main_vbox.add_theme_constant_override("separation", int(BUTTON_GAP))
	_panel.add_child(_main_vbox)

	# Title
	var title := Label.new()
	title.text = "GAME MANUAL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	_main_vbox.add_child(title)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	_main_vbox.add_child(spacer)

	# Buttons
	_add_button(_main_vbox, "Continue", _on_continue)
	_add_button(_main_vbox, "Settings", _on_settings)
	_add_button(_main_vbox, "Exit Game", _on_exit)

func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.10, 0.12, 0.92)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.border_color = Color(0.35, 0.35, 0.40, 0.8)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.content_margin_left = 40
	style.content_margin_right = 40
	style.content_margin_top = 30
	style.content_margin_bottom = 30
	return style

func _make_btn_style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	return s

func _add_button(parent: VBoxContainer, text: String, callback: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
	btn.add_theme_font_size_override("font_size", BUTTON_FONT_SIZE)
	btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.20, 0.20, 0.24, 0.9)))
	btn.add_theme_stylebox_override("hover", _make_btn_style(Color(0.30, 0.30, 0.36, 0.95)))
	btn.add_theme_stylebox_override("pressed", _make_btn_style(Color(0.15, 0.15, 0.18, 0.95)))
	btn.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	btn.pressed.connect(callback)
	parent.add_child(btn)

func _on_continue() -> void:
	manual_closed.emit()

func _on_settings() -> void:
	_show_settings()

func _on_exit() -> void:
	get_tree().quit()

# ------------------------------------------------------------------
# Settings sub-panel
# ------------------------------------------------------------------

func _show_settings() -> void:
	if _settings_panel:
		return
	# Hide the main manual panel
	_panel.visible = false

	# Create settings panel in the same center container
	_settings_panel = PanelContainer.new()
	_settings_panel.custom_minimum_size = Vector2(SETTINGS_WIDTH, SETTINGS_HEIGHT)
	_settings_panel.add_theme_stylebox_override("panel", _make_panel_style())
	_center.add_child(_settings_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_settings_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	# Tab bar
	var tab_bar := TabContainer.new()
	tab_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab_bar)

	# --- Resolution tab ---
	var res_tab := _build_resolution_tab()
	res_tab.name = "Resolution"
	tab_bar.add_child(res_tab)

	# Back button
	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(back_row)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(140, 40)
	back_btn.add_theme_font_size_override("font_size", 18)
	back_btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.20, 0.20, 0.24, 0.9)))
	back_btn.add_theme_stylebox_override("hover", _make_btn_style(Color(0.30, 0.30, 0.36, 0.95)))
	back_btn.add_theme_stylebox_override("pressed", _make_btn_style(Color(0.15, 0.15, 0.18, 0.95)))
	back_btn.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
	back_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	back_btn.pressed.connect(_close_settings)
	back_row.add_child(back_btn)

func _build_resolution_tab() -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	# Current resolution display
	var current_size := DisplayServer.window_get_size()
	var current_label := Label.new()
	current_label.text = "Current: %d x %d" % [current_size.x, current_size.y]
	current_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_label.add_theme_font_size_override("font_size", 16)
	current_label.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70))
	current_label.name = "CurrentLabel"
	vbox.add_child(current_label)

	# Resolution buttons
	for res in RESOLUTIONS:
		var res_vec: Vector2i = res
		var btn := Button.new()
		btn.text = "%d x %d" % [res_vec.x, res_vec.y]
		btn.custom_minimum_size = Vector2(0, 38)
		btn.add_theme_font_size_override("font_size", 16)

		# Highlight current resolution
		var is_current := (res_vec.x == current_size.x and res_vec.y == current_size.y)
		if is_current:
			btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.18, 0.35, 0.18, 0.9)))
		else:
			btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.20, 0.20, 0.24, 0.9)))
		btn.add_theme_stylebox_override("hover", _make_btn_style(Color(0.30, 0.30, 0.36, 0.95)))
		btn.add_theme_stylebox_override("pressed", _make_btn_style(Color(0.15, 0.15, 0.18, 0.95)))
		btn.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
		btn.pressed.connect(_apply_resolution.bind(res_vec, current_label))
		vbox.add_child(btn)

	return margin

func _apply_resolution(res: Vector2i, label: Label) -> void:
	DisplayServer.window_set_size(res)
	# Centre the window on screen
	var screen_size := DisplayServer.screen_get_size()
	var win_pos := Vector2i((screen_size.x - res.x) / 2, (screen_size.y - res.y) / 2)
	DisplayServer.window_set_position(win_pos)
	label.text = "Current: %d x %d" % [res.x, res.y]
	# Rebuild settings to update highlighted button
	_close_settings()
	_show_settings()

func _close_settings() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
		_settings_panel = null
	_panel.visible = true
