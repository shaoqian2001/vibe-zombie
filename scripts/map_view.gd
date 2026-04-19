extends CanvasLayer

## Full-screen top-down map overlay.
## Centered, square, with small top/bottom margins. Shows roads, buildings,
## the player (with facing direction), and active mission markers.

const TOP_MARGIN := 30.0
const BOTTOM_MARGIN := 30.0
const SIDE_MIN_MARGIN := 20.0

const BG_DIM_COLOR     := Color(0.0, 0.0, 0.0, 0.72)
const GRASS_COLOR      := Color(0.32, 0.46, 0.24)
const ROAD_COLOR       := Color(0.18, 0.18, 0.20)
const SIDEWALK_COLOR   := Color(0.55, 0.55, 0.52)
const BUILDING_COLOR   := Color(0.85, 0.82, 0.78)
const BUILDING_BORDER  := Color(0.15, 0.15, 0.18)
const MAP_BORDER_COLOR := Color(0.90, 0.85, 0.70)
const PLAYER_COLOR     := Color(0.25, 0.65, 1.0)
const PLAYER_OUTLINE   := Color(0.05, 0.08, 0.15)
const PICKUP_COLOR     := Color(0.2, 0.8, 1.0)
const DELIVERY_COLOR   := Color(1.0, 0.82, 0.15)

class MapDrawer extends Control:
	var view  # untyped ref back to the owning CanvasLayer script
	func _draw() -> void:
		if view and view.has_method("_render_map"):
			view._render_map(self)

var _world: Node3D
var _player: Node3D
var _pickup_building: Dictionary = {}
var _delivery_building: Dictionary = {}
var _has_package: bool = false
var _drawer: MapDrawer = null

func configure(world: Node3D, player: Node3D, pickup: Dictionary, delivery: Dictionary, has_package: bool) -> void:
	_world = world
	_player = player
	_pickup_building = pickup
	_delivery_building = delivery
	_has_package = has_package
	if _drawer:
		_drawer.queue_redraw()

func _ready() -> void:
	layer = 100
	_build_ui()

func _process(_delta: float) -> void:
	if _drawer:
		_drawer.queue_redraw()

func _build_ui() -> void:
	# Dim overlay — catches clicks so the world behind does not receive them
	var dim := ColorRect.new()
	dim.color = BG_DIM_COLOR
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# Drawer covers the full viewport; _render_map picks out a centered square region
	_drawer = MapDrawer.new()
	_drawer.view = self
	_drawer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drawer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_drawer)

	# Title / hint at the very top of the screen
	var title := Label.new()
	title.text = "MAP   —   Press M to close"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.90, 0.85, 0.70))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 1)
	title.add_theme_constant_override("shadow_offset_y", 1)
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.0
	title.anchor_bottom = 0.0
	title.offset_top = 4.0
	title.offset_bottom = 26.0
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)

