extends Node

## Survival mode — the wave-defence game mode.
##
## Players are handed a building as their headquarters and have to hold it
## through three scheduled zombie assaults. Waves land at dusk on day 7 and
## day 12 (probing attacks) and day 15 (the finale). Clear the final wave and
## the run is won; let the HQ's integrity hit zero and it's lost.
##
## The node runs on EVERY peer, unlike the campaign mission system:
##   - HQ selection is deterministic (derived from the shared world seed), so
##     every peer builds the same base marker, defence ring and map marker with
##     no networking at all.
##   - Wave logic, HQ integrity and the clock are host-authoritative and pushed
##     to clients in one "survival_sync" packet (see main.gd).
##
## It deliberately mirrors mission_system.gd's public surface (`setup`,
## `process`, `get_objective_text`, `get_map_markers`, `spawn_horde_at`,
## `notify_enemy_killed`, `zombie_density_multiplier`) so main.gd and the debug
## panel can drive either system through the same calls.

const FovCuller = preload("res://scripts/fov_culler.gd")

signal survival_won
signal survival_lost
signal wave_announced(text: String, color: Color)

## Wave schedule. `day` is the in-game day the assault lands on (at dusk).
const WAVES := [
	{"day": 7,  "size": 18, "label": "First Assault"},
	{"day": 12, "size": 30, "label": "Second Assault"},
	{"day": 15, "size": 52, "label": "FINAL ASSAULT", "final": true},
]

## Hour of day the assault begins. Zombies come at nightfall.
const WAVE_HOUR := 19.0

## Radius around the HQ centre that counts as "the base". Zombies inside it
## claw at the building; it's also the ring drawn on the ground.
const HQ_RADIUS := 16.0
const HQ_MAX_HP := 1200.0
## HP per second a single zombie strips off the HQ while inside the ring during
## an assault. A couple of dozen breaching zombies take the base down in about a
## minute, so the wave has to actually be fought, not waited out.
const HQ_DAMAGE_PER_ZOMBIE := 1.5
## Repairs between assaults, so one bad night isn't quietly fatal three days later.
const HQ_REGEN_PER_SECOND := 20.0

## Where wave zombies appear, measured from the HQ centre.
const WAVE_SPAWN_RADIUS := 55.0

## Material caches dropped at the base on day 1, plus a daily resupply, so
## there's always something to craft with.
const STARTING_CACHE := 14
const DAILY_CACHE := 5
## Chance a zombie killed during Survival leaves behind craft material.
const MATERIAL_DROP_CHANCE := 0.28

# ------------------------------------------------------------------
# State
# ------------------------------------------------------------------

var zombie_density_multiplier: float = 1.0   # debug-panel hook (mission-system parity)

var hq_position: Vector3 = Vector3.ZERO
var hq_hp: float = HQ_MAX_HP
var hq_max_hp: float = HQ_MAX_HP

var wave_index: int = 0            # next wave to run (== WAVES.size() when done)
var wave_active: bool = false
var wave_enemies_left: int = 0
var finished: bool = false

var _main: Node3D = null
var _world: Node3D = null
var _time = null                   # time_system.gd node
var _is_host: bool = true
var _rng := RandomNumberGenerator.new()

var _hq_building: Dictionary = {}
var _wave_enemies: Array = []
var _beacon: Node3D = null
var _ring: MeshInstance3D = null
var _last_cache_day: int = 1
var _announced_wave: int = -1

# ------------------------------------------------------------------
# Deterministic HQ selection
# ------------------------------------------------------------------

## Pick the headquarters building. Every peer runs this against the same
## seed-generated `world.buildings` array, so they all land on the same one
## without a single network message.
##
## Preference: close to the map centre (players spawn around it, waves converge
## on it) and roomy enough to actually fight inside.
static func pick_hq_building(world: Node3D) -> Dictionary:
	var raw: Variant = world.get("buildings")
	if typeof(raw) != TYPE_ARRAY or (raw as Array).is_empty():
		return {}
	var buildings: Array = raw
	# Rank by distance to the map centre, then take the largest of the closest
	# handful so the base is a real building rather than a shed.
	var ranked: Array = buildings.duplicate()
	ranked.sort_custom(func(a, b):
		var pa: Vector3 = a.node.position
		var pb: Vector3 = b.node.position
		return (pa.x * pa.x + pa.z * pa.z) < (pb.x * pb.x + pb.z * pb.z)
	)
	var pool: Array = ranked.slice(0, mini(8, ranked.size()))
	var best: Dictionary = pool[0]
	var best_area: float = float(best.width) * float(best.depth)
	for b in pool:
		var area: float = float(b.width) * float(b.depth)
		if area > best_area:
			best = b
			best_area = area
	return best

