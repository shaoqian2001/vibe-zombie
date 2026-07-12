extends CanvasLayer

## Bottom-left HUD showing Armor, Health, and Stamina bars + ammo counter above.
## All positioning uses anchors so the HUD stays bottom-left at any resolution.

var _armor_fill: ColorRect
var _health_fill: ColorRect
var _stamina_fill: ColorRect
var _ammo_label: Label
var _weapon_label: Label
var _container: Control
var _dev_label: Label = null
var _code_label: Label = null
var _peer_count_label: Label = null
var _toast_label: Label = null
var _toast_timer: float = 0.0
var _buff_label: Label = null
var _ping_label: Label = null   # top-left latency readout (multiplayer only)

# Quick-item bar (mid-bottom). Built once; set_quick_bar() just updates contents.
var _qb_slots: Array = []          # per-slot dict: {panel_style, name, count}
var _use_prompt_label: Label = null

const TOAST_HOLD := 2.2   # seconds at full opacity before fading
const TOAST_FADE := 0.6   # fade-out duration

const QB_SLOT := 60.0     # quick-bar slot size (square)
const QB_GAP := 6.0
const QB_COUNT := 7

# Current values (0-100). Armor starts empty — the player owns it and only has
# armor after picking up body armor.
var armor: float = 0.0
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

func _process(delta: float) -> void:
	_update_bars()
	_update_toast(delta)
	_update_ping()

func set_stamina(value: float) -> void:
	stamina = clamp(value, 0.0, max_stamina)

func set_health(value: float) -> void:
	health = clamp(value, 0.0, max_health)

func set_armor(value: float) -> void:
	armor = clamp(value, 0.0, max_armor)

## Brief centred message when an item is picked up (e.g. "Apple  +25 HP").
func show_toast(text: String, color: Color = Color(1, 1, 1, 1)) -> void:
	if _toast_label == null:
		_build_toast()
	_toast_label.text = text
	# Item glow colours are semi-transparent; brighten and force opaque so the
	# toast text stays crisp (fade is handled via modulate in _update_toast).
	var c := color
	c.a = 1.0
	_toast_label.add_theme_color_override("font_color", c.lightened(0.15))
	_toast_label.modulate.a = 1.0
	_toast_label.visible = true
	_toast_timer = TOAST_HOLD + TOAST_FADE

func _build_toast() -> void:
	_toast_label = Label.new()
	_toast_label.name = "ToastLabel"
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.add_theme_font_size_override("font_size", 22)
	_toast_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_toast_label.add_theme_constant_override("shadow_offset_x", 2)
	_toast_label.add_theme_constant_override("shadow_offset_y", 2)
	_toast_label.anchor_left = 0.0
	_toast_label.anchor_right = 1.0
	_toast_label.anchor_top = 0.16
	_toast_label.anchor_bottom = 0.22
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_label.visible = false
	_container.add_child(_toast_label)

func _update_toast(delta: float) -> void:
	if _toast_label == null or _toast_timer <= 0.0:
		return
	_toast_timer -= delta
	if _toast_timer <= 0.0:
		_toast_label.visible = false
	elif _toast_timer < TOAST_FADE:
		_toast_label.modulate.a = _toast_timer / TOAST_FADE

## Show / hide the temporary speed-buff indicator. `remaining` is the seconds
## left on the energy-drink buff; <= 0 hides it.
func set_speed_buff(remaining: float) -> void:
	if remaining <= 0.0:
		if _buff_label:
			_buff_label.visible = false
		return
	if _buff_label == null:
		_build_buff_label()
	_buff_label.visible = true
	_buff_label.text = "⚡ SPEED  %.0fs" % ceil(remaining)

func _build_buff_label() -> void:
	_buff_label = Label.new()
	_buff_label.name = "BuffLabel"
	_buff_label.add_theme_font_size_override("font_size", 16)
	_buff_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25, 1.0))
	_buff_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_buff_label.add_theme_constant_override("shadow_offset_x", 1)
	_buff_label.add_theme_constant_override("shadow_offset_y", 1)
	# Sits just above the weapon-name label in the bottom-left stack.
	_buff_label.anchor_left = 0.0
	_buff_label.anchor_bottom = 1.0
	_buff_label.anchor_top = 1.0
	_buff_label.offset_left = MARGIN
	_buff_label.offset_top = -200.0
	_buff_label.offset_bottom = -176.0
	_buff_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_buff_label.visible = false
	_container.add_child(_buff_label)

func set_ammo(current: int, magazine: int) -> void:
	if _ammo_label:
		if magazine < 0:
			_ammo_label.text = "MELEE"
			_ammo_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7, 1.0))
		elif magazine == 0:
			_ammo_label.text = ""
		else:
			_ammo_label.text = "%d / %d" % [current, magazine]
			if current == 0:
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

	_build_ping_label()
	_build_quick_bar()

