class_name MissionGen
extends RefCounted
## Procedural missions on a randomized steppe map: "defend", "assault" and "meeting".
## Everything is drawn from one seeded RandomNumberGenerator, so the same kind and
## seed always rebuild the same battle. The dict schema matches MissionTreeline.build().

const T := BattleMap.T

const VL_FIRST := ["Hill", "Farm", "Orchard", "Crossroads", "School", "Depot", "Mill", "Silo"]
const CARDINALS := ["North", "South", "East", "West"]
const VEHICLE_NAMES := {"ru_mtlb": "MT-LB", "ru_bmp2": "BMP-2", "ru_t72": "T-72B3"}
const INF_OFFSETS := [Vector3(-14, 0, 6), Vector3(14, 0, 6), Vector3(0, 0, 12), Vector3(-22, 0, 12)]


static func generate(kind: String, mission_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = mission_seed
	var m: Dictionary
	match kind:
		"assault":
			m = _assault(rng)
		"meeting":
			m = _meeting(rng)
		_:
			kind = "defend"
			m = _defend(rng)
	m["kind"] = kind
	m["seed"] = mission_seed
	return m


# --- The three kinds ---

static func _defend(rng: RandomNumberGenerator) -> Dictionary:
	# 8-10 min; every kind stays within the 10-minute battle cap (GDD 3.7b).
	var time_limit := 480.0 + 60.0 * rng.randi_range(0, 2)
	var vls := _make_vls(rng, Game.UA, 8.0, 46.0)
	var names := _vl_names(vls)
	var m := _base(rng, vls, Vector2(-70.0, 12.0), true)
	m["title"] = "%s DEFENSE" % String(names[1]).to_upper()
	m["briefing"] = "Zaporizhzhia direction. Your platoon holds %s, %s and %s. Drone recon reports an assault forming up to the north. Hold at least two of the three positions for %d minutes.\n\nTrees and trenches hide you; firing and moving give you away." % [names[0], names[1], names[2], int(time_limit / 60.0)]
	m["time_limit"] = time_limit
	var z_min := 120.0
	for vd: Array in vls:
		z_min = minf(z_min, (vd[1] as Vector3).z)
	m["deploy"] = Rect2(-118.0, z_min - 20.0, 236.0, 118.0 - (z_min - 20.0))
	m["ua_units"] = _ua_defenders(rng, vls)
	# 3-5 escalating attack waves from the north.
	var waves: Array = []
	var n := rng.randi_range(3, 5)
	var order := _shuffled(rng, [0, 1, 2])
	var msgs := ["Enemy mechanized assault from the north!", "Enemy moving on %s!", "Armour reported near %s!", "Large infantry assault forming up!"]
	for i in n:
		var vd: Array = vls[int(order[i % 3])]
		var goal: Vector3 = vd[1]
		var t := lerpf(25.0, time_limit * 0.7, float(i) / maxf(1.0, n - 1.0)) + rng.randf_range(-15.0, 15.0)
		var tier := float(i) / maxf(1.0, n - 1.0)
		var vid := "ru_mtlb" if tier < 0.25 else ("ru_t72" if tier > 0.65 and rng.randf() < 0.7 else "ru_bmp2")
		var units := _wave_units(rng, vid, 2 + (1 if tier > 0.5 else 0) + (1 if rng.randf() < 0.3 else 0), i * 4)
		var msg: String = msgs[mini(i, msgs.size() - 1)]
		if msg.contains("%s"):
			msg = msg % String(vd[0])
		waves.append(_wave(rng, maxf(15.0, t), goal, units, msg))
	waves.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["time"]) < float(b["time"]))
	m["waves"] = waves
	return m


