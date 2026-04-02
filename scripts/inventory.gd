extends CanvasLayer

## Inventory screen (I key).
## Left half: full-body character view with equipment slots.
## Right half: backpack inventory grid.
## All sizes scale proportionally with viewport resolution.

signal inventory_closed

# Base design values (for 720p). Scaled by _ui_scale().
const BASE_SLOT_SIZE := 56.0
const BASE_SLOT_GAP := 6.0
const GRID_COLS := 6
const GRID_ROWS := 5
const BASE_SECTION_FONT := 16
const BASE_LABEL_FONT := 12
const BASE_HINT_FONT := 12
const BASE_MARGIN := 20.0
const BASE_INNER_MARGIN := 16.0
const BASE_SEPARATION := 8.0

const SLOT_BG := Color(0.18, 0.18, 0.22, 0.85)
const SLOT_BORDER := Color(0.40, 0.40, 0.45, 0.7)
const PANEL_BG := Color(0.08, 0.08, 0.10, 0.92)
const EQUIP_SLOT_BG := Color(0.14, 0.22, 0.14, 0.85)

# Equipment slot names and positions relative to character silhouette
const EQUIP_SLOTS := [
	{"name": "Head", "offset": Vector2(0.5, 0.06)},
	{"name": "Chest", "offset": Vector2(0.5, 0.28)},
	{"name": "Legs", "offset": Vector2(0.5, 0.52)},
	{"name": "Feet", "offset": Vector2(0.5, 0.72)},
	{"name": "Main Hand", "offset": Vector2(0.15, 0.35)},
	{"name": "Off Hand", "offset": Vector2(0.85, 0.35)},
]

func _ready() -> void:
	layer = 90
	_build_ui()
	visible = true

func _ui_scale() -> float:
	var viewport_h := get_viewport().get_visible_rect().size.y
	return viewport_h / 720.0

func _build_ui() -> void:
	var s := _ui_scale()
	var slot_size := BASE_SLOT_SIZE * s
	var slot_gap := BASE_SLOT_GAP * s
	var margin := BASE_MARGIN * s
	var inner_margin := int(BASE_INNER_MARGIN * s)
	var separation := int(BASE_SEPARATION * s)

	# Dim background
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.50)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Main split container
	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.set_anchor_and_offset(SIDE_LEFT, 0.0, margin)
	root.set_anchor_and_offset(SIDE_RIGHT, 1.0, -margin)
	root.set_anchor_and_offset(SIDE_TOP, 0.0, margin)
	root.set_anchor_and_offset(SIDE_BOTTOM, 1.0, -margin)
	root.add_theme_constant_override("separation", int(16 * s))
	add_child(root)

	# ---- LEFT HALF: Character view ----
	var left_panel := _create_panel(s)
	left_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_panel.size_flags_stretch_ratio = 1.0
	root.add_child(left_panel)

	var left_content := MarginContainer.new()
	left_content.add_theme_constant_override("margin_left", inner_margin)
	left_content.add_theme_constant_override("margin_right", inner_margin)
	left_content.add_theme_constant_override("margin_top", inner_margin)
	left_content.add_theme_constant_override("margin_bottom", inner_margin)
	left_panel.add_child(left_content)

	var left_vbox := VBoxContainer.new()
	left_vbox.add_theme_constant_override("separation", separation)
	left_content.add_child(left_vbox)

	# Title
	var char_title := Label.new()
	char_title.text = "CHARACTER"
	char_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	char_title.add_theme_font_size_override("font_size", int(BASE_SECTION_FONT * s))
	char_title.add_theme_color_override("font_color", Color(0.85, 0.80, 0.65))
	left_vbox.add_child(char_title)

	# Character silhouette + equipment slots
	var char_area := Control.new()
	char_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(char_area)

	# Draw character body silhouette (simple procedural shapes)
	_draw_character_silhouette(char_area)

	# Equipment slots positioned around the silhouette
	for slot_info in EQUIP_SLOTS:
		_add_equip_slot(char_area, slot_info, slot_size, s)

	# ---- RIGHT HALF: Inventory grid ----
	var right_panel := _create_panel(s)
	right_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.size_flags_stretch_ratio = 1.0
	root.add_child(right_panel)

	var right_content := MarginContainer.new()
	right_content.add_theme_constant_override("margin_left", inner_margin)
	right_content.add_theme_constant_override("margin_right", inner_margin)
	right_content.add_theme_constant_override("margin_top", inner_margin)
	right_content.add_theme_constant_override("margin_bottom", inner_margin)
	right_panel.add_child(right_content)

	var right_vbox := VBoxContainer.new()
	right_vbox.add_theme_constant_override("separation", separation)
	right_content.add_child(right_vbox)

	# Title
	var inv_title := Label.new()
	inv_title.text = "BACKPACK"
	inv_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inv_title.add_theme_font_size_override("font_size", int(BASE_SECTION_FONT * s))
	inv_title.add_theme_color_override("font_color", Color(0.85, 0.80, 0.65))
	right_vbox.add_child(inv_title)

	# Grid container for inventory slots
	var grid := GridContainer.new()
	grid.columns = GRID_COLS
	grid.add_theme_constant_override("h_separation", int(slot_gap))
	grid.add_theme_constant_override("v_separation", int(slot_gap))
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	right_vbox.add_child(grid)

	for i in range(GRID_COLS * GRID_ROWS):
		var slot := _create_slot(SLOT_BG, slot_size, s)
		grid.add_child(slot)

	# Hint label
	var hint := Label.new()
	hint.text = "Press 'I' to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", int(BASE_HINT_FONT * s))
	hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	right_vbox.add_child(hint)

