class_name EnemyAI
extends RefCounted
## Scripted Russian assault. Timed waves follow routes to an objective: infantry advance,
## stop to fight when they meet resistance, then bound forward cover to cover. Vehicles
## overwatch from behind and pull back when their guns are knocked out.

const THINK_INTERVAL := 1.0
const INFANTRY_ENGAGE := 140.0
const VEHICLE_ENGAGE := 250.0

var battle: Battle
var waves: Array
var spawned: Array[Unit] = []
var _next_wave := 0
var _think := 0.0


func _init(b: Battle, w: Array) -> void:
	battle = b
	waves = w


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
## infantry digs in facing the player, vehicles sit in overwatch.
func _spawn(w: Dictionary) -> void:
	var origin: Vector3 = w["spawn"]
	var hold: bool = w.get("hold", false)
	for e: Array in w["units"]:
		var off: Vector3 = e[2]
		var u := battle.spawn(e[0], Game.RU, origin + off, e[1])
		var mode := "advance"
		if hold:
			mode = "overwatch_hold" if u.is_vehicle else "hold"
		u.ai = {"route": w["route"], "i": 0, "mode": mode, "timer": 0.0, "lost": 0, "push_until": 0.0, "home": origin + off, "off": off}
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
	var p: Vector3 = route[mini(i, route.size() - 1)]
	var off: Vector3 = u.ai["off"]
	return p + off * 0.6


func _near(u: Unit, p: Vector3, r: float) -> bool:
	return Vector2(u.position.x - p.x, u.position.z - p.z).length() < r


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
	var route: Array = ai["route"]
	var i: int = ai["i"]
	match String(ai["mode"]):
		"advance":
			if enemy != null and enemy_d < INFANTRY_ENGAGE:
				u.order_stop()
				ai["mode"] = "engage"
				ai["timer"] = randf_range(5.0, 10.0)
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
				if u.suppression < 35.0 and i < route.size():
					_bound(u, _waypoint(u, i))
					ai["mode"] = "bound"
				else:
					ai["timer"] = randf_range(3.0, 6.0)
		"bound":
			if u.arrived:
				if i < route.size() and _near(u, _waypoint(u, i), 10.0):
					ai["i"] = i + 1
				ai["mode"] = "engage" if enemy != null else "advance"
				ai["timer"] = randf_range(5.0, 9.0)
		"hold":
			if u.arrived and not u.guarding:
				u.hold_position()


## Short rush towards goal, ending in the best cover near the landing point.
func _bound(u: Unit, goal: Vector3) -> void:
	var dir := Vector3(goal.x - u.position.x, 0.0, goal.z - u.position.z)
	var hop := u.position + dir.normalized() * minf(25.0, dir.length())
	u.order_move(battle.map.best_cover_near(hop, 4, {}))


func _decide_vehicle(u: VehicleUnit, enemy: Unit, enemy_d: float) -> void:
	var ai := u.ai
	var route: Array = ai["route"]
	var i: int = ai["i"]
	if u.gun_out and String(ai["mode"]) != "retreat":
		ai["mode"] = "retreat"
		u.order_move(ai["home"])
		return
	match String(ai["mode"]):
		"advance":
			var pushing := battle.time < float(ai["push_until"])
			if enemy != null and enemy_d < VEHICLE_ENGAGE * 0.9 and not pushing:
				u.order_stop()
				ai["mode"] = "overwatch"
				ai["timer"] = randf_range(8.0, 14.0)
			elif u.arrived:
				# Vehicles stop one waypoint short of the objective and support from there.
				var last := maxi(0, route.size() - 2)
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
				ai["mode"] = "advance"
				ai["push_until"] = battle.time + 8.0
