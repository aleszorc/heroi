class_name InfantryUnit
extends Unit
## A squad or team. A leader point follows the path, the soldiers steer after it in loose
## formation, and on halting each man picks cover against the threat and a fitting stance.
##
## Men also act on their own: in contact the moving fire team sprints man by man to its
## next cover; riflemen lob grenades at close enemies; and when someone goes down wounded,
## the nearest free comrade runs over, drags him into cover and gives first aid.
##
## The squad fights without micromanagement: it picks its own pace (run out of contact,
## creep when closing unseen, walk and bound in a firefight), guards facing the threat on
## arrival, holds fire while hidden, pops smoke when pinned in the open, scrambles away
## from an FPV hunting it, and shifts a few metres to better cover under sustained fire.

## Situational formations, picked from context while moving (see _choose_formation):
## WEDGE in the open, COLUMN through trees/trenches and when running or sneaking,
## LINE when assaulting a known enemy, DISPERSED under artillery or suppression,
## STACK on the approach to a building entrance.
enum Form { WEDGE, COLUMN, LINE, DISPERSED, STACK }

const SMOKE_RANGE := 40.0
## How often a halted squad re-checks that its cover still faces the threat.
const COVER_RECHECK := 5.0
## Bounding overwatch: one fire team rushes this far while the other covers it.
const BOUND_LENGTH := 12.0
const TRAIL_SPACING := 0.5
const TRAIL_MAX := 240
## Hits that wound rather than kill: bullets, explosions.
const WOUND_CHANCE_BULLET := 0.5
const WOUND_CHANCE_BLAST := 0.35
const RESCUE_RANGE := 45.0
const DRAG_SPEED := 0.9
const GRENADE_MIN := 8.0
const GRENADE_MAX := 30.0
const GRENADE_COOLDOWN := 8.0
## Distance from a building destination at which the squad stacks into a tight file.
const STACK_RANGE := 14.0
## A known enemy closer than this, roughly ahead, makes an advancing squad go on line.
const ASSAULT_RANGE := 90.0
## Closing on a known enemy inside this range while still unseen, the squad creeps.
const SNEAK_RANGE := 80.0
const SMOKE_COOLDOWN := 30.0
const REPOSITION_CD := 15.0

var members: Array[Soldier] = []
## Where danger comes from: the nearest known enemy, or straight ahead.
var threat := Vector3.ZERO
var _threat_tick := 0.0
var _cover_threat := Vector3.ZERO
var _cover_age := 0.0
## Breadcrumbs of where the leader point has walked, oldest first. Men follow this
## trail rather than rigid slots, so the squad snakes around obstacles like a real file.
var _trail := PackedVector3Array()
var _bounding := false
var _moving_team := 0
var _bound_left := 0.0
var _bound_pause := 0.0
## Leader point velocity, fed forward to the men so they match the squad's pace
## instead of chasing their places and stopping.
var _leader_vel := Vector3.ZERO
var _contact := false
var _next_grenade := 0.0
## Current formation (Form). -1 forces a re-slot on the next pick.
var _formation := -1
## Earliest sim time the squad may dive for cover again (reaction rate limit).
var _react_cd := -99.0
## Cooldowns for acting without orders: smoke and local repositioning.
var _next_smoke := 0.0
var _next_repos := 0.0


func _build() -> void:
	# A campaign squad deploys only the men its roster has fit to fight.
	var men: Array = extra["men"] if not extra.get("men", []).is_empty() else def["men"]
	var n := men.size()
	threat = position + forward() * 60.0
	for i in n:
		var s := Soldier.new()
		battle.units_root.add_child(s)
		s.setup(side, String(men[i]))
		s.fx = battle.fx
		s.slot = Vector2((i - (n - 1) * 0.5) * 2.6, (i % 2) * 1.8 + Game.rng.randf_range(-0.4, 0.4))
		s.facing = heading
		s.aim_yaw = heading
		s.rotation.y = heading
		s.cooldown = Game.rng.randf_range(0.0, 1.5)
		s.pace = Game.rng.randf_range(0.93, 1.07)
		s.team = i % 2
		members.append(s)
	_place_in_cover()


func alive_count() -> int:
	var n := 0
	for s in members:
		if s.alive:
			n += 1
	return n


func total_count() -> int:
	return members.size()


func _weapon_ids() -> Array[String]:
	var out: Array[String] = []
	for s in members:
		if s.alive:
			out.append(s.weapon)
	return out


func _slot_offset(slot: Vector2) -> Vector3:
	var right := Vector3(cos(heading), 0.0, -sin(heading))
	return right * slot.x - forward() * slot.y


func _take_cover() -> void:
	var taken := {}
	_cover_threat = threat
	_cover_age = 0.0
	for s in members:
		if s.alive:
			s.cover_pos = map.best_cover_near(position + _slot_offset(s.slot), 2, taken, threat)


## Puts everyone straight into cover and stance (deployment, spawning).
func _place_in_cover() -> void:
	if not map.is_passable(position, false):
		var c := map.best_cover_near(position, 3, {})
		position = Vector3(c.x, map.height_at(c), c.z)
	_take_cover()
	for s in members:
		if s.alive:
			s.position = Vector3(s.cover_pos.x, map.height_at(s.cover_pos), s.cover_pos.z)
			s.vel = Vector3.ZERO
			s.reset_gait()
			_choose_stance(s, true)
			s.snap_stance()
			s.animate(0.0, battle.time, map)


