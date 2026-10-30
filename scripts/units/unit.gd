class_name Unit
extends Node3D
## Base for anything that takes orders: infantry squads, teams and vehicles.
## The player and the AI give only destinations and targets; the unit itself picks
## its pace, its facing, when to hold fire and when to shift cover.

## How a unit moves; chosen by the unit from the situation, never by the player.
enum Pace { WALK, RUN, SNEAK }

## A unit holding fire stays hidden until an enemy comes this close
## (vehicles: AMBUSH_RANGE_VEHICLE), or until it is fired on.
const AMBUSH_RANGE := 60.0
const AMBUSH_RANGE_VEHICLE := 150.0
## Half-width of the guard fire arc.
const GUARD_ARC := PI / 4.0
## A known enemy within this range counts as contact for pace selection.
const CONTACT_RANGE := 200.0
enum State { OK, SUPPRESSED, PINNED, PANICKED, ROUTED, DESTROYED }

const STATE_NAMES: Array[String] = ["Ready", "Suppressed", "Pinned", "Panicked", "Routed", "Lost"]
const STATE_COLORS: Array[Color] = [Color(0.75, 0.92, 0.6), Color(1.0, 0.85, 0.35), Color(1.0, 0.58, 0.2), Color(1.0, 0.3, 0.25), Color(0.6, 0.6, 0.6), Color(0.45, 0.45, 0.45)]

var battle: Battle
var map: BattleMap
var side := 0
var def_id := ""
var def: Dictionary = {}
var display_name := ""
var is_vehicle := false

var pace := Pace.WALK
## Earliest sim time the pace may be re-picked (autonomous dashes lock the sprint in).
var pace_lock := 0.0
## Holding ground facing guard_dir; set automatically on arrival.
var guarding := true
## Concealed and unseen: hold fire until an enemy is in AMBUSH_RANGE or fires first.
var hold_fire := false
var path := PackedVector3Array()
var path_i := 0
var arrived := true
## Yaw in radians; 0 faces -Z (north, towards the enemy).
var heading := 0.0
var fire_target: Unit = null
## Facing being guarded (zero until first set).
var guard_dir := Vector3.ZERO

var suppression := 0.0
var morale := 70.0
var state := State.OK
var panic_time := 0.0
var since_suppressed := 99.0
var last_fired := -99.0
## Signature of the last shot (Defs.WEAPONS "signature"): how much it gave away.
var last_fired_sig := 1.0
var last_moved := -99.0
## The post a unit was holding when it broke, and its facing; it goes back there
## once the panic passes (INF / ZERO when there is none to go back to).
var _post := Vector3.INF
var _post_dir := Vector3.ZERO
var _returning := false

## Spotting, indexed by observing side.
var seen: Array[bool] = [false, false]
var ever_seen: Array[bool] = [false, false]
var last_seen: Array[float] = [-99.0, -99.0]
var known_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var last_spot_check := 0.0

var selected := false
## Free-form state owned by EnemyAI.
var ai := {}
## Campaign payload this unit was spawned with (roster index, men, veterancy);
## empty outside campaign battles. Read back by Campaign.apply_result.
var extra := {}
## Battles survived (campaign veterancy). Raises morale and suppression recovery,
## never accuracy (Defs.VETERANCY).
var vet := 0
var _supp_recover := 1.0
var smoke_left := 0
var kills := 0
## True once a routed unit has left the map.
var removed := false

var _label: Label3D
var _ghost: Label3D
var _label_tick := 0.0


func setup(b: Battle, id: String, s: int, pos: Vector3, unit_name: String, ex := {}) -> void:
	battle = b
	map = b.map
	def_id = id
	def = Defs.UNITS[id]
	side = s
	display_name = unit_name
	is_vehicle = def.get("vehicle", false)
	extra = ex
	vet = int(extra.get("vet", 0))
	morale = def.get("morale", 70.0)
	for lvl: Array in Defs.VETERANCY:
		if vet >= int(lvl[0]):
			morale += float(lvl[1])
			_supp_recover = float(lvl[2])
			break
	smoke_left = def.get("smoke", 0)
	heading = PI if side == Game.RU else 0.0
	guard_dir = forward()
	position = Vector3(pos.x, map.height_at(pos), pos.z)
	_build()
	_build_markers()


