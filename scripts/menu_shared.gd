extends RefCounted

## Shared UI helpers for menu styling and settings panel.
## Used by both the title menu and in-game manual to keep visuals consistent.

const RESOLUTIONS := [
	Vector2i(1280, 720),
	Vector2i(1366, 768),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

static func ui_scale() -> float:
	var viewport_h := Engine.get_main_loop().root.get_visible_rect().size.y
	return viewport_h / 720.0

static func make_panel_style(s: float) -> StyleBoxFlat:
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

static func make_btn_style(bg: Color, s: float) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = bg
	var r := int(6 * s)
	st.corner_radius_top_left = r
	st.corner_radius_top_right = r
	st.corner_radius_bottom_left = r
	st.corner_radius_bottom_right = r
	return st

static func make_button(text: String, s: float, width: float = 260.0, height: float = 50.0, font_size: int = 20) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(width * s, height * s)
	btn.add_theme_font_size_override("font_size", int(font_size * s))
	btn.add_theme_stylebox_override("normal", make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
	btn.add_theme_stylebox_override("hover", make_btn_style(Color(0.30, 0.30, 0.36, 0.95), s))
	btn.add_theme_stylebox_override("pressed", make_btn_style(Color(0.15, 0.15, 0.18, 0.95), s))
	btn.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	return btn

static func get_current_resolution() -> Vector2i:
	var win := Engine.get_main_loop().root
	var scale_size := win.content_scale_size
	if scale_size != Vector2i.ZERO:
		return scale_size
	return win.get_visible_rect().size as Vector2i

static func apply_resolution(res: Vector2i) -> void:
	var win := Engine.get_main_loop().root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.content_scale_size = res
	DisplayServer.window_set_size(res)

## Build and return a complete settings panel with Resolution tab.
## parent_center: the CenterContainer to add the panel to.
## on_back: callable invoked when Back is pressed.
## on_resolution_changed: callable invoked after resolution changes (for UI rebuild).
static func build_settings_panel(parent_center: CenterContainer, on_back: Callable, on_resolution_changed: Callable) -> PanelContainer:
	var s := ui_scale()

	var settings_panel := PanelContainer.new()
	settings_panel.custom_minimum_size = Vector2(500 * s, 420 * s)
	settings_panel.add_theme_stylebox_override("panel", make_panel_style(s))
	parent_center.add_child(settings_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(12 * s))
	settings_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(28 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	# Tab container
	var tab_bar := TabContainer.new()
	tab_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab_bar)

	# Resolution tab
	var res_tab := _build_resolution_tab(s, on_resolution_changed)
	res_tab.name = "Resolution"
	tab_bar.add_child(res_tab)

	# Back button
	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(back_row)

	var back_btn := make_button("Back", s, 140, 40, 18)
	back_btn.pressed.connect(on_back)
	back_row.add_child(back_btn)

	return settings_panel

static func _build_resolution_tab(s: float, on_resolution_changed: Callable) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(20 * s))
	margin.add_theme_constant_override("margin_right", int(20 * s))
	margin.add_theme_constant_override("margin_top", int(16 * s))
	margin.add_theme_constant_override("margin_bottom", int(16 * s))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(14 * s))
	margin.add_child(vbox)

	var current_size := get_current_resolution()
	var current_label := Label.new()
	current_label.text = "Current: %d x %d" % [current_size.x, current_size.y]
	current_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_label.add_theme_font_size_override("font_size", int(16 * s))
	current_label.add_theme_color_override("font_color", Color(0.70, 0.70, 0.70))
	current_label.name = "CurrentLabel"
	vbox.add_child(current_label)

	for res in RESOLUTIONS:
		var res_vec: Vector2i = res
		var btn := Button.new()
		btn.text = "%d x %d" % [res_vec.x, res_vec.y]
		btn.custom_minimum_size = Vector2(0, 38 * s)
		btn.add_theme_font_size_override("font_size", int(16 * s))

		var is_current := (res_vec.x == current_size.x and res_vec.y == current_size.y)
		if is_current:
			btn.add_theme_stylebox_override("normal", make_btn_style(Color(0.18, 0.35, 0.18, 0.9), s))
		else:
			btn.add_theme_stylebox_override("normal", make_btn_style(Color(0.20, 0.20, 0.24, 0.9), s))
		btn.add_theme_stylebox_override("hover", make_btn_style(Color(0.30, 0.30, 0.36, 0.95), s))
		btn.add_theme_stylebox_override("pressed", make_btn_style(Color(0.15, 0.15, 0.18, 0.95), s))
		btn.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
		btn.pressed.connect(func() -> void:
			apply_resolution(res_vec)
			on_resolution_changed.call()
		)
		vbox.add_child(btn)

	return margin