func teleport(p: Vector3) -> void:
	super.teleport(p)
	order_stop()
	_place_in_cover()


## The men took cover against `threat`: that is the way the ground cover faces.
func cover_front() -> Vector3:
	var to := Vector3(_cover_threat.x - position.x, 0.0, _cover_threat.z - position.z)
	return to.normalized() if to.length() > 0.5 else super.cover_front()


func conceal_value() -> float:
	var c := super.conceal_value()
	var low := 0.0
	var n := 0
	for s in members:
		if s.alive:
			low += s.prone * float(Defs.STEALTH["prone_bonus"]) + s.crouch * float(Defs.STEALTH["crouch_bonus"])
			n += 1
	return minf(0.95, c + (low / n if n > 0 else 0.0))


func _speed() -> float:
	if state == State.PANICKED:
		return Soldier.RUN_SPEED
	var s := Soldier.WALK_SPEED
	match pace:
		Pace.RUN:
			s = Soldier.RUN_SPEED
		Pace.SNEAK:
			s = Soldier.CROUCH_SPEED
	# Under fire, anything short of a sprint becomes a crawl.
	if state == State.SUPPRESSED and pace != Pace.RUN:
		s = Soldier.CRAWL_SPEED
	return s * map.speed_factor(position, false)


## Distance of the furthest-behind man from his formation slot.
func _max_lag() -> float:
	var lag := 0.0
	for s in members:
		if s.alive and battle.time >= s.start_at:
			lag = maxf(lag, _flat(s.position, _trail_target(s)))
	return lag


func _team_lag(team: int) -> float:
	var lag := 0.0
	for s in members:
		if s.alive and s.team == team:
			lag = maxf(lag, _flat(s.position, _trail_target(s)))
	return lag


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## New move order: face the way, pick a formation, and let the men set off one by one.
## The leader points the direction before stepping off.
func _on_path_set(_target: Vector3) -> void:
	var first := path[0]
	var dir := Vector3(first.x - position.x, 0.0, first.z - position.z)
	if dir.length() > 0.5:
		heading = yaw_to(dir)
	_trail = PackedVector3Array([position])
	_formation = -1
	_apply_formation(_choose_formation())
	_bounding = false
	_moving_team = 0
	_bound_left = BOUND_LENGTH
	for s in members:
		s.start_at = battle.time + Game.rng.randf_range(0.1, 0.9)
		s.rush_pos = Vector3.INF
		_cancel_task(s)
	var lead := _leader()
	if lead != null:
		lead.signal_gesture("point", path[path.size() - 1], 1.3)
		lead.start_at = battle.time + 0.9


## First able-bodied man: he carries the leader point's hand signals.
func _leader() -> Soldier:
	for s in members:
		if s.alive and s.task == "" and not s.walking_wounded:
			return s
	return null


## Picks the formation that fits the ground and the situation, in priority order:
## stack on a building entrance, disperse under fire or shelling, file through close
## terrain (and when running or sneaking), line up against a known enemy ahead,
## otherwise wedge. Re-checked every threat tick while moving.
func _choose_formation() -> int:
	if not path.is_empty():
		var dest := path[path.size() - 1]
		if map.type_at(dest) == BattleMap.T.BUILDING and _flat(position, dest) < STACK_RANGE:
			return Form.STACK
	if state >= State.SUPPRESSED or suppression > 35.0:
		return Form.DISPERSED
	var t := map.type_at(position)
	if pace != Pace.WALK or t == BattleMap.T.TREES \
			or t == BattleMap.T.TRENCH or t == BattleMap.T.BUILDING:
		return Form.COLUMN
	if _contact and _flat(threat, position) < ASSAULT_RANGE:
		var to := Vector3(threat.x - position.x, 0.0, threat.z - position.z).normalized()
		if to.dot(forward()) > 0.4:
			return Form.LINE
	return Form.WEDGE


## Assigns slots for formation f (no-op when it is already formed).
## Slot: x = lateral offset, y = distance back along the leader's trail.
func _apply_formation(f: int) -> void:
	if f == _formation:
		return
	_formation = f
	var alive_n := alive_count()
	var k := 0
	for s in members:
		if not s.alive:
			continue
		match f:
			Form.COLUMN:
				# Staggered column: a snaking two-wide file.
				s.slot = Vector2(1.2 if k % 2 == 0 else -1.2, 1.0 + k * 2.8)
				s.team = k % 2
			Form.STACK:
				# Tight single file on the entry man's heels.
				s.slot = Vector2(0.0, 0.8 + k * 1.1)
				s.team = k % 2
			Form.LINE:
				# On line abreast, facing the enemy, a slight stagger for depth.
				s.slot = Vector2((k - (alive_n - 1) * 0.5) * 3.2, 1.0 + (k % 2) * 1.4)
				s.team = k % 2
			Form.DISPERSED:
				# Blown-out wedge: double spacing against shrapnel and bursts.
				var rank_d := (k + 1) / 2
				var side_d := -1.0 if k % 2 == 1 else 1.0
				s.slot = Vector2(0.0 if k == 0 else side_d * rank_d * 4.6, 1.0 + rank_d * 4.2)
				s.team = 0 if k == 0 or side_d < 0.0 else 1
			_:
				# Wedge: point man leading, wings echeloned back.
				var rank := (k + 1) / 2
				var side := -1.0 if k % 2 == 1 else 1.0
				s.slot = Vector2(0.0 if k == 0 else side * rank * 2.6, 1.0 + rank * 2.6)
				s.team = 0 if k == 0 or side < 0.0 else 1
		k += 1