func _build_markers() -> void:
	_label = _make_label()
	_label.position.y = 5.5 if is_vehicle else 3.6
	add_child(_label)
	_ghost = _make_label()
	_ghost.top_level = true
	_ghost.text = "?"
	_ghost.font_size = 40
	_ghost.modulate = Color(1.0, 0.4, 0.35, 0.8)
	_ghost.visible = false
	add_child(_ghost)


static func _make_label() -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0022
	l.font_size = 26
	l.outline_size = 8
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	return l


# --- Overridden by subclasses ---

func _build() -> void:
	pass


func alive_count() -> int:
	return 0


func total_count() -> int:
	return 0


func aim_point() -> Vector3:
	return position + Vector3.UP


func take_hit(_pos: Vector3, _shooter: Unit) -> void:
	pass


func take_penetration(_pen: float, _src: Vector3, _top: bool, _shooter: Unit) -> void:
	pass


func apply_blast(_pos: Vector3, _radius: float, _lethal: float, _supp: float, _pen: float, _top: bool) -> void:
	pass


## How much of the target near p a shooter can hit (posture), 1 = fully exposed.
func exposure_at(_p: Vector3) -> float:
	return 1.0


func distance_to_point(p: Vector3) -> float:
	return Vector2(position.x - p.x, position.z - p.z).length()


func teleport(p: Vector3) -> void:
	position = Vector3(p.x, map.height_at(p), p.z)


func throw_smoke(_p: Vector3) -> bool:
	return false


func status_text() -> String:
	return STATE_NAMES[state]


func _speed() -> float:
	return Defs.WALK


func _sim_move(_dt: float) -> void:
	pass


func _sim_fire(_dt: float) -> void:
	pass


func _set_body_visible(_v: bool) -> void:
	pass


func _take_cover() -> void:
	pass


func _on_path_set(_target: Vector3) -> void:
	pass


func _can_drive() -> bool:
	return true


## A jolt of incoming suppression (already cover-scaled). Infantry dive on it.
func _on_incoming(_amount: float) -> void:
	pass


## Reached the end of a move path (not routing). Infantry leaders signal a halt.
func _on_arrived() -> void:
	pass


## Recovered to Ready after being pinned or panicked. Infantry leaders rally the men.
func _on_recovered() -> void:
	pass


func cover_here() -> float:
	return map.cover_at(position)


## How hard this unit is to spot right now, 0..1 (Defs.STEALTH).
func conceal_value() -> float:
	var st: Dictionary = Defs.STEALTH
	var c: float = map.conceal_at(position) + float(def.get("stealth", 0.0))
	var t := battle.time
	if t - last_moved > 3.0:
		c = minf(0.92, c + float(st["still_bonus"]))
	elif pace == Pace.RUN:
		c *= float(st["run_factor"])
	elif pace == Pace.SNEAK:
		c = minf(0.92, c + float(st["sneak_bonus"]))
	if t - last_fired < float(st["fire_time"]):
		# A rifle burst gives the position away; a lone suppressed shot far less.
		c *= lerpf(1.0, float(st["fire_factor"]), last_fired_sig)
	elif hold_fire:
		c = minf(0.95, c + float(st["ambush_bonus"]))
	return c


## Direction the unit's ground cover was taken against (BattleMap.cover_from);
## ZERO when it has no facing yet.
func cover_front() -> Vector3:
	return guard_dir


# --- State queries ---

## Holding a position facing guard_dir.
func is_guarding() -> bool:
	return arrived and guarding

func is_targetable() -> bool:
	return not removed and state != State.DESTROYED and alive_count() > 0


## Steady enough to hold ground and count towards victory locations.
func is_effective() -> bool:
	return is_targetable() and state < State.PANICKED


func can_move() -> bool:
	return is_targetable() and state < State.PINNED and _can_drive()


