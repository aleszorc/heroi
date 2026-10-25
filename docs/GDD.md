# POSADKA — Game Design Document

Working title: **Posadka** (Ukrainian *посадка*, the windbreak treelines that cross the steppe and became the most fought-over terrain of the war).

Mobile real-time tactics with pause, in an isometric 3D view. You command a reinforced Ukrainian platoon in short, tense battles. It draws on *Close Combat* (soldier psychology, suppression, morale) and *Defilade* (small maps, readable low-poly look, mobile-first controls).

---

## 1. Vision and pillars

1. **You are always watched.** Drones turn concealment into the main resource. A unit that moves, fires or stands in the open gets spotted, then hit by FPVs or artillery. Trees, trenches and ruins mean survival.
2. **Soldiers are people, not hit points.** Fire suppresses before it kills. Squads get pinned, cower and break. Your orders compete with fear.
3. **Short battles, real decisions.** Each battle takes 8–10 minutes (hard cap at 10), so it fits a commute. A battle has a few big choices (where to defend, when to spend the mortar, what to hit with the one FPV left), not hundreds of clicks.
4. **Readable at a glance on a phone.** Team discs, clear state colours, chunky low-poly silhouettes, an always-visible roster.

### Tone and sensitivity
- The war is real and ongoing. The game is sober, not gleeful: no gore, no kill-cams, no score popups for kills. Bodies stay on the field.
- Places, units and people are **fictional**. Equipment is real and depicted accurately and generically. The game does not recreate named real battles or real brigades.
- The player commands Ukrainian forces. The opponent is presented as an army, not as caricatures. The game never uses "Z" or "V" symbolism on enemy assets.
- Monetisation stays clean (premium or premium plus campaign DLC). No loot boxes or pay-to-win. Consider donating a share of revenue to humanitarian demining or medical charities and say so in the store listing.

---

## 2. Core loop

```
Campaign map ─► Briefing & deployment ─► Battle (real-time, pausable) ─► Debrief
     ▲                                                                     │
     └──── replace losses, spend requisition, promote veterans ◄───────────┘
```

- **Battle loop (seconds):** spot, then decide (hold, move, fire, smoke, support), then watch suppression and morale play out, then react.
- **Campaign loop (minutes):** an operation is a chain of 5–8 battles on linked maps. Casualties, veterancy and ammunition carry over. Holding or losing a map changes the next battle's start line.

---

## 3. The battle

### 3.1 Map
- Grid model of 120×120 cells, 2 m each (240 m square), shown as a diorama board.
- Terrain types and their effects:

| Terrain | Cover | Concealment | Infantry cost | Vehicle cost | LOS kept / cell |
|---|---|---|---|---|---|
| Open | 0 | .10 | 1.0 | 1.0 | 1.0 |
| Field | .05 | .20 | 1.2 | 1.3 | 1.0 |
| Road | 0 | 0 | 0.9 | 0.6 | 1.0 |
| Trees (posadka) | .45 | .70 | 1.5 | 4.0 | .72 |
| Building | .70 | .80 | 1.6 | impassable | blocks |
| Trench | .75 | .65 | 1.1 | 3.0 | 1.0 |
| Gully | .45 | .50 | 1.3 | 2.5 | 1.0 |
| Crater | .35 | .30 | 1.4 | 2.0 | 1.0 |
| Rubble | .50 | .50 | 1.6 | 3.0 | .85 |
| Wreck | .60 | .50 | 1.3 | impassable | .5 |

- Big explosions create new craters at runtime, so cover changes as the battle goes on.
- Smoke grenades cut visibility to 30% per cell crossed for about 35 s.

### 3.2 Units
Infantry units are squads and teams of individual soldiers, each with one weapon. Vehicles are single entities with a turret and several weapons.