# ------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------

func setup(main: Node3D, world_node: Node3D, hq_building: Dictionary, time_system: Node, is_host: bool, rng: RandomNumberGenerator) -> void:
	_main = main
	_world = world_node
	_hq_building = hq_building
	_time = time_system
	_is_host = is_host
	_rng.seed = rng.seed ^ 0x5A1FE
	if not _hq_building.is_empty():
		var bp: Vector3 = _hq_building.node.position
		hq_position = Vector3(bp.x, 0.0, bp.z)
	_build_hq_visuals()
	if _is_host:
		_spawn_material_cache(STARTING_CACHE)

func process(delta: float) -> void:
	if _time == null:
		return
	# Every peer ticks the clock locally so the corner display stays smooth
	# between the host's 2 Hz packets; net_set_hours() corrects any drift.
	_time.advance(delta)
	if _is_host and not finished:
		_process_waves()
		_process_hq(delta)
	_animate_beacon(delta)

# ------------------------------------------------------------------
# Wave scheduling (host)
# ------------------------------------------------------------------

func _process_waves() -> void:
	# Daily resupply so the base never runs dry of craft materials.
	var today: int = _time.day()
	if today > _last_cache_day:
		_last_cache_day = today
		_spawn_material_cache(DAILY_CACHE)

	# Waves run on the calendar, not on how the last one went: if day 12 arrives
	# with day 7's horde still standing, you fight both. `wave_index` counts
	# waves LAUNCHED, so it also names the next one due.
	while wave_index < WAVES.size():
		var wave: Dictionary = WAVES[wave_index]
		var wave_day: int = int(wave["day"])
		if today > wave_day or (today == wave_day and _time.hour_of_day() >= WAVE_HOUR):
			wave_index += 1
			_start_wave(wave)
			continue
		# Not due yet — warn the defenders the evening before, then stop looking.
		if today == wave_day - 1 and _announced_wave != wave_index and _time.hour_of_day() >= WAVE_HOUR:
			_announced_wave = wave_index
			wave_announced.emit("%s arrives tomorrow night" % String(wave["label"]), Color(1.0, 0.75, 0.25))
		break

	_prune_wave_enemies()
	if wave_active and wave_enemies_left <= 0:
		wave_active = false
		_on_wave_cleared()

func _start_wave(wave: Dictionary) -> void:
	wave_active = true

	var horde_mult := 1.0
	if NetworkManager.is_networked:
		horde_mult = NetworkManager.difficulty_settings(NetworkManager.difficulty).horde_mult
	# More defenders means a bigger horde, so a 4-player base isn't trivial.
	var player_scale: float = 1.0 + 0.35 * float(maxi(_player_count() - 1, 0))
	var count := int(float(wave["size"]) * zombie_density_multiplier * horde_mult * player_scale)

	for _i in range(count):
		var angle := _rng.randf_range(0.0, TAU)
		var dist := _rng.randf_range(WAVE_SPAWN_RADIUS * 0.7, WAVE_SPAWN_RADIUS)
		var pos := Vector3(
			hq_position.x + cos(angle) * dist,
			0.5,
			hq_position.z + sin(angle) * dist)
		var enemy: CharacterBody3D = _main._spawn_enemy_at(pos)
		if enemy == null:
			continue
		# Wave zombies march on the base rather than idling out of detect range,
		# so the assault actually converges on the HQ.
		enemy.set("home_target", hq_position)
		_wave_enemies.append(enemy)

	wave_enemies_left = _wave_enemies.size()
	wave_announced.emit("%s — defend the base!" % String(wave["label"]), Color(0.95, 0.25, 0.20))

