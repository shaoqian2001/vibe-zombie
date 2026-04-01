class_name WeaponData

# Weapon lookup table — add new entries as weapons are introduced.
# Each key is the weapon name; the value is a dictionary of stats.

const WEAPONS := {
	"pistol": {
		"damage": 10.0,
		"range": 40.0,
		"magazine_size": 8,
		"fire_rate": 2.0,
		"reload_time": 1.2,
		"spread": 0.0,
		"bullet_speed": INF,
		"tracer_color": Color(1.0, 0.9, 0.3, 0.8),
		"hit_mode": "single",
		"hit_tolerance": 1.2,
	},
	"shotgun": {
		"damage": 15.0,
		"range": 12.0,
		"magazine_size": 4,
		"fire_rate": 1.0,
		"reload_time": 2.0,
		"spread": 0.0,
		"bullet_speed": INF,
		"tracer_color": Color(1.0, 0.5, 0.2, 0.8),
		"hit_mode": "fan",
		"fan_angle": 35.0,
		"fan_rays": 7,
	},
}

static func get_weapon(weapon_name: String) -> Dictionary:
	return WEAPONS.get(weapon_name, {})

static func shoot_cooldown(weapon_name: String) -> float:
	var w := get_weapon(weapon_name)
	if w.is_empty():
		return 0.25
	return 1.0 / w["fire_rate"]