## Position and travel direction d metres back along the leader's trail, extended
## straight back past its start.
func _trail_sample(d: float) -> Array:
	var tangent := forward()
	var prev := position
	var remaining := d
	for i in range(_trail.size() - 1, -1, -1):
		var q := _trail[i]
		var seg := _flat(prev, q)
		if seg > 0.001:
			tangent = Vector3(prev.x - q.x, 0.0, prev.z - q.z) / seg
			if seg >= remaining:
				return [prev - tangent * remaining, tangent]
			remaining -= seg
		prev = q
	return [prev - tangent * remaining, tangent]


## Where a man should be in the moving formation. A man already ahead of his place
## does not walk back: he waits for the file to reach him and falls in.
func _trail_target(s: Soldier) -> Vector3:
	var sample := _trail_sample(s.slot.y)
	var p: Vector3 = sample[0]
	var t: Vector3 = sample[1]
	var goal := p + Vector3(-t.z, 0.0, t.x) * s.slot.x
	if not map.is_passable(goal, false):
		goal = p
	var ahead := (s.position - goal).dot(t)
	if ahead > 0.5:
		goal += t * ahead
	return goal


func _in_contact() -> bool:
	for u in battle.units:
		if u.side != side and u.is_targetable() and battle.time - u.last_seen[side] < 10.0 \
				and u.known_pos[side].distance_to(position) < 220.0:
			return true
	return false


## Starts a bound: the covering team holds where it is (in the cover it rushed to), and
## each man of the moving team picks his own cover spot a bound further along the route.
func _start_holds() -> void:
	var taken := {}
	var ahead := _point_along_path(BOUND_LENGTH)
	var dir := Vector3(ahead.x - position.x, 0.0, ahead.z - position.z)
	var yaw := yaw_to(dir) if dir.length() > 0.5 else heading
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	for s in members:
		if not s.alive:
			continue
		if s.team != _moving_team:
			s.hold_pos = s.rush_pos if s.rush_pos != Vector3.INF else map.best_cover_near(s.position, 1, taken, threat)
		else:
			var spot := ahead + right * s.slot.x - fwd * s.slot.y * 0.5
			s.rush_pos = map.best_cover_near(spot, 2, taken, threat)


## Point dist metres further along the remaining path.
func _point_along_path(dist: float) -> Vector3:
	var p := position
	var left := dist
	for i in range(path_i, path.size()):
		var q := path[i]
		var seg := _flat(p, q)
		if seg >= left:
			return p + Vector3(q.x - p.x, 0.0, q.z - p.z).normalized() * left
		left -= seg
		p = q
	return p


func _team_rush_lag(team: int) -> float:
	var lag := 0.0
	for s in members:
		if s.alive and s.team == team and s.rush_pos != Vector3.INF:
			lag = maxf(lag, _flat(s.position, s.rush_pos))
	return lag


func _update_threat() -> void:
	var best := INF
	var found := false
	for u in battle.units:
		if u.side == side or not u.is_targetable() or battle.time - u.last_seen[side] > 20.0:
			continue
		var d := u.known_pos[side].distance_to(position)
		if d < best:
			best = d
			threat = u.known_pos[side]
			found = true
	if not found:
		var ahead := guard_dir if is_guarding() else Vector3(0.0, 0.0, -1.0 if side == Game.UA else 1.0)
		threat = position + ahead * 60.0


func _threat_dir() -> Vector3:
	var to := Vector3(threat.x - position.x, 0.0, threat.z - position.z)
	return to.normalized() if to.length() > 0.5 else super._threat_dir()


## Run when out of contact, creep when closing unseen on a known enemy, otherwise
## walk (and bound by fire teams once in contact).
func _choose_pace() -> int:
	if state >= State.PANICKED:
		return Pace.RUN
	var d := known_enemy_distance()
	if d > CONTACT_RANGE and suppression < 20.0:
		return Pace.RUN
	if d < SNEAK_RANGE and state == State.OK and not seen[1 - side]:
		return Pace.SNEAK
	return Pace.WALK


## Acting without orders while holding: smoke when pinned in the open, dodge an FPV
## coming for the squad, shift to better cover under sustained fire. Repositioning
## stays local — the squad never abandons the area it was sent to.
func _auto_tactics() -> void:
	_auto_smoke()
	if not can_move() or battle.time < _next_repos:
		return
	var fpv := incoming_fpv()
	if fpv != null:
		if cover_here() >= float(Defs.COVER["dodge_cover"]):
			return  # dug in: stay down, running would only put the men in the open
		var away := Vector3(position.x - fpv.position.x, 0.0, position.z - fpv.position.z)
		away = away.normalized() if away.length() > 1.0 else _retreat_dir()
		if _set_path(map.best_cover_near(position + away * 14.0, 4, {}, threat)):
			pace = Pace.RUN
			pace_lock = battle.time + 6.0
			_next_repos = battle.time + 10.0
		return
	if _contact and suppression > 30.0 and cover_here() < 0.3:
		var dest := map.best_cover_near(position + (position - threat).normalized() * 8.0, 5, {}, threat)
		if map.cover_at(dest) > cover_here() + 0.15 and _set_path(dest):
			_next_repos = battle.time + REPOSITION_CD