**Ukraine (player)**
| Unit | Men / crew | Weapons | Role |
|---|---|---|---|
| Rifle Squad | 5 | AK-74 ×4, RPG-7 | Holds ground; RPG for light armour |
| MG Team | 3 | PKM, AK ×2 | Suppression |
| ATGM Team (Stugna-P) | 2 | Stugna-P, AK | Tank killer at 450 m, must be stationary |
| Sniper Team | 2 | Sniper rifle, AK | Long-range picks, very hard to spot |
| Drone Team | 2 | AK ×2 | Enables Recon and FPV abilities while alive |
| M2A2 Bradley | 3 | 25 mm, TOW-2, coax | Mobile firepower; FPVs hunt it |
| Off-map 82 mm mortar | — | 2 missions × 6 rounds | Breaks up assaults |

**Russia (AI)**
| Unit | Notes |
|---|---|
| Assault Group (6) | AKs, PKM, RPG. Lower morale; attacks in waves |
| BMP-2 | 30 mm autocannon; thin armour |
| MT-LB | Light tractor-carrier, MG only |
| T-72B3 | Heavy front armour (600), weak sides (110); cope cage defeats 40% of drone hits |
| Off-map | Opening barrage, counter-battery-style strikes on spotted positions, FPV drones, "Orlan" recon passes |

### 3.3 Orders (touch)
| Order | Effect |
|---|---|
| **Move** (tap ground) | Walk at 2.2 m/s and fire at half accuracy |
| **Fast** (double-tap) | Run at 4 m/s, no firing, easy to spot |
| **Sneak** | Crawl at 1 m/s, +10% concealment, only fires at under 40 m |
| **Fire** (tap enemy) | Halt and engage that target. Tap ground for suppressive area fire on unseen enemies |
| **Defend** | Every unit. After choosing it, drag or tap on the ring around the unit to set its facing; the fire arc (±45°) is drawn. Men take cover against that direction and prefer targets inside the arc; vehicles pivot their front armour to it |
| **Smoke** | Throw a smoke screen within 40 m (limited) |
| **Ambush** | Like Defend, but hidden (+15% concealment) and holding fire until an enemy is within 60 m (150 m for vehicles) or the unit is fired on; then it springs and fights as Defend |
| **Stop** | Cancel everything |

Vehicles reverse automatically on short moves to the rear, keeping their front armour towards the enemy. TOW and Stugna fire only when stationary.

### 3.4 Spotting
- Each unit is re-checked several times a second against every enemy observer within 260 m.
- Chance per 0.5 s = visibility × (1 − concealment) × range falloff, doubled if the target was seen in the last 6 s.
- Concealment rises when stationary (+.12) and falls when running (×0.5) or firing (×0.35 for 3 s). Vehicles are ×0.5, and ×0.4 again while moving.
- Anything within 10–45 m (depending on concealment) with line of sight is spotted automatically.
- Lost contacts show a **?** at their last known position for 45 s.
- Recon drones reveal everything in a 55 m radius with high probability, except units in buildings.

### 3.5 Shooting
`hit = acc × state × range_falloff × (0.4 + 0.6·visibility) × (1 − cover)`, with ×0.8 if the target is halted and ×1.15 if it is running.
Misses scatter and still suppress whoever is nearby. Infantry hits are 55% killed, 45% wounded (both out of the fight).
Armour: penetration × (0.85–1.15) against front, side or top armour, chosen by impact angle (front within ±50°). A penetration rolls for destroyed (55%), immobilized, weapons out, or crew casualty.

