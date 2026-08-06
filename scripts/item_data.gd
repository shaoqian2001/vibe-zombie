class_name ItemData

# Item & equipment lookup table — the consumable / equipment counterpart to
# WeaponData. Each key is the item id; the value is a dictionary of stats.
#
# Two categories:
#   • "consumable" — used instantly the moment it is picked up. Apples and the
#     medkit restore health; the energy drink grants a timed move/turn buff.
#   • "equipment"  — applied as a persistent passive bonus on pickup (no slot
#     management yet). Body armor feeds the (previously dormant) armor bar,
#     the backpack enlarges the stamina pool, and tactical shoes raise base
#     movement speed.
#   • "material"   — craft stock (wood, scrap). Stacks in the bag, never takes a
#     quick-bar slot and can't be held or used directly; it is spent by the
#     Craft menu (B). See craft_data.gd.
#
# Effects are read by Player.pickup_item(); see _apply_consumable /
# _apply_equipment there. Everything visual (the floating world model, glow
# colour) is procedural — ItemPickup builds it from primitives keyed off the id.
const ITEMS := {
	"apple": {
		"category": "consumable",
		"display_name": "Apple",
		# Restores a small chunk of missing health — a quick snack, not a heal.
		"heal": 25.0,
		"glow_color": Color(0.90, 0.25, 0.20, 0.40),
		"spawn_weight": 3.0,
	},
	"medkit": {
		"category": "consumable",
		"display_name": "Medical Kit",
		# Full heal. Rarer than apples (lower spawn weight).
		"heal_full": true,
		"glow_color": Color(0.95, 0.95, 0.95, 0.45),
		"spawn_weight": 1.0,
	},
	"energy_drink": {
		"category": "consumable",
		"display_name": "Energy Drink",
		# Temporary mobility buff: faster walk/sprint AND a snappier turn rate
		# for boost_duration seconds. Multipliers stack onto the equipment
		# speed mult while active.
		"speed_boost": 1.40,
		"turn_boost": 1.50,
		"boost_duration": 10.0,
		"glow_color": Color(0.95, 0.80, 0.20, 0.45),
		"spawn_weight": 2.0,
	},
	"body_armor": {
		"category": "equipment",
		"display_name": "Body Armor",
		# Adds armor points (clamped to the player's max). Armor soaks incoming
		# damage before health — this is what finally drives the HUD armor bar.
		"armor": 75.0,
		"glow_color": Color(0.30, 0.55, 0.95, 0.45),
		"spawn_weight": 1.2,
	},
	"backpack": {
		"category": "equipment",
		"display_name": "Backpack",
		# More carrying capacity → more endurance: enlarges the stamina pool so
		# the player can sprint longer. Applies once (doesn't stack).
		"stamina_bonus": 40.0,
		"glow_color": Color(0.60, 0.42, 0.22, 0.45),
		"spawn_weight": 1.2,
	},
	"tactical_shoes": {
		"category": "equipment",
		"display_name": "Tactical Shoes",
		# Small persistent boost to base movement speed. Applies once.
		"speed_mult": 1.15,
		"glow_color": Color(0.40, 0.85, 0.50, 0.45),
		"spawn_weight": 1.4,
	},
	"wood": {
		"category": "material",
		"display_name": "Wood",
		# Salvaged planks — the bulk material behind barricades. Weighted below
		# the common consumables so world loot still leans toward apples and
		# ammo; Survival tops materials up with base caches and zombie drops.
		"glow_color": Color(0.62, 0.44, 0.22, 0.42),
		"spawn_weight": 2.5,
	},
	"scrap": {
		"category": "material",
		"display_name": "Scrap",
		# Bent metal and wiring — reinforcement, spikes and floodlights.
		"glow_color": Color(0.62, 0.66, 0.72, 0.42),
		"spawn_weight": 2.2,
	},
}

static func get_item(item_id: String) -> Dictionary:
	return ITEMS.get(item_id, {})

## All spawnable item ids (stable order).
static func ids() -> Array:
	return ITEMS.keys()

## Weighted random pick used by world generation so common consumables show up
## more often than equipment. Deterministic for a given seeded `rng`.
static func random_id(rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for id in ITEMS:
		total += ITEMS[id].get("spawn_weight", 1.0)
	var r := rng.randf() * total
	for id in ITEMS:
		r -= ITEMS[id].get("spawn_weight", 1.0)
		if r <= 0.0:
			return id
	return ITEMS.keys()[0]
