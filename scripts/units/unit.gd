class_name Unit
extends Node3D
## Base for anything that takes orders: infantry squads, teams and vehicles.
## Holds orders, morale, suppression and spotting state; subclasses move and shoot.

enum Order { NONE, MOVE, FAST, SNEAK, DEFEND, AMBUSH }

## Ambushers hold fire until an enemy comes this close (vehicles: AMBUSH_RANGE_VEHICLE),
## or until they are fired on.
const AMBUSH_RANGE := 60.0
const AMBUSH_RANGE_VEHICLE := 150.0
## Half-width of the fire arc shown for Defend and Ambush.
const GUARD_ARC := PI / 4.0
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

var order := Order.NONE
var path := PackedVector3Array()
var path_i := 0
var arrived := true
## Yaw in radians; 0 faces -Z (north, towards the enemy).
var heading := 0.0
var fire_target: Unit = null
var fire_point := Vector3.ZERO
var area_fire := false
## Facing chosen for Defend / Ambush (zero when not guarding).
var guard_dir := Vector3.ZERO

var suppression := 0.0
var morale := 70.0
var state := State.OK
var panic_time := 0.0
var since_suppressed := 99.0
var last_fired := -99.0
var last_moved := -99.0

## Spotting, indexed by observing side.
var seen: Array[bool] = [false, false]
var ever_seen: Array[bool] = [false, false]
var last_seen: Array[float] = [-99.0, -99.0]
var known_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var last_spot_check := 0.0

var selected := false
## Free-form state owned by EnemyAI.
var ai := {}
var smoke_left := 0
var kills := 0
## True once a routed unit has left the map.
var removed := false

var _label: Label3D
var _ghost: Label3D
var _label_tick := 0.0
var _pinned_msg_at := -99.0


func setup(b: Battle, id: String, s: int, pos: Vector3, unit_name: String) -> void:
	battle = b
	map = b.map
	def_id = id
	def = Defs.UNITS[id]
	side = s
	display_name = unit_name
	is_vehicle = def.get("vehicle", false)
	morale = def.get("morale", 70.0)
	smoke_left = def.get("smoke", 0)
	heading = PI if side == Game.RU else 0.0
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


func cover_here() -> float:
	return map.cover_at(position)


## How hard this unit is to spot right now, 0..1.
func conceal_value() -> float:
	var c := map.conceal_at(position)
	var t := battle.time
	if t - last_moved > 3.0:
		c = minf(0.92, c + 0.12)
	elif order == Order.FAST:
		c *= 0.5
	elif order == Order.SNEAK:
		c = minf(0.92, c + 0.1)
	if t - last_fired < 3.0:
		c *= 0.35
	elif order == Order.AMBUSH:
		c = minf(0.95, c + 0.15)
	return c


# --- State queries ---

## Holding a position facing a chosen direction (Defend or Ambush).
func is_guarding() -> bool:
	return order == Order.DEFEND or order == Order.AMBUSH

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


# --- Orders ---

func order_move(target: Vector3, mode: int) -> bool:
	if not can_move():
		return false
	return _set_path(target, mode)


func _set_path(target: Vector3, mode: int) -> bool:
	var p := map.find_path(position, target, is_vehicle)
	if p.is_empty():
		return false
	path = p
	path_i = 0
	order = mode
	arrived = false
	area_fire = false
	if mode == Order.FAST:
		fire_target = null
	_on_path_set(target)
	return true


func order_fire(t: Unit) -> void:
	if not is_targetable():
		return
	_halt()
	fire_target = t
	area_fire = false


func order_area_fire(p: Vector3) -> void:
	if not is_targetable():
		return
	_halt()
	fire_point = p
	area_fire = true
	fire_target = null


## Hold here facing `dir` (default: straight ahead). Ambush also holds fire and hides
## until the enemy walks into it.
func order_defend(dir := Vector3.ZERO, ambush := false) -> void:
	if not is_targetable():
		return
	_halt()
	order = Order.AMBUSH if ambush else Order.DEFEND
	dir.y = 0.0
	guard_dir = dir.normalized() if dir.length() > 0.1 else forward()
	if not is_vehicle:
		heading = yaw_to(guard_dir)
	fire_target = null
	area_fire = false
	_take_cover()


func order_stop() -> void:
	_halt()
	order = Order.NONE
	fire_target = null
	area_fire = false


func _halt() -> void:
	var was_moving := not arrived
	path = PackedVector3Array()
	path_i = 0
	arrived = true
	if not is_guarding():
		order = Order.NONE
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
	if not is_guarding():
		order = Order.NONE
	_take_cover()


# --- Morale ---

func receive_suppression(amount: float) -> void:
	if not is_targetable():
		return
	var scale := 0.15 if is_vehicle else 1.0 - cover_here() * 0.35
	suppression = minf(100.0, suppression + amount * scale)
	since_suppressed = 0.0


func morale_hit(amount: float) -> void:
	morale = maxf(0.0, morale - amount)


func _update_morale(dt: float) -> void:
	since_suppressed += dt
	if since_suppressed > 1.5:
		suppression = maxf(0.0, suppression - dt * (7.0 + 14.0 * cover_here()))
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
		if battle.time - _pinned_msg_at > 25.0:
			_pinned_msg_at = battle.time
			battle.notify(self, "%s is pinned down" % display_name, false)


func _panic() -> void:
	state = State.PANICKED
	panic_time = randf_range(7.0, 12.0)
	morale_hit(3.0)
	fire_target = null
	area_fire = false
	# In good cover men cower where they are; caught in the open they run for the rear.
	if cover_here() >= 0.4:
		_halt()
		battle.notify(self, "%s is cowering!" % display_name, true)
		return
	var dest := map.best_cover_near(position + _retreat_dir() * 22.0, 4, {})
	_set_path(dest, Order.FAST)
	battle.notify(self, "%s panics and falls back!" % display_name, true)


func _rout() -> void:
	state = State.ROUTED
	fire_target = null
	area_fire = false
	var edge := Vector3(position.x, 0.0, (BattleMap.HALF - 2.0) * (1.0 if side == Game.UA else -1.0))
	if not _set_path(edge, Order.FAST):
		removed = true
		_set_body_visible(false)
		battle.on_unit_lost(self)
	battle.notify(self, "%s is routing!" % display_name, true)


func _retreat_dir() -> Vector3:
	return Vector3(0.0, 0.0, 1.0) if side == Game.UA else Vector3(0.0, 0.0, -1.0)


# --- Simulation ---

func sim(dt: float) -> void:
	if removed or state == State.DESTROYED:
		return
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
	var ambushing := order == Order.AMBUSH and since_suppressed > 3.0
	if ambushing:
		rng = minf(rng, AMBUSH_RANGE_VEHICLE if is_vehicle else AMBUSH_RANGE)
	elif order == Order.SNEAK and not arrived:
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
		var score := d
		# Defenders prefer targets inside their arc.
		if is_guarding() and guard_dir != Vector3.ZERO:
			var to := Vector3(u.position.x - position.x, 0.0, u.position.z - position.z).normalized()
			if to.dot(guard_dir) < cos(GUARD_ARC):
				score += 80.0
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
	if best != null and order == Order.AMBUSH:
		# Sprung: from here on they fight as defenders.
		order = Order.DEFEND
		battle.notify(self, "%s springs the ambush!" % display_name, false)
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
				_label.text = display_name if state == State.OK else "%s\n%s" % [display_name, status_text()]
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