func _render_map(ctrl: Control) -> void:
	if _world == null or _player == null:
		return

	var vp := ctrl.size
	# Compute the largest square that fits within the viewport honouring margins
	var avail_h := vp.y - TOP_MARGIN - BOTTOM_MARGIN
	var avail_w := vp.x - SIDE_MIN_MARGIN * 2.0
	var map_side := min(avail_h, avail_w)
	if map_side <= 0.0:
		return
	var ox := (vp.x - map_side) * 0.5
	var oy := TOP_MARGIN + (avail_h - map_side) * 0.5
	var rect := Rect2(ox, oy, map_side, map_side)

	# Grass background
	ctrl.draw_rect(rect, GRASS_COLOR, true)

	var world_half: float = _world.map_half
	var s: float = map_side / (world_half * 2.0)
	var center := Vector2(ox + map_side * 0.5, oy + map_side * 0.5)

	var block_size: float = _world.BLOCK_SIZE
	var road_w: float = _world.ROAD_WIDTH
	var cell_size: float = _world.CELL_SIZE
	var nb: int = _world.num_blocks
	var total := nb * cell_size
	var grid_origin := -total * 0.5

	# Sidewalks (lighter) and roads between blocks
	for row in range(nb):
		for col in range(nb):
			var bx := grid_origin + col * cell_size
			var bz := grid_origin + row * cell_size
			ctrl.draw_rect(
				_world_rect(bx, bz, bx + block_size, bz + block_size, center, s),
				SIDEWALK_COLOR, true)
			ctrl.draw_rect(
				_world_rect(bx + block_size, bz, bx + block_size + road_w, bz + cell_size, center, s),
				ROAD_COLOR, true)
			ctrl.draw_rect(
				_world_rect(bx, bz + block_size, bx + cell_size, bz + block_size + road_w, center, s),
				ROAD_COLOR, true)

	# Buildings
	for binfo in _world.buildings:
		var bpos: Vector3 = binfo.node.position
		var hw: float = binfo.width * 0.5
		var hd: float = binfo.depth * 0.5
		var br := _world_rect(bpos.x - hw, bpos.z - hd, bpos.x + hw, bpos.z + hd, center, s)
		ctrl.draw_rect(br, BUILDING_COLOR, true)
		ctrl.draw_rect(br, BUILDING_BORDER, false, 1.0)

	# Outer map border on top of contents
	ctrl.draw_rect(rect, MAP_BORDER_COLOR, false, 2.0)

	# Mission markers — only show whichever objective is currently active
	if not _has_package and not _pickup_building.is_empty():
		var pp: Vector3 = _pickup_building.node.position
		_draw_marker(ctrl, _world_point(pp.x, pp.z, center, s), PICKUP_COLOR)
	if _has_package and not _delivery_building.is_empty():
		var dp: Vector3 = _delivery_building.node.position
		_draw_marker(ctrl, _world_point(dp.x, dp.z, center, s), DELIVERY_COLOR)

	# Player arrow — facing direction from player's transform
	var ppos: Vector3 = _player.global_position
	var pscreen := _world_point(ppos.x, ppos.z, center, s)
	var forward: Vector3 = _player.global_transform.basis.z
	var fwd2 := Vector2(forward.x, forward.z)
	if fwd2.length_squared() < 0.0001:
		fwd2 = Vector2(0, 1)
	fwd2 = fwd2.normalized()
	_draw_player_arrow(ctrl, pscreen, fwd2)

func _draw_marker(ctrl: Control, pos: Vector2, color: Color) -> void:
	ctrl.draw_circle(pos, 7.0, color)
	ctrl.draw_arc(pos, 7.0, 0.0, TAU, 24, Color(0, 0, 0, 0.8), 1.5)

func _draw_player_arrow(ctrl: Control, pos: Vector2, forward: Vector2) -> void:
	var size := 9.0
	var left := Vector2(-forward.y, forward.x)
	var tip := pos + forward * size
	var bl := pos - forward * size * 0.6 + left * size * 0.6
	var br := pos - forward * size * 0.6 - left * size * 0.6
	var pts := PackedVector2Array([tip, bl, br])
	ctrl.draw_colored_polygon(pts, PLAYER_COLOR)
	ctrl.draw_polyline(PackedVector2Array([tip, bl, br, tip]), PLAYER_OUTLINE, 1.5)

func _world_point(wx: float, wz: float, center: Vector2, s: float) -> Vector2:
	return Vector2(center.x + wx * s, center.y + wz * s)

func _world_rect(x1: float, z1: float, x2: float, z2: float, center: Vector2, s: float) -> Rect2:
	var p1 := _world_point(x1, z1, center, s)
	var p2 := _world_point(x2, z2, center, s)
	return Rect2(Vector2(min(p1.x, p2.x), min(p1.y, p2.y)),
		Vector2(abs(p2.x - p1.x), abs(p2.y - p1.y)))
