# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Posadka** — mobile isometric real-time tactics (Russo-Ukrainian war), Godot 4.7, GDScript, Mobile renderer. The full design and balance reference is `docs/GDD.md`; its §9 maps every script to its responsibility — keep both in sync when systems change.

## Commands

There is no test framework or linter. Verification is done by running the game:

```sh
godot --path .                      # play on desktop (mouse = touch, wheel zoom, WASD pan, Q/E rotate, Space pause, Esc cancel)
godot -e --path .                   # open the editor
godot --headless --path . --fixed-fps 30 --quit-after 6000 -- autostart fast log
                                    # headless full-battle test: player passive, prints event log + result (~2.5 s)
godot --headless --path . --export-debug "Android" build/posadka.apk   # debug APK (arm64, debug keystore)
```

Args after `--` are read via `Game.has_arg()` / `scripts/main.gd`:
- `autostart` (skip deployment), `fast` (4× speed), `log` (print events)
- `kind=assault|defend|meeting|treeline seed=123` — pick mission; same seed = same map
- `shots=/dir` (non-headless) saves screenshots at fixed frames; `demo` runs the scripted showcase in `scripts/dev/demo.gd` (`-- demo shots=/dir`)

Syntax-check a script without launching: `godot --headless --path . --check-only --script <file>`.

## Architecture

Everything is built in code from `scenes/main.tscn` — the only scene file. `scripts/main.gd` assembles the world at runtime: environment/lighting, then `Battle` (from a mission dict), `CameraRig`, `Hud`, `InputController`. There are no other .tscn files, no imported art assets, and no textures: **all models are procedural meshes** generated in `scripts/art/mesh_factory.gd` (soldiers, vehicles, trees, houses, drones), flat-shaded and vertex-coloured.

Key structural facts that span files:

- **`Game` autoload** (`scripts/core/game.gd`): side constants (`Game.UA`/`Game.RU`), pause/speed, and mission selection (`next_kind`/`next_seed`) that survives `reload_current_scene()`. The simulation runs on its own clock via `Game.sim_delta(delta)` — pausing freezes combat, impacts, artillery and drones while camera and UI stay live. Any new time-based gameplay logic must use `sim_delta`, not raw `delta`. Large frames are split into 50 ms sub-steps in `battle.gd`.
- **Missions are data dicts**, not scenes: `scripts/data/mission_treeline.gd` (hand-built) and `scripts/data/mission_gen.gd` (procedural from `kind` + `seed`) produce the map paint, buildings, units and enemy waves that `Battle.setup()` consumes.
- **All balance numbers live in `scripts/data/defs.gd`** (weapon and unit tables). Don't scatter magic combat numbers elsewhere; the GDD documents their intended values.
- **Simulation vs. view split:** `scripts/battle/battle.gd` is the stepped simulation (scheduler, spotting, blasts, victory); `scripts/map/battle_map.gd` is the logical grid (terrain, A*, LOS, cover search); `scripts/map/map_view.gd` and `scripts/fx/*` are presentation. `scripts/combat/combat.gd` resolves shots and delayed impacts.
- **Units:** `scripts/units/unit.gd` is the base (orders, morale, suppression, spotting state); `InfantryUnit` owns `Soldier` instances (19-bone procedural rig, IK gait, stances, steering); `VehicleUnit` is a single entity with turret. Destructible houses (`scripts/map/building.gd`) write their damage back into the grid (breaches become walkable rubble).
- **No cheating vision:** enemy AI and its fire support (`enemy_ai.gd`, `support.gd`) may only act on what the Russian side has actually spotted — same spotting rules as the player.

## Conventions

- Commit messages use Conventional Commits (`feat:`, `fix:`, `chore:`, …). Never mention the name "Posadka" in commit messages or anything else that leaves the repo — it is a working title.
- `*.gd.uid` files are Godot-generated; commit them alongside their scripts, never edit them.
- Input is touch-first (landscape phone); desktop mouse is handled directly, not through touch emulation (`emulate_touch_from_mouse=false`).
- Tone constraints from the GDD apply to content work: fictional places/units, blood shown matter-of-factly but no kill-cams or score popups, no "Z"/"V" symbolism, sober presentation.
