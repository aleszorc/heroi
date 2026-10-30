class_name Campaign
extends RefCounted
## The campaign (GDD §2b): one operation played as a run of battles along a front
## ribbon, generated from a single seed. The platoon roster is the save file: killed
## soldiers are gone (memorial), the wounded sit out a battle or two, replacements
## arrive green, squads gain veterancy. Requisition buys men and support charges.
##
## The state is one JSON-safe dictionary (user://campaign.json). JSON turns every
## number into a float, so all reads coerce through geti(). Balance lives in Defs.CAMPAIGN.

const SAVE_PATH := "user://campaign.json"
const VERSION := 1
## Game.UA, kept local so this data script compiles without autoloads (headless tests).
const UA := 0

## Fictional toponyms in the style of the curated scenarios (GDD tone rules).
const SECTOR_NAMES := [
	"Sukhyi Yar", "Topolyne", "Lysa Balka", "Verbovyi Kut", "Kamiani Stavky",
	"Zoriane", "Perepilky", "Dibrova", "Solone Pole", "Hlyboka Balka",
	"Malynove", "Zhytnie", "Stara Hreblia", "Vyshneve", "Kovylove",
	"Tyha Dolyna", "Horobyne", "Chornyi Shliakh", "Bile Pole", "Osokory",
	"Krynychne", "Zelenyi Hai", "Sivi Mohyly", "Yavorove",
]
const OP_NAMES := ["STEPPE WIND", "COLD DAWN", "IRON RESOLVE", "FIRST LIGHT", "HIGH GROUND", "QUIET THUNDER"]

const FIRST_NAMES := [
	"Andrii", "Bohdan", "Danylo", "Denys", "Dmytro", "Ihor", "Maksym", "Marko",
	"Mykola", "Nazar", "Oleh", "Oleksandr", "Orest", "Ostap", "Pavlo", "Petro",
	"Roman", "Serhii", "Stepan", "Taras", "Vasyl", "Viktor", "Volodymyr", "Yaroslav", "Yurii",
]
const LAST_NAMES := [
	"Boiko", "Bondarenko", "Havryliuk", "Honchar", "Kharchenko", "Kovalenko",
	"Kravchenko", "Kravets", "Lysenko", "Melnyk", "Moroz", "Oliinyk",
	"Polishchuk", "Rudenko", "Savchenko", "Shevchuk", "Sydorenko", "Tkachenko",
	"Zinchenko", "Hutsul", "Chornyi", "Vivcharyk", "Stelmakh", "Hajdamaka",
]

## The platoon a fresh operation starts with (matches the standard scenario platoon).
const START_ROSTER := [
	["ua_rifle", "1st Squad"], ["ua_rifle", "2nd Squad"], ["ua_rifle", "3rd Squad"],
	["ua_mg", "MG Team"], ["ua_atgm", "Stugna"], ["ua_sniper", "Sniper"],
	["ua_drone", "Drone Team"], ["ua_bradley", "Bradley"],
]


# --- State creation and persistence ---