func _create_panel(s: float) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	var r := int(8 * s)
	style.corner_radius_top_left = r
	style.corner_radius_top_right = r
	style.corner_radius_bottom_left = r
	style.corner_radius_bottom_right = r
	var bw := int(max(1, 1 * s))
	style.border_color = Color(0.30, 0.30, 0.35, 0.6)
	style.border_width_left = bw
	style.border_width_right = bw
	style.border_width_top = bw
	style.border_width_bottom = bw
	panel.add_theme_stylebox_override("panel", style)
	return panel

func _create_slot(bg_color: Color, slot_size: float, s: float) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = Vector2(slot_size, slot_size)
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	var r := int(4 * s)
	style.corner_radius_top_left = r
	style.corner_radius_top_right = r
	style.corner_radius_bottom_left = r
	style.corner_radius_bottom_right = r
	var bw := int(max(1, 1 * s))
	style.border_color = SLOT_BORDER
	style.border_width_left = bw
	style.border_width_right = bw
	style.border_width_top = bw
	style.border_width_bottom = bw
	slot.add_theme_stylebox_override("panel", style)
	return slot

func _draw_character_silhouette(parent: Control) -> void:
	# We draw the silhouette when the parent is resized so we know the size
	parent.resized.connect(func() -> void:
		# Remove old silhouette children (tagged)
		for child in parent.get_children():
			if child.has_meta("silhouette"):
				child.queue_free()

		var w := parent.size.x
		var h := parent.size.y
		var cx := w * 0.5
		var body_color := Color(0.28, 0.42, 0.22, 0.6)
		var skin_color := Color(0.89, 0.73, 0.58, 0.6)

		# Head
		var head := ColorRect.new()
		head.color = skin_color
		head.size = Vector2(h * 0.12, h * 0.12)
		head.position = Vector2(cx - h * 0.06, h * 0.02)
		head.set_meta("silhouette", true)
		parent.add_child(head)

		# Torso
		var torso := ColorRect.new()
		torso.color = body_color
		torso.size = Vector2(h * 0.20, h * 0.28)
		torso.position = Vector2(cx - h * 0.10, h * 0.15)
		torso.set_meta("silhouette", true)
		parent.add_child(torso)

		# Left arm
		var larm := ColorRect.new()
		larm.color = body_color
		larm.size = Vector2(h * 0.06, h * 0.24)
		larm.position = Vector2(cx - h * 0.18, h * 0.16)
		larm.set_meta("silhouette", true)
		parent.add_child(larm)

		# Right arm
		var rarm := ColorRect.new()
		rarm.color = body_color
		rarm.size = Vector2(h * 0.06, h * 0.24)
		rarm.position = Vector2(cx + h * 0.12, h * 0.16)
		rarm.set_meta("silhouette", true)
		parent.add_child(rarm)

		# Left leg
		var lleg := ColorRect.new()
		lleg.color = body_color
		lleg.size = Vector2(h * 0.08, h * 0.30)
		lleg.position = Vector2(cx - h * 0.10, h * 0.44)
		lleg.set_meta("silhouette", true)
		parent.add_child(lleg)

		# Right leg
		var rleg := ColorRect.new()
		rleg.color = body_color
		rleg.size = Vector2(h * 0.08, h * 0.30)
		rleg.position = Vector2(cx + h * 0.02, h * 0.44)
		rleg.set_meta("silhouette", true)
		parent.add_child(rleg)

		# Feet
		var lfoot := ColorRect.new()
		lfoot.color = Color(0.25, 0.20, 0.15, 0.6)
		lfoot.size = Vector2(h * 0.09, h * 0.05)
		lfoot.position = Vector2(cx - h * 0.10, h * 0.74)
		lfoot.set_meta("silhouette", true)
		parent.add_child(lfoot)

		var rfoot := ColorRect.new()
		rfoot.color = Color(0.25, 0.20, 0.15, 0.6)
		rfoot.size = Vector2(h * 0.09, h * 0.05)
		rfoot.position = Vector2(cx + h * 0.02, h * 0.74)
		rfoot.set_meta("silhouette", true)
		parent.add_child(rfoot)
	)

func _add_equip_slot(parent: Control, slot_info: Dictionary, slot_size: float, s: float) -> void:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", int(2 * s))
	container.set_meta("equip_slot", true)
	parent.add_child(container)

	var slot := _create_slot(EQUIP_SLOT_BG, slot_size, s)
	container.add_child(slot)

	var label := Label.new()
	label.text = slot_info["name"]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", int(BASE_LABEL_FONT * s))
	label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	container.add_child(label)

	# Position the container based on parent size
	var offset: Vector2 = slot_info["offset"]
	parent.resized.connect(func() -> void:
		var w := parent.size.x
		var h := parent.size.y
		container.position = Vector2(
			w * offset.x - slot_size * 0.5,
			h * offset.y - slot_size * 0.5
		)
	)
