extends CanvasLayer

## Debug control panel (only visible in DEV_MODE).
## Controls: zombie density multiplier, god mode toggle, horde spawn button.

signal density_changed(multiplier: float)
signal god_mode_changed(enabled: bool)
signal spawn_horde_requested(count: int)

var _panel: PanelContainer
var _density_slider: HSlider
var _density_label: Label
var _god_mode_check: CheckButton
var _horde_spin: SpinBox
var _visible := true

var _density_value: float = 1.0
var _god_mode_value: bool = true  # matches DEV_MODE default

func _ready() -> void:
	layer = 15
	_build_panel()
	_panel.visible = true

func toggle() -> void:
	_visible = not _visible
	_panel.visible = _visible

func set_god_mode(value: bool) -> void:
	_god_mode_value = value
	if _god_mode_check:
		_god_mode_check.button_pressed = value

func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "DebugPanel"

	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -320
	_panel.offset_right = -10
	_panel.offset_top = -120
	_panel.offset_bottom = 120

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.92)
	style.border_color = Color(0.8, 0.3, 0.2, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "DEBUG CONTROLS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3))
	vbox.add_child(title)

	# Separator
	var sep := HSeparator.new()
	vbox.add_child(sep)

	# Zombie Density
	var density_hbox := HBoxContainer.new()
	vbox.add_child(density_hbox)
	var density_title := Label.new()
	density_title.text = "Zombie Density:"
	density_title.add_theme_font_size_override("font_size", 13)
	density_title.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	density_hbox.add_child(density_title)
	_density_label = Label.new()
	_density_label.text = "1.0x"
	_density_label.add_theme_font_size_override("font_size", 13)
	_density_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	density_hbox.add_child(_density_label)

	_density_slider = HSlider.new()
	_density_slider.min_value = 0.0
	_density_slider.max_value = 5.0
	_density_slider.step = 0.25
	_density_slider.value = 1.0
	_density_slider.custom_minimum_size = Vector2(0, 20)
	_density_slider.value_changed.connect(_on_density_changed)
	vbox.add_child(_density_slider)

	# God Mode
	_god_mode_check = CheckButton.new()
	_god_mode_check.text = "God Mode (Invincible)"
	_god_mode_check.button_pressed = _god_mode_value
	_god_mode_check.add_theme_font_size_override("font_size", 13)
	_god_mode_check.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_god_mode_check.toggled.connect(_on_god_mode_toggled)
	vbox.add_child(_god_mode_check)

	# Separator
	var sep2 := HSeparator.new()
	vbox.add_child(sep2)

	# Spawn Horde
	var horde_hbox := HBoxContainer.new()
	vbox.add_child(horde_hbox)
	var horde_label := Label.new()
	horde_label.text = "Horde size:"
	horde_label.add_theme_font_size_override("font_size", 13)
	horde_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	horde_hbox.add_child(horde_label)

	_horde_spin = SpinBox.new()
	_horde_spin.min_value = 5
	_horde_spin.max_value = 100
	_horde_spin.step = 5
	_horde_spin.value = 20
	_horde_spin.custom_minimum_size = Vector2(80, 0)
	horde_hbox.add_child(_horde_spin)

	var spawn_btn := Button.new()
	spawn_btn.text = "Spawn Horde"
	spawn_btn.add_theme_font_size_override("font_size", 13)
	spawn_btn.pressed.connect(_on_spawn_horde)
	vbox.add_child(spawn_btn)

	# Hint
	var hint := Label.new()
	hint.text = "Press F3 to toggle this panel"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	vbox.add_child(hint)

func _on_density_changed(value: float) -> void:
	_density_value = value
	if _density_label:
		_density_label.text = "%.2fx" % value
	density_changed.emit(value)

func _on_god_mode_toggled(pressed: bool) -> void:
	_god_mode_value = pressed
	god_mode_changed.emit(pressed)

func _on_spawn_horde() -> void:
	var count: int = int(_horde_spin.value)
	spawn_horde_requested.emit(count)