static func generate(cseed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = cseed
	var names := _shuffled(rng, SECTOR_NAMES.duplicate())
	var n: int = rng.randi_range(int(Defs.CAMPAIGN["steps"][0]), int(Defs.CAMPAIGN["steps"][1]))
	var steps: Array = []
	var ni := 0
	for i in n:
		# The final sector is the operation objective: always a single assault.
		var count := 1 if i == n - 1 else (2 if rng.randf() < 0.7 else 1)
		var opts: Array = []
		for k in count:
			var kind := "assault" if (i == n - 1 or rng.randf() < 0.5) else ("town" if rng.randf() < 0.4 else "meeting")
			opts.append({"name": names[ni], "kind": kind, "seed": rng.randi_range(0, 999999)})
			ni += 1
		steps.append({"options": opts, "chosen": -1})
	var roster: Array = []
	for e: Array in START_ROSTER:
		roster.append(_new_unit(String(e[0]), String(e[1]), rng))
	return {
		"v": VERSION,
		"seed": cseed,
		"op_name": OP_NAMES[rng.randi_range(0, OP_NAMES.size() - 1)],
		"battle_n": 0,
		"taken": 0,
		"next_defend": false,
		"requisition": int(Defs.CAMPAIGN["start_requisition"]),
		"support": (Defs.CAMPAIGN["start_support"] as Dictionary).duplicate(),
		"steps": steps,
		"roster": roster,
		"memorial": [],
		"bought": {},
		"won": false,
		"lost": false,
	}


static func _new_unit(id: String, unit_name: String, rng: RandomNumberGenerator) -> Dictionary:
	var def: Dictionary = Defs.UNITS[id]
	if def.get("vehicle", false):
		return {"id": id, "name": unit_name, "vet": 0, "vehicle": true}
	var men: Array = []
	for w: String in def["men"]:
		men.append(_new_man(w, rng))
	return {"id": id, "name": unit_name, "vet": 0, "men": men}


static func _new_man(weapon: String, rng: RandomNumberGenerator) -> Dictionary:
	var nm := "%s %s" % [FIRST_NAMES[rng.randi_range(0, FIRST_NAMES.size() - 1)],
			LAST_NAMES[rng.randi_range(0, LAST_NAMES.size() - 1)]]
	return {"w": weapon, "name": nm, "battles": 0, "wounds": 0, "out": 0}


static func save_state(state: Dictionary) -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(state))


static func load_state() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary and geti(d, "v") == VERSION:
		return d
	return {}


static func delete_save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)


# --- The front ribbon ---

## The battle(s) the player may fight next: one defend after a loss, otherwise the
## 1-2 attack options of the current step (narrowed to the chosen one on a re-attack).
## Each entry: {step, opt, name, kind, seed, defend}.
static func next_options(state: Dictionary) -> Array:
	if state.get("won", false) or state.get("lost", false):
		return []
	var steps: Array = state["steps"]
	var taken := geti(state, "taken")
	if bool(state.get("next_defend", false)):
		# Counterattack on the last ground held (the start line when nothing is).
		var si := maxi(taken - 1, 0)
		var st: Dictionary = steps[si]
		var oi := maxi(geti(st, "chosen", -1), 0)
		var o: Dictionary = (st["options"] as Array)[oi]
		return [{"step": si, "opt": oi, "name": String(o["name"]), "kind": "defend", "seed": geti(o, "seed"), "defend": true}]
	var st: Dictionary = steps[taken]
	var chosen := geti(st, "chosen", -1)
	var out: Array = []
	var opts: Array = st["options"]
	for k in opts.size():
		if chosen >= 0 and k != chosen:
			continue
		var o: Dictionary = opts[k]
		out.append({"step": taken, "opt": k, "name": String(o["name"]), "kind": String(o["kind"]), "seed": geti(o, "seed"), "defend": false})
	return out


## Records the sector choice and marks the battle as pending; the caller sets
## Game.next_kind/next_seed and reloads the scene.
static func launch(state: Dictionary, option: Dictionary) -> void:
	if not bool(option["defend"]):
		var st: Dictionary = (state["steps"] as Array)[int(option["step"])]
		st["chosen"] = int(option["opt"])
	state["pending"] = option
	save_state(state)


static func battle_pending(state: Dictionary) -> bool:
	return not state.is_empty() and state.has("pending")


# --- Mission dressing: the campaign supplies the player force ---