static func _assault(rng: RandomNumberGenerator) -> Dictionary:
	# 9-10 min: the longest kind, pushed right up against the 10-minute cap.
	var time_limit := 540.0 + 60.0 * rng.randi_range(0, 1)
	var vls := _make_vls(rng, Game.RU, -78.0, -24.0)
	var names := _vl_names(vls)
	var m := _base(rng, vls, Vector2(-12.0, 52.0), true)
	m["title"] = "ASSAULT ON %s" % String(names[1]).to_upper()
	m["briefing"] = "The brigade is pushing north. Enemy infantry has dug in at %s, %s and %s. Take and hold at least two of the three positions before time runs out — %d minutes.\n\nThey hold in strength; expect a counterattack once you commit." % [names[0], names[1], names[2], int(time_limit / 60.0)]
	m["time_limit"] = time_limit
	m["deploy"] = Rect2(-118.0, 60.0, 236.0, 50.0)
	m["ua_units"] = _ua_attackers(rng, 74.0, 102.0)
	# Defenders hold each position from the first second; one counterattack later.
	var waves: Array = []
	var veh_vls := _shuffled(rng, [0, 1, 2])
	var veh_ids := ["ru_bmp2", "ru_t72" if rng.randf() < 0.6 else "ru_mtlb"]
	for j in 3:
		var pos: Vector3 = (vls[j] as Array)[1]
		var units: Array = []
		for k in rng.randi_range(1, 2):
			units.append(["ru_assault", "Defenders %d" % (j * 2 + k), Vector3(-8.0 + 16.0 * k, 0.0, rng.randf_range(-3.0, 3.0))])
		for v in 2:
			if int(veh_vls[v]) == j:
				units.append([veh_ids[v], String(VEHICLE_NAMES[veh_ids[v]]), Vector3(0.0, 0.0, -6.0)])
		var w := {"time": 0.0, "spawn": pos, "route": [pos], "hold": true, "units": units}
		if j == 0:
			w["msg"] = "Enemy holding the objectives in strength."
		waves.append(w)
	var ct := time_limit * rng.randf_range(0.42, 0.58)
	var target: Vector3 = (vls[rng.randi_range(0, 2)] as Array)[1]
	waves.append(_wave(rng, ct, target, _wave_units(rng, "ru_bmp2", rng.randi_range(2, 3), 90), "Enemy counterattack from the north!"))
	m["waves"] = waves
	return m


static func _meeting(rng: RandomNumberGenerator) -> Dictionary:
	# 8-10 min, within the 10-minute battle cap.
	var time_limit := 480.0 + 60.0 * rng.randi_range(0, 2)
	var vls := _make_vls(rng, -1, -50.0, -20.0)
	var names := _vl_names(vls)
	var m := _base(rng, vls, Vector2(-20.0, 55.0), false)
	m["title"] = "MEETING AT %s" % String(names[1]).to_upper()
	m["briefing"] = "Both sides are racing for the same ground: %s, %s and %s. Enemy lead elements are already moving south. Hold the majority of the positions when time runs out — %d minutes." % [names[0], names[1], names[2], int(time_limit / 60.0)]
	m["time_limit"] = time_limit
	m["deploy"] = Rect2(-118.0, 60.0, 236.0, 50.0)
	m["ua_units"] = _ua_attackers(rng, 88.0, 106.0)
	var waves: Array = []
	var n := rng.randi_range(3, 4)
	var order := _shuffled(rng, [0, 1, 2])
	var t := rng.randf_range(10.0, 30.0)
	for i in n:
		var vd: Array = vls[int(order[i % 3])]
		var vid := "ru_mtlb" if i == 0 else ("ru_t72" if i >= 2 and rng.randf() < 0.3 else "ru_bmp2")
		var msg := "Enemy racing for %s!" % String(vd[0]) if i == 0 else "More enemy moving on %s!" % String(vd[0])
		waves.append(_wave(rng, t, vd[1], _wave_units(rng, vid, rng.randi_range(2, 3), i * 4), msg))
		# Gaps compressed with the shorter battles so the last column still
		# arrives around 60-75% of the time limit.
		t += rng.randf_range(70.0, 110.0)
	m["waves"] = waves
	return m


# --- Victory locations and forces ---

## Three VLs spread across the map width inside a z band, with generated names.
static func _make_vls(rng: RandomNumberGenerator, owner: int, z0: float, z1: float) -> Array:
	var firsts := _shuffled(rng, VL_FIRST.duplicate())
	var out: Array = []
	var slots := [Vector2(-95, -45), Vector2(-25, 25), Vector2(45, 95)]
	for i in 3:
		var s: Vector2 = slots[i]
		var vl_name: String = firsts[i]
		if rng.randf() < 0.45:
			vl_name = "%s %s" % [CARDINALS[rng.randi_range(0, 3)], vl_name]
		out.append([vl_name, Vector3(rng.randf_range(s.x, s.y), 0.0, rng.randf_range(z0, z1)), owner])
	return out


static func _vl_names(vls: Array) -> Array:
	var out: Array = []
	for vd: Array in vls:
		out.append(vd[0])
	return out