func forward() -> Vector3:
	return Vector3(-sin(heading), 0.0, -cos(heading))


static func yaw_to(v: Vector3) -> float:
	return atan2(-v.x, -v.z)


# --- Orders (only destinations and targets come from outside) ---

func order_move(target: Vector3) -> bool:
	if not can_move():
		return false
	_post = Vector3.INF
	return _set_path(target)


func _set_path(target: Vector3) -> bool:
	var p := map.find_path(position, target, is_vehicle)
	if p.is_empty():
		return false
	path = p
	path_i = 0
	arrived = false
	guarding = false
	hold_fire = false
	pace = _choose_pace()
	if pace == Pace.RUN:
		fire_target = null
	_on_path_set(target)
	return true


func order_fire(t: Unit) -> void:
	if not is_targetable():
		return
	_post = Vector3.INF
	_halt()
	fire_target = t
	hold_fire = false


## Hold here facing `dir` (default: towards the threat).
func hold_position(dir := Vector3.ZERO) -> void:
	if not is_targetable():
		return
	_post = Vector3.INF
	_halt()
	fire_target = null
	_guard(dir)


func order_stop() -> void:
	_post = Vector3.INF
	_halt()
	fire_target = null


## Settle into a guard facing: cover against it. Settling concealed and unseen with
## the enemy already close is an ambush: hold fire until they walk into it. With no
## enemy near there is nothing to spring, so the unit fires at will at full range.
func _guard(dir := Vector3.ZERO) -> void:
	guarding = true
	dir.y = 0.0
	guard_dir = dir.normalized() if dir.length() > 0.1 else _threat_dir()
	if not is_vehicle:
		heading = yaw_to(guard_dir)
	hold_fire = fire_target == null and not seen[1 - side] and conceal_value() >= 0.5 \
			and known_enemy_distance() < CONTACT_RANGE
	_take_cover()


func _halt() -> void:
	var was_moving := not arrived
	path = PackedVector3Array()
	path_i = 0
	arrived = true
	_returning = false
	if was_moving:
		_take_cover()


func _reach_end() -> void:
	arrived = true
	path = PackedVector3Array()
	path_i = 0
	if state == State.ROUTED:
		removed = true
		_set_body_visible(false)
		battle.on_unit_lost(self)
		return
	# Back at the post it broke from: settle in facing the way it did before.
	var back := _returning
	_returning = false
	if back:
		_post = Vector3.INF
	_guard(_post_dir if back else Vector3.ZERO)
	_on_arrived()


# --- Autonomy helpers ---

## Picks how to move from the situation; re-checked while moving (see pace_lock).
func _choose_pace() -> int:
	if state >= State.PANICKED:
		return Pace.RUN
	return Pace.RUN if known_enemy_distance() > CONTACT_RANGE else Pace.WALK


## Distance to the nearest recently-seen enemy, INF with no contact.
func known_enemy_distance() -> float:
	var best := INF
	for u in battle.units:
		if u.side == side or not u.is_targetable() or battle.time - u.last_seen[side] > 20.0:
			continue
		best = minf(best, u.known_pos[side].distance_to(position))
	return best


## Direction danger comes from: the nearest known enemy, or the enemy map edge.
func _threat_dir() -> Vector3:
	var best := INF
	var dir := Vector3(0.0, 0.0, -1.0 if side == Game.UA else 1.0)
	for u in battle.units:
		if u.side == side or not u.is_targetable() or battle.time - u.last_seen[side] > 20.0:
			continue
		var d := u.known_pos[side].distance_to(position)
		var to := Vector3(u.known_pos[side].x - position.x, 0.0, u.known_pos[side].z - position.z)
		if d < best and to.length() > 0.5:
			best = d
			dir = to.normalized()
	return dir


## The enemy FPV currently hunting this unit, close enough that dodging matters.
func incoming_fpv() -> Drone:
	for d in battle.drones:
		if d.fpv and d.side != side and not d.done and d.target == self \
				and Vector2(d.position.x - position.x, d.position.z - position.z).length() < 90.0:
			return d
	return null


