extends CanvasLayer

## Game Manual (ESC menu) — overlay with Continue, Settings, and Exit buttons.
## The game view is dimmed when the manual is open.
## The game continues running underneath (no pause).

signal manual_closed

var _panel: PanelContainer
var _dim_overlay: ColorRect

const BUTTON_WIDTH := 260.0
const BUTTON_HEIGHT := 50.0
const BUTTON_GAP := 16.0
const TITLE_FONT_SIZE := 32
const BUTTON_FONT_SIZE := 20

func _ready() -> void:
	layer = 100  # render on top of everything
	_build_ui()
	visible = true

func _build_ui() -> void:
	# Full-screen dim overlay
	_dim_overlay = ColorRect.new()
	_dim_overlay.color = Color(0.0, 0.0, 0.0, 0.55)
	_dim_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim_overlay.mouse_filter = Control.MOUSE_FILTER_STOP  # block clicks through
	add_child(_dim_overlay)

	# Centre container
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	# Panel
	_panel = PanelContainer.new()
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
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	# Vertical layout
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", int(BUTTON_GAP))
	_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "GAME MANUAL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	vbox.add_child(spacer)

	# Buttons
	_add_button(vbox, "Continue", _on_continue)
	_add_button(vbox, "Settings", _on_settings)
	_add_button(vbox, "Exit Game", _on_exit)

func _add_button(parent: VBoxContainer, text: String, callback: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
	btn.add_theme_font_size_override("font_size", BUTTON_FONT_SIZE)

	# Normal style
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.20, 0.20, 0.24, 0.9)
	normal.corner_radius_top_left = 6
	normal.corner_radius_top_right = 6
	normal.corner_radius_bottom_left = 6
	normal.corner_radius_bottom_right = 6
	btn.add_theme_stylebox_override("normal", normal)

	# Hover style
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.30, 0.30, 0.36, 0.95)
	hover.corner_radius_top_left = 6
	hover.corner_radius_top_right = 6
	hover.corner_radius_bottom_left = 6
	hover.corner_radius_bottom_right = 6
	btn.add_theme_stylebox_override("hover", hover)

	# Pressed style
	var pressed := StyleBoxFlat.new()
	pressed.bg_color = Color(0.15, 0.15, 0.18, 0.95)
	pressed.corner_radius_top_left = 6
	pressed.corner_radius_top_right = 6
	pressed.corner_radius_bottom_left = 6
	pressed.corner_radius_bottom_right = 6
	btn.add_theme_stylebox_override("pressed", pressed)

	btn.add_theme_color_override("font_color", Color(0.90, 0.90, 0.90))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	btn.pressed.connect(callback)
	parent.add_child(btn)

func _on_continue() -> void:
	manual_closed.emit()

func _on_settings() -> void:
	# Dummy — will be implemented later
	pass

func _on_exit() -> void:
	get_tree().quit()