### 3.6 Suppression and morale
- Every shot near a unit adds suppression, reduced by up to 35% by cover. It decays 7–21 per second after 1.5 s without incoming fire; faster in cover.
- States: **Ready** → **Suppressed** (>28: 60% accuracy, 75% speed) → **Pinned** (>60: won't move, 30% accuracy) → **Panicked** (>90: in cover they *cower*, in the open they *flee* rearwards for 7–12 s).
- Morale starts at 55–80 and drops with casualties (−10), nearby friendly losses (−2 per man, −6 per unit) and panic. Thresholds scale with morale. At 12 or below the unit **routs** off the map.

### 3.6b Soldier bodies, stances and cover
- **Rig and look:** every soldier is a skinned 19-bone low-poly rig, posed procedurally each frame. The figure follows the clean low-poly reference style: few large volumes with strong color blocking (shirt / trousers / charcoal gear / skin) rather than greebles. Gear is limited to what reads at game zoom: plate carrier with one pouch row, chest radio with antenna, thigh holster and pouch, integrated dark knee pads, headset helmet with NVG mount and side rails. Ukrainians wear rolled sleeves (bare forearms) and a yellow armband; Russians full sleeves and red. Joint-filling balls match their surrounding color exactly, so they are invisible until a limb bends and they close the gap.
- **Gait (foot-planted IK):** each foot is a world-space point nailed to the ground through its stance half of the stride and stepped to a predicted landing in its swing half; two-bone IK bends the knee to reach it. Feet cannot slide and knees bend exactly as much as the step demands — walking, running and crouch-walking all come from the same system, with the body sinking as each foot passes under it and weight shifting over the stance foot. Standing men whose feet were left behind or twisted by a turn take one small step home, one foot at a time, so turning in place reads as a shuffle. Prone, crawling and kneeling remain scripted poses.
- **Stances:** kneeling, prone, ducked behind cover, rising to fire, cowering, and falling when hit. Blasts throw bodies in a short ballistic arc.
- **Movement physics:**
  - A squad's leader point follows the path and slows when men lag more than 4.5 m behind.
  - Each man steers to his formation slot with limited acceleration and eases into a stop.
  - Men keep 1.1 m apart (more when prone) and slide along walls.
- **Stance rules** (each man decides from his own position, relative to the nearest known threat):
  - **Trench, building or rubble, or behind a wall or wreck:** he ducks and only rises when he has a target. A ducked man must be up before he can fire.
  - **Open ground**, or when suppressed or on Defend: he goes prone.
  - **Trees or gully:** he kneels.
  - **Moving while suppressed:** he crawls.
  - **Panicked:** he cowers in place.
- **Directional cover:** obstacles 1–3 m towards the shooter add protection (wall .85, wreck .7, rubble .55, trees .3). Cover selection maximises that against the threat and is re-checked when the threat moves.
- **Posture modifies hit chance:** crouched ×0.7, prone ×0.5.

### 3.6b-2 Soldier detail and squad movement
- **Figure:**
  - About 1,000 triangles on a 19-bone rig: hips, spine, chest, head, upper and lower arms, hands, thighs, shins, feet, and a weapon bone.
  - Faceted tapered limbs, knee pads, cargo pockets, boots with soles, battle belt.
  - Plate carrier with magazine pouches and radio, helmet with goggles and NVG mount, side tape (Ukrainian yellow and blue, Russian red).
  - Four gear variants, which change shades, pack and balaclava.
- **Grounding:** every soldier casts a soft radial contact shadow on the terrain (wider when prone or fallen), and running heel strikes kick puffs of dust — the figures sit on the ground rather than hover over it.
- **Weapons**, modelled from their real layout:
  - AK-74: curved magazine (convex edge towards the muzzle), plum for Russian troops; black furniture with rail and red dot for Ukrainian.
  - PKM: ammo box and folded bipod.
  - SVD: thumbhole stock and PSO-1 scope.
  - RPG-7: slim tube with wooden heat guard and flared venturi; PG-7 grenade with needle fuze, 85 mm ogive bulb and boat-tail booster.
  - The Stugna tube is carried on the back.
- **Weapon handling (researched carry positions):** three context layers — *relaxed* (no known enemy): each man's personal carry, one of muzzle-down patrol sling, Sul-style close carry or relaxed low carry, with the RPG humped on the shoulder; *alert* (enemy known within 220 m, suppressed, or fired in the last 12 s): low ready, stock in the shoulder, muzzle depressed; *engaged*: shouldered aim. Running blends to port arms, prone to prone aim. Every man gets personal ready angles, a slow weapon sway, a stride bounce, and a periodic grip-shift where the support hand drops to the magazine well — and patrol-sling carriers take the support hand off entirely, the free arm swinging with the stride. Two-bone IK keeps hands on grip and handguard in every pose; tracers leave from the real muzzle.
- **Body motion:**
  - Hips swing and the chest counter-turns; the body bobs twice per stride.
  - He leans into turns and acceleration, his head scans when not aiming, and he breathes and shifts weight at rest.
  - Going prone drops to the knees first.
- **Squad movement:**
  - Grid paths are string-pulled into straight runs.
  - Men follow the leader's breadcrumb trail in a wedge (open ground) or staggered column (running, sneaking, leaving cover), and fall in instead of walking backwards.
  - Each man has his own reaction delay (0.1–0.9 s) and pace (±7%).
  - Men in formation are fed the squad's velocity and only gently correct towards their place, so the file flows instead of surging and stopping. Spacing pushes are smoothed, and the leader slows gradually as men lag.
  - No team discs under units: sides read from arm tape, silhouettes and labels.
  - In contact on a normal Move, two fire teams bound 12 m in turn while the other covers from cover at full accuracy.

### 3.6b-3 Individual soldier behaviour (Defilade-style)
- **Wounded:**
  - Half of bullet hits and a third of blast hits wound instead of kill.
  - The wounded lie on their backs, writhing, and bleed out after 120 s unless treated.
  - A wounded man can be finished off by a later blast.
- **Rescue:**
  - Each squad sends one free man (own casualties first, then any friendly within 65 m).
  - He crouch-runs to the casualty, slings his rifle, grabs the vest and drags the man backwards into the nearest cover away from the threat.
  - He then kneels and gives first aid for 8 s, after which the casualty is stabilized.
  - A new move order cancels the job.
  - The debrief reports killed, wounded and treated.
- **Cover-to-cover rushes:** in contact on a normal Move, each man of the moving fire team picks his own cover spot a bound (12 m) ahead and sprints there crouched. The covering team holds the cover it last rushed to. The next bound starts only when every rusher is down.
- **Tactical walk:** with the enemy known within 220 m, walking men drop to a crouched walk.
- **Grenades:**
  - Riflemen carry two and lob one at enemy infantry 8–30 m away (35% chance per firing decision, one per squad every 8 s), with a wind-up and throw animation.
  - The grenade arcs, rolls and goes off after 3.6 s (6 m radius; also chips walls).
  - Men within 7 m who see it land (75%) dive flat away from it.
- **Reloads:** magazines run dry (AK 10 bursts, PKM 10, SVD 10 shots, RPG 1). The reload animation tilts the weapon, sends the support hand to the vest pouch and back, and blocks firing for 2.6–6 s.

### 3.6c Destructible buildings
- **Construction:** houses are 1 m wall segments, window sills and lintels, and gable roof slabs. Every piece has hit points: brick 130, plaster 90.
- **Structural damage (power and radius):**

| Weapon | Power | Radius |
|---|---|---|
| 125 mm HE | 180 | 3 m |
| Artillery | 160 | ~4.7 m |
| ATGM | 90 | 2 m |
| RPG | 70 | 2 m |
| Mortar | 60 | 3 m |
| FPV | 35 | 1.5 m |
| Autocannon | ~20 | 1.2 m |

- **Hits on walls:**
  - Partial hits knock the top off a segment.
  - Lethal hits blow the piece out as 2–4 physics debris chunks. Rigid bodies settle and freeze after 8 s; a maximum of 160 active and 500 total.
  - Shells aimed at men inside a building hit the wall on the shooter's side 70% of the time.
- **Effect on the grid:**
  - Wall cells block movement; doors and breaches open them.
  - Breached cells become rubble, which can be seen and walked through.
- **Structural failure:**
  - Below 60% standing walls, the roof caves in, hurting anyone inside.
  - Below 30%, the house collapses into a rubble heap.

### 3.6d Smoke and atmosphere
- **Puffs:** smoke, dust and flame are faceted 3D puffs (same style as the tree crowns), lit and shadow-casting. They are simulated with velocity, drag, buoyancy and wind, swell, then dither-dissolve. About 3,100 puffs in two MultiMeshes, written in one buffer per frame.
- **Smoke grenade:** a dense 2 s burst followed by a canister feed for about 35 s. The line-of-sight block drifts with the visible cloud.
- **Other effects:** explosions (flame, black smoke, dust ring, thrown clods), burning wrecks, missile trails, track dust and exhaust, and the muzzle dust ring of a tank gun.

### 3.6e Vehicle models
- **Construction:** extruded side-profile hulls and lofted turrets, built from published dimensions and running-gear layouts.
- **T-72B3:** 6 large road wheels, 3 return rollers, rear sprocket, Kontakt-5 on glacis and turret, sleeved 125 mm gun, Sosna-U sight, fuel drums, unditching log, anti-drone cage.
- **BMP-2:** wedge nose, ribbed glacis with folded trim vane, front sprocket, 2A42 cannon, Konkurs launcher on the roof, bulged rear doors.
- **MT-LB:** flat cab with armoured windows, small MG turret front right, six wheels with no return rollers.
- **M2A2 Bradley:** sloped glacis, applique tiles, spaced skirts, turret offset right with the TOW box on the left, bustle rack, rear ramp.

### 3.6f Vehicle physics
- **Driving:** acceleration and braking, slowing for turns and for the final stop.
- **Hull motion:** the hull follows the ground slope and rocks on a damped spring when accelerating, braking, turning, or under main-gun recoil (relative to turret direction).
- **Destruction:** a destroyed T-72 always throws its turret (ammunition cook-off); other vehicles do 15% of the time.

### 3.7 Drones
- **Recon (player):** tap an area. Orbits for 25 s, 45 s cooldown.
- **FPV drone model:** racing X-frame kamikaze quad — carbon plate, four arms with two-blade props, strapped lipo on top, tilted nose camera, whip antennas, RPG warhead slung underneath. The recon drone keeps a commercial quadcopter look.
- **FPV (player):** 4 per battle, 12 s cooldown. Tap a spotted enemy. 80% hit (55% vs trench or building, 70% vs moving vehicle). Top attack with 350 penetration, plus 4 m blast.
- **Enemy FPVs:** every 40–60 s against a recently spotted unit (priority: vehicles, then ATGM and MG teams, then targets in the open). You get a warning message and a **FPV!** marker, roughly 5 s to react. Infantry within 35 m can shoot it down.
- No drone team means no drones. Protecting the operators matters.

### 3.7b Scenarios (procedural)
- `MissionGen.generate(kind, seed)` builds a full mission from a seed: randomized steppe (treelines with gaps, fields, roads with poles, gullies, a hamlet of 3–8 buildings near an objective, craters, wrecks), three named victory locations, deploy zone and enemy plan. The same seed reproduces the same map (combat itself stays random); kind and seed are shown on the briefing panel.
- **Every battle is capped at 10 minutes of sim time** (`Battle.TIME_CAP`); mission data may ask for less but never more. Wave schedules scale with each mission's `time_limit`, so pacing holds at any length.
- **Defend:** you hold three southern positions with trenches; 3–5 escalating waves attack from the north (8–10 min).
- **Assault:** the enemy is dug in on three northern positions from the start (hold-mode defenders, plus one counterattack wave); you deploy in the south and must take a majority before time runs out (9–10 min).
- **Meeting:** all three objectives start neutral in the middle band; enemy columns race for them from the first minute — whoever holds the majority at time-out wins (8–10 min).
- The briefing panel has TREELINE / DEFEND / ASSAULT / MEETING buttons; the end screen offers PLAY AGAIN (same map) and NEW BATTLE (new seed). The top-right quit button (confirmed with "Quit battle?") returns to the same map's briefing mid-battle. CLI: `-- kind=assault seed=7`.

### 3.8 Victory
- Victory locations (flags) are captured by being the only side with steady troops within 16 m for 8 s.
- **Win:** hold the majority of locations at time-out, or break every enemy wave.
- **Lose:** every unit destroyed or routed, or the enemy holds the majority at time-out.

---

## 4. Controls and UI (landscape phone)

- **One finger:** tap to select or order, drag to pan. **Hold** a unit to open its command menu (Move, Fast, Sneak, Fire, Smoke, Defend, Ambush, Stop) at your finger — the only order UI; there is no bottom order bar. The hold is tracked in frame time (pause-safe) and tolerates 30 px of finger drift before it becomes a camera pan. On desktop the mouse is handled directly, not through touch emulation. **Two fingers:** pinch to zoom, drag to pan. **Buttons:** rotate the view in 90° steps.
- **Selection:** a selected unit shows its name in yellow (no ground ring). Defend/Ambush facing is picked on a ring and shown as a translucent cone only.
- **Top left:** clock and objectives (blue held, red lost, `!` contested).
- **Top right:** rotate, speed (1×/2×), pause, quit (× — opens a "Quit battle?" confirm overlay that pauses the sim; QUIT reloads the same map's briefing, KEEP PLAYING restores the previous pause state).
- **Bottom:** roster cards (name, men alive, state colour). Tap a card to select and centre the camera.
- **Above roster:** order bar for the selected unit.
- **Right edge:** support (Mortar, Recon, FPV) with charges and cooldowns.
- Armed orders show a prompt with Cancel. Events scroll in the message feed (red = bad for you, green = good).
- **Desktop debug:** mouse acts as touch, wheel zooms, WASD pans, Q/E rotate, Space pauses, Esc backs out one layer (armed order → selection → quit confirm).

Planned:
- Tree-crown fade around the selected unit.
- Order wheel on long-press.
- Haptics on casualties.
- Left-handed layout.
- Colour-blind palette for the team discs.

---

## 5. Art direction

- **Diorama low-poly.** Every model is built in code from primitives, flat-shaded, vertex-coloured, one mesh per object. That means tiny builds, a single draw call per object, and no texture memory.
- **Palette:** late-autumn steppe. Olive grass, ploughed brown fields, ochre and olive poplars and acacias, grey-white plaster and red-brick ruins. Saturation is held around 0.9.
- **Readability over realism:** soldiers drawn 25% oversize, blue or red team discs, yellow tape on Ukrainian soldiers and red on Russian (both real practice), white crosses on Ukrainian vehicles, cope cages on Russian tanks.
- **Effects:** tracers, rocket and missile smoke trails, flash plus smoke plus dirt explosions, persistent burning wrecks, craters.

## 6. Audio direction (next milestone)
- Distance-filtered small arms. A distinctive FPV whine that rises in pitch as it closes; this doubles as the warning cue. Incoming artillery whistle. Short radio-chatter barks in Ukrainian with subtitles. Sparse ambient wind and distant artillery. No music in battle; a sparse bandura and strings theme in menus.

## 7. AI

- **Waves:** each wave has a spawn time, a route and an objective.
- **Infantry:** advance (run when no contact) → engage (halt and fire 5–10 s) → bound (rush ≤25 m to the best cover towards the next waypoint, only if suppression is under 35) → repeat → hold the objective in Defend.
- **Vehicles:** advance, then overwatch whenever enemies are within 225 m for 8–14 s, then push for 8 s. They stop one waypoint short of the objective. A vehicle with its weapons knocked out retreats.
- **Support:** fire director picks only from what the Russian side has actually spotted. The rule is the same as for the player: no cheating vision.

Planned:
- Flanking choice between alternative routes.
- Mounted infantry dismounting from BMPs.
- Reserve commitment when a wave stalls.
- Difficulty levels that change wave sizes and enemy morale, not accuracy.

## 8. Content plan

| Milestone | Content |
|---|---|
| **M1 Vertical slice (current)** | 1 map, 8 player units, 4 enemy waves, all core systems |
| M2 Feel | Audio, tree fade, better death and wound states (medic), tutorial battle, settings, save/resume mid-battle |
| M3 Campaign | Operation "Steppe" with 6 linked battles; persistence of men, veterancy and requisition; 3 more maps (village, industrial outskirts, river crossing) |
| M4 Content | Engineers and mines, EW team (jams FPVs in a radius), BMP mounted infantry, night battles with thermal sight, Leopard 2 and BMP-1 |
| M5 Ship | Store builds for iOS and Android (a debug Android APK already builds: `godot --headless --export-debug "Android" build/posadka.apk`), performance pass on low-end Android, localisation (UK/EN first) |

## 9. Technical architecture

Godot 4.7, GDScript, Mobile renderer. Everything is built in code from `scenes/main.tscn`.

| Path | Responsibility |
|---|---|
| `scripts/core/game.gd` | Autoload: pause and speed, side constants, test arguments |
| `scripts/data/defs.gd` | Weapon and unit tables (all balance numbers) |
| `scripts/data/mission_treeline.gd` | Mission: map painting, buildings, units, waves |
| `scripts/map/battle_map.gd` | Grid, terrain properties, heights, A* paths, LOS, cover search |
| `scripts/map/map_view.gd` | Ground mesh, multimesh trees and props, buildings, wrecks |
| `scripts/art/mesh_factory.gd` | All procedural models (soldiers, vehicles, trees, houses, drones) |
| `scripts/units/*.gd` | `Unit` base (orders, morale, spotting state), `InfantryUnit`, `Soldier` (rig, animation, steering), `VehicleUnit` |
| `scripts/map/building.gd` | Destructible houses: pieces, damage, debris, roof collapse, grid upkeep |
| `scripts/fx/puffs.gd` | Volumetric puff particle system (smoke, dust, flame) |
| `scripts/dev/demo.gd` | Scripted visual showcase for screenshots (`-- demo shots=/dir`) |
| `scripts/combat/combat.gd` | Shot and area-fire resolution, delayed impacts |
| `scripts/battle/battle.gd` | Simulation step, scheduler, spotting, blasts, victory |
| `scripts/battle/support.gd` | Player mortar and drones; enemy artillery, FPV and recon timers |
| `scripts/battle/drone.gd` | Recon and FPV drones |
| `scripts/battle/enemy_ai.gd` | Wave spawning and unit behaviour |
| `scripts/battle/victory_location.gd` | Capture flags |
| `scripts/ui/*.gd` | Camera rig, input controller, HUD |

- **Simulation** runs on its own clock, so pausing freezes impacts, artillery and drones while the camera and UI stay live. Large frames are split into 50 ms sub-steps.
- **Performance:** spotting is staggered across frames. A full 10-minute battle simulates headless in about 2 s.

**Test hooks:**
- `godot --headless --path . --fixed-fps 30 --quit-after 6000 -- autostart fast log` plays a whole battle with the player passive and prints the event log and result.
- `-- shots=/dir` (non-headless) saves screenshots at fixed frames.

## 10. Open questions
1. Is the campaign one linear operation or a choice of sectors?
2. Should we allow a player-controlled Russian side later? Recommendation: no.
3. Real-time with pause only, or also a "turn-based-ish" mode that auto-pauses on contact? Auto-pause options are cheap and mobile-friendly. Recommended for M2.
