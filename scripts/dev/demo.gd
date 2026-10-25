extends Node
## Scripted showcase for visual checks: `godot -- demo shots=/dir` stages a few events,
## frames the camera on them and saves screenshots, then quits.

var battle: Battle
var cam: CameraRig
var out := ""
var _frame := 0
var _events: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("shots="):
			out = a.substr(6)
	if Game.has_arg("vehicles"):
		_vehicle_lineup()
		return
	if Game.has_arg("fpvdemo"):
		_fpv_demo()
		return
	if Game.has_arg("gait"):
		_gait_demo()
		return
	if Game.has_arg("menutest"):
		_menu_test()
		return
	if Game.has_arg("rescue"):
		_rescue_demo()
		return
	if Game.has_arg("orders"):
		_orders_demo()
		return
	if Game.has_arg("soldiers"):
		_soldier_lineup()
		return
	var sq1 := _unit("1st Squad")
	var sq2 := _unit("2nd Squad")
	_events = [
		[5, func() -> void:
			battle.start_battle()
			cam.zoom = 18.0
			cam.focus_now(Vector3(-28, 0, 27))],
		[40, func() -> void: _shot("trench_crouch")],
		[45, func() -> void:
			sq1.order_move(Vector3(-30, 0, 52), Unit.Order.FAST)
			cam.focus_now(Vector3(-29, 0, 36))],
		[95, func() -> void: _shot("running")],
		[100, func() -> void: sq1.order_move(Vector3(-40, 0, 58), Unit.Order.SNEAK)],
		[150, func() -> void:
			cam.focus_now(sq1.position)
			_shot("sneaking")],
		[160, func() -> void:
			sq2.throw_smoke(Vector3(62, 0, -30))
			cam.zoom = 40.0
			cam.focus_now(Vector3(60, 0, -20))],
		[330, func() -> void: _shot("smoke_screen")],
		[340, func() -> void: _shell_farm()],
		[372, func() -> void: _shot("house_hit")],
		[400, func() -> void: _shot("debris")],
		[600, func() -> void: _shot("house_after")],
		[610, func() -> void: get_tree().quit()],
	]


## The four vehicle models side by side, shot from two angles.
func _vehicle_lineup() -> void:
	battle.start_battle()
	Game.paused = true
	var kinds := ["t72", "bmp2", "mtlb", "bradley"]
	for i in kinds.size():
		var parts := MeshFactory.vehicle(kinds[i])
		var hull := MeshInstance3D.new()
		hull.mesh = parts["hull"]
		hull.position = Vector3(20.0 + i * 9.0, 0.0, 80.0)
		hull.rotation.y = 0.5
		battle.add_child(hull)
		var turret := MeshInstance3D.new()
		turret.mesh = parts["turret"]
		turret.position = parts["turret_pos"]
		turret.rotation.y = -0.4
		hull.add_child(turret)
	_events = [
		[3, func() -> void:
			cam.zoom = 22.0
			cam.focus_now(Vector3(33.5, 0, 80))],
		[30, func() -> void: _shot("vehicles_a")],
		[31, func() -> void: cam.rotate_step(2)],
		[70, func() -> void: _shot("vehicles_b")],
		[72, func() -> void:
			cam.zoom = 10.0
			cam.focus_now(Vector3(20, 0, 80))],
		[110, func() -> void: _shot("t72_close")],
		[112, func() -> void: cam.focus_now(Vector3(47, 0, 80))],
		[150, func() -> void: _shot("bradley_close")],
		[152, func() -> void: get_tree().quit()],
	]


## Both drone models hovering side by side: FPV strike quad and recon camera drone.
func _fpv_demo() -> void:
	battle.start_battle()
	Game.paused = true
	for i in 2:
		var mi := MeshInstance3D.new()
		mi.mesh = MeshFactory.drone(i == 0)
		mi.position = Vector3(21.0 + i * 5.0, 2.0, 80.0)
		mi.rotation.y = 0.5
		battle.add_child(mi)
	_events = [
		[3, func() -> void:
			cam.zoom = 7.0
			cam.focus_now(Vector3(23.5, 0, 80))],
		[30, func() -> void: _shot("drones_a")],
		[31, func() -> void: cam.rotate_step(2)],
		[70, func() -> void: _shot("drones_b")],
		[72, func() -> void:
			cam.zoom = 6.0
			cam.focus_now(Vector3(21, 0, 80))],
		[110, func() -> void: _shot("fpv_close")],
		[112, func() -> void: get_tree().quit()],
	]