## Recount the surviving assault zombies, compacting out the dead so the list
## doesn't grow across three waves.
func _prune_wave_enemies() -> void:
	var alive: Array = []
	for e in _wave_enemies:
		if is_instance_valid(e):
			alive.append(e)
	_wave_enemies = alive
	wave_enemies_left = alive.size()

func _on_wave_cleared() -> void:
	# Every scheduled wave has launched and nothing is left standing — the run
	# is won. Otherwise it's a breather until the next date on the calendar.
	if wave_index >= WAVES.size():
		finished = true
		wave_announced.emit("The base holds. You survived!", Color(0.35, 0.95, 0.40))
		survival_won.emit()
	else:
		var days := _days_to_next_wave()
		wave_announced.emit("Wave repelled — %d day%s until the next" % [
			days, "" if days == 1 else "s",
		], Color(0.45, 0.85, 0.95))

func _days_to_next_wave() -> int:
	if wave_index >= WAVES.size():
		return 0
	return _time.days_until(int(WAVES[wave_index]["day"]))

func _player_count() -> int:
	if NetworkManager.is_networked:
		return maxi(NetworkManager.peers.size(), 1)
	return 1

# ------------------------------------------------------------------
# HQ integrity (host)
# ------------------------------------------------------------------

func _process_hq(delta: float) -> void:
	# Only an actual assault threatens the structure. Between waves the city's
	# ambient wanderers are a personal danger, not a structural one — otherwise
	# a couple of strays drifting through the ring would grind the base down
	# during the "quiet" days, which is not the game the calendar promises.
	if not wave_active:
		hq_hp = minf(hq_hp + HQ_REGEN_PER_SECOND * delta, hq_max_hp)
		return

	var inside := 0
	for n in _main.get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(n):
			continue
		var p: Vector3 = (n as Node3D).global_position
		if Vector2(p.x - hq_position.x, p.z - hq_position.z).length() <= HQ_RADIUS:
			inside += 1
	if inside > 0:
		hq_hp = maxf(hq_hp - float(inside) * HQ_DAMAGE_PER_ZOMBIE * delta, 0.0)
		if hq_hp <= 0.0 and not finished:
			finished = true
			wave_announced.emit("The base has fallen.", Color(0.9, 0.2, 0.15))
			survival_lost.emit()

# ------------------------------------------------------------------
# Material caches (host)
# ------------------------------------------------------------------

func _spawn_material_cache(count: int) -> void:
	if _main == null or not _main.has_method("host_spawn_item"):
		return
	for _i in range(count):
		var angle := _rng.randf_range(0.0, TAU)
		var dist := _rng.randf_range(6.0, HQ_RADIUS * 0.9)
		var pos := Vector3(
			hq_position.x + cos(angle) * dist,
			0.0,
			hq_position.z + sin(angle) * dist)
		_main.host_spawn_item("wood" if _rng.randf() < 0.55 else "scrap", pos)

## Called by enemy.gd on every kill (host side). Survival turns a share of the
## kills into craft material so fighting feeds building.
func notify_enemy_killed(pos: Vector3 = Vector3.ZERO) -> void:
	if not _is_host or pos == Vector3.ZERO:
		return
	if _rng.randf() > MATERIAL_DROP_CHANCE:
		return
	if _main and _main.has_method("host_spawn_item"):
		_main.host_spawn_item("wood" if _rng.randf() < 0.5 else "scrap", Vector3(pos.x, 0.0, pos.z))

## Debug-panel parity with the mission system.
func spawn_horde_at(center: Vector3, count: int) -> void:
	for _i in range(count):
		var angle := _rng.randf_range(0.0, TAU)
		var dist := _rng.randf_range(4.0, 14.0)
		_main._spawn_enemy_at(Vector3(center.x + cos(angle) * dist, 0.5, center.z + sin(angle) * dist))

# ------------------------------------------------------------------
# Networking — one packet carries clock + wave + HQ state
# ------------------------------------------------------------------

func build_state() -> Dictionary:
	return {
		"t": _time.total_hours if _time else 0.0,
		"hp": hq_hp,
		"max": hq_max_hp,
		"wi": wave_index,
		"wa": wave_active,
		"wl": wave_enemies_left,
		"fin": finished,
	}