## A squad pinned in the open pops smoke between itself and the shooter.
func _auto_smoke() -> void:
	if smoke_left <= 0 or battle.time < _next_smoke or state < State.PINNED \
			or not _contact or cover_here() >= 0.4:
		return
	var to := Vector3(threat.x - position.x, 0.0, threat.z - position.z)
	if to.length() < 1.0:
		return
	var at := position + to.normalized() * minf(to.length() * 0.5, SMOKE_RANGE * 0.7)
	if throw_smoke(at):
		_next_smoke = battle.time + SMOKE_COOLDOWN


func _sim_move(dt: float) -> void:
	_threat_tick -= dt
	if _threat_tick <= 0.0:
		_threat_tick = 0.5
		_update_threat()
		_contact = _in_contact()
		_assign_rescue()
		if not arrived and state != State.PINNED:
			# The situation changes mid-move: re-check the pace and formation against it.
			if battle.time >= pace_lock:
				var want := _choose_pace()
				if want != pace:
					pace = want
					if pace == Pace.RUN:
						fire_target = null
			_apply_formation(_choose_formation())
		elif arrived:
			_auto_tactics()
	_medical(dt)
	if not arrived and state != State.PINNED:
		_advance_leader(dt)
	elif arrived:
		_cover_age += dt
		if _cover_age > COVER_RECHECK:
			_cover_age = 0.0
			var old := (_cover_threat - position).normalized()
			var now := (threat - position).normalized()
			if old.dot(now) < 0.7:
				_take_cover()
	position.y = map.height_at(position)
	_move_members(dt)


## Moves the leader point along the path. In contact on a normal move the squad bounds:
## one team rushes BOUND_LENGTH metres while the other covers, then they swap.
func _advance_leader(dt: float) -> void:
	var before := position
	var contact := pace == Pace.WALK and _in_contact()
	if contact != _bounding:
		_bounding = contact
		_bound_left = BOUND_LENGTH
		if _bounding:
			_start_holds()
	var spd := _speed()
	if _bounding:
		if _bound_left <= 0.0:
			spd = 0.0
			if _team_rush_lag(_moving_team) < 1.5:
				_bound_pause -= dt
				if _bound_pause <= 0.0:
					_moving_team = 1 - _moving_team
					_bound_left = BOUND_LENGTH
					_bound_pause = 1.5
					_start_holds()
					# The leader waves the next team forward.
					var lead := _leader()
					if lead != null:
						lead.signal_gesture("point", _point_along_path(BOUND_LENGTH), 1.0)
		elif _team_rush_lag(_moving_team) > 8.0:
			spd *= 0.2
	else:
		# The leader eases off gradually as men fall behind, so the squad moves as one.
		spd *= clampf(1.0 - (_max_lag() - 3.0) / 4.0, 0.25, 1.0)
	var target := path[path_i]
	var to := Vector3(target.x - position.x, 0.0, target.z - position.z)
	var d := to.length()
	var step := spd * dt
	if d > 0.01:
		heading = lerp_angle(heading, yaw_to(to), minf(1.0, dt * 3.0))
	if d <= step:
		position.x = target.x
		position.z = target.z
		path_i += 1
		if path_i >= path.size():
			_reach_end()
	else:
		position += to / d * step
	_bound_left -= step
	_leader_vel = Vector3(position.x - before.x, 0.0, position.z - before.z) / maxf(dt, 0.0001)
	if step > 0.0:
		last_moved = battle.time
	if _trail.is_empty() or _flat(position, _trail[_trail.size() - 1]) >= TRAIL_SPACING:
		_trail.append(position)
		if _trail.size() > TRAIL_MAX:
			_trail.remove_at(0)


func _move_members(dt: float) -> void:
	var stationary := arrived or state == State.PINNED
	if stationary:
		_leader_vel = Vector3.ZERO
	# Weapons come up to the ready when enemies are known about, down on the sling when not.
	var alert_now := _contact or state >= State.SUPPRESSED or battle.time - last_fired < 12.0
	var neighbours := _nearby_soldiers()
	var max_speed := maxf(_speed() * 1.3, 1.0)
	for s in members:
		if not s.alive:
			continue
		s.alert = alert_now
		if s.task != "":
			_do_task(s, dt, neighbours)
			continue
		s.face_point = Vector3.INF
		s.hand_targets.clear()
		s.slung = false
		var goal := s.cover_pos
		var holding := stationary
		var feed := Vector3.ZERO
		var speed_limit := max_speed
		if not stationary:
			if battle.time < s.start_at:
				goal = s.position
			elif _bounding and s.team != _moving_team:
				goal = s.hold_pos
				holding = true
			elif _bounding and s.rush_pos != Vector3.INF:
				# Sprint to his own next cover, crouched.
				goal = s.rush_pos
				speed_limit = Soldier.RUN_SPEED * 0.9
				holding = _flat(s.position, s.rush_pos) < 0.8
			else:
				goal = _trail_target(s)
				feed = _leader_vel
		var push := Vector3.ZERO
		# Combat spacing: men keep a good arm's-length-plus apart (tighter only in a
		# building-entry stack), and more when prone, so nobody walks over anybody.
		var sep := 1.0 if _formation == Form.STACK else 1.6
		for o in neighbours:
			if o == s or not o.alive:
				continue
			var away := Vector3(s.position.x - o.position.x, 0.0, s.position.z - o.position.z)
			var d := away.length()
			var min_d := sep + 0.5 * maxf(s.prone, o.prone)
			if d < min_d and d > 0.001:
				push += away / d * (min_d - d) * 4.0
		if s.cooldown > 0.0 or battle.time > s.engage_until:
			s.aim_yaw = yaw_to(threat - s.position)
		s.steer(dt, goal, minf(speed_limit, s.speed_cap()), push, map, feed)
		_choose_stance(s, holding)


