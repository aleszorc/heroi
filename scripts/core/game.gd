extends Node
## Global session state shared by every system. Autoloaded as `Game`.

const UA := 0
const RU := 1
const SIDE_COLORS: Array[Color] = [Color(0.35, 0.65, 1.0), Color(1.0, 0.3, 0.22)]

## Simulation is frozen while paused; the camera and UI keep working.
var paused := true
var speed := 1.0

## Deterministic simulation RNG: every combat, AI and support roll draws from here,
## so the same mission seed replays the same battle (presentation randomness — fx,
## meshes, audio, animation jitter — keeps the global RNG). Battle.setup() seeds it
## from the mission seed; `-- sim=N` on the command line overrides that seed.
var rng := RandomNumberGenerator.new()

## Mission selection for the next scene load; being an autoload, this survives
## reload_current_scene(). A negative seed means "pick one at random".
var next_kind := "treeline"
var next_seed := -1
## When true, the next scene load shows the start menu instead of a battle.
## Normal boots start here; CLI test hooks (autostart, demo, kind=, shots=) skip it.
var show_menu := true
## Curated scenario behind the next load (an entry from Scenarios.ALL), empty when
## the mission is generated or rerolled. Its name/briefing dress the deployment
## screen only while next_kind/next_seed still match the preset.
var scenario := {}
## When true, the next scene load shows the campaign screen (GDD §2b).
var show_campaign := false
## The live campaign state dict (Campaign). Kept here so it survives scene reloads;
## persisted to user://campaign.json by Campaign.save_state. While it holds a
## "pending" entry, the current battle belongs to the campaign.
var campaign := {}
## Set once the command-line mission args were read, so UI choices survive reloads.
var cli_mission_applied := false


func sim_delta(delta: float) -> float:
	return 0.0 if paused else delta * speed


## Seeds the simulation RNG for one battle. `-- sim=N` overrides the mission seed so
## the same map can be replayed with different battle rolls (A/B balance runs).
func seed_sim(mission_seed: int) -> void:
	var s := mission_seed
	for a in OS.get_cmdline_user_args():
		if a.begins_with("sim="):
			s = int(a.substr(4))
	rng.seed = s
	# The global RNG (presentation: pose sway, fx, debris) is seeded too, on its own
	# stream. Animation feeds sim inputs — muzzle() shoots from the solved pose — so
	# replays only match when presentation is reproducible as well (it is under the
	# fixed-fps test harness; interactive play has variable frame counts anyway).
	seed(s + 1013904223)


## Values passed after `--` on the command line, e.g. `godot -- autostart fast`.
func has_arg(name: String) -> bool:
	return OS.get_cmdline_user_args().has(name)