## Long-press menu, then choosing a Defend facing on the ring, then the resulting arc.
func _orders_demo() -> void:
	var sq := _unit("1st Squad")
	var ctl: InputController = get_parent().get_node("InputController")
	var hud: Hud = get_parent().get_node("Hud")
	_events = [
		[5, func() -> void:
			battle.start_battle()
			Game.paused = true
			cam.zoom = 30.0
			cam.focus_now(sq.position)],
		[20, func() -> void:
			ctl.select(sq)
			hud.show_menu(sq, cam.cam.unproject_position(sq.position))],
		[40, func() -> void: _shot("menu")],
		[42, func() -> void:
			hud.hide_menu()
			ctl.set_mode("defend")
			ctl.set("_orient_dir", Vector3(0.7, 0, -0.7).normalized())],
		[60, func() -> void: _shot("defend_ring")],
		[62, func() -> void: ctl.call("_apply_orient")],
		[90, func() -> void: _shot("defend_arc")],
		[92, func() -> void: get_tree().quit()],
	]


## A man of 1st Squad is wounded in the open behind the trench; a comrade drags him into
## cover and treats him. Then a Russian squad closes on 3rd Squad for a grenade exchange.
func _rescue_demo() -> void:
	var sq: InfantryUnit = _unit("1st Squad")
	var victim := sq.members[1]
	_events = [
		[5, func() -> void:
			battle.start_battle()
			victim.position = sq.position + Vector3(4.0, 0.0, 9.0)
			sq.casualty(victim, null, Vector3.ZERO, 0.0, true)
			cam.zoom = 8.0
			cam.focus_now(victim.position)],
		[60, func() -> void: _shot("rescue_go")],
		[120, func() -> void: cam.focus_now(victim.position)],
		[150, func() -> void: _shot("rescue_drag")],
		[170, func() -> void: cam.rotate_step(1)],
		[200, func() -> void: _shot("rescue_drag_b")],
		[330, func() -> void:
			cam.focus_now(victim.position)
			_shot("rescue_aid")],
		[340, func() -> void:
			var ru := battle.spawn("ru_assault", Game.RU, Vector3(-56, 0, -30), "Demo")
			for u in battle.units:
				battle.mark_seen(u, Game.UA)
				battle.mark_seen(u, Game.RU)
			ru.order_move(Vector3(-56, 0, -24), Unit.Order.MOVE)
			cam.zoom = 26.0
			cam.focus_now(Vector3(-56, 0, -16))],
		[480, func() -> void: _shot("firefight_a")],
		[560, func() -> void: _shot("firefight_b")],
		[640, func() -> void: _shot("firefight_c")],
		[642, func() -> void: get_tree().quit()],
	]


## Walks, runs and sneaks a squad past a close camera; successive shots catch the stride.
func _gait_demo() -> void:
	var sq: InfantryUnit = _unit("1st Squad")
	var shot_walk := func(n: String) -> void:
		cam.focus_now(sq.members[2].position)
		_shot(n)
	_events = [
		[5, func() -> void:
			battle.start_battle()
			cam.zoom = 9.0
			sq.order_move(sq.position + Vector3(2.0, 0.0, 30.0), Unit.Order.MOVE)],
		[80, func() -> void: shot_walk.call("walk_1")],
		[86, func() -> void: shot_walk.call("walk_2")],
		[92, func() -> void: shot_walk.call("walk_3")],
		[98, func() -> void: shot_walk.call("walk_4")],
		[110, func() -> void: sq.order_move(sq.position + Vector3(0.0, 0.0, 25.0), Unit.Order.FAST)],
		[150, func() -> void: shot_walk.call("run_1")],
		[155, func() -> void: shot_walk.call("run_2")],
		[165, func() -> void: sq.order_move(sq.position + Vector3(12.0, 0.0, 0.0), Unit.Order.SNEAK)],
		[230, func() -> void: shot_walk.call("sneak_1")],
		[236, func() -> void: shot_walk.call("sneak_2")],
		[250, func() -> void: sq.order_stop()],
		[320, func() -> void: shot_walk.call("idle_cover")],
		[322, func() -> void: get_tree().quit()],
	]


