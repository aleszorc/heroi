class_name MissionGen
extends RefCounted
## Procedural missions on a randomized map: "defend", "assault", "meeting" and "town".
## Everything is drawn from one seeded RandomNumberGenerator, so the same kind and
## seed always rebuild the same battle. The dict schema matches MissionTreeline.build(),
## plus the per-seed enemy plan: wave "style"/"edge"/"comp"/"stop_at" hints for EnemyAI,
## "ru_support" (the Russian fire plan, Support.DEFAULT_RU schema), "plan" (the pattern
## name, for logs and briefings) and "season" (summer/autumn/winter/mud, rendered by
## MapView).

const T := BattleMap.T

const VL_FIRST := ["Hill", "Farm", "Orchard", "Crossroads", "School", "Depot", "Mill", "Silo"]
const TOWN_VL := ["Church", "School", "Market", "Station", "Clinic", "Square", "Bakery", "Culture House", "Council", "Garage"]
const TOWN_NAMES := ["Verbivka", "Kamianka", "Stepove", "Lypove", "Novoselivka", "Vyshneve", "Zelenyi Hai", "Sukhyi Yar"]
const CARDINALS := ["North", "South", "East", "West"]
const VEHICLE_NAMES := {"ru_mtlb": "MT-LB", "ru_bmp2": "BMP-2", "ru_t72": "T-72B3"}
const INF_OFFSETS := [Vector3(-14, 0, 6), Vector3(14, 0, 6), Vector3(0, 0, 12), Vector3(-22, 0, 12)]
## Minimum distance between victory location centres: the 16 m capture rings
## (VictoryLocation.RADIUS) must never touch.
const VL_MIN_DIST := 40.0
## How far a defender may be moved from its intended spot onto cover.
const SNAP_RANGE := 20.0
const SEASONS := ["summer", "summer", "summer", "autumn", "autumn", "autumn", "winter", "mud"]
const SEASON_LINES := {
	"summer": "High summer: full treelines and tall crops hide movement, but dust gives vehicles away.",
	"autumn": "Late autumn: thin treelines, bare fields and long sightlines.",
	"winter": "Winter: the ground is frozen hard and the snow shows every track.",
	"mud": "The thaw has turned every field to mud; vehicles keep to the roads.",
}


