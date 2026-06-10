class_name WeaponData

# Weapon lookup table — add new entries as weapons are introduced.
# Each key is the weapon name; the value is a dictionary of stats.
#
# Knockback / recoil note:
#   • knockback is the world-unit/sec impulse applied to a target on hit
#     (per-bullet for single rounds, per-pellet for the shotgun, full
#     impulse for explosive splash).
#   • recoil is the world-unit/sec impulse pushed back into the player
#     each time the trigger is pulled. Both are kept very small so a
#     pistol "barely" repels the target and barely kicks the shooter.

## Grip metadata used by the rig:
##  - `two_handed` — when true, the support arm is solved via IK to grab the
##    weapon at `off_hand_anchor` instead of pendulum-swinging at the side.
##  - `off_hand_anchor` — local-space position on the weapon mesh where the
##    support hand grips (forend for long guns, slide for the pistol-isoceles
##    stance, etc.). Always +Z forward, so this is roughly the barrel midpoint.
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
		"knockback": 0.5,
		"recoil": 0.2,
		"two_handed": false,
	},
	"shotgun": {
		"damage": 5.0,
		"range": 15.0,
		"magazine_size": 5,
		"fire_rate": 1.0,
		"reload_time": 2.0,
		"spread": 0.0,
		"bullet_speed": INF,
		"tracer_color": Color(1.0, 0.5, 0.2, 0.8),
		"hit_mode": "pellet",
		"pellet_count": 12,
		"pellet_spread": 4.0,
		"knockback": 0.15,  # per pellet — ~1.8 cumulative on a point-blank target
		"recoil": 1.5,
		"two_handed": true,
		# Pump-action forend grip. Anchor sits at the rear edge of the
		# forend (toward the trigger) so the off-hand stays inside arm
		# reach when both shoulders cradle the stock.
		"off_hand_anchor": Vector3(0.0, -0.02, 0.04),
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
		"knockback": 0.25,
		"recoil": 0.08,  # per shot — accumulates with rapid fire
		"two_handed": true,
		# Front of the body where the off-hand wraps the rail.
		"off_hand_anchor": Vector3(0.0, 0.02, 0.06),
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
		"knockback": 4.0,
		"recoil": 1.0,
		"two_handed": true,
		# Off-hand braces the heavy tube barrel.
		"off_hand_anchor": Vector3(0.0, 0.02, 0.08),
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
		"knockback": 1.5,
		"recoil": 0.0,
		"two_handed": true,
		# Bat-local point higher up the handle (+Y is up the bat) that the
		# right / main hand is IK'd onto, so it stacks ON TOP of the left
		# (bottom) hand for a two-handed baseball grip.
		"off_hand_anchor": Vector3(0.0, 0.18, 0.0),
	},
}

static func get_weapon(weapon_name: String) -> Dictionary:
	return WEAPONS.get(weapon_name, {})

static func shoot_cooldown(weapon_name: String) -> float:
	var w := get_weapon(weapon_name)
	if w.is_empty():
		return 0.25
	return 1.0 / w["fire_rate"]