func _push_from(s: Soldier, neighbours: Array[Soldier]) -> Vector3:
	var push := Vector3.ZERO
	for o in neighbours:
		if o == s or not o.alive:
			continue
		var away := Vector3(s.position.x - o.position.x, 0.0, s.position.z - o.position.z)
		var d := away.length()
		if d < 1.3 and d > 0.001:
			push += away / d * (1.3 - d) * 4.0
	return push


# --- Wounded and rescue ---

## Bleed-out for the untreated; recovery for the stabilized. A treated man rests
## Defs.WOUNDED_FIGHT recover_time seconds, then gets up as walking wounded.
func _medical(dt: float) -> void:
	for s in members:
		if not s.wounded or s.alive:
			continue
		if not s.stabilized:
			s.bleed -= dt
			if s.bleed <= 0.0:
				_release(s)
				s.expire()
				battle.on_died_of_wounds(self)
		elif s.carried_by == null and s.rescuer == null and state != State.DESTROYED:
			s.recover_t += dt
			if s.recover_t >= float(Defs.WOUNDED_FIGHT["recover_time"]):
				s.recover()
				s.aim_yaw = yaw_to(threat - s.position)


## Sends one free man after the nearest untreated casualty, own squad first.
func _assign_rescue() -> void:
	if state >= State.PINNED or not is_effective():
		return
	for s in members:
		if s.task != "":
			return
	var best: Soldier = null
	var best_score := INF
	for u in battle.units:
		if u.side != side or not (u is InfantryUnit) or u.position.distance_to(position) > RESCUE_RANGE + 20.0:
			continue
		for w in (u as InfantryUnit).members:
			if not w.wounded or w.stabilized or w.rescuer != null:
				continue
			var score := _flat(w.position, position) + (0.0 if u == self else 15.0)
			if score < best_score:
				best_score = score
				best = w
	if best == null:
		return
	var helper: Soldier = null
	var helper_d := RESCUE_RANGE
	for s in members:
		# Walking wounded are too slow to send after a casualty.
		if s.alive and not s.busy() and not s.walking_wounded:
			var d := _flat(s.position, best.position)
			if d < helper_d:
				helper_d = d
				helper = s
	if helper == null:
		return
	helper.task = "go"
	helper.patient = best
	best.rescuer = helper


func _cancel_task(s: Soldier) -> void:
	if s.patient != null:
		s.patient.rescuer = null
		s.patient.carried_by = null
	s.patient = null
	s.task = ""
	s.drag_to = Vector3.INF
	s.face_point = Vector3.INF
	s.hand_targets.clear()
	s.slung = false


func _release(w: Soldier) -> void:
	if w.rescuer != null:
		var r := w.rescuer
		r.patient = null
		_cancel_task(r)
	w.rescuer = null
	w.carried_by = null


## Run to the casualty, drag him out of the line of fire, kneel and patch him up.
func _do_task(s: Soldier, dt: float, neighbours: Array[Soldier]) -> void:
	var w := s.patient
	if w == null or not w.wounded or state >= State.PANICKED:
		_cancel_task(s)
		return
	var away := Vector3(position.x - threat.x, 0.0, position.z - threat.z).normalized()
	var push := _push_from(s, neighbours)
	match s.task:
		"go":
			s.slung = false
			s.face_point = Vector3.INF
			var reach := w.position + away * 1.2
			s.steer(dt, reach, minf(Soldier.RUN_SPEED, s.speed_cap()), push, map)
			s.want_crouch = 0.45
			s.want_prone = 0.0
			if _flat(s.position, reach) < 1.0:
				if map.cover_from(w.position, threat) >= 0.5:
					s.task = "aid"
				else:
					s.task = "drag"
					s.drag_to = map.best_cover_near(w.position + away * 7.0, 3, {}, threat)
					w.carried_by = s
				s.task_timer = 0.0
		"drag":
			s.slung = true
			s.want_crouch = 0.6
			s.want_prone = 0.0
			s.steer(dt, s.drag_to, DRAG_SPEED, push, map)
			# The body follows on an arm's length, head first, sliding over the ground.
			# It may never be pulled through a wall cell the rescuer walked around.
			var to_r := Vector3(s.position.x - w.position.x, 0.0, s.position.z - w.position.z)
			if to_r.length() > 0.01:
				var dir := to_r.normalized()
				var want := s.position - dir * Soldier.DRAG_DISTANCE
				if map.infantry_step_open(w.position, want):
					w.position = Vector3(want.x, map.height_at(want), want.z)
				w.lay_head_towards(dir)
				var chest := w.position + dir * 1.15 + Vector3.UP * 0.3
				var side := Vector3(dir.z, 0.0, -dir.x) * 0.16
				s.face_point = chest
				s.hand_targets = [chest + side, chest - side]
			if _flat(s.position, s.drag_to) < 0.7:
				w.carried_by = null
				s.task = "aid"
				s.task_timer = 0.0
		"aid":
			s.slung = true
			s.want_crouch = 1.0
			s.want_prone = 0.0
			var dir := w.head_dir()
			var chest := w.position + dir * 1.15 + Vector3.UP * 0.25
			var spot := chest + Vector3(dir.z, 0.0, -dir.x) * 0.75
			s.steer(dt, spot, 1.5, push, map)
			s.face_point = chest
			s.hand_targets = [chest + Vector3(0.0, 0.0, 0.1), chest - Vector3(0.0, 0.0, 0.1)]
			if _flat(s.position, spot) < 0.5:
				s.task_timer += dt
				if s.task_timer >= float(Defs.WOUNDED_FIGHT["first_aid_time"]):
					w.stabilized = true
					w.rescuer = null
					s.patient = null
					_cancel_task(s)