static func generate(kind: String, mission_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = mission_seed
	# The season comes from its own stream so maps found under a seed stay the same.
	var srng := RandomNumberGenerator.new()
	srng.seed = hash("season %d" % mission_seed)
	var season: String = SEASONS[srng.randi_range(0, SEASONS.size() - 1)]
	var m: Dictionary
	match kind:
		"assault":
			m = _assault(rng, season)
		"meeting":
			m = _meeting(rng, season)
		"town":
			m = _town(rng, season)
		_:
			kind = "defend"
			m = _defend(rng, season)
	m["kind"] = kind
	m["seed"] = mission_seed
	m["season"] = season
	m["briefing"] = String(m["briefing"]) + "\n\n" + String(SEASON_LINES[season])
	m["ru_support"] = _ru_support(rng, kind, m)
	if Game.has_arg("log"):
		var vl_text: Array = []
		for vd: Array in m["vls"]:
			vl_text.append("%s (%d, %d)" % [String(vd[0]), int((vd[1] as Vector3).x), int((vd[1] as Vector3).z)])
		print("Mission %s seed %d \"%s\" [%s, %s]: VLs %s; %d buildings; RU support %s" % [kind, mission_seed, String(m["title"]), String(m["plan"]), season,
				", ".join(PackedStringArray(vl_text)), (m["buildings"] as Array).size(), JSON.stringify(m["ru_support"])])
		var ua_text: Array = []
		for ud: Array in m["ua_units"]:
			ua_text.append("%s (%d, %d)" % [String(ud[1]), int((ud[2] as Vector3).x), int((ud[2] as Vector3).z)])
		print("UA platoon: %s" % ", ".join(PackedStringArray(ua_text)))
	return m


# --- The four kinds ---

static func _defend(rng: RandomNumberGenerator, season: String) -> Dictionary:
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
	m["ua_units"] = _ua_defenders(rng, vls, m["plan"], m["buildings"])
	_plan_defend(rng, m, vls, time_limit, season)
	return m


static func _assault(rng: RandomNumberGenerator, season: String) -> Dictionary:
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
	# Defenders hold each position from the first second; the reserve comes later.
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
				units.append([veh_ids[v], String(VEHICLE_NAMES[veh_ids[v]]), _clear_offset(pos, m["buildings"])])
		var w := {"time": 0.0, "spawn": pos, "route": [pos], "hold": true, "units": units, "style": "assault", "edge": "", "comp": "defenders"}
		if j == 0:
			w["msg"] = "Enemy holding the objectives in strength."
		waves.append(w)
	m["waves"] = waves
	_plan_assault(rng, m, vls, time_limit, season)
	return m


static func _meeting(rng: RandomNumberGenerator, season: String) -> Dictionary:
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
	_plan_meeting(rng, m, vls, time_limit, season)
	return m


## A village on a street grid: 12-20 houses along the streets, some already ruined,
## gardens instead of treelines, objectives on crossroads and public buildings.
## Held like a defend mission; the enemy comes house to house with more infantry.
static func _town(rng: RandomNumberGenerator, season: String) -> Dictionary:
	var time_limit := 480.0 + 60.0 * rng.randi_range(0, 2)
	var town_name: String = TOWN_NAMES[rng.randi_range(0, TOWN_NAMES.size() - 1)]
	var m := _town_base(rng)
	var vls: Array = m["vls"]
	var names := _vl_names(vls)
	m["title"] = town_name.to_upper()
	m["briefing"] = "The village of %s sits across the enemy axis. Your platoon holds the %s, the %s and the %s. Drone recon reports infantry massing in the fields to the north. Hold at least two of the three positions for %d minutes.\n\nWalls stop bullets and hide you; every street is a fire lane for whoever reaches it first." % [town_name, names[0], names[1], names[2], int(time_limit / 60.0)]
	m["time_limit"] = time_limit
	var z_min := 120.0
	for vd: Array in vls:
		z_min = minf(z_min, (vd[1] as Vector3).z)
	m["deploy"] = Rect2(-118.0, z_min - 22.0, 236.0, 118.0 - (z_min - 22.0))
	_plan_town(rng, m, vls, time_limit, season)
	return m


# --- Victory locations and forces ---

## Three VLs spread across the map width inside a z band, with generated names.
## Neighbouring centres are kept at least VL_MIN_DIST apart so the rings never touch.
static func _make_vls(rng: RandomNumberGenerator, owner: int, z0: float, z1: float) -> Array:
	var firsts := _shuffled(rng, VL_FIRST.duplicate())
	var out: Array = []
	var slots := [Vector2(-95, -45), Vector2(-25, 25), Vector2(45, 95)]
	for i in 3:
		var s: Vector2 = slots[i]
		var vl_name: String = firsts[i]
		if rng.randf() < 0.45:
			vl_name = "%s %s" % [CARDINALS[rng.randi_range(0, 3)], vl_name]
		var p := Vector3(rng.randf_range(s.x, s.y), 0.0, rng.randf_range(z0, z1))
		if i > 0:
			var prev: Vector3 = (out[i - 1] as Array)[1]
			if Vector2(p.x - prev.x, p.z - prev.z).length() < VL_MIN_DIST:
				# Slots are 20 m apart at worst, so pushing east always fits the slot.
				p.x = minf(s.y, prev.x + VL_MIN_DIST)
		out.append([vl_name, p, owner])
	return out


## First spot around `pos` that is not inside a house (a vehicle must never spawn in one).
static func _clear_offset(pos: Vector3, buildings: Array) -> Vector3:
	for off: Vector3 in [Vector3(0, 0, -6), Vector3(0, 0, 8), Vector3(-10, 0, -4), Vector3(10, 0, -4), Vector3(0, 0, -14), Vector3(-14, 0, 6), Vector3(14, 0, 6)]:
		var q := Vector2(pos.x + off.x, pos.z + off.z)
		var clear := true
		for b: Array in buildings:
			if (b[0] as Rect2).grow(3.0).has_point(q):
				clear = false
		if clear:
			return off
	return Vector3(0, 0, -20)


static func _vl_names(vls: Array) -> Array:
	var out: Array = []
	for vd: Array in vls:
		out.append(vd[0])
	return out


## The standard UA platoon, deployed around the three positions it must hold. Every
## infantry team is then snapped onto cover from the terrain plan within SNAP_RANGE
## of its intended spot: squads and the MG team into the nearest trench (or house),
## the sniper and drone team into a treeline or grove, failing that a trench end or
## a house. Trenches run south of the flags, so a unit on one faces north by default
## (Unit._threat_dir) with the parapet towards the attack. The Bradley is nudged out
## of any house footprint.
static func _ua_defenders(rng: RandomNumberGenerator, vls: Array, plan: Dictionary = {}, buildings: Array = []) -> Array:
	var p: Array[Vector3] = []
	for vd: Array in vls:
		p.append(vd[1])
	var cx := (p[0].x + p[1].x + p[2].x) / 3.0
	# One squad per flag and one support team per flag, each pairing and flank drawn
	# from the seed, so the platoon is not laid out the same way every battle.
	var sq := _shuffled(rng, [0, 1, 2])
	var tm := _shuffled(rng, [0, 1, 2])
	var out := [
		["ua_rifle", "1st Squad", p[sq[0]] + Vector3(_flank(rng, 4, 10), 0, rng.randf_range(2, 8))],
		["ua_rifle", "2nd Squad", p[sq[1]] + Vector3(_flank(rng, 4, 10), 0, rng.randf_range(2, 8))],
		["ua_rifle", "3rd Squad", p[sq[2]] + Vector3(_flank(rng, 4, 10), 0, rng.randf_range(2, 8))],
		["ua_mg", "MG Team", p[tm[0]] + Vector3(_flank(rng, 6, 12), 0, rng.randf_range(4, 9))],
		["ua_atgm", "Stugna", p[tm[1]] + Vector3(_flank(rng, 6, 12), 0, rng.randf_range(4, 9))],
		["ua_sniper", "Sniper", p[tm[2]] + Vector3(rng.randf_range(-12, 12), 0, rng.randf_range(-4, 2))],
		["ua_drone", "Drone Team", Vector3(cx + rng.randf_range(-20, 20), 0, _max_z(p) + 26.0)],
		["ua_bradley", "Bradley", Vector3(cx + rng.randf_range(-15, 15), 0, _max_z(p) + 20.0)],
	]
	for ud: Array in out:
		var q: Vector3 = ud[2]
		ud[2] = Vector3(clampf(q.x, -110.0, 110.0), 0.0, clampf(q.z, -110.0, 110.0))
	var taken: Array = []
	for ud: Array in out:
		var q: Vector3 = ud[2]
		var snapped := Vector3.INF
		match String(ud[0]):
			"ua_rifle", "ua_mg", "ua_atgm":
				snapped = _nearest_trench(q, plan, false)
				if snapped == Vector3.INF:
					snapped = _nearest_house(q, buildings, taken)
			"ua_sniper", "ua_drone":
				snapped = _nearest_trees(q, plan)
				if snapped == Vector3.INF:
					snapped = _nearest_trench(q, plan, true)
				if snapped == Vector3.INF:
					snapped = _nearest_house(q, buildings, taken)
			"ua_bradley":
				snapped = _outside_houses(q, buildings)
		if snapped != Vector3.INF:
			q = snapped
		# Two teams snapped onto the same spot spread out along the line.
		for other: Vector3 in taken:
			if Vector2(q.x - other.x, q.z - other.z).length() < 5.0:
				q.x += 6.0
		taken.append(q)
		ud[2] = Vector3(clampf(q.x, -110.0, 110.0), 0.0, clampf(q.z, -110.0, 110.0))
	return out


## Random offset of lo..hi m to either side.
static func _flank(rng: RandomNumberGenerator, lo: float, hi: float) -> float:
	return rng.randf_range(lo, hi) * (1.0 if rng.randf() < 0.5 else -1.0)


## Nearest point on a trench line of the plan (or a trench end) within SNAP_RANGE.
static func _nearest_trench(q: Vector3, plan: Dictionary, ends_only: bool) -> Vector3:
	var best := Vector3.INF
	var best_d := SNAP_RANGE
	var q2 := Vector2(q.x, q.z)
	for seg: Array in plan.get("trenches", []):
		var a := Vector2(seg[0], seg[1])
		var b := Vector2(seg[2], seg[3])
		var cands: Array = [a, b]
		if not ends_only:
			var ab := b - a
			var t := 0.5 if ab.length_squared() < 0.01 else clampf((q2 - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
			cands = [a + ab * t]
		for c: Vector2 in cands:
			var d := c.distance_to(q2)
			if d < best_d:
				best_d = d
				best = Vector3(c.x, 0.0, c.y)
	return best


## Nearest treeline or grove cell within SNAP_RANGE, kept out of the treeline gaps.
static func _nearest_trees(q: Vector3, plan: Dictionary) -> Vector3:
	var best := Vector3.INF
	var best_d := SNAP_RANGE
	var q2 := Vector2(q.x, q.z)
	for t: Array in plan.get("trees", []):
		var r := Rect2(float(t[0]), float(t[1]), float(t[2]) - float(t[0]), float(t[3]) - float(t[1])).grow(-1.5)
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		var c := Vector2(clampf(q2.x, r.position.x, r.end.x), clampf(q2.y, r.position.y, r.end.y))
		for g: Array in plan.get("gaps", []):
			var gr := Rect2(float(g[0]), float(g[1]), float(g[2]) - float(g[0]), float(g[3]) - float(g[1])).grow(2.0)
			if gr.has_point(c):
				c.x = clampf(gr.position.x if c.x - gr.position.x < gr.end.x - c.x else gr.end.x, r.position.x, r.end.x)
		var d := c.distance_to(q2)
		if d < best_d:
			best_d = d
			best = Vector3(c.x, 0.0, c.y)
	for g: Array in plan.get("groves", []):
		var centre := Vector2(g[0], g[1])
		var inner := maxf(0.5, float(g[2]) - 1.5)
		var c := q2
		if centre.distance_to(q2) > inner:
			c = centre + (q2 - centre).normalized() * inner
		var d := c.distance_to(q2)
		if d < best_d:
			best_d = d
			best = Vector3(c.x, 0.0, c.y)
	return best


## Centre of the nearest house within SNAP_RANGE not already held by another team
## (infantry can hold a house).
static func _nearest_house(q: Vector3, buildings: Array, taken: Array) -> Vector3:
	var best := Vector3.INF
	var best_d := SNAP_RANGE
	var q2 := Vector2(q.x, q.z)
	for b: Array in buildings:
		var r: Rect2 = b[0]
		var used := false
		for other: Vector3 in taken:
			if r.has_point(Vector2(other.x, other.z)):
				used = true
		if used:
			continue
		var near := Vector2(clampf(q2.x, r.position.x, r.end.x), clampf(q2.y, r.position.y, r.end.y))
		var d := near.distance_to(q2)
		if d < best_d:
			best_d = d
			best = Vector3(r.get_center().x, 0.0, r.get_center().y)
	return best


## `q` itself unless it lies in a house footprint; then the first clear spot around it.
static func _outside_houses(q: Vector3, buildings: Array) -> Vector3:
	for off: Vector3 in [Vector3.ZERO, Vector3(0, 0, 8), Vector3(0, 0, -8), Vector3(10, 0, 0), Vector3(-10, 0, 0), Vector3(0, 0, 16), Vector3(14, 0, 8), Vector3(-14, 0, 8)]:
		var c := Vector2(q.x + off.x, q.z + off.z)
		var clear := true
		for b: Array in buildings:
			if (b[0] as Rect2).grow(3.0).has_point(c):
				clear = false
		if clear:
			return q + off
	return q


## The UA platoon lined up in the southern deploy strip for assault/meeting missions,
## in a seeded random order along the line. The list order stays fixed: the campaign
## hands out these slots by index (Campaign._slot_pos).
static func _ua_attackers(rng: RandomNumberGenerator, z0: float, z1: float) -> Array:
	var ids := [["ua_rifle", "1st Squad"], ["ua_rifle", "2nd Squad"], ["ua_rifle", "3rd Squad"],
		["ua_mg", "MG Team"], ["ua_atgm", "Stugna"], ["ua_sniper", "Sniper"],
		["ua_drone", "Drone Team"], ["ua_bradley", "Bradley"]]
	var slots := _shuffled(rng, range(ids.size()))
	var out: Array = []
	for i in ids.size():
		var x := -84.0 + 24.0 * int(slots[i]) + rng.randf_range(-6.0, 6.0)
		out.append([ids[i][0], ids[i][1], Vector3(clampf(x, -110.0, 110.0), 0.0, rng.randf_range(z0, z1))])
	return out


static func _max_z(points: Array[Vector3]) -> float:
	var z := -120.0
	for q in points:
		z = maxf(z, q.z)
	return z


# --- Enemy plan: patterns, edges, routes, compositions, styles ---
#
# Each kind rolls a named pattern, then builds its waves from a short list of
# [time fraction, composition, style, edge, route style] entries. Everything is
# drawn from the mission rng, so the plan is part of the seed.
#
# comp:  mech (vehicle + 2-3 groups), probe (2 groups, no vehicle), armour (2 vehicles
#        + 1 group), dismount (3-4 groups, MT-LB behind), tank (lone T-72), feint
#        (vehicle + 1 group that halts short)
# style: EnemyAI.STYLES key. edge: n / ne / nw / e / w. route: direct / hook / road / gully.

static func _plan_defend(rng: RandomNumberGenerator, m: Dictionary, vls: Array, time_limit: float, season: String) -> void:
	var pattern: String = ["drumbeat", "lull_push", "early_rush", "steady"][rng.randi_range(0, 3)]
	var entries: Array = []
	match pattern:
		"drumbeat":
			# Even beats, one of them heavier; the first is often a probe.
			var n := rng.randi_range(4, 5)
			var heavy := rng.randi_range(1, n - 2)
			for i in n:
				var comp := "mech"
				if i == 0 and rng.randf() < 0.5:
					comp = "probe"
				elif i == heavy:
					comp = "armour" if rng.randf() < 0.5 else "dismount"
				elif i == n - 1 and rng.randf() < 0.4:
					comp = "dismount"
				var frac := lerpf(0.05, 0.7, float(i) / (n - 1.0)) + rng.randf_range(-0.03, 0.03)
				var edge := "n"
				if i > 0 and rng.randf() < 0.35:
					edge = ["ne", "nw", "e", "w"][rng.randi_range(0, 3)]
				entries.append([frac, comp, "probe" if comp == "probe" else ("flank" if edge in ["e", "w"] else "assault"), edge, ""])
		"lull_push":
			# A probe, a long quiet, then everything at once from two directions.
			entries.append([0.05, "probe", "probe", "n", ""])
			entries.append([rng.randf_range(0.2, 0.28), "tank" if rng.randf() < 0.5 else "feint", "overwatch", "n", "direct"])
			var push := rng.randf_range(0.48, 0.56)
			entries.append([push, "armour", "rush", "n", "road"])
			entries.append([push + rng.randf_range(0.04, 0.08), "dismount", "assault", "ne" if rng.randf() < 0.5 else "nw", "hook"])
			if rng.randf() < 0.6:
				entries.append([rng.randf_range(0.74, 0.8), "mech", "assault", "n", ""])
		"early_rush":
			# A hard MT-LB rush just after the first minute with a flank probe on
			# its heels, then they regroup; the armour keeps its later slot.
			entries.append([rng.randf_range(0.11, 0.14), "mech", "rush", "n", "road" if rng.randf() < 0.5 else "direct"])
			entries.append([rng.randf_range(0.17, 0.23), "probe", "flank", "ne" if rng.randf() < 0.5 else "nw", "direct"])
			if rng.randf() < 0.5:
				entries.append([rng.randf_range(0.28, 0.34), "tank", "overwatch", "n", "direct"])
			entries.append([rng.randf_range(0.42, 0.5), "armour", "assault", "n", ""])
			entries.append([rng.randf_range(0.66, 0.74), "dismount", "flank", "e" if rng.randf() < 0.5 else "w", "direct"])
		_:
			# Steady mechanized pressure, the last column round a corner.
			var n := rng.randi_range(3, 4)
			for i in n:
				var comp := "dismount" if rng.randf() < 0.35 else "mech"
				var frac := lerpf(0.08, 0.65, float(i) / (n - 1.0)) + rng.randf_range(-0.04, 0.04)
				var edge := "n"
				if i == n - 1:
					edge = "ne" if rng.randf() < 0.5 else "nw"
				entries.append([frac, comp, "assault", edge, ""])
			if rng.randf() < 0.4:
				entries.append([rng.randf_range(0.3, 0.5), "feint", "feint", "w" if rng.randf() < 0.5 else "e", "direct"])
	var msgs := ["Enemy mechanized assault from the north!", "Enemy moving on %s!", "Armour reported near %s!", "Large infantry assault forming up!"]
	m["plan"] = pattern
	m["waves"] = _build_waves(rng, m, vls, time_limit, entries, msgs, season, 4)


static func _plan_assault(rng: RandomNumberGenerator, m: Dictionary, vls: Array, time_limit: float, season: String) -> void:
	var pattern: String = ["counter", "reinforce", "flank_counter", "tank_overwatch"][rng.randi_range(0, 3)]
	var entries: Array = []
	match pattern:
		"counter":
			entries.append([rng.randf_range(0.42, 0.58), "armour" if rng.randf() < 0.4 else "mech", "rush" if rng.randf() < 0.4 else "assault", "n" if rng.randf() < 0.6 else ("ne" if rng.randf() < 0.5 else "nw"), ""])
		"reinforce":
			# Fresh infantry joins the defence early; the counterattack comes late.
			entries.append([rng.randf_range(0.2, 0.3), "probe", "probe", "n", "road"])
			entries.append([rng.randf_range(0.58, 0.66), "mech", "assault", "n", ""])
		"flank_counter":
			entries.append([rng.randf_range(0.4, 0.5), "armour" if rng.randf() < 0.5 else "mech", "flank", "e" if rng.randf() < 0.5 else "w", "direct"])
		_:
			entries.append([rng.randf_range(0.25, 0.35), "tank", "overwatch", "n", "direct"])
			entries.append([rng.randf_range(0.58, 0.66), "dismount", "assault", "n", ""])
	m["plan"] = pattern
	var waves: Array = m["waves"]
	waves.append_array(_build_waves(rng, m, vls, time_limit, entries, ["Enemy counterattack from the north!", "More enemy moving on %s!"], season))
	m["waves"] = waves


static func _plan_meeting(rng: RandomNumberGenerator, m: Dictionary, vls: Array, time_limit: float, season: String) -> void:
	var pattern: String = ["columns", "race", "echelon"][rng.randi_range(0, 2)]
	var entries: Array = []
	var t := rng.randf_range(10.0, 30.0) / time_limit
	match pattern:
		"columns":
			# Three or four mechanized columns, evenly spaced, one from a corner.
			var n := rng.randi_range(3, 4)
			for i in n:
				var edge := "n"
				if i == n - 1:
					edge = "ne" if rng.randf() < 0.5 else "nw"
				entries.append([t, "mech", "rush" if i == 0 else "assault", edge, "road" if i == 1 else ""])
				t += rng.randf_range(70.0, 110.0) / time_limit
		"race":
			# A fast probe grabs ground, armour follows, infantry fills in late.
			entries.append([t, "probe", "rush", "n", "road"])
			entries.append([t + rng.randf_range(40.0, 70.0) / time_limit, "armour", "assault", "n", ""])
			entries.append([t + rng.randf_range(150.0, 200.0) / time_limit, "dismount", "assault", "ne" if rng.randf() < 0.5 else "nw", "hook"])
			if rng.randf() < 0.5:
				entries.append([t + rng.randf_range(260.0, 320.0) / time_limit, "mech", "assault", "n", ""])
		_:
			# Echelon: a lead column, a tank in overwatch behind it, then two more.
			entries.append([t, "mech", "assault", "n", ""])
			entries.append([t + rng.randf_range(50.0, 80.0) / time_limit, "tank", "overwatch", "n", "direct"])
			entries.append([t + rng.randf_range(120.0, 160.0) / time_limit, "mech", "assault", "n", "hook"])
			entries.append([t + rng.randf_range(220.0, 280.0) / time_limit, "feint" if rng.randf() < 0.4 else "dismount", "feint" if rng.randf() < 0.4 else "assault", "ne" if rng.randf() < 0.5 else "nw", "direct"])
	m["plan"] = pattern
	m["waves"] = _build_waves(rng, m, vls, time_limit, entries, ["Enemy racing for %s!", "More enemy moving on %s!"], season)


static func _plan_town(rng: RandomNumberGenerator, m: Dictionary, vls: Array, time_limit: float, season: String) -> void:
	var pattern: String = ["house_to_house", "street_rush", "encircle"][rng.randi_range(0, 2)]
	var entries: Array = []
	match pattern:
		"house_to_house":
			entries.append([0.05, "probe", "probe", "n", "road"])
			entries.append([rng.randf_range(0.18, 0.24), "dismount", "assault", "n", "road"])
			entries.append([rng.randf_range(0.36, 0.42), "mech", "assault", "ne" if rng.randf() < 0.5 else "nw", "direct"])
			entries.append([rng.randf_range(0.54, 0.6), "dismount", "assault", "n", ""])
			if rng.randf() < 0.5:
				entries.append([rng.randf_range(0.7, 0.76), "mech", "rush", "n", "road"])
		"street_rush":
			entries.append([0.04, "mech", "rush", "n", "road"])
			entries.append([rng.randf_range(0.1, 0.16), "probe", "rush", "n", "direct"])
			entries.append([rng.randf_range(0.3, 0.36), "tank", "overwatch", "n", "road"])
			entries.append([rng.randf_range(0.5, 0.58), "dismount", "assault", "ne" if rng.randf() < 0.5 else "nw", "hook"])
			entries.append([rng.randf_range(0.7, 0.76), "probe", "probe", "n", ""])
		_:
			# Encircle: probes from both flanks pin the edges, the main body comes down the road.
			entries.append([0.06, "probe", "probe", "n", "direct"])
			entries.append([rng.randf_range(0.2, 0.26), "dismount", "flank", "e" if rng.randf() < 0.5 else "w", "direct"])
			entries.append([rng.randf_range(0.3, 0.36), "probe", "flank", "w" if String(entries[1][3]) == "e" else "e", "direct"])
			entries.append([rng.randf_range(0.5, 0.58), "mech", "assault", "n", "road"])
			if rng.randf() < 0.5:
				entries.append([rng.randf_range(0.68, 0.74), "probe", "probe", "n", ""])
	m["plan"] = pattern
	m["waves"] = _build_waves(rng, m, vls, time_limit, entries, ["Enemy infantry entering the village from the north!", "Enemy moving on the %s!", "Armour reported near the %s!", "Enemy infantry pushing house to house!"], season)


## Turns plan entries into wave dicts: goal VLs cycle in a shuffled order, times are
## fractions of the time limit, routes and spawn points follow the entry's edge and
## route style. In mud every wave with a vehicle keeps to the road where it can.
static func _build_waves(rng: RandomNumberGenerator, m: Dictionary, vls: Array, time_limit: float, entries: Array, msgs: Array, season: String, inf_cap := 3) -> Array:
	var waves: Array = []
	var order := _shuffled(rng, [0, 1, 2])
	var tag := 0
	for i in entries.size():
		var e: Array = entries[i]
		var vd: Array = vls[int(order[i % 3])]
		var goal: Vector3 = vd[1]
		var comp := String(e[1])
		var style := String(e[2])
		var edge := String(e[3])
		var route_style := String(e[4])
		var tier := clampf(float(e[0]) / 0.7, 0.0, 1.0)
		if route_style == "":
			route_style = ["direct", "direct", "hook", "road", "gully"][rng.randi_range(0, 4)]
		if season == "mud" and comp in ["mech", "armour", "feint"] and edge == "n" and rng.randf() < 0.7:
			route_style = "road"
		if edge in ["e", "w"] and route_style != "direct":
			route_style = "direct"
		var spawn := _spawn_at(rng, edge, goal, m, route_style)
		var route := _route(rng, route_style, spawn, goal, m)
		var units := _comp_units(rng, comp, tier, tag, edge)
		while _group_count(units) > inf_cap:
			units.pop_back()
		tag += units.size()
		for e2: Array in units:
			# Flank columns form up along the edge: keep every man on the map.
			var q: Vector3 = spawn + (e2[2] as Vector3)
			e2[2] = Vector3(clampf(q.x, -114.0, 114.0), 0.0, clampf(q.z, -114.0, 114.0)) - spawn
		var msg: String = msgs[mini(i, msgs.size() - 1)]
		if msg.contains("%s"):
			msg = msg % String(vd[0])
		var w := {"time": maxf(15.0, float(e[0]) * time_limit + rng.randf_range(-8.0, 8.0)), "spawn": spawn, "route": route,
				"units": units, "msg": msg, "style": style, "edge": edge, "comp": comp}
		if style in ["overwatch", "feint"]:
			w["stop_at"] = maxi(1, route.size() - 3)
		waves.append(w)
	waves.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["time"]) < float(b["time"]))
	return waves


## Where a wave enters: the north edge above the goal (or where the road/gully
## meets it), a north corner, or partway down the east/west edge for a flank.
static func _spawn_at(rng: RandomNumberGenerator, edge: String, goal: Vector3, m: Dictionary, route_style: String) -> Vector3:
	match edge:
		"ne":
			return Vector3(rng.randf_range(78.0, 102.0), 0.0, -108.0)
		"nw":
			return Vector3(rng.randf_range(-102.0, -78.0), 0.0, -108.0)
		"e":
			return Vector3(98.0, 0.0, clampf(goal.z - rng.randf_range(30.0, 70.0), -88.0, 30.0))
		"w":
			return Vector3(-98.0, 0.0, clampf(goal.z - rng.randf_range(30.0, 70.0), -88.0, 30.0))
	var x := clampf(goal.x + rng.randf_range(-45.0, 45.0), -100.0, 100.0)
	if route_style == "road" and not (m.get("roads", []) as Array).is_empty():
		var r: Array = (m["roads"] as Array)[0]
		x = clampf(_x_on(r, -112.0) + 3.0, -100.0, 100.0)
	elif route_style == "gully" and not (m.get("gullies", []) as Array).is_empty():
		var g: Array = (m["gullies"] as Array)[0]
		x = clampf(float(g[0]), -100.0, 100.0)
	return Vector3(x, 0.0, -112.0)


## x of a line segment [x0, z0, x1, z1, ...] at height z.
static func _x_on(seg: Array, z: float) -> float:
	var z0 := float(seg[1])
	var z1 := float(seg[3])
	if absf(z1 - z0) < 0.01:
		return float(seg[0])
	return lerpf(float(seg[0]), float(seg[2]), clampf((z - z0) / (z1 - z0), 0.0, 1.0))


## Route styles: direct (drifting straight line), hook (swing wide and come in from a
## flank), road / gully (follow the first north-south one while it leads roughly
## towards the goal, then cut across). Every route ends on the goal.
static func _route(rng: RandomNumberGenerator, style: String, spawn: Vector3, goal: Vector3, m: Dictionary) -> Array:
	var route: Array = []
	match style:
		"hook":
			var s := -1.0 if goal.x > 0.0 else 1.0
			if absf(goal.x) < 30.0:
				s = -1.0 if rng.randf() < 0.5 else 1.0
			var wide := clampf(goal.x + s * rng.randf_range(50.0, 75.0), -108.0, 108.0)
			route.append(Vector3(lerpf(spawn.x, wide, 0.5), 0.0, lerpf(spawn.z, goal.z, 0.3)))
			route.append(Vector3(wide, 0.0, goal.z - rng.randf_range(25.0, 45.0)))
			route.append(Vector3(clampf(goal.x + s * rng.randf_range(20.0, 30.0), -110.0, 110.0), 0.0, goal.z - rng.randf_range(4.0, 12.0)))
		"road", "gully":
			var key := "roads" if style == "road" else "gullies"
			var segs: Array = m.get(key, [])
			if not segs.is_empty():
				var seg: Array = segs[0]
				var z_end := minf(goal.z - 30.0, float(seg[3]))
				var z := spawn.z + 35.0
				while z < z_end and route.size() < 5:
					route.append(Vector3(clampf(_x_on(seg, z) + 3.0, -112.0, 112.0), 0.0, z))
					z += rng.randf_range(30.0, 45.0)
				if not route.is_empty():
					var last: Vector3 = route[route.size() - 1]
					if absf(last.x - goal.x) > 70.0:
						route.clear()
	if route.is_empty():
		for f: float in [0.3, 0.6, 0.85]:
			var q := spawn.lerp(goal, f)
			route.append(Vector3(clampf(q.x + rng.randf_range(-15.0, 15.0), -112.0, 112.0), 0.0, q.z))
	route.append(goal)
	return route


## Units of one wave by composition archetype. Formation offsets assume a column
## heading south; waves entering from the east or west edge get them rotated.
static func _comp_units(rng: RandomNumberGenerator, comp: String, tier: float, tag: int, edge: String) -> Array:
	var units: Array = []
	var inf := 0
	match comp:
		"probe":
			inf = 2
		"armour":
			units.append([_vehicle_id(rng, maxf(tier, 0.3)), "", Vector3(-10.0, 0.0, 0.0)])
			units.append(["ru_t72" if rng.randf() < 0.5 else "ru_bmp2", "", Vector3(12.0, 0.0, 4.0)])
			inf = 1
		"dismount":
			inf = rng.randi_range(3, 4)
			if rng.randf() < 0.6:
				units.append(["ru_mtlb", "", Vector3(0.0, 0.0, 18.0)])
		"tank":
			units.append(["ru_t72", "", Vector3.ZERO])
		"feint":
			units.append(["ru_bmp2" if rng.randf() < 0.5 else "ru_mtlb", "", Vector3.ZERO])
			inf = 1
		_:
			units.append([_vehicle_id(rng, tier), "", Vector3.ZERO])
			inf = 2 + (1 if tier > 0.5 else 0) + (1 if rng.randf() < 0.3 else 0)
	for k in mini(inf, INF_OFFSETS.size()):
		var off: Vector3 = INF_OFFSETS[k]
		units.append(["ru_assault", "Assault %d" % (tag + k + 1), off + Vector3(rng.randf_range(-2, 2), 0, 0)])
	for e: Array in units:
		if String(e[1]) == "":
			e[1] = String(VEHICLE_NAMES[e[0]])
		var off: Vector3 = e[2]
		if edge == "e":
			e[2] = Vector3(off.z, 0.0, off.x)
		elif edge == "w":
			e[2] = Vector3(-off.z, 0.0, off.x)
	return units


static func _group_count(units: Array) -> int:
	var n := 0
	for e: Array in units:
		if String(e[0]) == "ru_assault":
			n += 1
	return n


static func _vehicle_id(rng: RandomNumberGenerator, tier: float) -> String:
	if tier < 0.25:
		return "ru_mtlb"
	if tier > 0.65 and rng.randf() < 0.7:
		return "ru_t72"
	return "ru_bmp2"


## The Russian fire plan (schema in Support.DEFAULT_RU). The prep barrage lands where
## the Russians expect us: the held positions when we defend, the forming-up strip
## when we attack, the contested middle when both race — or not at all. Cadences
## and first-strike times vary with a per-seed intensity.
static func _ru_support(rng: RandomNumberGenerator, kind: String, m: Dictionary) -> Dictionary:
	var intensity := rng.randf_range(0.7, 1.3)
	var vls: Array = m["vls"]
	var lo := Vector2(999.0, 999.0)
	var hi := Vector2(-999.0, -999.0)
	for vd: Array in vls:
		var p: Vector3 = vd[1]
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
	var band: Rect2
	var modes: Array
	match kind:
		"assault":
			band = Rect2(-100.0, 66.0, 200.0, 40.0)
			modes = ["none", "none", "none", "short", "short", "late", "late"]
		"meeting":
			band = Rect2(lo.x - 25.0, lo.y - 10.0, hi.x - lo.x + 50.0, hi.y - lo.y + 20.0)
			modes = ["none", "none", "none", "late", "late", "short"]
		_:
			# Trenches lie 4-8 m south of the flags: the band covers flags and trenches.
			band = Rect2(lo.x - 25.0, lo.y - 6.0, hi.x - lo.x + 50.0, hi.y - lo.y + 20.0)
			modes = ["none", "short", "short", "full", "full", "full", "late"]
	var mode: String = modes[rng.randi_range(0, modes.size() - 1)]
	var shells := {"none": 0, "short": 5, "full": 10, "late": 8}
	var prep := {"mode": mode, "shells": int(shells[mode]), "band": band,
			"at": rng.randf_range(60.0, 200.0) if mode == "late" else 8.0}
	if mode == "short" and kind == "meeting":
		# A short stonk on the approach from our deploy strip, not on the flags.
		prep["band"] = Rect2(-90.0, 20.0, 180.0, 30.0)
	if kind == "assault" and mode != "none":
		# The start line is registered: the briefing warns, and the first rounds
		# give the player half a minute to get off it.
		prep["at"] = rng.randf_range(28.0, 45.0) if mode == "short" else float(prep["at"])
		m["briefing"] = String(m["briefing"]) + "\n\nThe enemy has our start line registered. Do not linger on it."
	var fpv_min := rng.randf_range(30.0, 50.0) / intensity
	var arty_min := rng.randf_range(90.0, 140.0) / intensity
	var recon_min := rng.randf_range(50.0, 70.0)
	return {
		"prep": prep,
		"fpv": {"first": rng.randf_range(50.0, 150.0) / intensity, "min": fpv_min, "max": fpv_min + rng.randf_range(15.0, 30.0)},
		"arty": {"first": rng.randf_range(100.0, 260.0) / intensity, "min": arty_min, "max": arty_min + rng.randf_range(30.0, 60.0),
			"shells": clampi(int(round(rng.randf_range(4.0, 7.0) * intensity)), 4, 8)},
		"recon": {"first": rng.randf_range(20.0, 70.0), "min": recon_min, "max": recon_min + 20.0},
		"intensity": intensity,
	}


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
		"roads": plan["roads"],
		"gullies": plan["gullies"],
		"plan": plan,
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
		if not _house_fits(r, plan, vls, buildings, []):
			continue
		buildings.append([r, snappedf(rng.randf_range(0.0, 0.6), 0.1), rng.randi_range(1, 9999), rng.randf() < 0.5])
		placed += 1


## A house rect is valid when it is on the map and clear of other houses, flags,
## roads, gullies and any `keep_clear` points (unit spawns).
static func _house_fits(r: Rect2, plan: Dictionary, vls: Array, buildings: Array, keep_clear: Array) -> bool:
	if r.position.x < -108 or r.position.y < -108 or r.end.x > 108 or r.end.y > 108:
		return false
	for other: Array in buildings:
		if r.grow(2.0).intersects(other[0]):
			return false
	for vd: Array in vls:
		var p: Vector3 = vd[1]
		if r.grow(4.0).has_point(Vector2(p.x, p.z)):
			return false
	for q: Vector2 in keep_clear:
		if r.grow(3.0).has_point(q):
			return false
	for seg: Array in (plan["roads"] as Array) + (plan["gullies"] as Array):
		var a := Vector2(seg[0], seg[1])
		var b := Vector2(seg[2], seg[3])
		for s in 61:
			if r.grow(2.0).has_point(a.lerp(b, s / 60.0)):
				return false
	return true


## Village scenery: a street grid (main street, two or three cross streets, a side
## lane), houses along every street, gardens, rubble, craters and the fields beyond.
## Objectives sit on crossroads and public buildings, at least VL_MIN_DIST apart.
static func _town_base(rng: RandomNumberGenerator) -> Dictionary:
	var plan := {"fields": [], "trees": [], "gaps": [], "groves": [], "gullies": [], "roads": [], "trenches": [], "rubble": [], "craters": [], "craters_t": []}
	# Fields around the village, a treeline to the north now and then
	plan["fields"].append([-115.0, -115.0, 115.0, rng.randf_range(-80.0, -65.0)])
	plan["fields"].append([-115.0, rng.randf_range(60.0, 75.0), 115.0, 115.0])
	if rng.randf() < 0.5:
		var z := rng.randf_range(-100.0, -85.0)
		var x0 := rng.randf_range(-112.0, -40.0)
		plan["trees"].append([x0, z, x0 + rng.randf_range(60.0, 120.0), z + 8.0])
	# Streets: a main street north-south through the middle, cross streets, a lane
	var rx := rng.randf_range(-30.0, 30.0)
	var main := [rx, -120.0, rx + rng.randf_range(-8.0, 8.0), 120.0, 6.0]
	plan["roads"].append(main)
	var cross_zs: Array = []
	var slots := [Vector2(-52.0, -34.0), Vector2(-12.0, 12.0), Vector2(32.0, 50.0)]
	for s: Vector2 in slots:
		if cross_zs.size() < 2 or rng.randf() < 0.6:
			cross_zs.append(rng.randf_range(s.x, s.y))
	for z: float in cross_zs:
		plan["roads"].append([-120.0, z, 120.0, z + rng.randf_range(-4.0, 4.0), 5.0])
	var lane_side := -1.0 if rng.randf() < 0.5 else 1.0
	var lane_x := rx + lane_side * rng.randf_range(40.0, 58.0)
	var lane_z0: float = cross_zs[0] - rng.randf_range(0.0, 20.0)
	var lane_z1: float = cross_zs[cross_zs.size() - 1] + rng.randf_range(10.0, 30.0)
	plan["roads"].append([lane_x, lane_z0, lane_x + rng.randf_range(-4.0, 4.0), lane_z1, 4.0])
	# Objectives: crossroads and public buildings, far enough apart
	var cands: Array = []
	for z: float in cross_zs:
		cands.append(Vector2(_x_on(main, z), z))
		cands.append(Vector2(lane_x, z))
	var z_mid: float = (float(cross_zs[0]) + float(cross_zs[1])) * 0.5
	cands.append(Vector2(_x_on(main, z_mid) + 14.0, z_mid))
	cands.append(Vector2(rx - lane_side * rng.randf_range(30.0, 50.0), rng.randf_range(-20.0, 30.0)))
	cands = _shuffled(rng, cands)
	var vls: Array = []
	var vl_names := _shuffled(rng, TOWN_VL.duplicate())
	for c: Vector2 in cands:
		if vls.size() >= 3:
			break
		var ok := absf(c.x) < 96.0 and absf(c.y) < 60.0
		for vd: Array in vls:
			var p: Vector3 = vd[1]
			if Vector2(p.x - c.x, p.z - c.y).length() < VL_MIN_DIST:
				ok = false
		if ok:
			vls.append([vl_names[vls.size()], Vector3(c.x, 0.0, c.y), Game.UA])
	while vls.size() < 3:
		# Should not happen with four or more candidates, but never ship fewer than three.
		var fallback := _make_vls(rng, Game.UA, -30.0, 30.0)
		for vd: Array in fallback:
			if vls.size() < 3:
				vls.append(vd)
	# Houses along every street, both sides, in walking distance of each other
	var buildings: Array = []
	var target := rng.randi_range(12, 20)
	var streets: Array = plan["roads"]
	var tries := 0
	while buildings.size() < target and tries < 400:
		tries += 1
		var seg: Array = streets[rng.randi_range(0, streets.size() - 1)]
		var vertical := absf(float(seg[3]) - float(seg[1])) > absf(float(seg[2]) - float(seg[0]))
		var w := 2 * rng.randi_range(3, 6)
		var d := 2 * rng.randi_range(3, 5)
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var setback := float(seg[4]) * 0.5 + rng.randf_range(3.0, 6.0)
		var r: Rect2
		if vertical:
			var z := rng.randf_range(maxf(float(seg[1]), -70.0), minf(float(seg[3]), 70.0))
			var x := _x_on(seg, z) + side * setback
			r = Rect2(_even(x - (w if side < 0.0 else 0.0)), _even(z - d * 0.5), w, d)
		else:
			var x := rng.randf_range(-95.0, 95.0)
			var z := lerpf(float(seg[1]), float(seg[3]), (x + 120.0) / 240.0) + side * setback
			r = Rect2(_even(x - w * 0.5), _even(z - (d if side < 0.0 else 0.0)), w, d)
		if not _house_fits(r, plan, vls, buildings, []):
			continue
		buildings.append([r, snappedf(rng.randf_range(0.0, 0.8), 0.1), rng.randi_range(1, 9999), rng.randf() < 0.5])
	# The platoon, each team snapped into the nearest house
	var ua_units := _ua_defenders(rng, vls, plan, buildings)
	# Rubble beside the worst ruins, gardens behind the houses
	for b: Array in buildings:
		var r: Rect2 = b[0]
		if float(b[1]) >= 0.5 and rng.randf() < 0.7:
			plan["rubble"].append([r.get_center().x + rng.randf_range(-6.0, 6.0), r.get_center().y + rng.randf_range(-6.0, 6.0), rng.randf_range(2.0, 3.5)])
	for i in rng.randi_range(4, 7):
		plan["groves"].append([rng.randf_range(-100.0, 100.0), rng.randf_range(-60.0, 60.0), rng.randf_range(3.0, 6.0)])
	# A gully along one map edge
	if rng.randf() < 0.6:
		var gx := 100.0 if lane_side < 0.0 else -100.0
		plan["gullies"].append([gx, -120.0, gx + rng.randf_range(-10.0, 10.0), rng.randf_range(20.0, 100.0), rng.randf_range(6.0, 8.0)])
	# Craters: the northern approaches and the village itself
	for i in rng.randi_range(30, 50):
		plan["craters"].append([rng.randf_range(-110.0, 110.0), rng.randf_range(-100.0, -40.0), rng.randf_range(1.0, 2.5)])
	for i in rng.randi_range(15, 25):
		plan["craters_t"].append([rng.randf_range(-100.0, 100.0), rng.randf_range(-60.0, 60.0), rng.randf_range(1.0, 2.0)])
	# Wrecks in the northern fields, poles along the main street
	var wrecks: Array = []
	for i in rng.randi_range(2, 3):
		var kinds := ["bmp2", "t72", "mtlb"]
		wrecks.append([kinds[rng.randi_range(0, 2)], Vector3(rng.randf_range(-95.0, 95.0), 0.0, rng.randf_range(-100.0, -45.0)), rng.randf_range(-PI, PI)])
	var poles: Array = []
	for f in [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95]:
		if rng.randf() < 0.85:
			var pz := lerpf(float(main[1]), float(main[3]), float(f))
			poles.append(Vector3(_x_on(main, pz) - 4.0, 0.0, pz))
	return {
		"paint": func(map: BattleMap) -> void: _paint(map, plan),
		"vls": vls,
		"ua_units": ua_units,
		"buildings": buildings,
		"wrecks": wrecks,
		"poles": poles,
		"roads": plan["roads"],
		"gullies": plan["gullies"],
		"plan": plan,
	}


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
