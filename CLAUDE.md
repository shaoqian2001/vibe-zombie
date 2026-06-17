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

**Networking** (`scripts/network_manager.gd`): Autoloaded `NetworkManager` singleton — a high-level wrapper around the **GD-Sync** addon (cloud relay, no port-forwarding). Scenes talk only to `NetworkManager`, never to the `GDSync` node directly. It owns connect/lobby lifecycle, 6-char room codes, the lobby-data peer roster, lobby config (map size / players / difficulty / shared world seed), and a generic host↔client event channel: `broadcast_event(name, payload)` / `send_event_to(peer, name, payload)` → the `net_event` signal. This event channel is the GD-Sync replacement for Godot's `@rpc`. The host is authoritative over enemies and world state; enemy AI runs on the host using `WorkerThreadPool` for parallel processing.

`main.gd` is the single gameplay dispatcher: it subscribes to `NetworkManager.net_event` and routes events to the right player/enemy/pickup node by id. The host broadcasts the full enemy set ("enemy_state", ~20Hz) and pickup set ("pickup_state", ~1Hz); clients reconcile (create unseen, update known, drop absent), which self-heals for late joiners and propagates deaths/pickups without explicit despawn messages. Each player broadcasts its own transform ("player_xform"); damage requests flow client→host ("enemy_damage") or host→owner ("player_damage").

> Setup: enable the GD-Sync plugin and set its API key in **Project → Tools → GD-Sync**. Order the `GDSync` autoload **before** `NetworkManager` (NetworkManager retries once deferred if not). Without the addon, single-player still runs; multiplayer is disabled with a warning.

**Enemy AI** (`scripts/enemy.gd`): Wander/chase/attack state machine, networked health, HP bars. The host runs AI; clients apply host-pushed transform/HP via `net_apply_transform()` / `net_set_hp()`.

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

### Item & Equipment System

`scripts/item_data.gd` (`ItemData`) is the consumable/equipment counterpart to `WeaponData` — a lookup table keyed by item id, each entry tagged `"consumable"` or `"equipment"`. `scripts/item_pickup.gd` (`ItemPickup`) mirrors `weapon_pickup.gd`: a floating, glowing, FOV-cullable `Area3D` with a procedural per-item model that calls `Player.pickup_item()` on contact. Items spawn mostly *inside* building footprints (`main._spawn_items`, weighted by `ItemData.random_id`).

- **Consumables** apply instantly on pickup: apple (small heal), medical kit (full heal), energy drink (timed move + turn speed buff).
- **Equipment** is a persistent passive bonus (no slot management yet): body armor (feeds the armor bar — damage hits armor before health in `Player._apply_damage`), backpack (enlarges the stamina pool via `_stamina_max()`), tactical shoes (raises base move speed).

Networking mirrors weapons exactly: the host broadcasts the full set as `item_state` (~1 Hz) and clients reconcile; `item_despawn` drops a collected pickup. Pickups feed the HUD's toast (`show_toast`) and speed-buff indicator (`set_speed_buff`).

### Camera

Isometric-style camera at 45° yaw / 42° pitch, smoothly following the player. Q/E rotate around the player. Configured in `scripts/camera_controller.gd`.
