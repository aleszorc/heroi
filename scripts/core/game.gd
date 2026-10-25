extends Node
## Global session state shared by every system. Autoloaded as `Game`.

const UA := 0
const RU := 1
const SIDE_COLORS: Array[Color] = [Color(0.35, 0.65, 1.0), Color(1.0, 0.3, 0.22)]

## Simulation is frozen while paused; the camera and UI keep working.
var paused := true
var speed := 1.0

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


## Values passed after `--` on the command line, e.g. `godot -- autostart fast`.
func has_arg(name: String) -> bool:
	return OS.get_cmdline_user_args().has(name)
