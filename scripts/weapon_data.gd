class_name WeaponData

# Weapon lookup table — add new entries as weapons are introduced.
# Each key is the weapon name; the value is a dictionary of stats.

const WEAPONS := {
	"pistol": {
		"damage": 10.0,
		"range": 30.0,          # max shooting / aim-line distance
		"magazine_size": 8,
		"fire_rate": 2.0,       # rounds per second  (1 / cooldown = 0.5s)
		"reload_time": 1.2,     # seconds to reload
		"spread": 0.0,          # accuracy cone half-angle in degrees (0 = perfect)
		"bullet_speed": INF,    # hitscan (instant)
		"tracer_color": Color(1.0, 0.9, 0.3, 0.8),
	},
}

static func get_weapon(weapon_name: String) -> Dictionary:
	return WEAPONS.get(weapon_name, {})

static func shoot_cooldown(weapon_name: String) -> float:
	var w := get_weapon(weapon_name)
	if w.is_empty():
		return 0.25
	return 1.0 / w["fire_rate"]