## The standard UA platoon, deployed around the three positions it must hold.
static func _ua_defenders(rng: RandomNumberGenerator, vls: Array) -> Array:
	var p: Array[Vector3] = []
	for vd: Array in vls:
		p.append(vd[1])
	var cx := (p[0].x + p[1].x + p[2].x) / 3.0
	var out := [
		["ua_rifle", "1st Squad", p[0] + Vector3(rng.randf_range(-10, -4), 0, rng.randf_range(2, 8))],
		["ua_rifle", "2nd Squad", p[1] + Vector3(rng.randf_range(4, 10), 0, rng.randf_range(2, 8))],
		["ua_rifle", "3rd Squad", p[2] + Vector3(rng.randf_range(-8, 8), 0, rng.randf_range(2, 8))],
		["ua_mg", "MG Team", p[0] + Vector3(rng.randf_range(6, 12), 0, rng.randf_range(4, 9))],
		["ua_atgm", "Stugna", p[1] + Vector3(rng.randf_range(-12, -6), 0, rng.randf_range(4, 9))],
		["ua_sniper", "Sniper", p[2] + Vector3(rng.randf_range(-12, 12), 0, rng.randf_range(-4, 2))],
		["ua_drone", "Drone Team", Vector3(cx + rng.randf_range(-20, 20), 0, _max_z(p) + 26.0)],
		["ua_bradley", "Bradley", Vector3(cx + rng.randf_range(-15, 15), 0, _max_z(p) + 20.0)],
	]
	for ud: Array in out:
		var q: Vector3 = ud[2]
		ud[2] = Vector3(clampf(q.x, -110.0, 110.0), 0.0, clampf(q.z, -110.0, 110.0))
	return out


## The UA platoon lined up in the southern deploy strip for assault/meeting missions.
static func _ua_attackers(rng: RandomNumberGenerator, z0: float, z1: float) -> Array:
	var ids := [["ua_rifle", "1st Squad"], ["ua_rifle", "2nd Squad"], ["ua_rifle", "3rd Squad"],
		["ua_mg", "MG Team"], ["ua_atgm", "Stugna"], ["ua_sniper", "Sniper"],
		["ua_drone", "Drone Team"], ["ua_bradley", "Bradley"]]
	var out: Array = []
	for i in ids.size():
		var x := -84.0 + 24.0 * i + rng.randf_range(-6.0, 6.0)
		out.append([ids[i][0], ids[i][1], Vector3(clampf(x, -110.0, 110.0), 0.0, rng.randf_range(z0, z1))])
	return out


static func _max_z(points: Array[Vector3]) -> float:
	var z := -120.0
	for q in points:
		z = maxf(z, q.z)
	return z


## An attack wave from the north edge towards `goal`, with a drifting route.
static func _wave(rng: RandomNumberGenerator, time: float, goal: Vector3, units: Array, msg: String) -> Dictionary:
	var spawn := Vector3(clampf(goal.x + rng.randf_range(-45.0, 45.0), -100.0, 100.0), 0.0, -112.0)
	var route: Array = []
	for f: float in [0.3, 0.6, 0.85]:
		var q := spawn.lerp(goal, f)
		route.append(Vector3(clampf(q.x + rng.randf_range(-15.0, 15.0), -112.0, 112.0), 0.0, q.z))
	route.append(goal)
	return {"time": time, "spawn": spawn, "route": route, "units": units, "msg": msg}


## One vehicle leading `inf` assault groups, numbered from `tag` so names stay unique.
static func _wave_units(rng: RandomNumberGenerator, vehicle_id: String, inf: int, tag: int) -> Array:
	var units: Array = [[vehicle_id, String(VEHICLE_NAMES[vehicle_id]), Vector3.ZERO]]
	for k in mini(inf, INF_OFFSETS.size()):
		var off: Vector3 = INF_OFFSETS[k]
		units.append(["ru_assault", "Assault %d" % (tag + k + 1), off + Vector3(rng.randf_range(-2, 2), 0, 0)])
	return units


# --- Terrain ---

