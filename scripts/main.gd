extends Node3D
## Scene root: lighting, then the battle, camera, input and HUD for the current mission.

## Per-season sky and sun: sun colour, sun energy, sun pitch (deg), ambient colour,
## ambient energy, background, saturation. Missions carry `season`; missing = summer.
const SEASONS := {
	"summer": {"sun": Color(1.0, 0.96, 0.88), "sun_e": 1.2, "pitch": -54.0, "amb": Color(0.60, 0.66, 0.72), "amb_e": 0.55, "bg": Color(0.17, 0.18, 0.17), "sat": 0.95},
	"autumn": {"sun": Color(1.0, 0.92, 0.78), "sun_e": 1.1, "pitch": -44.0, "amb": Color(0.62, 0.63, 0.68), "amb_e": 0.55, "bg": Color(0.17, 0.18, 0.17), "sat": 0.9},
	"winter": {"sun": Color(0.92, 0.95, 1.0), "sun_e": 0.95, "pitch": -34.0, "amb": Color(0.70, 0.74, 0.84), "amb_e": 0.75, "bg": Color(0.19, 0.20, 0.21), "sat": 0.8},
	"mud": {"sun": Color(0.86, 0.87, 0.90), "sun_e": 0.8, "pitch": -48.0, "amb": Color(0.62, 0.64, 0.68), "amb_e": 0.8, "bg": Color(0.16, 0.17, 0.17), "sat": 0.82},
}

var _cam: CameraRig
var _battle: Battle


func _ready() -> void:
	_apply_mission_args()
	_apply_campaign_test_arg()
	if Game.show_menu:
		_build_menu()
		return
	if Game.show_campaign:
		_build_backdrop()
		add_child(CampaignScreen.new())
		return
	if Game.next_seed < 0:
		Game.next_seed = randi() % 1000000
	var mission := MissionTreeline.build() if Game.next_kind == "treeline" else MissionGen.generate(Game.next_kind, Game.next_seed)
	if Campaign.battle_pending(Game.campaign):
		# A campaign battle: the campaign supplies title, briefing, platoon and
		# support stock (survives RESTART reloads — "pending" clears on debrief).
		Campaign.dress_mission(mission, Game.campaign)
	else:
		# A curated preset dresses the generated mission with its own name and briefing,
		# but only while the selection still matches it (rerolls fall back to generated
		# text). The hand-built treeline mission keeps its own briefing.
		var scen := Game.scenario
		if not scen.is_empty() and Game.next_kind != "treeline" \
				and String(scen["kind"]) == Game.next_kind and int(scen["seed"]) == Game.next_seed:
			mission["title"] = String(scen["name"]).to_upper()
			mission["briefing"] = String(scen["briefing"])
	# Test hook: `-- season=winter` overrides the mission's season for a look.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("season="):
			mission["season"] = a.substr(7)
	_environment(String(mission.get("season", "summer")))
	var battle := Battle.new()
	add_child(battle)
	battle.setup(mission)
	var cam := CameraRig.new()
	add_child(cam)
	cam.focus_now(Vector3(-5.0, 0.0, 15.0))
	_cam = cam
	_battle = battle
	var hud := Hud.new()
	hud.name = "Hud"
	var ctl := InputController.new()
	ctl.name = "InputController"
	ctl.battle = battle
	ctl.cam = cam
	ctl.hud = hud
	add_child(ctl)
	add_child(hud)
	hud.setup(battle, ctl, cam)
	# Test hooks: `godot -- autostart fast` skips deployment and runs at 4x.
	if Game.has_arg("autostart"):
		battle.start_battle()
	if Game.has_arg("fast"):
		Game.speed = 4.0
	if Game.has_arg("demo"):
		var demo: Node = load("res://scripts/dev/demo.gd").new()
		demo.set("battle", battle)
		demo.set("cam", cam)
		add_child(demo)


## Test hooks: `godot -- kind=assault seed=123` picks the mission on first launch.
## Applied once, so menu choices and PLAY AGAIN work across scene reloads. Any
## mission/test arg also skips the start menu on that first boot — headless tests,
## demo and screenshot runs must land straight in the battle as before.
func _apply_mission_args() -> void:
	if Game.cli_mission_applied:
		return
	Game.cli_mission_applied = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("kind="):
			Game.next_kind = a.substr(5)
			Game.show_menu = false
		elif a.begins_with("seed="):
			Game.next_seed = int(a.substr(5))
			Game.show_menu = false
		elif a.begins_with("shots=") or a == "autostart" or a == "demo" or a == "campaign":
			# `menu` keeps the start menu up so a shots run can capture it.
			Game.show_menu = Game.has_arg("menu")


