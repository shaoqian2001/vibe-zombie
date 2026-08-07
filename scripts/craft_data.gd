class_name CraftData

# Crafting lookup tables — the recipe counterpart to WeaponData / ItemData.
#
# Two halves:
#   • RECIPES   — what the Craft menu (B) lists. Each entry costs materials from
#                 the player's inventory and produces either a placeable
#                 structure ("structure") or an inventory item ("item").
#   • STRUCTURES— stats + procedural build data for anything placeable. Shared by
#                 the real structure node and the translucent placement ghost
#                 (see structure.gd), so what you preview is what you get.
#
# Materials are ordinary ItemData entries tagged category "material" (wood,
# scrap). They stack in the inventory, never take a quick-bar slot, and are
# spent here.

const MATERIAL_NAMES := {
	"wood": "Wood",
	"scrap": "Scrap",
}

## Recipe table. Order is the order shown in the Craft menu (and the 1..N hotkeys).
const RECIPES := {
	"barricade": {
		"display_name": "Wooden Barricade",
		"description": "A plank wall. Blocks zombies and soaks their claws.",
		"cost": {"wood": 3},
		"kind": "structure",
		"structure": "barricade",
	},
	"reinforced_barricade": {
		"display_name": "Reinforced Barricade",
		"description": "Planks over a scrap-metal frame — more than twice the durability.",
		"cost": {"wood": 3, "scrap": 3},
		"kind": "structure",
		"structure": "reinforced_barricade",
	},
	"spike_trap": {
		"display_name": "Spike Trap",
		"description": "Bleeds any zombie standing on it. Wears out as it works.",
		"cost": {"wood": 2, "scrap": 2},
		"kind": "structure",
		"structure": "spike_trap",
	},
	"watch_light": {
		"display_name": "Floodlight",
		"description": "Lights the ground around the base through the night.",
		"cost": {"scrap": 4},
		"kind": "structure",
		"structure": "watch_light",
	},
	"field_medkit": {
		"display_name": "Field Medkit",
		"description": "Stowed in your bag — hold it and press E for a full heal.",
		"cost": {"scrap": 3, "wood": 1},
		"kind": "item",
		"item": "medkit",
	},
	"scrap_armor": {
		"display_name": "Scrap Armor",
		"description": "Plate vest, equipped on the spot. Soaks damage before health.",
		"cost": {"scrap": 6},
		"kind": "item",
		"item": "body_armor",
	},
}

## Placeable structure stats. `size` is the collision / mesh footprint in metres,
## `blocks` decides whether it gets a collider that stops movement.
const STRUCTURES := {
	"barricade": {
		"display_name": "Wooden Barricade",
		"hp": 160.0,
		"size": Vector3(3.0, 1.5, 0.35),
		"color": Color(0.52, 0.36, 0.20),
		"accent": Color(0.34, 0.24, 0.14),
		"blocks": true,
	},
	"reinforced_barricade": {
		"display_name": "Reinforced Barricade",
		"hp": 400.0,
		"size": Vector3(3.0, 1.9, 0.45),
		"color": Color(0.46, 0.33, 0.19),
		"accent": Color(0.42, 0.44, 0.48),
		"blocks": true,
	},
	"spike_trap": {
		"display_name": "Spike Trap",
		"hp": 90.0,
		"size": Vector3(2.2, 0.35, 2.2),
		"color": Color(0.40, 0.30, 0.18),
		"accent": Color(0.62, 0.64, 0.68),
		"blocks": false,
		# Damage per second dealt to every zombie standing on the pad. The trap
		# loses the same amount of durability, so it eventually breaks.
		"damage_per_second": 22.0,
		"damage_radius": 1.6,
		"wear_per_second": 6.0,
	},
	"watch_light": {
		"display_name": "Floodlight",
		"hp": 120.0,
		"size": Vector3(0.5, 2.6, 0.5),
		"color": Color(0.40, 0.42, 0.46),
		"accent": Color(1.0, 0.94, 0.72),
		"blocks": true,
		"light_range": 16.0,
	},
}

static func get_recipe(recipe_id: String) -> Dictionary:
	return RECIPES.get(recipe_id, {})

static func get_structure(structure_id: String) -> Dictionary:
	return STRUCTURES.get(structure_id, {})

## Recipe ids in menu order.
static func recipe_ids() -> Array:
	return RECIPES.keys()

## "3 Wood, 2 Scrap" — the cost line shown in the Craft menu.
static func cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for id in cost:
		parts.append("%d %s" % [int(cost[id]), MATERIAL_NAMES.get(id, id.capitalize())])
	return ", ".join(parts)