func apply_state(state: Dictionary) -> void:
	if _time:
		_time.net_set_hours(float(state.get("t", 0.0)))
	hq_hp = float(state.get("hp", hq_hp))
	hq_max_hp = maxf(float(state.get("max", hq_max_hp)), 1.0)
	wave_index = int(state.get("wi", wave_index))
	wave_active = bool(state.get("wa", false))
	wave_enemies_left = int(state.get("wl", 0))
	finished = bool(state.get("fin", false))

# ------------------------------------------------------------------
# HUD / map read-outs (mission-system parity)
# ------------------------------------------------------------------

func get_objective_text() -> String:
	if finished:
		return "The base holds — you survived the outbreak!" if hq_hp > 0.0 else "The base has fallen."
	if wave_active:
		return "DEFEND THE BASE — %d zombie%s left" % [
			wave_enemies_left, "" if wave_enemies_left == 1 else "s",
		]
	if wave_index >= WAVES.size():
		return "Hold the base."
	var wave: Dictionary = WAVES[wave_index]
	var days := _days_to_next_wave()
	var when := "tonight" if days == 0 else ("tomorrow" if days == 1 else "in %d days" % days)
	return "%s hits on day %d (%s) — fortify the base  ·  B to craft" % [
		String(wave["label"]), int(wave["day"]), when,
	]

func get_map_markers() -> Array:
	return [{
		"position": hq_position,
		"color": Color(0.30, 0.85, 1.0),
		"label": "HQ",
	}]

## Fraction of HQ integrity remaining, for the HUD bar.
func hq_ratio() -> float:
	return clampf(hq_hp / maxf(hq_max_hp, 1.0), 0.0, 1.0)

# ------------------------------------------------------------------
# HQ visuals (built on every peer — deterministic, no sync needed)
# ------------------------------------------------------------------

func _build_hq_visuals() -> void:
	if _main == null:
		return
	_build_defence_ring()
	_build_beacon()

func _build_defence_ring() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.75, 1.0, 0.13)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mesh := CylinderMesh.new()
	mesh.top_radius = HQ_RADIUS
	mesh.bottom_radius = HQ_RADIUS
	mesh.height = 0.08
	mesh.material = mat

	_ring = MeshInstance3D.new()
	_ring.name = "HQDefenceRing"
	_ring.mesh = mesh
	_ring.position = Vector3(hq_position.x, 0.04, hq_position.z)
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_main.add_child(_ring)
	_ring.add_to_group(&"fov_cullable")
	_ring.set_meta(&"fov_cull_radius", HQ_RADIUS + 1.0)
	FovCuller.apply_shader_to_subtree(_ring)

## A tall banner above the base roof so it can be spotted from across the city.
func _build_beacon() -> void:
	var height: float = 6.0
	if not _hq_building.is_empty():
		height = float(_hq_building.get("height", 10.0)) + 4.0

	_beacon = Node3D.new()
	_beacon.name = "HQBeacon"
	_beacon.position = Vector3(hq_position.x, height, hq_position.z)
	_main.add_child(_beacon)
	_beacon.add_to_group(&"fov_cullable")
	_beacon.set_meta(&"fov_cull_radius", 3.0)

	var color := Color(0.30, 0.85, 1.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.9)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var prism_mesh := PrismMesh.new()
	prism_mesh.size = Vector3(2.2, 3.0, 2.2)
	prism_mesh.material = mat
	var prism := MeshInstance3D.new()
	prism.mesh = prism_mesh
	prism.rotation_degrees.x = 180
	_beacon.add_child(prism)

	var beam_mat := StandardMaterial3D.new()
	beam_mat.albedo_color = Color(color.r, color.g, color.b, 0.25)
	beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.2
	beam_mesh.bottom_radius = 0.2
	beam_mesh.height = height
	beam_mesh.material = beam_mat
	var beam := MeshInstance3D.new()
	beam.mesh = beam_mesh
	beam.position.y = -height * 0.5
	_beacon.add_child(beam)

	FovCuller.apply_shader_to_subtree(_beacon)

func _animate_beacon(delta: float) -> void:
	if _beacon and is_instance_valid(_beacon):
		_beacon.rotation.y += delta * 1.2