# --- Morale ---

func receive_suppression(amount: float) -> void:
	if not is_targetable():
		return
	var scale := 0.15 if is_vehicle else 1.0 - cover_here() * float(Defs.SUPPRESSION["unit_cover"])
	suppression = minf(100.0, suppression + amount * scale)
	since_suppressed = 0.0
	_on_incoming(amount * scale)


func morale_hit(amount: float) -> void:
	morale = maxf(0.0, morale - amount)


func _update_morale(dt: float) -> void:
	since_suppressed += dt
	var recover := (7.0 + 14.0 * cover_here()) * _supp_recover
	if since_suppressed <= 1.5:
		# Still under fire: only men in cover keep their nerve, ducking between bursts.
		recover *= cover_here() * float(Defs.SUPPRESSION["under_fire"])
	suppression = maxf(0.0, suppression - dt * recover)
	if state == State.DESTROYED or state == State.ROUTED:
		return
	if morale <= 12.0:
		_rout()
		return
	if panic_time > 0.0:
		panic_time -= dt
		if panic_time > 0.0:
			return
		suppression = minf(suppression, 55.0)
		_rally()
	# Good troops shrug off more fire before breaking.
	var bonus := (morale - 60.0) * 0.3
	var prev := state
	if suppression > 90.0 + bonus:
		_panic()
		return
	elif suppression > 60.0 + bonus:
		state = State.PINNED
	elif suppression > 28.0 + bonus * 0.5:
		state = State.SUPPRESSED
	else:
		state = State.OK
	if state == State.PINNED and prev < State.PINNED:
		_take_cover()
	elif state == State.OK and prev >= State.PINNED:
		_on_recovered()


## Breaking (Defs.PANIC): men never run across a field. With any real cover against
## the threat they go to ground where they are; in the open they dash a few metres
## to the best cover close by. The post they were holding is remembered (_rally).
func _panic() -> void:
	var pn: Dictionary = Defs.PANIC
	state = State.PANICKED
	panic_time = randf_range(float(pn["time_min"]), float(pn["time_max"]))
	morale_hit(3.0)
	fire_target = null
	if is_guarding() and _post == Vector3.INF:
		_post = position
		_post_dir = guard_dir
	var threat_at := position + _threat_dir() * 30.0
	if map.cover_from(position, threat_at, cover_front()) >= float(pn["stay_cover"]):
		_halt()
		return
	var cells := maxi(1, int(round(float(pn["dash"]) / BattleMap.CELL)))
	var dest := map.best_cover_near(position + _retreat_dir() * float(pn["dash"]) * 0.5, cells, {}, threat_at)
	if map.cover_at(dest) > cover_here() + 0.1 and _set_path(dest):
		return
	_halt()


## The panic has passed: a unit that broke from a post crawls back to it and takes
## up its old facing again; one caught on the move just settles where it stopped.
func _rally() -> void:
	if _post == Vector3.INF:
		if arrived and not guarding:
			_guard()
		return
	if distance_to_point(_post) < 3.0:
		_halt()
		_guard(_post_dir)
		_post = Vector3.INF
	elif _set_path(_post):
		_returning = true
		pace = Pace.WALK
	else:
		_post = Vector3.INF
		_guard()


func _rout() -> void:
	state = State.ROUTED
	fire_target = null
	var edge := Vector3(position.x, 0.0, (BattleMap.HALF - 2.0) * (1.0 if side == Game.UA else -1.0))
	if not _set_path(edge):
		removed = true
		_set_body_visible(false)
		battle.on_unit_lost(self)


func _retreat_dir() -> Vector3:
	return Vector3(0.0, 0.0, 1.0) if side == Game.UA else Vector3(0.0, 0.0, -1.0)


# --- Simulation ---

func sim(dt: float) -> void:
	if removed or state == State.DESTROYED:
		return
	# A hidden ambusher that has been spotted gains nothing by waiting.
	if hold_fire and seen[1 - side]:
		hold_fire = false
	_update_morale(dt)
	if removed:
		return
	_sim_move(dt)
	_sim_fire(dt)


