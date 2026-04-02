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

# Base design values (for 720p). Scaled by _ui_scale().
const BASE_BUTTON_WIDTH := 260.0
const BASE_BUTTON_HEIGHT := 50.0
const BASE_BUTTON_GAP := 16.0
const BASE_TITLE_FONT := 32
const BASE_BUTTON_FONT := 20
const BASE_SETTINGS_WIDTH := 500.0
const BASE_SETTINGS_HEIGHT := 420.0

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

func _ui_scale() -> float:
	var viewport_h := get_viewport().get_visible_rect().size.y
	return viewport_h / 720.0

func _build_ui() -> void:
	var s := _ui_scale()

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
	_panel.add_theme_stylebox_override("panel", _make_panel_style(s))
	_center.add_child(_panel)

	# Vertical layout
	_main_vbox = VBoxContainer.new()
	_main_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_main_vbox.add_theme_constant_override("separation", int(BASE_BUTTON_GAP * s))
	_panel.add_child(_main_vbox)

	# Title
	var title := Label.new()
	title.text = "GAME MANUAL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(BASE_TITLE_FONT * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	_main_vbox.add_child(title)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12 * s)
	_main_vbox.add_child(spacer)

	# Buttons
	_add_button(_main_vbox, "Continue", _on_continue, s)
	_add_button(_main_vbox, "Settings", _on_settings, s)
	_add_button(_main_vbox, "Exit Game", _on_exit, s)

func _make_panel_style(s: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.10, 0.12, 0.92)
	var r := int(12 * s)
	style.corner_radius_top_left = r
	style.corner_radius_top_right = r
	style.corner_radius_bottom_left = r
	style.corner_radius_bottom_right = r
	var bw := int(max(1, 2 * s))
	style.border_color = Color(0.35, 0.35, 0.40, 0.8)
	style.border_width_left = bw
	style.border_width_right = bw
	style.border_width_top = bw
	style.border_width_bottom = bw
	var cm_h := int(40 * s)
	var cm_v := int(30 * s)
	style.content_margin_left = cm_h
	style.content_margin_right = cm_h
	style.content_margin_top = cm_v
	style.content_margin_bottom = cm_v
	return style

func _make_btn_style(bg: Color, s: float) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = bg
	var r := int(6 * s)
	st.corner_radius_top_left = r
	st.corner_radius_top_right = r
	st.corner_radius_bottom_left = r
	st.corner_radius_bottom_right = r
	return st

func _add_button(parent: VBoxContainer, text: String, callback: Callable, s: float) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(BASE_BUTTON_WIDTH * s, BASE_BUTTON_HEIGHT * s)
	btn.add_theme_font_size_override("font_size", int(BASE_BUTTON_FONT * s))
	btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
	btn.add_theme_stylebox_override("hover", _make_btn_style(Color(0.30, 0.30, 0.36, 0.95), s))
	btn.add_theme_stylebox_override("pressed", _make_btn_style(Color(0.15, 0.15, 0.18, 0.95), s))
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
	var s := _ui_scale()
	# Hide the main manual panel
	_panel.visible = false

	# Create settings panel in the same center container
	_settings_panel = PanelContainer.new()
	_settings_panel.custom_minimum_size = Vector2(BASE_SETTINGS_WIDTH * s, BASE_SETTINGS_HEIGHT * s)
	_settings_panel.add_theme_stylebox_override("panel", _make_panel_style(s))
	_center.add_child(_settings_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(12 * s))
	_settings_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(28 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	# Tab bar
	var tab_bar := TabContainer.new()
	tab_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab_bar)

	# --- Resolution tab ---
	var res_tab := _build_resolution_tab(s)
	res_tab.name = "Resolution"
	tab_bar.add_child(res_tab)

	# Back button
	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(back_row)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(140 * s, 40 * s)
	back_btn.add_theme_font_size_override("font_size", int(18 * s))
	back_btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
	back_btn.add_theme_stylebox_override("hover", _make_btn_style(Color(0.30, 0.30, 0.36, 0.95), s))
	back_btn.add_theme_stylebox_override("pressed", _make_btn_style(Color(0.15, 0.15, 0.18, 0.95), s))
	back_btn.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
	back_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	back_btn.pressed.connect(_close_settings)
	back_row.add_child(back_btn)

func _build_resolution_tab(s: float) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(20 * s))
	margin.add_theme_constant_override("margin_right", int(20 * s))
	margin.add_theme_constant_override("margin_top", int(16 * s))
	margin.add_theme_constant_override("margin_bottom", int(16 * s))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(14 * s))
	margin.add_child(vbox)

	# Current resolution display
	var current_size := _get_current_resolution()
	var current_label := Label.new()
	current_label.text = "Current: %d x %d" % [current_size.x, current_size.y]
	current_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_label.add_theme_font_size_override("font_size", int(16 * s))
	current_label.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70))
	current_label.name = "CurrentLabel"
	vbox.add_child(current_label)

	# Resolution buttons
	for res in RESOLUTIONS:
		var res_vec: Vector2i = res
		var btn := Button.new()
		btn.text = "%d x %d" % [res_vec.x, res_vec.y]
		btn.custom_minimum_size = Vector2(0, 38 * s)
		btn.add_theme_font_size_override("font_size", int(16 * s))

		# Highlight current resolution
		var is_current := (res_vec.x == current_size.x and res_vec.y == current_size.y)
		if is_current:
			btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.18, 0.35, 0.18, 0.9), s))
		else:
			btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
		btn.add_theme_stylebox_override("hover", _make_btn_style(Color(0.30, 0.30, 0.36, 0.95), s))
		btn.add_theme_stylebox_override("pressed", _make_btn_style(Color(0.15, 0.15, 0.18, 0.95), s))
		btn.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
		btn.pressed.connect(_apply_resolution.bind(res_vec, current_label))
		vbox.add_child(btn)

	return margin

func _get_current_resolution() -> Vector2i:
	var scale_size := get_window().content_scale_size
	if scale_size != Vector2i.ZERO:
		return scale_size
	return get_viewport().get_visible_rect().size as Vector2i

func _apply_resolution(res: Vector2i, label: Label) -> void:
	var win := get_window()
	# Set scale mode to VIEWPORT so the entire game (3D + 2D) renders at the
	# chosen resolution and then gets scaled to fit the actual window.
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.content_scale_size = res
	# Also try to resize the OS window (works in standalone, no-op if embedded)
	DisplayServer.window_set_size(res)
	label.text = "Current: %d x %d" % [res.x, res.y]
	# Rebuild the entire manual UI so all elements pick up the new scale
	_close_settings()
	_rebuild_ui()

func _rebuild_ui() -> void:
	# Remove all children and rebuild
	for child in get_children():
		child.queue_free()
	_settings_panel = null
	# Defer build so freed nodes are gone
	call_deferred("_build_ui")
	call_deferred("_show_settings")

func _close_settings() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
		_settings_panel = null
	_panel.visible = true
