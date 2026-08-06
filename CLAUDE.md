# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Vibe Zombie is a 2.5D cartoon zombie survival game built with **Godot 4.6** and **GDScript**. It features procedurally generated cities, multiplayer via LAN, two game modes (Campaign missions and Survival wave-defence), and a crafting system — all visuals are generated in code with no external art assets.

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

**Enemy AI** (`scripts/enemy.gd`): Wander/chase/attack state machine, networked health, HP bars. The host runs AI; clients apply host-pushed transform/HP via `net_apply_transform()` / `net_set_hp()`. Two hooks feed the modes below: `home_target` makes a zombie march on a fixed point (Survival's HQ) when no player is in detect range, and `_try_attack_structure()` makes one claw down any crafted barricade it's pressed against.

### Game Modes

`NetworkManager.game_mode` (`GameMode.CAMPAIGN` / `SURVIVAL`) is lobby config like map size or difficulty — published in lobby data, carried in `cfg_sync` / `game_started`, and picked in the multiplayer create panel, the lobby (host), and the single-player setup screen.

`main.gd` holds the active driver in `_mission_system`. Both modes expose the same surface — `setup()`, `process(delta)`, `get_objective_text()`, `get_map_markers()`, `spawn_horde_at()`, `notify_enemy_killed(pos)`, `zombie_density_multiplier` — so the objective label, map view, and debug panel drive either one through identical calls.

**Campaign** (`scripts/mission_system.gd`): the original mission chain. Host-only; clients read a host-pushed `mission_sync` (objective text + marker positions).

**Survival** (`scripts/survival_mode.gd`): wave defence. Runs on **every** peer, not just the host — the HQ is chosen deterministically from the shared world seed (`SurvivalMode.pick_hq_building()` ranks `world.buildings` by distance to the map centre, then picks the largest of the closest few), so each peer builds the same beacon, defence ring and map marker locally with zero networking. Only the numbers sync, in a single `survival_sync` packet (clock, wave index, wave enemies left, HQ integrity) at 2 Hz.

- Players spawn in a ring around the HQ instead of the map rim.
- Assaults land at 19:00 on **day 7**, **day 12** and **day 15** (final). The scheduler is calendar-driven: a wave launches on its date whether or not the previous one was cleared. Clear every launched wave once the last is out and the run is won.
- The HQ has integrity (`HQ_MAX_HP`), drained only *during* an assault by zombies inside `HQ_RADIUS`, and repaired between them. Zero = loss. Outcomes broadcast as `survival_outcome`.
- Kills drop craft material; a cache spawns at the base on day 1 and restocks daily.

**Game clock** (`scripts/time_system.gd`): a single monotonic `total_hours` float, so it replicates as one number and can't drift out of order. Day 1 starts at 08:00; `REAL_SECONDS_PER_DAY` (120s) sets the pace. Every peer ticks it locally for a smooth display; `net_set_hours()` eases in the host's value. The HUD shows it top-left via `set_clock()`, and it drives `world.set_time_of_day()` — sun elevation/colour, ambient, fog and sky all follow the hour (Campaign never calls this and keeps its fixed midday lighting).

### Crafting (B) — available in both modes

`scripts/craft_data.gd` (`CraftData`) is the recipe table plus stats for anything placeable, in the same shape as `WeaponData` / `ItemData`. Recipes cost **materials** — `wood` and `scrap`, ordinary `ItemData` entries tagged `category: "material"`. Materials stack in `Player._inventory`, never claim a quick-bar slot, and can't be held or used; they're spent through `Player.has_materials()` / `consume_materials()`.

Two recipe kinds:
- `"item"` — crafted instantly into the bag via `Player.grant_item()` → the normal `pickup_item()` path, so a crafted medkit stows and crafted armor equips.
- `"structure"` — hands off to **placement mode** in `main.gd`: a translucent ghost (built by `Structure.build_visual()`, the same static helper the real node uses, so preview == result) follows the cursor within `PLACE_MAX_DIST`, tinted green/red by `_placement_is_valid()`. Left click commits, right click / ESC cancels, wheel rotates. Materials are spent only on commit, and an affordable recipe chain-builds.

`scripts/structure.gd` is the placed node: HP, an optional blocking collider, and a spike-trap tick that damages zombies standing on it while wearing itself down. Replication mirrors pickups — the host owns ids and broadcasts the full set as `structure_state` (2 Hz), clients reconcile; clients request placement (`structure_place`) and damage (`structure_damage`) from the host.

While the Craft menu is open or a ghost is up, `main.gd` sets `Player.input_locked` so the same mouse button doesn't also fire the weapon.

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
| *(no scene)* | `survival_mode.gd` | Survival driver — HQ, waves, integrity |
| *(no scene)* | `time_system.gd` | Day / hour clock |
| *(no scene)* | `craft_menu.gd` | Craft screen (B) |
| *(no scene)* | `structure.gd` | Placed barricades / traps / floodlights |

### Weapon System

`scripts/weapon_data.gd` defines all weapon stats (pistol, shotgun, SMG, grenade launcher, bat). `scripts/weapon_pickup.gd` handles world spawning and pickup. Player equips weapons via number keys; logic lives in `player.gd`.

### Item & Equipment System

`scripts/item_data.gd` (`ItemData`) is the consumable/equipment counterpart to `WeaponData` — a lookup table keyed by item id, each entry tagged `"consumable"` or `"equipment"`. `scripts/item_pickup.gd` (`ItemPickup`) mirrors `weapon_pickup.gd`: a floating, glowing, FOV-cullable `Area3D` with a procedural per-item model that calls `Player.pickup_item()` on contact. Items spawn mostly *inside* building footprints (`main._spawn_items`, weighted by `ItemData.random_id`).

- **Consumables** are *stowed* on pickup (into `_inventory` + a free quick-bar slot), then **held and used** later: apple (small heal), medical kit (full heal), energy drink (timed move + turn speed buff).
- **Equipment** equips instantly on pickup (never stored) as a persistent passive bonus: body armor (feeds the armor bar — damage hits armor before health in `Player._apply_damage`), backpack (enlarges the stamina pool via `_stamina_max()`), tactical shoes (raises base move speed).

Equipment is also **worn on the character model**: `player.gd` builds procedural worn meshes (vest on `_torso_top`, backpack behind it, boots on each foot) once in `_build_rig` (hidden), and `_update_equipment_visuals()` shows them on pickup. Worn state is networked as a bitfield in the `player_xform` payload (`_equip_bits` → `_set_remote_equipment`) so remote players see each other's gear.

### Quick Item Bar (unified hotbar)

Weapons AND consumables are unified "items" in a single 7-slot hotbar, selected with number keys **1–7** (`weapon_1`..`weapon_7`). `player.gd` owns the model: `_inventory` (id → count; weapons are count 1, consumables stack) and `_quick` (7 slot ids). Pickups route through `pickup_weapon` / `pickup_item` → `_assign_quick_slot`. Selecting a slot (`_select_quick_slot`) either **draws a weapon** (`_hold_weapon`, the existing armed/aim/fire path) or **holds a consumable** (`_hold_consumable`, shows an in-hand model + a "Press E to use" prompt). **E** (`use_item`) uses the held consumable (`_use_held_item`); since E also rotates the camera, `camera_controller.gd` yields the key when `Player.wants_use_key()` is true. The bar + prompt render at mid-bottom via `HUD.set_quick_bar` / `set_use_prompt` (pushed every frame from `_sync_hud`); the held consumable is networked via the `held` field in `player_xform`. The inventory screen (`I`) lists the real stored items via `Player.get_inventory_items()`.

Item pickups: the host broadcasts the full set as `item_state` (~1 Hz) and clients reconcile; `item_despawn` drops a collected pickup. Pickups feed the HUD's toast (`show_toast`) and speed-buff indicator (`set_speed_buff`).

### Input Actions

All input is defined in `project.godot` under `[input]`. Recent additions: `craft` (**B**) opens the Craft screen. Placement mode reads raw mouse buttons in `main._unhandled_input` rather than adding actions, so left/right click and the wheel keep their obvious meanings.

### Camera

Isometric-style camera at 45° yaw / 42° pitch, smoothly following the player. Q/E rotate around the player. Configured in `scripts/camera_controller.gd`.
