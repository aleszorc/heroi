extends Node3D
## Scene root: lighting, then the battle, camera, input and HUD for the current mission.


func _ready() -> void:
	_environment()
	_apply_mission_args()
	if Game.next_seed < 0:
		Game.next_seed = randi() % 1000000
	var mission := MissionTreeline.build() if Game.next_kind == "treeline" else MissionGen.generate(Game.next_kind, Game.next_seed)
	var battle := Battle.new()
	add_child(battle)
	battle.setup(mission)
	var cam := CameraRig.new()
	add_child(cam)
	cam.focus_now(Vector3(-5.0, 0.0, 15.0))
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
## Applied once, so kind buttons and PLAY AGAIN work across scene reloads.
func _apply_mission_args() -> void:
	if Game.cli_mission_applied:
		return
	Game.cli_mission_applied = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("kind="):
			Game.next_kind = a.substr(5)
		elif a.begins_with("seed="):
			Game.next_seed = int(a.substr(5))


func _environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.17, 0.18, 0.17)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.65, 0.70)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.9
	env.adjustment_contrast = 1.05
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-52.0), deg_to_rad(-30.0), 0.0)
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 400.0
	add_child(sun)


## Test hook: `godot -- shots=/dir` saves screenshots at fixed frames, then quits.
func _process(_delta: float) -> void:
	if Game.has_arg("demo"):
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("shots="):
			var frame := Engine.get_process_frames()
			if frame in [30, 400, 900, 1500, 2400]:
				get_viewport().get_texture().get_image().save_png("%s/shot_%04d.png" % [a.substr(6), frame])
			if frame > 2400:
				get_tree().quit()
