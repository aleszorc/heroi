class_name EnemyAI
extends RefCounted
## Scripted Russian assault. Timed waves follow routes to an objective: infantry advance,
## stop to fight when they meet resistance, then bound forward cover to cover. Vehicles
## overwatch from behind and pull back when their guns are knocked out. Each wave carries
## a "style" (mission data) that tunes the same loop: probes fight at range and pull
## back when hurt, rushes close in and keep moving under fire, feints and lone tanks
## stop at a route point and only shoot from there. The AI only ever reacts to units
## the Russian side has actually spotted (no cheating vision).

const THINK_INTERVAL := 1.0
const INFANTRY_ENGAGE := 140.0
const VEHICLE_ENGAGE := 250.0

## Per-style tuning. engage: contact range (m) at which infantry halts to fight.
## fire: [min, max] seconds of fire before the next bound. bound_supp: max suppression
## that still allows a bound. hop: bound length (m). veh_engage: vehicle overwatch
## range. push: seconds a vehicle keeps driving once it decides to push.
## withdraw: share of the group lost (or suppression) that makes it fall back a waypoint.
const STYLES := {
	"assault": {"engage": 140.0, "fire": [5.0, 10.0], "bound_supp": 35.0, "hop": 25.0, "veh_engage": 250.0, "push": 8.0, "withdraw": 0.0},
	"rush": {"engage": 90.0, "fire": [2.0, 4.0], "bound_supp": 55.0, "hop": 35.0, "veh_engage": 170.0, "push": 14.0, "withdraw": 0.0},
	"probe": {"engage": 190.0, "fire": [8.0, 14.0], "bound_supp": 20.0, "hop": 18.0, "veh_engage": 260.0, "push": 5.0, "withdraw": 0.5},
	"flank": {"engage": 120.0, "fire": [4.0, 8.0], "bound_supp": 40.0, "hop": 28.0, "veh_engage": 220.0, "push": 10.0, "withdraw": 0.0},
	"overwatch": {"engage": 200.0, "fire": [10.0, 16.0], "bound_supp": 15.0, "hop": 15.0, "veh_engage": 300.0, "push": 0.0, "withdraw": 0.0},
	"feint": {"engage": 180.0, "fire": [8.0, 14.0], "bound_supp": 15.0, "hop": 15.0, "veh_engage": 280.0, "push": 0.0, "withdraw": 0.4},
}

var battle: Battle
var waves: Array
var spawned: Array[Unit] = []
var _next_wave := 0
var _think := 0.0
var _log := false


func _init(b: Battle, w: Array) -> void:
	battle = b
	waves = w
	_log = Game.has_arg("log")
	if _log:
		var parts: Array = []
		for wd: Dictionary in waves:
			parts.append("%s %s%s@%d" % [String(wd.get("comp", "mech")), String(wd.get("style", "assault")),
					"/" + String(wd["edge"]) if String(wd.get("edge", "")) != "" else "", int(wd["time"])])
		print("RU plan [%s|%s]: %s" % [String(b.mission.get("plan", "classic")), String(b.mission.get("season", "-")), ", ".join(PackedStringArray(parts))])


func all_spawned() -> bool:
	return _next_wave >= waves.size()


func alive_count() -> int:
	var n := 0
	for u in spawned:
		if u.is_targetable() and u.state != Unit.State.ROUTED:
			n += 1
	return n


func sim(dt: float) -> void:
	while _next_wave < waves.size() and battle.time >= float(waves[_next_wave]["time"]):
		_spawn(waves[_next_wave])
		_next_wave += 1
	_think -= dt
	if _think <= 0.0:
		_think = THINK_INTERVAL
		for u in spawned:
			_decide(u)


## A wave with "hold": true spawns defenders that stay where they are placed:
## infantry digs in facing the player, vehicles sit in overwatch. "style" picks the
## STYLES tuning (default "assault"); "stop_at" (route index) truncates the route so
## the wave halts there and fights from that point (feints, overwatch tanks).
func _spawn(w: Dictionary) -> void:
	var origin: Vector3 = w["spawn"]
	var hold: bool = w.get("hold", false)
	var style := String(w.get("style", "assault"))
	if not STYLES.has(style):
		style = "assault"
	var route: Array = w["route"]
	var stop_at := int(w.get("stop_at", -1))
	var short := 1
	if stop_at >= 0 and stop_at < route.size() - 1:
		route = route.slice(0, stop_at + 1)
		short = 0
	if _log:
		var ids: Array = []
		for e: Array in w["units"]:
			ids.append(String(e[0]).trim_prefix("ru_"))
		print("[%s] RU wave: %s%s from (%d, %d) via %d points [%s]%s" % [Battle.clock_text(battle.time),
				"holding" if hold else style, " " + String(w["edge"]) if String(w.get("edge", "")) != "" else "", int(origin.x), int(origin.z),
				route.size(), ", ".join(PackedStringArray(ids)), " halts at point %d" % stop_at if short == 0 else ""])
	for e: Array in w["units"]:
		var off: Vector3 = e[2]
		var u := battle.spawn(e[0], Game.RU, origin + off, e[1])
		var mode := "advance"
		if hold:
			mode = "overwatch_hold" if u.is_vehicle else "hold"
		u.ai = {"route": route, "i": 0, "mode": mode, "timer": 0.0, "lost": 0, "push_until": 0.0,
				"home": origin + off, "off": off, "style": style, "short": short, "men": u.total_count()}
		if hold and not u.is_vehicle:
			u.hold_position(Vector3(0, 0, 1))
		spawned.append(u)