# ------------------------------------------------------------------
# Latency readout — pinned top-left, shown only in multiplayer. Every peer's
# HUD reads its own NetworkManager.ping_ms, so each player sees their own RTT.
# ------------------------------------------------------------------

func _build_ping_label() -> void:
	_ping_label = Label.new()
	_ping_label.name = "PingLabel"
	_ping_label.add_theme_font_size_override("font_size", 14)
	_ping_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_ping_label.add_theme_constant_override("shadow_offset_x", 1)
	_ping_label.add_theme_constant_override("shadow_offset_y", 1)
	# Top-left corner (game code / dev label live top-right, so no overlap).
	_ping_label.anchor_left = 0.0
	_ping_label.anchor_top = 0.0
	_ping_label.anchor_right = 0.0
	_ping_label.anchor_bottom = 0.0
	_ping_label.offset_left = MARGIN
	_ping_label.offset_top = 12.0
	_ping_label.offset_right = MARGIN + 180.0
	_ping_label.offset_bottom = 34.0
	_ping_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ping_label.visible = false
	_container.add_child(_ping_label)

func _update_ping() -> void:
	if _ping_label == null:
		return
	if not NetworkManager.is_networked:
		if _ping_label.visible:
			_ping_label.visible = false
		return
	_ping_label.visible = true
	var ms: float = NetworkManager.ping_ms
	if ms < 0.0:
		_ping_label.text = "PING  – ms"
		_ping_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.9))
	else:
		_ping_label.text = "PING  %d ms" % int(round(ms))
		_ping_label.add_theme_color_override("font_color", _ping_color(ms))

## Green (good) → yellow → orange → red (bad) by round-trip milliseconds.
func _ping_color(ms: float) -> Color:
	if ms < 80.0:
		return Color(0.40, 0.85, 0.40, 0.95)
	elif ms < 150.0:
		return Color(0.85, 0.85, 0.35, 0.95)
	elif ms < 250.0:
		return Color(0.90, 0.60, 0.25, 0.95)
	return Color(0.90, 0.30, 0.25, 0.95)

# ------------------------------------------------------------------
# Quick-item bar (mid-bottom). Seven slots mapped to number keys 1..7, with a
# "Press E to use" prompt above when a usable item is held. Built once here;
# set_quick_bar()/set_use_prompt() only mutate label text + slot colours.
# ------------------------------------------------------------------

func _build_quick_bar() -> void:
	# Full-width strip pinned just above the bottom edge; a CenterContainer keeps
	# the bar centred horizontally at any resolution.
	var strip := Control.new()
	strip.name = "QuickBarStrip"
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.anchor_left = 0.0
	strip.anchor_right = 1.0
	strip.anchor_top = 1.0
	strip.anchor_bottom = 1.0
	strip.offset_top = -(QB_SLOT + 40.0)
	strip.offset_bottom = -10.0
	_container.add_child(strip)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vbox)

	_use_prompt_label = Label.new()
	_use_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_use_prompt_label.add_theme_font_size_override("font_size", 16)
	_use_prompt_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
	_use_prompt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_use_prompt_label.add_theme_constant_override("shadow_offset_x", 1)
	_use_prompt_label.add_theme_constant_override("shadow_offset_y", 1)
	_use_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_use_prompt_label.visible = false
	vbox.add_child(_use_prompt_label)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", int(QB_GAP))
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hbox)

	for i in range(QB_COUNT):
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(QB_SLOT, QB_SLOT)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.10, 0.10, 0.12, 0.55)
		style.set_corner_radius_all(5)
		style.set_border_width_all(2)
		style.border_color = Color(0.40, 0.40, 0.45, 0.8)
		slot.add_theme_stylebox_override("panel", style)
		hbox.add_child(slot)

		# Key number (top-left).
		var key := Label.new()
		key.text = str(i + 1)
		key.add_theme_font_size_override("font_size", 11)
		key.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
		key.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		key.position = Vector2(5, 2)
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(key)

		# Item name (centred, wraps).
		var name_label := Label.new()
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		name_label.add_theme_font_size_override("font_size", 9)
		name_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
		name_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		name_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		name_label.offset_top = 12.0
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(name_label)

		# Stack count (bottom-right).
		var count_label := Label.new()
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		count_label.add_theme_font_size_override("font_size", 13)
		count_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.7))
		count_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		count_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		count_label.offset_right = -4.0
		count_label.offset_bottom = -2.0
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(count_label)

		_qb_slots.append({"style": style, "name": name_label, "count": count_label})