## Replaces the generated mission's title, briefing, UA platoon and support stock
## with the campaign's. Positions come from the generated platoon (they are tuned
## per kind), taken in roster order; extra bought units reuse them with an offset.
static func dress_mission(mission: Dictionary, state: Dictionary) -> void:
	var pending: Dictionary = state["pending"]
	var sector := String(pending["name"])
	var kind := String(pending["kind"])
	var titles := {"assault": "TAKE %s", "meeting": "RACE FOR %s", "defend": "HOLD %s", "town": "HOLD %s"}
	mission["title"] = String(titles.get(kind, "BATTLE AT %s")) % sector.to_upper()
	var lead := "Operation %s, battle %d. " % [String(state["op_name"]).capitalize(), geti(state, "battle_n") + 1]
	lead += "The ground at %s was taken — now comes the counterattack." % sector if kind == "defend" or kind == "town" \
			else "The front runs to %s." % sector
	mission["briefing"] = lead + "\n\n" + String(mission["briefing"])
	var base: Array = mission["ua_units"]
	var out: Array = []
	var roster: Array = state["roster"]
	for ri in roster.size():
		var entry: Dictionary = roster[ri]
		var extra := {"roster_i": ri, "vet": geti(entry, "vet")}
		if entry.get("vehicle", false):
			out.append([String(entry["id"]), String(entry["name"]), _slot_pos(base, out.size()), extra])
			continue
		var idx := deploy_men_idx(entry)
		if idx.is_empty():
			continue
		var weapons: Array = []
		for mi: int in idx:
			weapons.append(String(((entry["men"] as Array)[mi] as Dictionary)["w"]))
		extra["men"] = weapons
		extra["men_idx"] = idx
		out.append([String(entry["id"]), String(entry["name"]), _slot_pos(base, out.size()), extra])
	mission["ua_units"] = out
	mission["support"] = {
		"mortar": geti(state["support"], "mortar"),
		"fpv": geti(state["support"], "fpv"),
		"bomber": geti(state["support"], "bomber"),
	}


static func _slot_pos(base: Array, j: int) -> Vector3:
	if j < base.size():
		return (base[j] as Array)[2]
	var p: Vector3 = (base[j % base.size()] as Array)[2] + Vector3(4.0 * (1 + j / base.size()), 0.0, 3.0)
	return Vector3(clampf(p.x, -110.0, 110.0), 0.0, clampf(p.z, -110.0, 110.0))


## Indices of a squad's men fit to deploy (not sitting a battle out wounded).
static func deploy_men_idx(entry: Dictionary) -> Array:
	var out: Array = []
	var men: Array = entry.get("men", [])
	for i in men.size():
		if geti(men[i], "out") <= 0:
			out.append(i)
	return out


# --- Debrief writer: folds a finished battle back into the state ---

