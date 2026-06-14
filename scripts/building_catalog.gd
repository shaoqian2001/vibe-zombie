extends RefCounted

## Data-driven catalog of building types.
## Every entry pins a realistic footprint range, a height range, a colour palette,
## and a set of visual feature flags consumed by `world.gd` when it generates
## the exterior. The list is intentionally flat so adding a new building type
## means appending one row here plus (optionally) an interior generator in
## `building_interior.gd`.

const BuildingInterior = preload("res://scripts/building_interior.gd")

# Block categories — drive both which buildings get placed and the visual
# style of the block (paving, fences, layout pattern).
enum BlockCategory {
	RESIDENTIAL,
	COMMERCIAL,
	INDUSTRIAL,
	CIVIC,
	MIXED,
	PARK,
	PARKING_LOT,
	PLAZA,
}

const CATEGORY_NAMES := {
	BlockCategory.RESIDENTIAL: "Residential",
	BlockCategory.COMMERCIAL:  "Commercial",
	BlockCategory.INDUSTRIAL:  "Industrial",
	BlockCategory.CIVIC:       "Civic",
	BlockCategory.MIXED:       "Mixed",
	BlockCategory.PARK:        "Park",
	BlockCategory.PARKING_LOT: "Parking Lot",
	BlockCategory.PLAZA:       "Plaza",
}

# Per-building parameter table. Sizes are in metres.
#   w / d  : footprint (width × depth)
#   h      : building height
#   layout : how the building tends to sit on the block:
#              "small"  -> packs along block perimeter
#              "medium" -> stands in mid-sized rows
#              "large"  -> takes most of a block, centred
#   palette: ARGB colour list to choose from
#   accent : optional accent colour for trim / signage
#   feature: visual feature flags (sign, chimney, antenna, columns, cross,
#            tower, gate, billboard)
const BUILDINGS := {
	BuildingInterior.BuildingType.CONVENIENCE_STORE: {
		"name": "Convenience Store",
		"w_min": 10.0, "w_max": 14.0,
		"d_min": 8.0,  "d_max": 12.0,
		"h_min": 4.0,  "h_max": 5.0,
		"layout": "small",
		"palette": [Color(0.86, 0.78, 0.55), Color(0.78, 0.68, 0.55)],
		"accent":  Color(0.85, 0.25, 0.20),
		"features": ["sign", "awning"],
	},
	BuildingInterior.BuildingType.DINER: {
		"name": "Diner",
		"w_min": 10.0, "w_max": 16.0,
		"d_min": 8.0,  "d_max": 12.0,
		"h_min": 4.0,  "h_max": 5.0,
		"layout": "small",
		"palette": [Color(0.92, 0.62, 0.25), Color(0.86, 0.42, 0.18)],
		"accent":  Color(0.95, 0.85, 0.30),
		"features": ["sign", "awning", "neon"],
	},
	BuildingInterior.BuildingType.SHOP: {
		"name": "Shop",
		"w_min": 12.0, "w_max": 22.0,
		"d_min": 8.0,  "d_max": 12.0,
		"h_min": 4.5,  "h_max": 6.0,
		"layout": "small",
		"palette": [Color(0.55, 0.70, 0.78), Color(0.75, 0.62, 0.45), Color(0.62, 0.58, 0.70)],
		"accent":  Color(0.20, 0.45, 0.65),
		"features": ["sign", "awning", "billboard"],
	},
	BuildingInterior.BuildingType.APARTMENT: {
		"name": "Apartment",
		"w_min": 16.0, "w_max": 22.0,
		"d_min": 16.0, "d_max": 40.0,
		"h_min": 14.0, "h_max": 26.0,
		"layout": "medium",
		"palette": [Color(0.78, 0.62, 0.50), Color(0.70, 0.65, 0.58), Color(0.62, 0.55, 0.48)],
		"accent":  Color(0.45, 0.32, 0.22),
		"features": ["balcony", "antenna"],
	},
	BuildingInterior.BuildingType.OFFICE: {
		"name": "Office",
		"w_min": 18.0, "w_max": 30.0,
		"d_min": 18.0, "d_max": 30.0,
		"h_min": 18.0, "h_max": 38.0,
		"layout": "medium",
		"palette": [Color(0.55, 0.62, 0.72), Color(0.48, 0.55, 0.65), Color(0.62, 0.65, 0.70)],
		"accent":  Color(0.25, 0.30, 0.40),
		"features": ["glass", "antenna"],
	},
	BuildingInterior.BuildingType.WAREHOUSE: {
		"name": "Warehouse",
		"w_min": 28.0, "w_max": 45.0,
		"d_min": 28.0, "d_max": 50.0,
		"h_min": 7.0,  "h_max": 10.0,
		"layout": "large",
		"palette": [Color(0.58, 0.58, 0.56), Color(0.52, 0.50, 0.46), Color(0.62, 0.55, 0.40)],
		"accent":  Color(0.30, 0.32, 0.35),
		"features": ["gate", "sign"],
	},
	BuildingInterior.BuildingType.FACTORY: {
		"name": "Factory",
		"w_min": 32.0, "w_max": 55.0,
		"d_min": 30.0, "d_max": 55.0,
		"h_min": 9.0,  "h_max": 14.0,
		"layout": "large",
		"palette": [Color(0.48, 0.46, 0.42), Color(0.55, 0.50, 0.42)],
		"accent":  Color(0.30, 0.28, 0.26),
		"features": ["chimney", "gate", "sign"],
	},
	BuildingInterior.BuildingType.BANK: {
		"name": "Bank",
		"w_min": 20.0, "w_max": 30.0,
		"d_min": 18.0, "d_max": 26.0,
		"h_min": 9.0,  "h_max": 14.0,
		"layout": "medium",
		"palette": [Color(0.85, 0.82, 0.74), Color(0.78, 0.74, 0.66)],
		"accent":  Color(0.30, 0.45, 0.30),
		"features": ["columns", "sign"],
	},
	BuildingInterior.BuildingType.POLICE_STATION: {
		"name": "Police Station",
		"w_min": 18.0, "w_max": 28.0,
		"d_min": 16.0, "d_max": 24.0,
		"h_min": 8.0,  "h_max": 12.0,
		"layout": "medium",
		"palette": [Color(0.40, 0.45, 0.55), Color(0.48, 0.52, 0.58)],
		"accent":  Color(0.10, 0.25, 0.55),
		"features": ["sign", "antenna"],
	},
	BuildingInterior.BuildingType.HOSPITAL: {
		"name": "Hospital",
		"w_min": 30.0, "w_max": 50.0,
		"d_min": 25.0, "d_max": 40.0,
		"h_min": 16.0, "h_max": 28.0,
		"layout": "large",
		"palette": [Color(0.92, 0.92, 0.90), Color(0.86, 0.88, 0.90)],
		"accent":  Color(0.85, 0.15, 0.15),
		"features": ["cross", "antenna", "sign"],
	},
	BuildingInterior.BuildingType.SCHOOL: {
		"name": "School",
		"w_min": 30.0, "w_max": 55.0,
		"d_min": 18.0, "d_max": 28.0,
		"h_min": 8.0,  "h_max": 12.0,
		"layout": "large",
		"palette": [Color(0.72, 0.42, 0.30), Color(0.80, 0.55, 0.40)],
		"accent":  Color(0.40, 0.20, 0.12),
		"features": ["sign", "tower"],
	},
}

