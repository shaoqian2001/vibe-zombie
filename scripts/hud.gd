extends CanvasLayer

## Bottom-left HUD showing Armor, Health, and Stamina bars + ammo counter above.
## All positioning uses anchors so the HUD stays bottom-left at any resolution.

var _armor_fill: ColorRect
var _health_fill: ColorRect
var _stamina_fill: ColorRect
var _ammo_label: Label
var _weapon_label: Label
var _container: Control

# Current values (0-100)
var armor: float = 15.0
var max_armor: float = 100.0
var health: float = 100.0
var max_health: float = 100.0
var stamina: float = 40.0
var max_stamina: float = 100.0

# Sizing (in virtual-viewport units — scales automatically with canvas_items stretch)
const BAR_WIDTH := 200.0
const BAR_HEIGHT := 16.0
const BAR_GAP := 6.0
const MARGIN := 20.0
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
		if magazine == 0:
			_ammo_label.text = ""
		else:
			_ammo_label.text = "%d / %d" % [current, magazine]
		if current == 0 and magazine > 0:
			_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.25, 0.2, 1.0))
		else:
			_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7, 1.0))

func set_weapon_name(weapon_name: String) -> void:
	if _weapon_label:
		_weapon_label.text = weapon_name

func set_reloading(is_reloading: bool) -> void:
	if _ammo_label and is_reloading:
		_ammo_label.text = "RELOADING..."
		_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2, 1.0))

func _build_hud() -> void:
	# Full-rect container (mouse-transparent)
	_container = Control.new()
	_container.name = "HUDContainer"
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container)

	# Anchor wrapper pinned to bottom-left
	var anchor := Control.new()
	anchor.name = "BottomLeftAnchor"
	anchor.set_anchor(SIDE_LEFT, 0.0)
	anchor.set_anchor(SIDE_BOTTOM, 1.0)
	anchor.set_anchor(SIDE_RIGHT, 0.0)
	anchor.set_anchor(SIDE_TOP, 1.0)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.add_child(anchor)

	var bar_data := [
		{"label": "ARMOR", "color": ARMOR_COLOR},
		{"label": "HEALTH", "color": HEALTH_COLOR},
		{"label": "STAMINA", "color": STAMINA_COLOR},
	]

	var total_bars_height := bar_data.size() * BAR_HEIGHT + (bar_data.size() - 1) * BAR_GAP
	var ammo_height := 24.0
	var weapon_height := 24.0
	var gap := 4.0
	var total_height := total_bars_height + gap + ammo_height + gap + weapon_height

	# Weapon name label (topmost)
	_weapon_label = Label.new()
	_weapon_label.name = "WeaponLabel"
	_weapon_label.text = "UNARMED"
	_weapon_label.position = Vector2(MARGIN, -MARGIN - total_height)
	_weapon_label.size = Vector2(LABEL_WIDTH + BAR_WIDTH, weapon_height)
	_weapon_label.add_theme_font_size_override("font_size", 14)
	_weapon_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8, 0.9))
	_weapon_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_weapon_label.add_theme_constant_override("shadow_offset_x", 1)
	_weapon_label.add_theme_constant_override("shadow_offset_y", 1)
	_weapon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_child(_weapon_label)

	# Ammo counter
	_ammo_label = Label.new()
	_ammo_label.name = "AmmoLabel"
	_ammo_label.text = ""
	_ammo_label.position = Vector2(MARGIN, -MARGIN - total_bars_height - gap - ammo_height)
	_ammo_label.size = Vector2(LABEL_WIDTH + BAR_WIDTH, ammo_height)
	_ammo_label.add_theme_font_size_override("font_size", 16)
	_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7, 1.0))
	_ammo_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_ammo_label.add_theme_constant_override("shadow_offset_x", 1)
	_ammo_label.add_theme_constant_override("shadow_offset_y", 1)
	_ammo_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_child(_ammo_label)

	# Bars
	var fills := []
	for i in range(bar_data.size()):
		var data = bar_data[i]
		var y_pos := -MARGIN - total_bars_height + i * (BAR_HEIGHT + BAR_GAP)

		# Label
		var label := Label.new()
		label.text = data["label"]
		label.position = Vector2(MARGIN, y_pos - 2)
		label.size = Vector2(LABEL_WIDTH, BAR_HEIGHT)
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 0.95))
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		anchor.add_child(label)

		# Background bar
		var bg := ColorRect.new()
		bg.color = BG_COLOR
		bg.position = Vector2(MARGIN + LABEL_WIDTH, y_pos)
		bg.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		anchor.add_child(bg)

		# Fill bar
		var fill := ColorRect.new()
		fill.color = data["color"]
		fill.position = Vector2(MARGIN + LABEL_WIDTH, y_pos)
		fill.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		anchor.add_child(fill)

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