## Test hook: `godot -- autostart campaign [seed=N]` plays the saved campaign's next
## battle (first option) and commits the debrief at the end; without a save it starts
## a fresh operation. With `log` the campaign outcome prints. Repeated runs walk one
## operation battle by battle.
func _apply_campaign_test_arg() -> void:
	if not Game.has_arg("campaign") or Campaign.battle_pending(Game.campaign):
		return
	Game.campaign = Campaign.load_state()
	if Game.campaign.is_empty() or Game.campaign.get("won", false) or Game.campaign.get("lost", false):
		Game.campaign = Campaign.generate(Game.next_seed if Game.next_seed >= 0 else randi() % 1000000)
	# `-- campaign screen shots=/dir` lands on the campaign screen itself.
	if Game.has_arg("screen"):
		Game.show_menu = false
		Game.show_campaign = true
		return
	var opts := Campaign.next_options(Game.campaign)
	Campaign.launch(Game.campaign, opts[0])
	Game.next_kind = String(opts[0]["kind"])
	Game.next_seed = int(opts[0]["seed"])
	Game.show_menu = false
	Game.show_campaign = false


## The start menu over a unit-less backdrop: a generated map (fresh one each boot)
## seen from the usual isometric rig, so the first screen is already the board.
func _build_menu() -> void:
	_build_backdrop()
	add_child(MainMenu.new())


## The unit-less generated board behind the start menu and the campaign screen.
func _build_backdrop() -> void:
	var mission := MissionGen.generate("meeting", randi() % 1000000)
	_environment(String(mission.get("season", SEASONS.keys()[randi() % SEASONS.size()])))
	var map := BattleMap.new()
	(mission["paint"] as Callable).call(map)
	map.finalize()
	var view := MapView.new()
	add_child(view)
	view.build(map, mission)
	var cam := CameraRig.new()
	add_child(cam)
	cam.zoom = 110.0
	cam.focus_now(Vector3(0.0, 0.0, 10.0))


## Lighting for the season: high warm summer sun, low gold autumn light, a pale
## low winter sun over a bright snow ambient, flat overcast for the mud season.
func _environment(season := "summer") -> void:
	var sd: Dictionary = SEASONS.get(season, SEASONS["summer"])
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = sd["bg"]
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = sd["amb"]
	env.ambient_light_energy = sd["amb_e"]
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.adjustment_enabled = true
	env.adjustment_saturation = sd["sat"]
	env.adjustment_contrast = 1.05 if season != "mud" else 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(float(sd["pitch"])), deg_to_rad(-30.0), 0.0)
	sun.light_color = sd["sun"]
	sun.light_energy = sd["sun_e"]
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	add_child(sun)


## Test hook: `godot -- shots=/dir` saves screenshots at fixed frames, then quits.
## `look=x,z,zoom[,turns]` frames the camera on a ground point for a close look at
## scenery (quits after the second shot); `hit=x,z,power,radius` lands a structural
## blast there before the second shot, to inspect a damaged house.
func _process(_delta: float) -> void:
	if Game.has_arg("demo"):
		return
	var look := ""
	var hit := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("look="):
			look = a.substr(5)
		elif a.begins_with("hit="):
			hit = a.substr(4)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("shots="):
			var frame := Engine.get_process_frames()
			if frame == 5 and look != "" and _cam != null:
				var v := look.split(",")
				_cam.zoom = float(v[2]) if v.size() > 2 else 20.0
				_cam.focus_now(Vector3(float(v[0]), 0.0, float(v[1])))
				if v.size() > 3:
					_cam.rotate_step(int(v[3]))
			if frame == 200 and hit != "" and _battle != null:
				var v := hit.split(",")
				_battle.blast(Vector3(float(v[0]), 0.0, float(v[1])), 1.0, 0.0, 0.0, 0.0, false, float(v[2]), float(v[3]))
			if frame in [30, 400, 900, 1500, 2400]:
				get_viewport().get_texture().get_image().save_png("%s/shot_%04d.png" % [a.substr(6), frame])
			if frame > 2400 or (look != "" and frame > (900 if hit != "" else 400)):
				get_tree().quit()