# Which building types fit into which block category, with relative weights.
# A higher weight ⇒ more frequent.
const CATEGORY_TYPES := {
	BlockCategory.RESIDENTIAL: [
		{ "type": BuildingInterior.BuildingType.APARTMENT,         "weight": 4 },
		{ "type": BuildingInterior.BuildingType.SHOP,              "weight": 1 },
		{ "type": BuildingInterior.BuildingType.CONVENIENCE_STORE, "weight": 1 },
	],
	BlockCategory.COMMERCIAL: [
		{ "type": BuildingInterior.BuildingType.SHOP,              "weight": 3 },
		{ "type": BuildingInterior.BuildingType.CONVENIENCE_STORE, "weight": 2 },
		{ "type": BuildingInterior.BuildingType.DINER,             "weight": 2 },
		{ "type": BuildingInterior.BuildingType.OFFICE,            "weight": 2 },
		{ "type": BuildingInterior.BuildingType.BANK,              "weight": 1 },
	],
	BlockCategory.INDUSTRIAL: [
		{ "type": BuildingInterior.BuildingType.WAREHOUSE, "weight": 3 },
		{ "type": BuildingInterior.BuildingType.FACTORY,   "weight": 2 },
	],
	BlockCategory.CIVIC: [
		{ "type": BuildingInterior.BuildingType.HOSPITAL,        "weight": 1 },
		{ "type": BuildingInterior.BuildingType.SCHOOL,          "weight": 1 },
		{ "type": BuildingInterior.BuildingType.POLICE_STATION,  "weight": 1 },
		{ "type": BuildingInterior.BuildingType.BANK,            "weight": 1 },
	],
	BlockCategory.MIXED: [
		{ "type": BuildingInterior.BuildingType.APARTMENT,         "weight": 2 },
		{ "type": BuildingInterior.BuildingType.SHOP,              "weight": 2 },
		{ "type": BuildingInterior.BuildingType.OFFICE,            "weight": 2 },
		{ "type": BuildingInterior.BuildingType.DINER,             "weight": 1 },
		{ "type": BuildingInterior.BuildingType.CONVENIENCE_STORE, "weight": 1 },
	],
}

# How blocks are sprinkled across the world. Each map style picks a
# different category mix; pick one with `pick_block_category(rng, style)`.
# Park / parking-lot / plaza tiles break up the cityscape and double as
# visual landmarks.
enum MapStyle {
	DOWNTOWN,
	METROPOLIS,
	INDUSTRIAL,
	SUBURBAN,
	CIVIC_CENTER,
}

const STYLE_NAMES := {
	MapStyle.DOWNTOWN:     "Downtown",
	MapStyle.METROPOLIS:   "Metropolis",
	MapStyle.INDUSTRIAL:   "Industrial Zone",
	MapStyle.SUBURBAN:     "Suburban",
	MapStyle.CIVIC_CENTER: "Civic Center",
}

