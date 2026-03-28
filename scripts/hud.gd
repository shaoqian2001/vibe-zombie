extends CanvasLayer

## Bottom-left HUD showing Armor, Health, and Stamina bars + ammo counter above.

var _armor_fill: ColorRect
var _health_fill: ColorRect
var _stamina_fill: ColorRect
var _ammo_label: Label
var _container: Control

# Current values (0-100)
var armor: float = 15.0
var max_armor: float = 100.0
var health: float = 30.0
var max_health: float = 100.0
var stamina: float = 40.0
var max_stamina: float = 100.0

const BAR_WIDTH := 200.0
const BAR_HEIGHT := 16.0
const BAR_GAP := 6.0
const MARGIN_LEFT := 20.0
const MARGIN_BOTTOM := 20.0
const LABEL_WIDTH := 70.0

const ARMOR_COLOR := Color(0.30, 0.50, 0.85, 0.9)
const HEALTH_COLOR := Color(0.80, 0.20, 0.15, 0.9)
const STAMINA_COLOR := Color(0.20, 0.75, 0.30, 0.9)
const BG_COLOR := Color(0.12, 0.12, 0.12, 0.7)

func _ready() -> void:
	_build_hud()

func _process(_delta: float) -> void:
	_update_bars()

func set_stamina(value: float) -> void:
	stamina = clamp(value, 0.0, max_stamina)

func set_health(value: float) -> void:
	health = clamp(value, 0.0, max_health)

func set_armor(value: float) -> void:
	armor = clamp(value, 0.0, max_armor)

func set_ammo(current: int, magazine: int) -> void:
	if _ammo_label:
		_ammo_label.text = "%d / %d" % [current, magazine]
		if current == 0:
			_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.25, 0.2, 1.0))
		else:
			_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7, 1.0))

func set_reloading(is_reloading: bool) -> void:
	if _ammo_label and is_reloading:
		_ammo_label.text = "RELOADING..."
		_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2, 1.0))

func _build_hud() -> void:
	_container = Control.new()
	_container.name = "HUDContainer"
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container)

	var viewport_h := 720.0  # match project viewport height

	# Bars from top to bottom: Armor, Health, Stamina
	var bar_data := [
		{"label": "ARMOR", "color": ARMOR_COLOR},
		{"label": "HEALTH", "color": HEALTH_COLOR},
		{"label": "STAMINA", "color": STAMINA_COLOR},
	]

	var total_height := bar_data.size() * BAR_HEIGHT + (bar_data.size() - 1) * BAR_GAP
	var start_y := viewport_h - MARGIN_BOTTOM - total_height

	# Ammo counter above the bars
	_ammo_label = Label.new()
	_ammo_label.name = "AmmoLabel"
	_ammo_label.text = "8 / 8"
	_ammo_label.position = Vector2(MARGIN_LEFT, start_y - 28)
	_ammo_label.size = Vector2(LABEL_WIDTH + BAR_WIDTH, 24)
	_ammo_label.add_theme_font_size_override("font_size", 16)
	_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7, 1.0))
	_ammo_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_ammo_label.add_theme_constant_override("shadow_offset_x", 1)
	_ammo_label.add_theme_constant_override("shadow_offset_y", 1)
	_ammo_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.add_child(_ammo_label)

	var fills := []
	for i in range(bar_data.size()):
		var data = bar_data[i]
		var y_pos := start_y + i * (BAR_HEIGHT + BAR_GAP)

		# Label
		var label := Label.new()
		label.text = data["label"]
		label.position = Vector2(MARGIN_LEFT, y_pos - 2)
		label.size = Vector2(LABEL_WIDTH, BAR_HEIGHT)
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 0.95))
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_container.add_child(label)

		# Background bar
		var bg := ColorRect.new()
		bg.color = BG_COLOR
		bg.position = Vector2(MARGIN_LEFT + LABEL_WIDTH, y_pos)
		bg.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_container.add_child(bg)

		# Fill bar
		var fill := ColorRect.new()
		fill.color = data["color"]
		fill.position = Vector2(MARGIN_LEFT + LABEL_WIDTH, y_pos)
		fill.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_container.add_child(fill)

		fills.append(fill)

	_armor_fill = fills[0]
	_health_fill = fills[1]
	_stamina_fill = fills[2]

func _update_bars() -> void:
	if _armor_fill:
		_armor_fill.size.x = BAR_WIDTH * (armor / max_armor)
	if _health_fill:
		_health_fill.size.x = BAR_WIDTH * (health / max_health)
	if _stamina_fill:
		_stamina_fill.size.x = BAR_WIDTH * (stamina / max_stamina)