# --- Reacting to fire, hand signals ---

## Effective fire just arrived: every free man dives for the nearest micro-cover
## after his own split-second delay (ST.HIT_REACT), then the squad adapts through
## the normal suppression logic (return fire, crawl, bound).
func _on_incoming(amount: float) -> void:
	if amount < float(Defs.REACT["trigger"]) or battle.time < _react_cd or state >= State.PANICKED:
		return
	_react_cd = battle.time + float(Defs.REACT["cooldown"])
	var from := threat
	for s in members:
		if s.alive and not s.busy() and s.prone < 0.6:
			var sl: Soldier = s
			battle.schedule(Game.rng.randf_range(float(Defs.REACT["delay_min"]), float(Defs.REACT["delay_max"])),
					func() -> void: sl.hit_the_dirt(from, map, battle.time))


## Reached the destination: the leader raises a fist — halt.
func _on_arrived() -> void:
	var lead := _leader()
	if lead != null:
		lead.signal_gesture("halt", Vector3.INF, 1.2)


## Recovered from pinned or panic: the leader circles an arm — rally on me.
func _on_recovered() -> void:
	var lead := _leader()
	if lead != null:
		lead.signal_gesture("rally", Vector3.INF, 1.6)


func _nearby_soldiers() -> Array[Soldier]:
	var out: Array[Soldier] = []
	for u in battle.units:
		if u is InfantryUnit and u.position.distance_to(position) < 25.0:
			out.append_array((u as InfantryUnit).members)
	return out


## Picks the stance that fits his ground, his orders and the squad's nerve.
func _choose_stance(s: Soldier, stationary: bool) -> void:
	var t := map.type_at(s.position)
	var shield := map.shield_at(s.position, threat)
	var c := 0.0
	var p := 0.0
	s.ducked = false
	s.cowering = false
	var wants_fire := battle.time < s.engage_until and state < State.PINNED
	if state == State.PANICKED:
		if stationary:
			s.cowering = true
			if t == BattleMap.T.TRENCH or t == BattleMap.T.BUILDING or shield >= 0.45:
				c = 1.0
			else:
				p = 1.0
	elif battle.time < s.stay_low_until and shield < 0.45 \
			and t != BattleMap.T.TRENCH and t != BattleMap.T.BUILDING:
		# Just dove from effective fire: stays flat for a few seconds.
		p = 1.0
	elif not stationary:
		if _bounding and s.rush_pos != Vector3.INF and s.team == _moving_team:
			c = 0.35
		elif pace == Pace.RUN:
			pass
		elif state == State.SUPPRESSED:
			p = 1.0
		elif pace == Pace.SNEAK:
			c = 0.9
		elif _contact:
			# Enemy about: tactical crouched walk, staying low.
			c = 0.5
	elif t == BattleMap.T.TRENCH:
		s.ducked = true
		c = 0.45 if wants_fire else 1.0
	elif t == BattleMap.T.BUILDING or t == BattleMap.T.RUBBLE:
		s.ducked = true
		c = 0.35 if wants_fire else 0.9
	elif shield >= 0.45:
		# Behind a wall or wreck: crouch out of sight, rise over it to shoot.
		s.ducked = true
		c = 0.3 if wants_fire else 1.0
	elif state >= State.SUPPRESSED or is_guarding() or t in [BattleMap.T.OPEN, BattleMap.T.FIELD, BattleMap.T.ROAD, BattleMap.T.CRATER]:
		p = 1.0
	else:
		c = 1.0
	s.want_crouch = c
	s.want_prone = p


