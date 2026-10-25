class_name Support
extends RefCounted
## Off-map fire and drones. Ukrainian assets fire on request; Russian ones run on timers
## and target whatever their side has spotted, so staying hidden is the best defence.

const RECON_COOLDOWN := 45.0
const FPV_COOLDOWN := 12.0
const MORTAR_DELAY := 10.0

var battle: Battle
var mortar_left := 2
var fpv_left := 4
var recon_ready_at := 0.0
var fpv_ready_at := 0.0

var _prep_done := false
var _ru_fpv_at := 90.0
var _ru_arty_at := 170.0
var _ru_recon_at := 45.0


func _init(b: Battle) -> void:
	battle = b


# --- Ukrainian support (player) ---

func drone_team() -> Unit:
	for u in battle.units:
		if u.side == Game.UA and u.def.get("drones", false) and u.is_effective():
			return u
	return null


func can_recon() -> bool:
	return drone_team() != null and battle.time >= recon_ready_at


func can_fpv() -> bool:
	return drone_team() != null and fpv_left > 0 and battle.time >= fpv_ready_at


func call_mortar(p: Vector3) -> bool:
	if mortar_left <= 0:
		return false
	mortar_left -= 1
	battle.notify_msg("82mm mortar: rounds in %ds" % int(MORTAR_DELAY), Color(0.7, 0.85, 1.0))
	for i in 6:
		battle.schedule(MORTAR_DELAY + i * 0.9, func() -> void: _shell(p, 9.0, 6.5, 0.55, 40.0, 25.0, 60.0))
	return true


func launch_recon(p: Vector3) -> bool:
	var team := drone_team()
	if team == null or not can_recon():
		return false
	recon_ready_at = battle.time + RECON_COOLDOWN
	var d := Drone.new()
	battle.add_drone(d)
	d.setup_recon(battle, Game.UA, team.position, p, 25.0)
	battle.notify_msg("Recon drone launched", Color(0.7, 0.85, 1.0))
	return true


func launch_fpv(t: Unit) -> bool:
	var team := drone_team()
	if team == null or not can_fpv():
		return false
	fpv_left -= 1
	fpv_ready_at = battle.time + FPV_COOLDOWN
	var d := Drone.new()
	battle.add_drone(d)
	d.setup_fpv(battle, Game.UA, team.position, t)
	battle.notify_msg("FPV away → %s" % ("Enemy " + String(t.def["name"]) if t.is_vehicle else "enemy infantry"), Color(0.7, 0.85, 1.0))
	return true


func _shell(target: Vector3, scatter: float, radius: float, lethal: float, supp: float, pen: float, struct_power := 0.0) -> void:
	var a := randf() * TAU
	var r := sqrt(randf()) * scatter
	var pos := target + Vector3(cos(a) * r, 0.0, sin(a) * r)
	pos.y = battle.map.height_at(pos)
	battle.fx.explosion(pos, radius * 0.35)
	battle.blast(pos, radius, lethal, supp, pen, true, struct_power, 2.0 + struct_power / 60.0)


# --- Russian support (AI) ---

func sim(_dt: float) -> void:
	var t := battle.time
	if not _prep_done and t > 8.0:
		_prep_done = true
		_prep_barrage()
	if t >= _ru_fpv_at:
		_ru_fpv_at = t + randf_range(40.0, 60.0)
		_ru_fpv()
	if t >= _ru_arty_at:
		_ru_arty_at = t + randf_range(120.0, 160.0)
		_ru_artillery()
	if t >= _ru_recon_at:
		_ru_recon_at = t + randf_range(60.0, 80.0)
		_ru_recon()


## Opening barrage on the Ukrainian treeline. Trenches make it survivable.
func _prep_barrage() -> void:
	battle.notify_msg("Incoming artillery! Stay in the trenches.", Color(1.0, 0.4, 0.3))
	for i in 10:
		battle.schedule(3.0 + i * 1.4 + randf() * 0.5, func() -> void:
			_shell(Vector3(randf_range(-80.0, 70.0), 0.0, randf_range(14.0, 32.0)), 0.0, 7.0, 0.45, 35.0, 40.0, 160.0))


## UA units the Russians have seen in the last few seconds.
func _ru_known_targets(window: float) -> Array[Unit]:
	var out: Array[Unit] = []
	for u in battle.units:
		if u.side == Game.UA and u.is_targetable() and battle.time - u.last_seen[Game.RU] < window:
			out.append(u)
	return out


func _ru_fpv() -> void:
	var best: Unit = null
	var best_score := -1.0
	for u in _ru_known_targets(8.0):
		var score := randf()
		if u.is_vehicle:
			score += 3.0
		elif u.def_id == "ua_atgm" or u.def_id == "ua_mg":
			score += 2.0
		if u.cover_here() < 0.4:
			score += 1.0
		if score > best_score:
			best_score = score
			best = u
	if best == null:
		return
	var d := Drone.new()
	battle.add_drone(d)
	d.setup_fpv(battle, Game.RU, Vector3(best.position.x + randf_range(-30.0, 30.0), 0.0, -BattleMap.HALF + 2.0), best)
	battle.notify_msg("FPV drone inbound → %s! Move or get into cover." % best.display_name, Color(1.0, 0.4, 0.3))


func _ru_artillery() -> void:
	var targets := _ru_known_targets(15.0)
	if targets.is_empty():
		return
	var aim: Vector3 = targets.pick_random().known_pos[Game.RU]
	battle.notify_msg("Artillery incoming near %s!" % _nearest_vl_name(aim), Color(1.0, 0.4, 0.3))
	for i in 6:
		battle.schedule(8.0 + i * 1.3, func() -> void: _shell(aim, 15.0, 7.0, 0.5, 40.0, 40.0, 160.0))


func _ru_recon() -> void:
	var aim: Vector3 = battle.vls.pick_random().position
	var d := Drone.new()
	battle.add_drone(d)
	d.setup_recon(battle, Game.RU, Vector3(aim.x, 0.0, -BattleMap.HALF + 2.0), aim, 20.0)


func _nearest_vl_name(p: Vector3) -> String:
	var best := "your lines"
	var best_d := 60.0
	for vl in battle.vls:
		var d := vl.position.distance_to(p)
		if d < best_d:
			best_d = d
			best = vl.loc_name
	return best
