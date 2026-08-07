# Vibe Zombie

A 2.5D cartoon zombie survival game inspired by *No More Room in Hell*, built with **Godot 4.6** and GDScript.

Explore a procedurally generated small town, enter buildings, and survive among wandering zombies — all rendered in a colorful low-poly style with no external assets.

## Gameplay

- **Explore** a procedurally generated 5×5 city grid with roads, sidewalks, and buildings
- **Enter buildings** — press **F** to open/close doors and explore procedural interiors (convenience stores, apartments, offices, warehouses, diners)
- **Sprint** with **Shift** (drains stamina; recovers after a cooldown)
- **Jump** with **Space** to hop over low obstacles
- **Survive** among 25 wandering zombies with visible HP bars
- **Loot** weapons, consumables, and equipment that spawn around the map (mostly inside buildings)
- **Craft** barricades, traps and supplies with **B**

### Game Modes

Pick a mode in the single-player setup screen, or in the multiplayer create-game panel (the host can also switch it in the lobby). The 1v1 Duel is multiplayer-only.

**Campaign** — run a chain of missions across the city, then reach the rescue point to escape.

**1v1 Duel** — two players fight on a compact 20×20 m barricaded arena; grab a weapon and eliminate your opponent, and the first to fall loses. Capped at two players.

**Survival** — the party is given a headquarters building and has to hold it against zombie assaults scheduled on the in-game calendar:

| Day | Event |
|---|---|
| 7 | First assault |
| 12 | Second assault |
| 15 | Final assault — survive it and you win |

A day/hour clock runs in the top-left corner (one in-game day takes about two minutes of real time), and the world lights and sky follow it, so the assaults really do arrive after dark. Under the clock is the HQ integrity bar: zombies that get inside the base's defence ring during an assault tear it down, and if it hits zero the run is lost. Between assaults the base repairs itself, which is your window to scavenge and fortify.

### Crafting

Press **B** to open the Craft screen. Recipes are paid for with **Wood** and **Scrap**, which are scattered around the city, cached at the base, and dropped by zombies you kill during Survival.

| Recipe | Cost | Effect |
|---|---|---|
| Wooden Barricade | 3 Wood | Plank wall that blocks zombies and soaks their claws |
| Reinforced Barricade | 3 Wood, 3 Scrap | Same, with a scrap frame — over twice the durability |
| Spike Trap | 2 Wood, 2 Scrap | Bleeds zombies standing on it; wears out as it works |
| Floodlight | 4 Scrap | Lights the ground around the base through the night |
| Field Medkit | 3 Scrap, 1 Wood | Stowed in your bag — hold it and press E for a full heal |
| Scrap Armor | 6 Scrap | Plate vest, equipped on the spot |

Anything placeable drops you into placement mode: a translucent preview follows the cursor, **left click** builds, the **mouse wheel** rotates, and **right click** or **ESC** cancels. Materials are only spent when you actually place something, and if you can still afford another the preview stays up so you can run a whole wall in one go.

### Items & Equipment

Pickups glow and float on the ground; walk over one to collect it.

| Pickup | Type | Effect |
|---|---|---|
| Apple | Consumable | Restores a small amount of health |
| Medical Kit | Consumable | Fully restores health |
| Energy Drink | Consumable | Temporary move + turn speed boost (10s) |
| Body Armor | Equipment | Adds armor that soaks damage before health |
| Backpack | Equipment | Enlarges the stamina pool (sprint longer) |
| Tactical Shoes | Equipment | Small permanent movement-speed boost |
| Wood | Material | Craft stock for barricades |
| Scrap | Material | Craft stock for reinforcement, traps and lights |

### Controls

| Action | Key |
|---|---|
| Move | W / A / S / D (or arrow keys) |
| Rotate camera | Q / E |
| Sprint | Shift |
| Jump | Space |
| Interact (doors) | F |
| Select quick-bar slot | 1 – 7 |
| Use held item | E |
| Inventory | I |
| Map | M |
| Craft | B |

Weapons and consumables share one **quick-item bar** (mid-bottom of the screen, 7 slots). Press a number key to hold that slot's item; holding a consumable shows a *"Press E to use"* prompt. Picked-up weapons and consumables are stored in your inventory and auto-placed on the bar when a slot is free; equipment is equipped instantly.

### HUD

The on-screen HUD displays Armor, Health, and Stamina bars. Armor (filled by body-armor pickups) absorbs incoming damage before it reaches health. The top-left corner stacks the Survival day/hour clock and HQ integrity bar (Survival only) above the multiplayer **ping (round-trip latency) readout**, which is colour-coded from green (good) to red (high latency).

## Screenshots

*Coming soon*

## Project Structure

```
vibe-zombie/
├── project.godot              # Godot project configuration
├── scenes/
│   ├── Main.tscn              # Root scene (world + player + camera)
│   ├── Player.tscn            # Player character
│   └── World.tscn             # World container (populated at runtime)
└── scripts/
    ├── main.gd                # Game initialization, HUD, building logic
    ├── player.gd              # Movement, sprint, stamina
    ├── camera_controller.gd   # Isometric-style camera with rotation
    ├── world.gd               # Procedural city generation
    ├── enemy.gd               # Zombie AI, wandering, HP bars
    ├── building_interior.gd   # Procedural interior generation
    ├── mission_system.gd      # Campaign mode — mission chain + rescue
    ├── survival_mode.gd       # Survival mode — HQ, wave schedule, integrity
    ├── time_system.gd         # Day / hour game clock
    ├── craft_data.gd          # Craft recipes + structure stats
    ├── craft_menu.gd          # Craft screen (B)
    ├── structure.gd           # Placed barricades / traps / floodlights
    └── hud.gd                 # Armor / Health / Stamina, clock, HQ integrity
```

All visuals are generated procedurally in code — no external 3D models or textures are required.

## Getting Started

### Prerequisites

- [Godot 4.6](https://godotengine.org/download) (or compatible 4.x release)

### Running the Game

1. Clone this repository:
   ```bash
   git clone https://github.com/shaoqian2001/vibe-zombie.git
   ```
2. Open Godot and import the `vibe-zombie` folder (select the folder containing `project.godot`).
3. Press **F5** or click the Play button to run.

### Exporting

Use **Project → Export** in Godot to create builds for Windows, macOS, Linux, or other platforms. No export presets are included yet.

## Current Status

This is an early prototype. Current scope:

- Procedural world generation with enterable buildings
- Player movement with sprint/stamina mechanics
- Zombie enemies that wander (no combat damage yet)
- Basic HUD with armor, health, and stamina

## License

All rights reserved.