## Holds a simulated finger on a unit, verifies the menu opens, then runs MOVE.
func _menu_test() -> void:
	var sq := _unit("1st Squad")
	var ctl: InputController = get_parent().get_node("InputController")
	var hud: Hud = get_parent().get_node("Hud")
	var at := []
	_events = [
		[5, func() -> void:
			battle.start_battle()
			cam.zoom = 30.0
			cam.focus_now(sq.members[0].position)],
		[20, func() -> void:
			at.append(cam.cam.unproject_position(sq.members[0].position))
			ctl._press_begin(900, at[0])],
		[45, func() -> void:
			ctl._press_end(900, at[0] + Vector2(11.0, -8.0))
			print("menu visible: ", hud.get("_menu").visible, " selected: ", ctl.selected.display_name if ctl.selected else "none")],
		[50, func() -> void:
			_shot("menu_open")
			var list: VBoxContainer = hud.get("_menu_list")
			for ch in list.get_children():
				if ch is Button:
					print("entry: ", (ch as Button).text, " rect: ", (ch as Control).get_global_rect())
			var move: Button = list.get_child(1)
			print("pressing ", move.text)
			move.pressed.emit()],
		[53, func() -> void:
			print("mode after press: '", ctl.mode, "' menu visible: ", hud.get("_menu").visible)
			ctl._press_begin(900, cam.cam.unproject_position(sq.position + Vector3(6, 0, 6)))],
		[55, func() -> void:
			ctl._press_end(900, cam.cam.unproject_position(sq.position + Vector3(6, 0, 6)))],
		[58, func() -> void:
			print("after target tap: order=", sq.order, " arrived=", sq.arrived)
			get_tree().quit()],
	]


var _models: Array[Soldier] = []
var _speeds: Array[float] = []


## One soldier per stance, animated in place: idle, walk, run, aim, kneel, crouch-walk,
## prone aim, crawl, cower, killed.
func _soldier_lineup() -> void:
	battle.start_battle()
	Game.paused = true
	var setups := [
		["ak", 0.0, 0.0, 0.0, false], ["ak", 1.9, 0.0, 0.0, false], ["pkm", 4.0, 0.0, 0.0, false],
		["ak", 0.0, 0.0, 0.0, true], ["sniper", 0.0, 1.0, 0.0, true], ["ak", 1.2, 0.9, 0.0, false],
		["ak", 0.0, 0.0, 1.0, true], ["rpg", 0.6, 0.0, 1.0, false], ["rpg", 0.0, 0.0, 0.0, true], ["ak", 0.0, 1.0, 0.0, false],
	]
	for i in setups.size():
		var st: Array = setups[i]
		var s := Soldier.new()
		battle.add_child(s)
		s.setup(Game.UA if i % 3 != 2 else Game.RU, String(st[0]))
		s.position = Vector3(20.0 + (i % 5) * 3.0, 0.0, 80.0 + (i / 5) * 4.0)
		s.want_crouch = st[2]
		s.want_prone = st[3]
		s.snap_stance()
		s.engage_until = 1e9 if st[4] else -1.0
		s.cowering = i == 9
		s.facing = 0.6
		s.rotation.y = 0.6
		_models.append(s)
		_speeds.append(float(st[1]))
	_events = [
		[3, func() -> void:
			cam.zoom = 14.0
			cam.focus_now(Vector3(26, 0, 82))],
		[40, func() -> void: _shot("soldiers_a")],
		[41, func() -> void: cam.rotate_step(1)],
		[80, func() -> void: _shot("soldiers_b")],
		[81, func() -> void:
			cam.zoom = 7.0
			cam.focus_now(Vector3(23, 0, 80))],
		[120, func() -> void: _shot("soldiers_close")],
		[160, func() -> void:
			_models[0].die(Vector3(2, 0, 0), 2.0)
			cam.focus_now(Vector3(20, 0, 80))],
		[200, func() -> void: _shot("soldier_dead")],
		[202, func() -> void: get_tree().quit()],
	]


func _animate_models(dt: float) -> void:
	for i in _models.size():
		var s := _models[i]
		s.vel = Vector3(-sin(s.facing), 0.0, -cos(s.facing)) * _speeds[i]
		s.animate(dt, 10.0, battle.map)


func _unit(n: String) -> Unit:
	for u in battle.units:
		if u.display_name == n:
			return u
	return null


func _shell_farm() -> void:
	for i in 4:
		battle.schedule(i * 0.25, func() -> void:
			var p := Vector3(54 + randf_range(-3, 3), 1.0, -20 + randf_range(-3, 3))
			battle.fx.explosion(p, 2.4)
			battle.blast(p, 7.0, 0.0, 20.0, 0.0, true, 170.0, 4.0))


func _shot(shot_name: String) -> void:
	if out != "":
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [out, shot_name])


func _process(delta: float) -> void:
	_frame += 1
	if not _models.is_empty():
		_animate_models(delta)
	for e: Array in _events:
		if int(e[0]) == _frame:
			(e[1] as Callable).call()