## Update the quick bar from the player's payload. `slots` is QB_COUNT entries,
## each null (empty) or {name, count, color, kind}; `selected` highlights one.
func set_quick_bar(slots: Array, selected: int) -> void:
	for i in range(_qb_slots.size()):
		var ui: Dictionary = _qb_slots[i]
		var style: StyleBoxFlat = ui["style"]
		var data = slots[i] if i < slots.size() else null
		if data == null:
			ui["name"].text = ""
			ui["count"].text = ""
			style.bg_color = Color(0.10, 0.10, 0.12, 0.45)
		else:
			ui["name"].text = String(data.get("name", "")).to_upper()
			var c := int(data.get("count", 0))
			ui["count"].text = ("x%d" % c) if c > 1 else ""
			var col: Color = data.get("color", Color(0.3, 0.3, 0.35))
			col.a = 0.5
			style.bg_color = col
		# Highlight the selected slot with a bright thicker border.
		if i == selected:
			style.border_color = Color(1.0, 0.95, 0.5, 1.0)
			style.set_border_width_all(3)
		else:
			style.border_color = Color(0.40, 0.40, 0.45, 0.8)
			style.set_border_width_all(2)

## Show / hide the "Press E to use ..." prompt above the quick bar.
func set_use_prompt(text: String) -> void:
	if _use_prompt_label == null:
		return
	_use_prompt_label.text = text
	_use_prompt_label.visible = text != ""

func show_game_code(code: String, peer_count: int = 0) -> void:
	if code.is_empty():
		return
	if _code_label == null:
		_code_label = Label.new()
		_code_label.name = "GameCodeLabel"
		_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_code_label.add_theme_font_size_override("font_size", 22)
		_code_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.55, 1.0))
		_code_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		_code_label.add_theme_constant_override("shadow_offset_x", 2)
		_code_label.add_theme_constant_override("shadow_offset_y", 2)
		_code_label.anchor_left = 0.0
		_code_label.anchor_top = 0.0
		_code_label.anchor_right = 1.0
		_code_label.anchor_bottom = 0.0
		_code_label.offset_right = -16
		_code_label.offset_top = 12
		_code_label.offset_bottom = 38
		_code_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_container.add_child(_code_label)

		_peer_count_label = Label.new()
		_peer_count_label.name = "PeerCountLabel"
		_peer_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_peer_count_label.add_theme_font_size_override("font_size", 12)
		_peer_count_label.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95, 0.95))
		_peer_count_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
		_peer_count_label.add_theme_constant_override("shadow_offset_x", 1)
		_peer_count_label.add_theme_constant_override("shadow_offset_y", 1)
		_peer_count_label.anchor_left = 0.0
		_peer_count_label.anchor_top = 0.0
		_peer_count_label.anchor_right = 1.0
		_peer_count_label.anchor_bottom = 0.0
		_peer_count_label.offset_right = -16
		_peer_count_label.offset_top = 38
		_peer_count_label.offset_bottom = 56
		_peer_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_container.add_child(_peer_count_label)

	_code_label.text = "CODE  %s" % code
	if peer_count > 0:
		_peer_count_label.text = "%d player%s" % [peer_count, "" if peer_count == 1 else "s"]
	else:
		_peer_count_label.text = ""

func update_peer_count(peer_count: int) -> void:
	if _peer_count_label:
		_peer_count_label.text = "%d player%s" % [peer_count, "" if peer_count == 1 else "s"]

func show_dev_mode() -> void:
	if _dev_label != null:
		return
	_dev_label = Label.new()
	_dev_label.text = "DEV MODE"
	_dev_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_dev_label.add_theme_font_size_override("font_size", 14)
	_dev_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 0.8))
	_dev_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_dev_label.add_theme_constant_override("shadow_offset_x", 1)
	_dev_label.add_theme_constant_override("shadow_offset_y", 1)
	_dev_label.anchor_left = 0.0
	_dev_label.anchor_top = 0.0
	_dev_label.anchor_right = 1.0
	_dev_label.anchor_bottom = 0.0
	_dev_label.offset_right = -10
	# Push DEV MODE label below the game code label if it exists.
	var top_offset := 60.0 if _code_label != null else 10.0
	_dev_label.offset_top = top_offset
	_dev_label.offset_bottom = top_offset + 20.0
	_dev_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.add_child(_dev_label)

func _update_bars() -> void:
	if _armor_fill:
		_armor_fill.size.x = BAR_WIDTH * (armor / max_armor)
	if _health_fill:
		_health_fill.size.x = BAR_WIDTH * (health / max_health)
	if _stamina_fill:
		_stamina_fill.size.x = BAR_WIDTH * (stamina / max_stamina)
