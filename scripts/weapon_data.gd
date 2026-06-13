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
	"fists": {
		# Bare-hand brawling — the default when no weapon is equipped. Short
		# reach, light damage, but fast so a flurry of alternating jabs adds
		# up. Not a pickup; looked up directly by the unarmed punch code.
		"damage": 8.0,
		"range": 1.7,
		"magazine_size": -1,
		"fire_rate": 2.5,
		"reload_time": 0.0,
		"hit_mode": "melee",
		"sweep_angle": 70.0,
		"knockback": 1.0,
		"recoil": 0.0,
		"two_handed": false,
	},
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
		"recoil": 0.6,      # heaviest kick of the guns, but no longer a shove
		"two_handed": true,
		# Support (left) hand well forward of the right grip hand, out on the
		# pump forend — a long gun is held with the hands a fair width apart.
		"off_hand_anchor": Vector3(0.0, 0.0, 0.14),
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
		# Fully automatic: holding the trigger keeps firing at fire_rate.
		"automatic": true,
		"hit_mode": "single",
		"hit_tolerance": 1.0,
		"knockback": 0.25,
		"recoil": 0.08,  # per shot — accumulates with rapid fire
		"two_handed": true,
		# Support (left) hand forward of the right grip hand on the rail.
		"off_hand_anchor": Vector3(0.0, 0.02, 0.13),
	},
	"ak47": {
		# Fully automatic battle rifle — higher damage and range than the SMG
		# with a slower cyclic rate and a heavier per-shot kick. Holding the
		# trigger empties the 30-round mag in a controllable burst.
		"damage": 12.0,
		"range": 45.0,
		"magazine_size": 30,
		"fire_rate": 8.5,
		"reload_time": 2.4,
		"spread": 2.5,
		"bullet_speed": INF,
		"tracer_color": Color(1.0, 0.8, 0.35, 0.8),
		"automatic": true,
		"hit_mode": "single",
		"hit_tolerance": 1.0,
		"knockback": 0.4,
		"recoil": 0.12,  # per shot — accumulates with sustained fire
		"two_handed": true,
		# Support (left) hand well forward of the right grip hand, out on the
		# wooden forend — held with the hands a rifle's width apart.
		"off_hand_anchor": Vector3(0.0, 0.02, 0.15),
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
		"recoil": 0.5,
		"two_handed": true,
		# Support (left) hand forward of the right grip hand.
		"off_hand_anchor": Vector3(0.0, 0.02, 0.12),
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
		# Bat-local point LOWER on the handle (+Y is up the bat) that the
		# left / support hand is IK'd onto, so the right / main hand (which
		# holds the grip on the upper handle) stacks ON TOP of it for a
		# right-handed two-handed baseball grip.
		"off_hand_anchor": Vector3(0.0, 0.09, 0.0),
	},
}

static func get_weapon(weapon_name: String) -> Dictionary:
	return WEAPONS.get(weapon_name, {})

static func shoot_cooldown(weapon_name: String) -> float:
	var w := get_weapon(weapon_name)
	if w.is_empty():
		return 0.25
	return 1.0 / w["fire_rate"]