## Returns a summary for the end screen: {rp, fallen: Array[String], front: String}.
static func apply_result(state: Dictionary, battle: Battle, victory: bool) -> Dictionary:
	var pending: Dictionary = state["pending"]
	var battle_label := "%s, battle %d" % [String(pending["name"]), geti(state, "battle_n") + 1]
	# Support charges are campaign ammunition: whatever was not spent comes home.
	state["support"] = {
		"mortar": battle.support.mortar_left,
		"fpv": battle.support.fpv_left,
		"bomber": battle.support.bomber_left,
	}
	var roster: Array = state["roster"]
	var fallen: Array = []
	var deployed := {}  # roster_i -> true
	var dead_vehicles: Array = []
	for u in battle.units:
		if u.side != UA or u.extra.is_empty():
			continue
		var ri := int(u.extra["roster_i"])
		deployed[ri] = true
		var entry: Dictionary = roster[ri]
		if u.is_vehicle:
			if u.state == Unit.State.DESTROYED:
				dead_vehicles.append(ri)
			else:
				entry["vet"] = geti(entry, "vet") + 1
			continue
		var men: Array = entry["men"]
		var men_idx: Array = u.extra["men_idx"]
		var dead_idx: Array = []
		var survived := false
		for k in (u as InfantryUnit).members.size():
			var s: Soldier = (u as InfantryUnit).members[k]
			var man: Dictionary = men[int(men_idx[k])]
			if s.killed or (not s.alive and not s.wounded):
				dead_idx.append(int(men_idx[k]))
			elif s.wounded and not s.alive and not s.stabilized and not victory:
				# Untreated and the field was lost: he could not be brought out.
				dead_idx.append(int(men_idx[k]))
			elif s.wounded:
				man["out"] = randi_range(int(Defs.CAMPAIGN["wounded_out"][0]), int(Defs.CAMPAIGN["wounded_out"][1]))
				man["wounds"] = geti(man, "wounds") + 1
				man["battles"] = geti(man, "battles") + 1
				survived = true
			else:
				man["battles"] = geti(man, "battles") + 1
				survived = true
		dead_idx.sort()
		dead_idx.reverse()
		for di: int in dead_idx:
			var man: Dictionary = men[di]
			fallen.append(String(man["name"]))
			(state["memorial"] as Array).append({"name": String(man["name"]), "unit": String(entry["name"]), "battle": battle_label})
			men.remove_at(di)
		if survived:
			entry["vet"] = geti(entry, "vet") + 1
	dead_vehicles.sort()
	dead_vehicles.reverse()
	for ri: int in dead_vehicles:
		roster.remove_at(ri)
	# Men who sat this one out heal one battle closer to returning.
	for ri in roster.size():
		if deployed.has(ri):
			continue
		for man: Dictionary in (roster[ri] as Dictionary).get("men", []):
			if geti(man, "out") > 0:
				man["out"] = geti(man, "out") - 1
	# Requisition income.
	var rp := geti(Defs.CAMPAIGN, "rp_battle") + battle.held_count(UA) * geti(Defs.CAMPAIGN, "rp_objective")
	if victory:
		rp += geti(Defs.CAMPAIGN, "rp_victory")
	state["requisition"] = geti(state, "requisition") + rp
	# The front shifts: a won attack opens the next sector, a lost defend gives
	# ground back, and any loss draws one counterattack battle.
	var front := ""
	var steps: Array = state["steps"]
	if victory:
		if not bool(pending["defend"]):
			state["taken"] = geti(state, "taken") + 1
			if geti(state, "taken") >= steps.size():
				state["won"] = true
				front = "The operation objective is taken."
			else:
				front = "%s is taken. The front moves forward." % String(pending["name"])
		else:
			front = "The counterattack is broken. %s holds." % String(pending["name"])
		state["next_defend"] = false
	else:
		if bool(pending["defend"]):
			state["taken"] = maxi(geti(state, "taken") - 1, 0)
			state["next_defend"] = false
			front = "%s is lost. The front bends back." % String(pending["name"])
		else:
			state["next_defend"] = true
			front = "The attack failed. Expect a counterattack."
	state["battle_n"] = geti(state, "battle_n") + 1
	state.erase("pending")
	if deployable_men(state) == 0 and geti(state, "requisition") < geti(Defs.CAMPAIGN, "cost_man"):
		state["lost"] = true
		front = "The platoon is combat-ineffective. The operation has failed."
	save_state(state)
	if OS.get_cmdline_user_args().has("log"):
		print("CAMPAIGN: +%d RP (%d total), fallen %d, taken %d/%d — %s" % [
			rp, geti(state, "requisition"), fallen.size(), geti(state, "taken"), steps.size(), front])
	return {"rp": rp, "fallen": fallen, "front": front}


# --- Queries and purchases (the between-battle screen) ---

## Men fit to fight right now, across the whole roster.
static func deployable_men(state: Dictionary) -> int:
	var n := 0
	for entry: Dictionary in state["roster"]:
		if entry.get("vehicle", false):
			continue
		n += deploy_men_idx(entry).size()
	return n


static func vet_level(battles: int) -> int:
	for i in Defs.VETERANCY.size():
		if battles >= int(Defs.VETERANCY[i][0]):
			return Defs.VETERANCY.size() - i
	return 0


