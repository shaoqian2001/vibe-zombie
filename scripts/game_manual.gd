extends CanvasLayer

## Game Manual (ESC menu) — overlay with Continue, Settings, and Exit buttons.
## The game view is dimmed when the manual is open.
## The game continues running underneath (no pause).
## Settings opens a secondary panel with a Resolution tab (shared with title menu).

const MenuShared = preload("res://scripts/menu_shared.gd")

signal manual_closed

var _panel: PanelContainer
var _dim_overlay: ColorRect
var _center: CenterContainer
var _settings_panel: PanelContainer = null

const BASE_BUTTON_WIDTH := 260.0
const BASE_BUTTON_HEIGHT := 50.0
const BASE_BUTTON_GAP := 16.0
const BASE_TITLE_FONT := 32

func _ready() -> void:
	layer = 100
	_build_ui()
	visible = true

func _build_ui() -> void:
	var s := MenuShared.ui_scale()

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
	_panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	_center.add_child(_panel)

	# Vertical layout
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", int(BASE_BUTTON_GAP * s))
	_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "GAME MANUAL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(BASE_TITLE_FONT * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12 * s)
	vbox.add_child(spacer)

	# Buttons
	var continue_btn := MenuShared.make_button("Continue", s, BASE_BUTTON_WIDTH, BASE_BUTTON_HEIGHT)
	continue_btn.pressed.connect(_on_continue)
	vbox.add_child(continue_btn)

	var settings_btn := MenuShared.make_button("Settings", s, BASE_BUTTON_WIDTH, BASE_BUTTON_HEIGHT)
	settings_btn.pressed.connect(_on_settings)
	vbox.add_child(settings_btn)

	var exit_btn := MenuShared.make_button("Exit Game", s, BASE_BUTTON_WIDTH, BASE_BUTTON_HEIGHT)
	exit_btn.pressed.connect(_on_exit)
	vbox.add_child(exit_btn)

func _on_continue() -> void:
	manual_closed.emit()

func _on_settings() -> void:
	_show_settings()

func _on_exit() -> void:
	get_tree().quit()

# ------------------------------------------------------------------
# Settings sub-panel (shared builder)
# ------------------------------------------------------------------

func _show_settings() -> void:
	if _settings_panel:
		return
	_panel.visible = false
	_settings_panel = MenuShared.build_settings_panel(
		_center,
		_close_settings,
		_on_resolution_changed,
	)

func _close_settings() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
		_settings_panel = null
	_panel.visible = true

func _on_resolution_changed() -> void:
	_settings_panel = null
	for child in get_children():
		child.queue_free()
	call_deferred("_build_ui")
	call_deferred("_show_settings")
