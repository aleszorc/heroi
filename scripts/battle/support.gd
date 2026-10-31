class_name Support
extends RefCounted
## Off-map fire and drones. Ukrainian assets fire on request; Russian ones follow the
## mission's fire plan (mission["ru_support"], seed-generated) and target whatever
## their side has spotted, so staying hidden is the best defence. Shell parameters
## live in Defs.ARTILLERY.

const RECON_COOLDOWN := 45.0
const FPV_COOLDOWN := 12.0
const BOMBER_COOLDOWN := 20.0

var battle: Battle
var mortar_left := 2
var fpv_left := 5
var bomber_left := 3
var recon_ready_at := 0.0
var fpv_ready_at := 0.0
var bomber_ready_at := 0.0

## Russian fire plan when the mission brings none (the hand-built Treeline 7): the
## classic opening barrage on the treeline band, then the old fixed cadences.
## Schema (mission["ru_support"], generated per seed by MissionGen._ru_support):
##   prep:  {mode: none|short|full|late, at: s, shells: n, band: Rect2 (x, z, w, d)}
##   fpv:   {first: s, min: s, max: s}        first strike, then a random gap in [min, max]
##   arty:  {first: s, min: s, max: s, shells: n}
##   recon: {first: s, min: s, max: s}
const DEFAULT_RU := {
	"prep": {"mode": "full", "at": 8.0, "shells": 10, "band": Rect2(-80.0, 14.0, 150.0, 18.0)},
	"fpv": {"first": 90.0, "min": 40.0, "max": 60.0},
	"arty": {"first": 170.0, "min": 120.0, "max": 160.0, "shells": 6},
	"recon": {"first": 45.0, "min": 60.0, "max": 80.0},
}

var _ru: Dictionary
var _prep_done := false
var _ru_fpv_at := 90.0
var _ru_arty_at := 170.0
var _ru_recon_at := 45.0
var _log := false


func _init(b: Battle) -> void:
	battle = b
	# Campaign battles bring their own stock (support is campaign ammunition, GDD §2b.3).
	var stock: Dictionary = b.mission.get("support", {})
	mortar_left = int(stock.get("mortar", mortar_left))
	fpv_left = int(stock.get("fpv", fpv_left))
	bomber_left = int(stock.get("bomber", bomber_left))
	# The Russian fire plan is mission data; missing parts fall back to the classic one.
	_ru = DEFAULT_RU.duplicate(true)
	var plan: Dictionary = b.mission.get("ru_support", {})
	for k in plan:
		_ru[k] = plan[k]
	_ru_fpv_at = float((_ru["fpv"] as Dictionary)["first"])
	_ru_arty_at = float((_ru["arty"] as Dictionary)["first"])
	_ru_recon_at = float((_ru["recon"] as Dictionary)["first"])
	_log = Game.has_arg("log")


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


func can_bomber() -> bool:
	return drone_team() != null and bomber_left > 0 and battle.time >= bomber_ready_at


func call_mortar(p: Vector3) -> bool:
	if mortar_left <= 0:
		return false
	mortar_left -= 1
	_fire_mission(Defs.ARTILLERY["mortar"], p)
	return true


## One fire mission from a Defs.ARTILLERY entry: `rounds` shells walked onto `aim`.
func _fire_mission(a: Dictionary, aim: Vector3) -> void:
	for i in int(a["rounds"]):
		_volley(float(a["delay"]) + i * float(a["spacing"]), aim, float(a["scatter"]),
				float(a["radius"]), float(a["lethal"]), float(a["supp"]), float(a["pen"]), float(a["struct"]))


func launch_recon(p: Vector3) -> bool:
	var team := drone_team()
	if team == null or not can_recon():
		return false
	recon_ready_at = battle.time + RECON_COOLDOWN
	var d := Drone.new()
	battle.add_drone(d)
	d.setup_recon(battle, Game.UA, team.position, p, 25.0)
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
	return true


## The heavy bomber comes in from the Ukrainian map edge, not from the drone team:
## it is a battalion asset the team only talks onto the target.
func launch_bomber(t: Unit) -> bool:
	var team := drone_team()
	if team == null or not can_bomber():
		return false
	bomber_left -= 1
	bomber_ready_at = battle.time + BOMBER_COOLDOWN
	var d := Drone.new()
	battle.add_drone(d)
	var x := clampf(t.position.x + Game.rng.randf_range(-25.0, 25.0), -BattleMap.HALF + 6.0, BattleMap.HALF - 6.0)
	d.setup_bomber(battle, Game.UA, Vector3(x, 0.0, BattleMap.HALF - 2.0), t)
	return true


