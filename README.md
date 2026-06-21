# Vibe Zombie

A 2.5D cartoon zombie survival game inspired by *No More Room in Hell*, built with **Godot 4.6** and GDScript.

Explore a procedurally generated small town, enter buildings, and survive among wandering zombies — all rendered in a colorful low-poly style with no external assets.

## Gameplay

- **Explore** a procedurally generated 5×5 city grid with roads, sidewalks, and buildings
- **Enter buildings** — press **F** to open/close doors and explore procedural interiors (convenience stores, apartments, offices, warehouses, diners)
- **Sprint** with **Shift** (drains stamina; recovers after a cooldown)
- **Survive** among 25 wandering zombies with visible HP bars
- **Loot** weapons, consumables, and equipment that spawn around the map (mostly inside buildings)

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

### Controls

| Action | Key |
|---|---|
| Move | W / A / S / D (or arrow keys) |
| Rotate camera | Q / E |
| Sprint | Shift |
| Interact (doors) | F |
| Select quick-bar slot | 1 – 7 |
| Use held item | E |
| Inventory | I |

Weapons and consumables share one **quick-item bar** (mid-bottom of the screen, 7 slots). Press a number key to hold that slot's item; holding a consumable shows a *"Press E to use"* prompt. Picked-up weapons and consumables are stored in your inventory and auto-placed on the bar when a slot is free; equipment is equipped instantly.

### HUD

The on-screen HUD displays Armor, Health, and Stamina bars. Armor (filled by body-armor pickups) absorbs incoming damage before it reaches health.

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
    └── hud.gd                 # Armor / Health / Stamina display
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