func _sim_fire(dt: float) -> void:
	if state >= State.PANICKED:
		return
	if not arrived and pace == Pace.RUN:
		return
	var acc := _accuracy()
	for s in members:
		if not s.alive:
			continue
		if s.action == "throw" and not s.thrown and s.action_t >= s.action_len * 0.55:
			s.thrown = true
			battle.throw_grenade(s.hand_point(), s.throw_at, side)
		s.cooldown -= dt
		if s.cooldown > 0.0:
			continue
		var w: Dictionary = Defs.WEAPONS[s.weapon]
		var reload: float = w["reload"]
		var t := pick_target(w, s.position)
		if t == null:
			s.cooldown = 0.4
			continue
		s.engage_until = battle.time + 2.5
		s.aim_yaw = yaw_to(t.position - s.position)
		if _try_grenade(s, t):
			continue
		if not s.can_fire():
			s.cooldown = 0.25
			continue
		# Men of the covering team fire from a halt at full accuracy.
		var a := acc * (2.0 if not arrived and s.vel.length() < 0.3 else 1.0)
		if s.walking_wounded:
			a *= float(Defs.WOUNDED_FIGHT["acc"])
		var fired := Combat.fire(battle, self, s.muzzle(), s.weapon, t, a)
		if fired:
			s.cooldown = reload * Game.rng.randf_range(0.8, 1.3)
			s.fired(battle.time)
			last_fired = battle.time
			last_fired_sig = float(w.get("signature", 1.0))
			_displace_shots += 1
			_check_displace()
		else:
			s.cooldown = 0.6


## Shoot-and-move (Defs.DISPLACE): firing reveals the position, so infantry
## decides on its own to sneak to the best concealed cell 15–25 m away from the
## known threat after enough shots, then settles back into its old facing and
## ambush (unit._reach_end). Never while moving, pinned, panicked or on cooldown.
func _check_displace() -> void:
	var dc: Dictionary = Defs.DISPLACE
	if _displacing or not arrived or not can_move() \
			or _displace_shots < int(dc["shots"]) or battle.time < _next_displace_at:
		return
	# Dug in (trench, building): fieldworks beat a bush somewhere else — hold.
	if map.cover_at(position) >= float(dc["hold_cover"]):
		return
	# With the enemy at point-blank range, breaking cover is worse than holding
	# it: stay put and fight until the ground is clear enough to slip away.
	if known_enemy_distance() < 30.0:
		return
	var away := -_threat_dir()
	var dir := away.rotated(Vector3.UP, Game.rng.randf_range(-PI / 3.0, PI / 3.0))
	var dist := Game.rng.randf_range(float(dc["min_dist"]), float(dc["max_dist"]))
	var dest := map.best_cover_near(position + dir * dist, int(dc["search_cells"]), {}, threat, true)
	# Already spotted: shifting in plain sight gains nothing, so move only if
	# the new spot actually breaks line of sight (strictly better concealment).
	var need := float(dc["seen_gain"]) if seen[1 - side] else -0.05
	if _flat(dest, position) < float(dc["min_dist"]) * 0.5 \
			or map.conceal_at(dest) < map.conceal_at(position) + need:
		_next_displace_at = battle.time + 4.0  # nowhere as good from here; try again soon
		return
	var resume_hold := hold_fire
	if not _set_path(dest):
		_next_displace_at = battle.time + 4.0
		return
	_displacing = true
	_displace_resume_hold = resume_hold
	_displace_shots = 0
	# Slip away unseen; once spotted there is nothing left to hide, so sprint.
	pace = Pace.RUN if seen[1 - side] else Pace.SNEAK
	pace_lock = battle.time + 30.0
	if Game.has_arg("trace"):
		print("[%s] DISPLACE %s %.0fm to (%.0f, %.0f)" % [battle.clock_text(battle.time), display_name, _flat(dest, position), dest.x, dest.z])


## Riflemen lob a grenade at close enemy infantry, especially men behind cover.
func _try_grenade(s: Soldier, t: Unit) -> bool:
	if t == null or t.is_vehicle or s.grenades <= 0 or s.busy() or not arrived \
			or s.walking_wounded or battle.time < _next_grenade:
		return false
	var at := t.aim_point()
	var d := _flat(s.position, at)
	if d < GRENADE_MIN or d > GRENADE_MAX or Game.rng.randf() > 0.35:
		return false
	at.y = map.height_at(at)
	s.start_throw(at + Vector3(Game.rng.randf_range(-2.0, 2.0), 0.0, Game.rng.randf_range(-2.0, 2.0)))
	s.aim_yaw = yaw_to(at - s.position)
	s.cooldown = 1.5
	_next_grenade = battle.time + GRENADE_COOLDOWN
	return true


func aim_point() -> Vector3:
	var alive: Array[Soldier] = []
	for s in members:
		if s.alive:
			alive.append(s)
	if alive.is_empty():
		return position + Vector3.UP
	return alive[Game.rng.randi_range(0, alive.size() - 1)].center()


func exposure_at(p: Vector3) -> float:
	var s := _nearest(p, 3.0)
	return s.exposure() if s != null else 1.0


func distance_to_point(p: Vector3) -> float:
	var best := INF
	for s in members:
		if s.alive:
			best = minf(best, Vector2(s.position.x - p.x, s.position.z - p.z).length())
	return best


func _nearest(p: Vector3, max_d: float) -> Soldier:
	var best: Soldier = null
	var best_d := max_d
	for s in members:
		if s.alive:
			var d := Vector2(s.position.x - p.x, s.position.z - p.z).length()
			if d < best_d:
				best_d = d
				best = s
	return best


