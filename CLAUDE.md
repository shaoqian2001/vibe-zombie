# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Vibe Zombie is a 2.5D cartoon zombie survival game built with **Godot 4.6** and **GDScript**. It features procedurally generated cities, multiplayer via LAN, and a mission system — all visuals are generated in code with no external art assets.

## Running the Game

This is a Godot Engine project with no build step. To run:
- Open Godot 4.6+, import the project folder, then press **F5** or click Play
- The entry scene is `TitleMenu.tscn` (configured in `project.godot`)
- Enable `DEV_MODE = true` in `scripts/main.gd` for faster playtesting (skips menus, spawns near buildings)

There is no linting tool, test framework, or package manager — Godot is self-contained.

## Architecture

### Core Systems

**Game Loop** (`scripts/main.gd`): Orchestrates building enter/exit transitions, mission spawning, enemy management, and HUD setup. This is the central coordinator for in-session gameplay.

**Procedural World** (`scripts/world.gd`): Generates an NxN city grid at runtime — roads, city blocks, and buildings placed procedurally. No tilemaps or external level files exist; the entire world is built from `MeshInstance3D` + `BoxMesh`/`CylinderMesh` primitives.

**Building Interiors** (`scripts/building_interior.gd`): Each building has a procedurally generated interior. Five building types with distinct furniture arrangements, all created from primitive meshes at runtime.

**Networking** (`scripts/network_manager.gd`): Autoloaded singleton. The host (peer 1) has authority over enemies and game state. LAN discovery uses UDP broadcast. Players sync at ~20Hz via RPCs. Enemy AI runs on the host using `WorkerThreadPool` for parallel processing.

**Enemy AI** (`scripts/enemy.gd`): Wander/chase/attack state machine, networked health, HP bars. The host runs AI; clients receive position updates.

### Key Patterns

- **All visuals are procedural**: No sprites, textures, or external 3D models. Everything is generated with Godot primitives and `SurfaceTool`.
- **Group-based system queries**: Systems find their targets via Godot groups (e.g., `"enemy"`, `"fov_cullable"`) rather than direct node references.
- **Autoload for multiplayer state**: `NetworkManager` persists across scene changes and is the single source of truth for peer/lobby state.
- **FOV culling**: `scripts/fov_culler.gd` hides enemies outside the player's vision cone; `shaders/fov.gdshader` renders the overlay effect.
- **Input actions**: All input is defined in `project.godot` under `[input]`, not hardcoded in scripts.

### Scene → Script Mapping

| Scene | Script | Role |
|---|---|---|
| `TitleMenu.tscn` | `title_menu.gd` | Entry point, menu navigation |
| `Main.tscn` | `main.gd` | Core game loop |
| `World.tscn` | `world.gd` | Procedural city generation |
| `Player.tscn` | `player.gd` | Movement, combat, stamina, inventory |
| *(no scene)* | `network_manager.gd` | Autoload — multiplayer authority |

### Weapon System

`scripts/weapon_data.gd` defines all weapon stats (pistol, shotgun, SMG, grenade launcher, bat). `scripts/weapon_pickup.gd` handles world spawning and pickup. Player equips weapons via number keys; logic lives in `player.gd`.

### Camera

Isometric-style camera at 45° yaw / 42° pitch, smoothly following the player. Q/E rotate around the player. Configured in `scripts/camera_controller.gd`.
