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
		"fan_angle": 20.0,
		"fan_rays": 5,
	},
	"smg": {
		"damage": 5.0,
		"range": 30.0,
		"magazine_size": 30,
		"fire_rate": 10.0,
		"reload_time": 2.0,
		"spread": 3.0,
		"bullet_speed": INF,
		"tracer_color": Color(1.0, 1.0, 0.5, 0.7),
		"hit_mode": "single",
		"hit_tolerance": 1.0,
	},
	"grenade_launcher": {
		"damage": 30.0,
		"range": 25.0,
		"magazine_size": 1,
		"fire_rate": 0.5,
		"reload_time": 2.5,
		"spread": 0.0,
		"bullet_speed": INF,
		"tracer_color": Color(1.0, 0.4, 0.1, 0.9),
		"hit_mode": "explosive",
		"explosion_radius": 5.0,
	},
	"bat": {
		"damage": 20.0,
		"range": 2.5,
		"magazine_size": -1,
		"fire_rate": 1.5,
		"reload_time": 0.0,
		"spread": 0.0,
		"bullet_speed": INF,
		"tracer_color": Color(0.6, 0.4, 0.2, 0.5),
		"hit_mode": "melee",
		"sweep_angle": 90.0,
	},
}

static func get_weapon(weapon_name: String) -> Dictionary:
	return WEAPONS.get(weapon_name, {})

static func shoot_cooldown(weapon_name: String) -> float:
	var w := get_weapon(weapon_name)
	if w.is_empty():
		return 0.25
	return 1.0 / w["fire_rate"]