## A bullet found a man: he is knocked along the shot's direction as he falls.
func take_hit(pos: Vector3, shooter: Unit) -> void:
	var s := _nearest(pos, 3.0)
	if s == null:
		return
	var dir := Vector3.ZERO
	if shooter != null:
		dir = Vector3(s.position.x - shooter.position.x, 0.0, s.position.z - shooter.position.z)
		dir = dir.normalized() if dir.length() > 0.5 else Vector3.ZERO
	casualty(s, shooter, dir * Game.rng.randf_range(1.0, 2.2), 0.0, Game.rng.randf() < WOUND_CHANCE_BULLET)


func apply_blast(pos: Vector3, radius: float, lethal: float, supp: float, _pen: float, _top: bool) -> void:
	var nearest := INF
	for s in members:
		if not s.alive:
			continue
		var away := Vector3(s.position.x - pos.x, 0.0, s.position.z - pos.z)
		var d := away.length()
		nearest = minf(nearest, d)
		if d < radius:
			# A shell from above still reaches into a trench; a rocket or tank round
			# fired across the ground is stopped by the same cover that stops bullets.
			var c := map.cover_from(s.position, pos, cover_front())
			var keep := (1.0 - c * float(Defs.COVER["blast_top"])) if _top else pow(1.0 - c, float(Defs.COVER["hit_power"]))
			if _top and map.cover_at(s.position) >= float(Defs.COVER["dugin_cover"]) \
					and (s.ducked or maxf(s.prone, s.crouch) >= 0.5):
				# Dug in and down: the shrapnel sweeps over the lip of the hole he is
				# in, whichever side the shell lands (hence ground cover, not the
				# directional cover_from above). The full suppression below still
				# lands, so the squad is pinned, not shredded.
				keep *= float(Defs.COVER["dugin_keep"])
			var chance := lethal * (1.0 - d / radius) * keep * (0.6 + 0.4 * s.exposure())
			if Game.rng.randf() < chance:
				var force := (1.0 - d / radius) * radius
				casualty(s, null, away.normalized() * force * 1.6, force * 0.9, Game.rng.randf() < WOUND_CHANCE_BLAST)
	for s in members:
		# A blast can finish off a man already down (the walking wounded go through
		# the normal casualty roll above instead).
		if s.wounded and not s.alive and _flat(s.position, pos) < radius * 0.6 and Game.rng.randf() < lethal * 0.5:
			_release(s)
			s.expire()
			battle.on_died_of_wounds(self)
	if nearest < radius * 3.0:
		receive_suppression(supp * (1.0 - nearest / (radius * 3.0)) + 5.0)


## The roof or the whole house is coming down on the squad (Building collapse):
## every man inside the footprint takes a direct hit roll — no cover applies,
## because the cover itself is falling on him — with the usual blast wound share,
## and a wounded man already on the floor can be crushed outright.
func struck_by_collapse(area: Rect2, hit_chance: float) -> void:
	battle.cause = "collapse"
	for s in members:
		if not area.has_point(Vector2(s.position.x, s.position.z)):
			continue
		if s.alive:
			if Game.rng.randf() < hit_chance:
				var dir := Vector3(Game.rng.randf_range(-1.0, 1.0), 0.0, Game.rng.randf_range(-1.0, 1.0))
				casualty(s, null, dir * 1.2, 0.0, Game.rng.randf() < WOUND_CHANCE_BLAST)
		elif s.wounded and Game.rng.randf() < hit_chance * 0.6:
			_release(s)
			s.expire()
			battle.on_died_of_wounds(self)
	battle.cause = ""


func casualty(s: Soldier, shooter: Unit, knock: Vector3, up_speed: float, wounded := false) -> void:
	if not s.alive:
		return
	if s.patient != null:
		s.patient.rescuer = null
		s.patient.carried_by = null
	# A walking wounded going down again was already counted as a loss once.
	var recounted := s.walking_wounded
	s.die(knock, up_speed, wounded)
	if shooter != null:
		shooter.kills += 1
	morale_hit(10.0)
	suppression = minf(100.0, suppression + 12.0)
	if not recounted:
		battle.on_casualty(self, "fire:%s" % shooter.def_id if shooter != null else battle.cause)
	if Game.has_arg("trace"):
		var sh := "-" if shooter == null else "%s@%dm t%d" % [shooter.def_id, int(shooter.position.distance_to(s.position)), map.type_at(shooter.position)]
		print("[%s] CAS %s %s t%d cov%.2f st%d prone%s by %s" % [battle.clock_text(battle.time), display_name, side, map.type_at(s.position), map.cover_at(s.position), state, "%.1f" % s.prone, sh])
	if alive_count() == 0:
		state = State.DESTROYED
		battle.on_unit_lost(self)


func throw_smoke(p: Vector3) -> bool:
	if smoke_left <= 0 or not is_effective() or distance_to_point(p) > SMOKE_RANGE:
		return false
	smoke_left -= 1
	var at := Vector3(p.x, map.height_at(p), p.z)
	battle.schedule(1.2, func() -> void: battle.add_smoke_cloud(at, 35.0))
	return true


func update_visuals(dt: float) -> void:
	super.update_visuals(dt)
	var sdt := Game.sim_delta(dt) if battle.phase == Battle.Phase.BATTLE else 0.0
	for s in members:
		s.animate(sdt, battle.time, map)


func _set_body_visible(v: bool) -> void:
	for s in members:
		s.visible = v