## Accuracy multiplier from state and movement.
func _accuracy() -> float:
	var a := 1.0
	match state:
		State.SUPPRESSED:
			a = 0.6
		State.PINNED:
			a = 0.3
	if not arrived:
		a *= 0.5
	elif is_guarding():
		a *= 1.1
	return a


## Best target for weapon `w` fired from `from`, or null. Respects the player's chosen target.
func pick_target(w: Dictionary, from: Vector3) -> Unit:
	if fire_target != null and _valid_target(fire_target, w, from):
		return fire_target
	var rng: float = w["range"]
	var holding := hold_fire and since_suppressed > 3.0
	if pace == Pace.SNEAK and not arrived:
		rng = minf(rng, 40.0)
	var at_only: bool = w.get("at_only", false)
	var pen: float = w["pen"]
	var blast: float = w["blast"]
	var best: Unit = null
	var best_score := INF
	for u in battle.units:
		if u.side == side or not u.is_targetable() or not u.seen[side]:
			continue
		var d := from.distance_to(u.position)
		if d > rng:
			continue
		# An ambusher lets infantry walk in close but takes a vehicle at longer range.
		if holding and d > (AMBUSH_RANGE_VEHICLE if u.is_vehicle else AMBUSH_RANGE):
			continue
		var score := d
		# Defenders prefer targets inside their arc.
		if is_guarding() and guard_dir != Vector3.ZERO:
			var to := Vector3(u.position.x - position.x, 0.0, u.position.z - position.z).normalized()
			if to.dot(guard_dir) < cos(GUARD_ARC):
				score += float(Defs.TARGETING["arc_out"])
		if not u.is_vehicle:
			# A lone man or a two-man team off in the distance is not worth the squad's fire.
			score += float(Defs.TARGETING["small_team"]) * maxf(0.0, 3.0 - u.alive_count())
		if u.is_vehicle:
			if pen <= 0.0:
				score += 400.0
			elif pen < u.armor_side() * 0.8:
				score += 300.0
			else:
				score -= 150.0
		else:
			if at_only:
				continue
			if pen > 0.0:
				if blast <= 0.0:
					continue
				score += 60.0
		if score < best_score:
			best_score = score
			best = u
	if best != null:
		# Springing the ambush: from here on it fights in the open.
		hold_fire = false
	return best


func _valid_target(t: Unit, w: Dictionary, from: Vector3) -> bool:
	if not t.is_targetable() or not t.seen[side]:
		return false
	if from.distance_to(t.position) > float(w["range"]):
		return false
	return t.is_vehicle or not w.get("at_only", false)


func armor_side() -> float:
	return 0.0


# --- Visuals ---

func is_shown() -> bool:
	return not removed and (side == Game.UA or seen[Game.UA])


func update_visuals(dt: float) -> void:
	var shown := is_shown()
	_set_body_visible(shown or (not removed and ever_seen[Game.UA] and alive_count() == 0))
	if side != Game.UA:
		var since := battle.time - last_seen[Game.UA]
		_ghost.visible = is_targetable() and not seen[Game.UA] and ever_seen[Game.UA] and since < 45.0
		if _ghost.visible:
			_ghost.global_position = known_pos[Game.UA] + Vector3.UP * 2.5
	_label_tick -= dt
	if _label_tick <= 0.0:
		_label_tick = 0.25
		if not shown or not is_targetable():
			_label.visible = false
		else:
			_label.visible = true
			if side == Game.UA:
				# State shows as label colour only; the full status text lives on the HUD card.
				_label.text = display_name
			else:
				_label.text = String(def["name"]) if is_vehicle else "Infantry"
	if not _label.visible:
		return
	# The selected unit's name turns yellow; otherwise the colour tracks state (or enemy red).
	if selected:
		_label.modulate = Color(1.0, 0.85, 0.25)
	elif side == Game.UA:
		_label.modulate = STATE_COLORS[state] if state != State.OK else Color(0.85, 0.92, 1.0)
	else:
		_label.modulate = Color(1.0, 0.5, 0.45)