func _nearest_enemy(u: Unit) -> Unit:
	var best: Unit = null
	var best_d := INF
	for e in battle.units:
		if e.side == u.side or not e.is_targetable() or not e.seen[u.side]:
			continue
		var d := e.position.distance_to(u.position)
		if d < best_d:
			best_d = d
			best = e
	return best


## Route point for this unit, offset so squads of a wave keep their spacing.
func _waypoint(u: Unit, i: int) -> Vector3:
	var route: Array = u.ai["route"]
	var p: Vector3 = route[clampi(i, 0, route.size() - 1)]
	var off: Vector3 = u.ai["off"]
	return p + off * 0.6


func _near(u: Unit, p: Vector3, r: float) -> bool:
	return Vector2(u.position.x - p.x, u.position.z - p.z).length() < r


func _style(u: Unit) -> Dictionary:
	return STYLES[String(u.ai.get("style", "assault"))]


func _decide(u: Unit) -> void:
	if not u.is_targetable() or u.state >= Unit.State.PINNED:
		return
	var enemy := _nearest_enemy(u)
	var enemy_d := INF if enemy == null else enemy.position.distance_to(u.position)
	if u.is_vehicle:
		_decide_vehicle(u as VehicleUnit, enemy, enemy_d)
	else:
		_decide_infantry(u, enemy, enemy_d)


func _decide_infantry(u: Unit, enemy: Unit, enemy_d: float) -> void:
	var ai := u.ai
	var st := _style(u)
	var route: Array = ai["route"]
	var i: int = ai["i"]
	var fire: Array = st["fire"]
	# Cautious styles fall back one waypoint and dig in once the group is bleeding.
	var withdraw := float(st["withdraw"])
	if withdraw > 0.0 and String(ai["mode"]) in ["engage", "bound", "advance"] \
			and (u.alive_count() <= int(ai["men"]) * (1.0 - withdraw) or u.suppression > 50.0):
		ai["mode"] = "withdraw"
		ai["i"] = maxi(0, i - 1)
		u.order_move(battle.map.best_cover_near(_waypoint(u, maxi(0, i - 1)), 5, {}))
		return
	match String(ai["mode"]):
		"advance":
			if enemy != null and enemy_d < float(st["engage"]):
				u.order_stop()
				ai["mode"] = "engage"
				ai["timer"] = randf_range(float(fire[0]), float(fire[1]))
				ai["lost"] = 0
			elif u.arrived:
				while i < route.size() and _near(u, _waypoint(u, i), 6.0):
					i += 1
				ai["i"] = i
				if i >= route.size():
					ai["mode"] = "hold"
					u.hold_position()
				else:
					u.order_move(_waypoint(u, i))
		"engage":
			ai["timer"] = float(ai["timer"]) - THINK_INTERVAL
			if enemy == null:
				ai["lost"] = int(ai["lost"]) + 1
				if int(ai["lost"]) >= 3:
					ai["mode"] = "advance"
			elif float(ai["timer"]) <= 0.0:
				if u.suppression < float(st["bound_supp"]) and i < route.size():
					_bound(u, _waypoint(u, i), float(st["hop"]))
					ai["mode"] = "bound"
				else:
					ai["timer"] = randf_range(3.0, 6.0)
		"bound":
			if u.arrived:
				if i < route.size() and _near(u, _waypoint(u, i), 10.0):
					ai["i"] = i + 1
				ai["mode"] = "engage" if enemy != null else "advance"
				ai["timer"] = randf_range(float(fire[0]), float(fire[1]) * 0.9)
		"withdraw":
			if u.arrived:
				ai["mode"] = "hold"
				u.hold_position()
		"hold":
			if u.arrived and not u.guarding:
				u.hold_position()


## Short rush towards goal, ending in the best cover near the landing point.
func _bound(u: Unit, goal: Vector3, hop: float) -> void:
	var dir := Vector3(goal.x - u.position.x, 0.0, goal.z - u.position.z)
	var to := u.position + dir.normalized() * minf(hop, dir.length())
	u.order_move(battle.map.best_cover_near(to, 4, {}))


func _decide_vehicle(u: VehicleUnit, enemy: Unit, enemy_d: float) -> void:
	var ai := u.ai
	var st := _style(u)
	var route: Array = ai["route"]
	var i: int = ai["i"]
	if u.gun_out and String(ai["mode"]) != "retreat":
		ai["mode"] = "retreat"
		u.order_move(ai["home"])
		return
	match String(ai["mode"]):
		"advance":
			var pushing := battle.time < float(ai["push_until"])
			if enemy != null and enemy_d < float(st["veh_engage"]) * 0.9 and not pushing:
				u.order_stop()
				ai["mode"] = "overwatch"
				ai["timer"] = randf_range(8.0, 14.0)
			elif u.arrived:
				# Vehicles stop one waypoint short of the objective and support from
				# there; a wave that halts at a route point drives right up to it.
				var last := maxi(0, route.size() - 1 - int(ai["short"]))
				while i <= last and _near(u, _waypoint(u, i), 8.0):
					i += 1
				ai["i"] = i
				if i > last:
					ai["mode"] = "overwatch_hold"
				else:
					u.order_move(_waypoint(u, i))
		"overwatch":
			ai["timer"] = float(ai["timer"]) - THINK_INTERVAL
			if float(ai["timer"]) <= 0.0:
				if float(st["push"]) <= 0.0:
					# Overwatch styles never push into contact: they sit and shoot.
					ai["mode"] = "overwatch_hold"
				else:
					ai["mode"] = "advance"
					ai["push_until"] = battle.time + float(st["push"])