## Schedules one shell: scatter is resolved now so the incoming whistle can lead the impact.
func _volley(delay: float, target: Vector3, scatter: float, radius: float, lethal: float, supp: float, pen: float, struct_power := 0.0) -> void:
	var a := Game.rng.randf() * TAU
	var r := sqrt(Game.rng.randf()) * scatter
	var pos := target + Vector3(cos(a) * r, 0.0, sin(a) * r)
	pos.y = battle.map.height_at(pos)
	battle.schedule(maxf(0.0, delay - 0.9), func() -> void: battle.sfx.shell_whistle(pos))
	battle.schedule(delay, func() -> void: _shell(pos, radius, lethal, supp, pen, struct_power))


func _shell(pos: Vector3, radius: float, lethal: float, supp: float, pen: float, struct_power := 0.0) -> void:
	battle.fx.explosion(pos, radius * 0.35)
	battle.blast(pos, radius, lethal, supp, pen, true, struct_power, 2.0 + struct_power / 60.0, "arty")


# --- Russian support (AI) ---

func sim(_dt: float) -> void:
	var t := battle.time
	var prep: Dictionary = _ru["prep"]
	if not _prep_done and t > float(prep["at"]):
		_prep_done = true
		_prep_barrage(prep)
	if t >= _ru_fpv_at:
		_ru_fpv_at = t + _gap(_ru["fpv"])
		_ru_fpv()
	if t >= _ru_arty_at:
		_ru_arty_at = t + _gap(_ru["arty"])
		_ru_artillery(int((_ru["arty"] as Dictionary)["shells"]))
	if t >= _ru_recon_at:
		_ru_recon_at = t + _gap(_ru["recon"])
		_ru_recon()


func _gap(c: Dictionary) -> float:
	return Game.rng.randf_range(float(c["min"]), float(c["max"]))


## Opening barrage walked across a band of ground the Russians expect us to hold
## (the mission says where and how many shells; "none" plans skip it). Trenches
## and cellars make it survivable; standing in the open does not.
func _prep_barrage(prep: Dictionary) -> void:
	var shells := int(prep["shells"])
	if shells <= 0:
		return
	var band: Rect2 = prep["band"]
	var a: Dictionary = Defs.ARTILLERY["prep"]
	if _log:
		print("[%s] RU prep barrage (%s): %d shells on x %d..%d z %d..%d" % [Battle.clock_text(battle.time), String(prep.get("mode", "full")), shells, int(band.position.x), int(band.end.x), int(band.position.y), int(band.end.y)])
	for i in shells:
		_volley(3.0 + i * float(a["spacing"]) + Game.rng.randf() * 0.5,
				Vector3(Game.rng.randf_range(band.position.x, band.end.x), 0.0, Game.rng.randf_range(band.position.y, band.end.y)),
				0.0, float(a["radius"]), float(a["lethal"]), float(a["supp"]), float(a["pen"]), float(a["struct"]))


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
		var score := Game.rng.randf()
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
	if _log:
		print("[%s] RU FPV launched at %s" % [Battle.clock_text(battle.time), best.display_name])
	var d := Drone.new()
	battle.add_drone(d)
	d.setup_fpv(battle, Game.RU, Vector3(best.position.x + Game.rng.randf_range(-30.0, 30.0), 0.0, -BattleMap.HALF + 2.0), best)


func _ru_artillery(shells: int) -> void:
	var targets := _ru_known_targets(15.0)
	if targets.is_empty():
		return
	var target: Unit = targets[Game.rng.randi_range(0, targets.size() - 1)]
	var aim: Vector3 = target.known_pos[Game.RU]
	if _log:
		print("[%s] RU artillery: %d shells on %s" % [Battle.clock_text(battle.time), shells, target.display_name])
	var a: Dictionary = (Defs.ARTILLERY["ru_arty"] as Dictionary).duplicate()
	a["rounds"] = shells
	_fire_mission(a, aim)


func _ru_recon() -> void:
	var aim: Vector3 = battle.vls[Game.rng.randi_range(0, battle.vls.size() - 1)].position
	var d := Drone.new()
	battle.add_drone(d)
	d.setup_recon(battle, Game.RU, Vector3(aim.x, 0.0, -BattleMap.HALF + 2.0), aim, 20.0)