## The first weapon slot of the squad template that is currently unfilled, or "".
static func missing_weapon(entry: Dictionary) -> String:
	var have := {}
	for man: Dictionary in entry.get("men", []):
		var w := String(man["w"])
		have[w] = int(have.get(w, 0)) + 1
	for w: String in (Defs.UNITS[String(entry["id"])] as Dictionary)["men"]:
		if int(have.get(w, 0)) > 0:
			have[w] = int(have[w]) - 1
		else:
			return w
	return ""


## Buys one green replacement into `entry`. Returns false if full or unaffordable.
static func buy_man(state: Dictionary, entry: Dictionary) -> bool:
	var w := missing_weapon(entry)
	if w == "" or geti(state, "requisition") < geti(Defs.CAMPAIGN, "cost_man"):
		return false
	state["requisition"] = geti(state, "requisition") - geti(Defs.CAMPAIGN, "cost_man")
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	(entry["men"] as Array).append(_new_man(w, rng))
	save_state(state)
	return true


static func buy_support(state: Dictionary, kind: String) -> bool:
	var cost := geti(Defs.CAMPAIGN["cost_support"], kind)
	if geti(state, "requisition") < cost:
		return false
	state["requisition"] = geti(state, "requisition") - cost
	(state["support"] as Dictionary)[kind] = geti(state["support"], kind) + 1
	save_state(state)
	return true


## Buys a whole new green unit (or a replacement Bradley).
static func buy_unit(state: Dictionary, id: String) -> bool:
	var cost := geti(Defs.CAMPAIGN["cost_unit"], id)
	if geti(state, "requisition") < cost:
		return false
	state["requisition"] = geti(state, "requisition") - cost
	var bought: Dictionary = state["bought"]
	bought[id] = geti(bought, id) + 1
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var unit_name := _reinforcement_name(state, id)
	(state["roster"] as Array).append(_new_unit(id, unit_name, rng))
	save_state(state)
	return true


## Disbanding (GDD §2b.3): the unit leaves the roster and refunds `disband_refund` of
## its purchase price (rounded down); the men bought into it refund nothing. Its
## survivors are not fallen, so they do not go to the memorial. The last unit can
## never be disbanded — the player must keep one deployable unit.
static func disband_refund(id: String) -> int:
	return int(floor(geti(Defs.CAMPAIGN["cost_unit"], id) * float(Defs.CAMPAIGN["disband_refund"])))


static func can_disband(state: Dictionary) -> bool:
	return (state["roster"] as Array).size() > 1


## Removes `entry` from the roster and refunds part of its price. Returns false
## when it is the last unit or not on the roster.
static func disband_unit(state: Dictionary, entry: Dictionary) -> bool:
	var roster: Array = state["roster"]
	var ri := roster.find(entry)
	if ri < 0 or not can_disband(state):
		return false
	roster.remove_at(ri)
	state["requisition"] = geti(state, "requisition") + disband_refund(String(entry["id"]))
	save_state(state)
	return true


## The lowest free name of the unit's kind ("3rd Squad", "MG Team 2"), so a unit
## bought after a disband does not duplicate a surviving one's name.
static func _reinforcement_name(state: Dictionary, id: String) -> String:
	var used := {}
	for entry: Dictionary in state["roster"]:
		used[String(entry["name"])] = true
	var base := String((Defs.UNITS[id] as Dictionary)["name"])
	for n in range(1, 100):
		var candidate: String
		if id == "ua_rifle":
			var suffix := "th"
			match n:
				1: suffix = "st"
				2: suffix = "nd"
				3: suffix = "rd"
			candidate = "%d%s Squad" % [n, suffix]
		else:
			candidate = base if n == 1 else "%s %d" % [base, n]
		if not used.has(candidate):
			return candidate
	return base


# --- Small helpers ---

## JSON parses every number as float; this coerces dictionary reads back to int.
static func geti(d: Dictionary, key: String, def := 0) -> int:
	return int(d.get(key, def))


static func _shuffled(rng: RandomNumberGenerator, arr: Array) -> Array:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
	return arr