const STYLE_DESCRIPTIONS := {
	MapStyle.DOWNTOWN:     "Balanced city — shops, offices, apartments and a few parks.",
	MapStyle.METROPOLIS:   "Dense urban skyline. Tall offices and apartments dominate.",
	MapStyle.INDUSTRIAL:   "Sprawling warehouses, factories and parking lots.",
	MapStyle.SUBURBAN:     "Quiet neighborhoods with plenty of parks and small shops.",
	MapStyle.CIVIC_CENTER: "Hospitals, schools, banks and police stations cluster the streets.",
}

# Per-style category weights. Higher weight ⇒ more of that block category.
# Use 0 to suppress a category entirely for a given style.
const STYLE_CATEGORY_WEIGHTS := {
	MapStyle.DOWNTOWN: {
		BlockCategory.RESIDENTIAL: 5,
		BlockCategory.COMMERCIAL:  4,
		BlockCategory.MIXED:       3,
		BlockCategory.INDUSTRIAL:  2,
		BlockCategory.CIVIC:       2,
		BlockCategory.PARK:        2,
		BlockCategory.PARKING_LOT: 1,
		BlockCategory.PLAZA:       1,
	},
	MapStyle.METROPOLIS: {
		BlockCategory.RESIDENTIAL: 3,
		BlockCategory.COMMERCIAL:  6,
		BlockCategory.MIXED:       4,
		BlockCategory.INDUSTRIAL:  0,
		BlockCategory.CIVIC:       2,
		BlockCategory.PARK:        1,
		BlockCategory.PARKING_LOT: 2,
		BlockCategory.PLAZA:       2,
	},
	MapStyle.INDUSTRIAL: {
		BlockCategory.RESIDENTIAL: 1,
		BlockCategory.COMMERCIAL:  1,
		BlockCategory.MIXED:       1,
		BlockCategory.INDUSTRIAL:  8,
		BlockCategory.CIVIC:       0,
		BlockCategory.PARK:        1,
		BlockCategory.PARKING_LOT: 4,
		BlockCategory.PLAZA:       0,
	},
	MapStyle.SUBURBAN: {
		BlockCategory.RESIDENTIAL: 7,
		BlockCategory.COMMERCIAL:  2,
		BlockCategory.MIXED:       1,
		BlockCategory.INDUSTRIAL:  0,
		BlockCategory.CIVIC:       1,
		BlockCategory.PARK:        6,
		BlockCategory.PARKING_LOT: 1,
		BlockCategory.PLAZA:       2,
	},
	MapStyle.CIVIC_CENTER: {
		BlockCategory.RESIDENTIAL: 2,
		BlockCategory.COMMERCIAL:  2,
		BlockCategory.MIXED:       3,
		BlockCategory.INDUSTRIAL:  0,
		BlockCategory.CIVIC:       6,
		BlockCategory.PARK:        2,
		BlockCategory.PARKING_LOT: 2,
		BlockCategory.PLAZA:       2,
	},
}

# Multiplies catalog building heights when generating buildings for a
# given style — Metropolis gets towering skyscrapers, Suburban shrinks
# down to cottage-scale rooflines.
const STYLE_HEIGHT_SCALE := {
	MapStyle.DOWNTOWN:     1.0,
	MapStyle.METROPOLIS:   1.7,
	MapStyle.INDUSTRIAL:   0.9,
	MapStyle.SUBURBAN:     0.65,
	MapStyle.CIVIC_CENTER: 1.05,
}

static func pick_block_category(rng: RandomNumberGenerator, style: int = MapStyle.DOWNTOWN) -> int:
	var weights: Dictionary = STYLE_CATEGORY_WEIGHTS.get(style, STYLE_CATEGORY_WEIGHTS[MapStyle.DOWNTOWN])
	var total := 0
	for w in weights.values():
		total += w
	if total <= 0:
		return BlockCategory.MIXED
	var roll := rng.randi() % total
	var acc := 0
	for cat in weights.keys():
		acc += weights[cat]
		if roll < acc:
			return cat
	return BlockCategory.MIXED

static func style_height_scale(style: int) -> float:
	return STYLE_HEIGHT_SCALE.get(style, 1.0)

static func style_name(style: int) -> String:
	return STYLE_NAMES.get(style, "Custom")

static func style_description(style: int) -> String:
	return STYLE_DESCRIPTIONS.get(style, "")

static func pick_building_for_category(rng: RandomNumberGenerator, category: int) -> int:
	var pool: Array = CATEGORY_TYPES.get(category, CATEGORY_TYPES[BlockCategory.MIXED])
	var total := 0
	for entry in pool:
		total += entry.weight
	var roll := rng.randi() % total
	var acc := 0
	for entry in pool:
		acc += entry.weight
		if roll < acc:
			return entry.type
	return pool[0].type

static func info_for(type_id: int) -> Dictionary:
	return BUILDINGS.get(type_id, BUILDINGS[BuildingInterior.BuildingType.SHOP])
