extends CanvasLayer

## Craft menu (B key).
##
## Lists every CraftData recipe with its cost, greys out anything the player
## can't afford, and reports the chosen recipe back to main.gd. Structures then
## go into placement mode; items land straight in the player's bag.
##
## Rows are also bound to number keys 1..N, so the whole loop can be driven
## without leaving the keyboard: B → 1 → click to place.

const MenuShared = preload("res://scripts/menu_shared.gd")
const CraftDataRef = preload("res://scripts/craft_data.gd")

signal craft_requested(recipe_id: String)
signal craft_closed

# Set by main.gd before add_child so the panel can read real material counts.
var player_ref: Node = null

var _rows: Array = []          # per-recipe { id, button, cost_label, affordable }
var _materials_label: Label = null
var _hint_label: Label = null

func _ready() -> void:
	layer = 95
	_build_ui()
	visible = true

func _process(_delta: float) -> void:
	# Materials change while the menu is open (a teammate's drop, a pickup you
	# walked over), so keep affordability live rather than snapshotting it.
	_refresh_affordability()

func _build_ui() -> void:
	var s := MenuShared.ui_scale()

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(660 * s, 0)
	panel.add_theme_stylebox_override("panel", MenuShared.make_panel_style(s))
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", int(10 * s))
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "CRAFT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(30 * s))
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	vbox.add_child(title)

	_materials_label = Label.new()
	_materials_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_materials_label.add_theme_font_size_override("font_size", int(15 * s))
	_materials_label.add_theme_color_override("font_color", Color(0.85, 0.80, 0.55))
	vbox.add_child(_materials_label)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	var ids := CraftDataRef.recipe_ids()
	for i in range(ids.size()):
		vbox.add_child(_build_row(String(ids[i]), i, s))

	_hint_label = Label.new()
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.text = "Press 1-%d to craft  ·  B or ESC to close  ·  Scavenge Wood and Scrap around the city" % ids.size()
	_hint_label.add_theme_font_size_override("font_size", int(12 * s))
	_hint_label.add_theme_color_override("font_color", Color(0.55, 0.56, 0.52))
	vbox.add_child(_hint_label)

	_refresh_affordability()

func _build_row(recipe_id: String, index: int, s: float) -> Control:
	var data := CraftDataRef.get_recipe(recipe_id)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(12 * s))

	var key := Label.new()
	key.text = "%d" % (index + 1)
	key.custom_minimum_size = Vector2(24 * s, 0)
	key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	key.add_theme_font_size_override("font_size", int(18 * s))
	key.add_theme_color_override("font_color", Color(0.70, 0.72, 0.78))
	row.add_child(key)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", int(1 * s))
	row.add_child(text_box)

	var name_label := Label.new()
	name_label.text = String(data.get("display_name", recipe_id))
	name_label.add_theme_font_size_override("font_size", int(17 * s))
	name_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.80))
	text_box.add_child(name_label)

	var desc := Label.new()
	desc.text = String(data.get("description", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", int(12 * s))
	desc.add_theme_color_override("font_color", Color(0.60, 0.62, 0.56))
	text_box.add_child(desc)

	var cost_label := Label.new()
	cost_label.text = CraftDataRef.cost_text(data.get("cost", {}))
	cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cost_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cost_label.custom_minimum_size = Vector2(150 * s, 0)
	cost_label.add_theme_font_size_override("font_size", int(14 * s))
	row.add_child(cost_label)

	var btn := MenuShared.make_button("Craft", s, 110, 40, 15)
	btn.pressed.connect(func() -> void: _try_craft(recipe_id))
	row.add_child(btn)

	_rows.append({"id": recipe_id, "button": btn, "cost": cost_label})
	return row

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("craft") or event.is_action_pressed("game_manual"):
		craft_closed.emit()
		get_viewport().set_input_as_handled()
		return
	# Number keys pick a recipe by row (1..N), matching the labels on the left.
	for i in range(_rows.size()):
		if i < 7 and event.is_action_pressed("weapon_%d" % (i + 1)):
			_try_craft(String(_rows[i]["id"]))
			get_viewport().set_input_as_handled()
			return

func _try_craft(recipe_id: String) -> void:
	if not _can_afford(recipe_id):
		return
	craft_requested.emit(recipe_id)

func _can_afford(recipe_id: String) -> bool:
	if player_ref == null or not player_ref.has_method("has_materials"):
		return false
	return player_ref.has_materials(CraftDataRef.get_recipe(recipe_id).get("cost", {}))

func _refresh_affordability() -> void:
	if _materials_label:
		var counts: Array[String] = []
		for id in CraftDataRef.MATERIAL_NAMES:
			var n := 0
			if player_ref and player_ref.has_method("material_count"):
				n = player_ref.material_count(id)
			counts.append("%s  %d" % [CraftDataRef.MATERIAL_NAMES[id], n])
		_materials_label.text = "   ·   ".join(counts)

	for row in _rows:
		var ok := _can_afford(String(row["id"]))
		var btn: Button = row["button"]
		btn.disabled = not ok
		var cost: Label = row["cost"]
		cost.add_theme_color_override("font_color",
			Color(0.70, 0.85, 0.55) if ok else Color(0.75, 0.42, 0.38))