## Shared scenery: a terrain plan for the paint callable, plus hamlet buildings,
## wrecks and poles. `band` is the no-man's-land z range where craters cluster.
static func _base(rng: RandomNumberGenerator, vls: Array, band: Vector2, trenches: bool) -> Dictionary:
	var plan := {"fields": [], "trees": [], "gaps": [], "groves": [], "gullies": [], "roads": [], "trenches": [], "rubble": [], "craters": [], "craters_t": []}
	# Fields
	for i in rng.randi_range(2, 3):
		var x0 := rng.randf_range(-110.0, 30.0)
		var z0 := rng.randf_range(-110.0, 50.0)
		plan["fields"].append([x0, z0, x0 + rng.randf_range(40.0, 90.0), z0 + rng.randf_range(30.0, 60.0)])
	# Treelines (posadky) with gaps
	var tl_zs: Array = []
	for i in rng.randi_range(2, 4):
		if rng.randf() < 0.7:
			var z := rng.randf_range(-90.0, 70.0)
			var clear := true
			for other: float in tl_zs:
				if absf(z - other) < 18.0:
					clear = false
			if not clear:
				continue
			tl_zs.append(z)
			var x0 := rng.randf_range(-112.0, -60.0)
			var x1 := rng.randf_range(60.0, 112.0)
			plan["trees"].append([x0, z, x1, z + rng.randf_range(7.0, 10.0)])
			for g in rng.randi_range(1, 2):
				var gx := rng.randf_range(x0 + 15.0, x1 - 15.0)
				plan["gaps"].append([gx, z - 1.0, gx + rng.randf_range(8.0, 14.0), z + 11.0])
		else:
			var x := rng.randf_range(-100.0, 100.0)
			var za := rng.randf_range(-100.0, -20.0)
			plan["trees"].append([x, za, x + rng.randf_range(7.0, 9.0), za + rng.randf_range(50.0, 110.0)])
	for i in rng.randi_range(1, 2):
		plan["groves"].append([rng.randf_range(-100.0, 100.0), rng.randf_range(-90.0, 80.0), rng.randf_range(6.0, 10.0)])
	# Gullies
	for i in rng.randi_range(1, 2):
		var gx := rng.randf_range(-100.0, 100.0)
		plan["gullies"].append([gx, -120.0, gx + rng.randf_range(-25.0, 25.0), rng.randf_range(10.0, 110.0), rng.randf_range(6.0, 9.0)])
	# Roads: one north-south, sometimes one east-west
	var rx := rng.randf_range(-90.0, 90.0)
	plan["roads"].append([rx, -120.0, rx + rng.randf_range(-12.0, 12.0), 120.0, 5.0])
	if rng.randf() < 0.65:
		var rz := rng.randf_range(-60.0, 60.0)
		plan["roads"].append([-120.0, rz, 120.0, rz + rng.randf_range(-10.0, 10.0), 5.0])
	# Trenches dug in around the defended positions
	if trenches:
		for vd: Array in vls:
			var p: Vector3 = vd[1]
			var tz := p.z + rng.randf_range(4.0, 8.0)
			var half := rng.randf_range(10.0, 16.0)
			plan["trenches"].append([p.x - half, tz, p.x + half, tz])
			if rng.randf() < 0.5:
				plan["trenches"].append([p.x, tz, p.x + rng.randf_range(-6.0, 6.0), tz + 10.0])
	# A hamlet or farm huddled near one or two of the positions
	var buildings: Array = []
	var hamlet_vls := _shuffled(rng, [0, 1, 2])
	var n_hamlets := 1 if rng.randf() < 0.55 else 2
	var total := rng.randi_range(3, 8)
	for h in n_hamlets:
		var p: Vector3 = (vls[int(hamlet_vls[h])] as Array)[1]
		var count := total if n_hamlets == 1 else (total / 2 + (total % 2 if h == 0 else 0))
		_place_hamlet(rng, Vector2(p.x, p.z), count, plan, vls, buildings)
		plan["rubble"].append([p.x + rng.randf_range(-8.0, 8.0), p.z + rng.randf_range(-8.0, 8.0), rng.randf_range(2.0, 3.5)])
	# Shell craters, thickest in no-man's land
	for i in rng.randi_range(45, 80):
		plan["craters"].append([rng.randf_range(-110.0, 110.0), rng.randf_range(band.x, band.y), rng.randf_range(1.0, 2.5)])
	for i in rng.randi_range(12, 20):
		plan["craters_t"].append([rng.randf_range(-100.0, 100.0), rng.randf_range(-110.0, 110.0), rng.randf_range(1.0, 2.0)])
	# Wrecks of earlier fighting in the open, poles along the main road
	var wrecks: Array = []
	for i in rng.randi_range(2, 3):
		var kinds := ["bmp2", "t72", "mtlb"]
		wrecks.append([kinds[rng.randi_range(0, 2)], Vector3(rng.randf_range(-95.0, 95.0), 0.0, rng.randf_range(band.x, band.y)), rng.randf_range(-PI, PI)])
	var poles: Array = []
	var road: Array = plan["roads"][0]
	for f in [0.08, 0.22, 0.36, 0.5, 0.64, 0.78, 0.92]:
		if rng.randf() < 0.85:
			var px: float = lerpf(float(road[0]), float(road[2]), float(f)) - 4.0
			poles.append(Vector3(px, 0.0, lerpf(float(road[1]), float(road[3]), float(f))))
	return {
		"paint": func(map: BattleMap) -> void: _paint(map, plan),
		"vls": vls,
		"buildings": buildings,
		"wrecks": wrecks,
		"poles": poles,
	}


## Houses on even-metre rects around `center`, avoiding each other, roads, gullies
## and the flag itself, so the hamlet reads as a settlement instead of a pile.
static func _place_hamlet(rng: RandomNumberGenerator, center: Vector2, count: int, plan: Dictionary, vls: Array, buildings: Array) -> void:
	var placed := 0
	var tries := 0
	while placed < count and tries < 90:
		tries += 1
		var w := 2 * rng.randi_range(3, 6)
		var d := 2 * rng.randi_range(3, 5)
		var bx := _even(center.x + rng.randf_range(-22.0, 22.0) - w * 0.5)
		var bz := _even(center.y + rng.randf_range(-20.0, 20.0) - d * 0.5)
		var r := Rect2(bx, bz, w, d)
		if bx < -108 or bz < -108 or r.end.x > 108 or r.end.y > 108:
			continue
		var bad := false
		for other: Array in buildings:
			if r.grow(2.0).intersects(other[0]):
				bad = true
		for vd: Array in vls:
			var p: Vector3 = vd[1]
			if r.grow(4.0).has_point(Vector2(p.x, p.z)):
				bad = true
		for seg: Array in (plan["roads"] as Array) + (plan["gullies"] as Array):
			var a := Vector2(seg[0], seg[1])
			var b := Vector2(seg[2], seg[3])
			for s in 61:
				if r.grow(2.0).has_point(a.lerp(b, s / 60.0)):
					bad = true
					break
		if bad:
			continue
		buildings.append([r, snappedf(rng.randf_range(0.0, 0.6), 0.1), rng.randi_range(1, 9999), rng.randf() < 0.5])
		placed += 1


static func _paint(map: BattleMap, plan: Dictionary) -> void:
	for f: Array in plan["fields"]:
		map.paint_rect(f[0], f[1], f[2], f[3], T.FIELD)
	for t: Array in plan["trees"]:
		map.paint_rect(t[0], t[1], t[2], t[3], T.TREES)
	for g: Array in plan["gaps"]:
		map.paint_rect(g[0], g[1], g[2], g[3], T.OPEN)
	for g: Array in plan["groves"]:
		map.paint_disc(Vector2(g[0], g[1]), g[2], T.TREES)
	for g: Array in plan["gullies"]:
		map.paint_line(Vector2(g[0], g[1]), Vector2(g[2], g[3]), g[4], T.GULLY)
	for r: Array in plan["roads"]:
		map.paint_line(Vector2(r[0], r[1]), Vector2(r[2], r[3]), r[4], T.ROAD)
	for t: Array in plan["trenches"]:
		map.paint_line(Vector2(t[0], t[1]), Vector2(t[2], t[3]), 2.0, T.TRENCH)
	for r: Array in plan["rubble"]:
		map.paint_disc(Vector2(r[0], r[1]), r[2], T.RUBBLE)
	var soft := [T.OPEN, T.FIELD, T.ROAD]
	for c: Array in plan["craters"]:
		map.paint_disc(Vector2(c[0], c[1]), c[2], T.CRATER, soft)
	for c: Array in plan["craters_t"]:
		map.paint_disc(Vector2(c[0], c[1]), c[2], T.CRATER, soft + [T.TREES])


# --- Small helpers ---

static func _even(v: float) -> int:
	return int(round(v / 2.0)) * 2


static func _shuffled(rng: RandomNumberGenerator, arr: Array) -> Array:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
	return arr
