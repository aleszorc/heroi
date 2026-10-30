class_name Drone
extends Node3D
## A recon quadcopter that circles an area revealing enemies, an FPV kamikaze drone
## that hunts one unit, or a heavy bomber hexacopter that crosses the map slowly and
## drops a string of bombs on one unit. Infantry underneath may shoot any of them down;
## the big slow bomber is the easiest mark.

const RECON_RADIUS := 55.0
const FPV_PEN := 350.0
const BOMBER_SPEED := 13.0
const BOMBER_ALT := 22.0
const BOMB_INTERVAL := 1.0  # seconds between releases
const BOMB_SCATTER := 3.0  # metres of aim scatter per bomb
const BOMB_PEN := 45.0  # top attack: kills IFVs outright, roughly even odds on a T-72 roof
const BOMB_RADIUS := 5.0
const BOMB_STRUCT := 90.0  # structural damage per bomb; a short string levels a house
const BOMB_GRAVITY := 9.8
const COMMIT_DIST := 26.0  # flat distance at which the FPV rolls its hit and dives
const HIT_DIST := 2.2
const DIVE_SPEED := 46.0
const TURN_RATE := 3.2  # rad/s of steering authority at cruise
const DIVE_TURN_RATE := 7.0
const ROTOR_SPIN := 18.0  # rad/s: slow enough that the blade cross reads as turning

var battle: Battle
var side := 0
var fpv := false
var heavy := false
var target: Unit = null
var target_pos := Vector3.ZERO
var altitude := 30.0
var speed := 20.0
var loiter_left := 0.0
var done := false
var _tick := 0.0
var _angle := 0.0
var _orbiting := false

# FPV flight state.
var _vel := Vector3.ZERO
var _t := 0.0  # sim-time flight clock (wobble phase)
var _committed := false
var _will_hit := false
var _impact := Vector3.ZERO  # locked detonation point; tracks the aim while a hit target lives
var _bank := 0.0
var _rotors: Array[MeshInstance3D] = []

# Bomber state.
var _home := Vector3.ZERO
var _bombs_left := 0
var _dropping := false
var _drop_tick := 0.0
var _racked: Array[MeshInstance3D] = []  # bombs still on the belly rack
var _falling: Array[Dictionary] = []  # released bombs: {node, from, to, t, fall}


func setup_recon(b: Battle, s: int, start: Vector3, p: Vector3, duration: float) -> void:
	battle = b
	side = s
	target_pos = p
	altitude = 30.0 if s == Game.UA else 55.0
	speed = 20.0
	loiter_left = duration
	_common(start)


func setup_fpv(b: Battle, s: int, start: Vector3, t: Unit) -> void:
	battle = b
	side = s
	fpv = true
	target = t
	altitude = 14.0
	speed = 30.0
	_common(start)
	var to := t.aim_point() - position
	_vel = Vector3(to.x, 0.0, to.z).normalized() * speed


## The heavy bomber: flies in from `start` (its home edge), crosses to the target at
## cruise altitude, drops its bomb string, then turns for home and despawns there.
func setup_bomber(b: Battle, s: int, start: Vector3, t: Unit) -> void:
	battle = b
	side = s
	heavy = true
	target = t
	altitude = BOMBER_ALT
	speed = BOMBER_SPEED
	_home = start
	_bombs_left = randi_range(3, 4)
	_common(start)
	target_pos = t.aim_point()
	_vel = Vector3(target_pos.x - start.x, 0.0, target_pos.z - start.z).normalized() * speed
	for k in _bombs_left:
		var bm := MeshInstance3D.new()
		bm.mesh = MeshFactory.bomber_bomb()
		bm.position = MeshFactory.bomber_bomb_pos(k)
		add_child(bm)
		_racked.append(bm)


func _common(start: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = MeshFactory.bomber() if heavy else MeshFactory.drone(fpv)
	add_child(mi)
	# Translucent blur discs plus spinning blade crosses over the motors.
	var discs := MeshInstance3D.new()
	discs.mesh = MeshFactory.bomber_discs() if heavy else MeshFactory.drone_discs(fpv)
	add_child(discs)
	for k in (6 if heavy else 4):
		var rotor := MeshInstance3D.new()
		rotor.mesh = MeshFactory.bomber_rotor() if heavy else MeshFactory.drone_rotor(fpv)
		rotor.position = MeshFactory.bomber_rotor_pos(k) if heavy else MeshFactory.drone_rotor_pos(fpv, k)
		rotor.rotation.y = randf() * TAU
		add_child(rotor)
		_rotors.append(rotor)
	position = Vector3(start.x, altitude, start.z)


func sim(dt: float) -> void:
	if done:
		return
	# Spin the props on the sim clock so they freeze with the pause; adjacent rotors
	# counter-rotate and run slightly apart so the four never turn in lockstep.
	for k in _rotors.size():
		_rotors[k].rotation.y += ROTOR_SPIN * (1.0 + 0.11 * k) * (1.0 if k % 2 == 0 else -1.0) * dt
	if fpv:
		_sim_fpv(dt)
	elif heavy:
		_sim_bomber(dt)
	else:
		_sim_recon(dt)


func _sim_fpv(dt: float) -> void:
	_t += dt
	if target.is_targetable():
		var aim := target.aim_point()
		if _will_hit or not _committed:
			_impact = aim  # track the live target; a rolled miss keeps its locked point
		if not _committed and Vector2(aim.x - position.x, aim.z - position.z).length() <= COMMIT_DIST:
			_commit(aim)
	elif not _committed:
		# Target destroyed before the attack run: abort in place.
		battle.fx.explosion(Vector3(position.x, battle.map.height_at(position), position.z), 0.8)
		_finish()
		return
	else:
		_will_hit = false  # target died mid-dive; crash into its last position
	var goal := _impact
	var max_speed := speed
	var turn := TURN_RATE
	if _committed:
		max_speed = DIVE_SPEED
		turn = DIVE_TURN_RATE
	else:
		# Cruise above the target with a light flight wobble that is gone by commit range.
		goal = Vector3(_impact.x, altitude, _impact.z)
		var flat := Vector2(goal.x - position.x, goal.z - position.z).length()
		var amp := 1.1 * clampf((flat - COMMIT_DIST) / 25.0, 0.0, 1.0)
		goal += Vector3(sin(_t * 6.7), 0.55 * sin(_t * 8.9 + 1.7), cos(_t * 5.3)) * amp
	var to := goal - position
	# Steer the velocity with limited turn authority; accelerate into the dive.
	var dir := _vel.normalized()
	var want := to.normalized()
	if dir.dot(want) < -0.999:
		want = (want + Vector3(0.02, 0.01, 0.0)).normalized()
	var new_dir := dir.slerp(want, minf(1.0, turn * dt))
	var spd := minf(_vel.length() + (28.0 if _committed else 10.0) * dt, max_speed)
	_vel = new_dir * spd
	if _committed and (to.length() <= maxf(HIT_DIST, spd * dt) or (to.length() < 8.0 and to.dot(_vel) < 0.0)):
		_strike()
		return
	position += _vel * dt
	_pose(dir, new_dir, dt)
	_tick -= dt
	if _tick <= 0.0:
		_tick = 0.5
		_ground_fire()


## Terminal commit: roll the hit once, then fly a straight decisive dive. A miss
## locks an overshoot point just past the target and crashes there.
func _commit(aim: Vector3) -> void:
	_committed = true
	var p := 0.8
	if not target.is_vehicle:
		var t := battle.map.type_at(target.position)
		if t == BattleMap.T.BUILDING or t == BattleMap.T.TRENCH:
			p = 0.55
		elif not target.arrived:
			# A squad scrambling (on its own or on an order) is harder to hit.
			p = 0.65
	elif not target.arrived:
		p = 0.7
	_will_hit = randf() < p
	if not _will_hit:
		var fwd := Vector3(_vel.x, 0.0, _vel.z).normalized()
		var side_v := Vector3(-fwd.z, 0.0, fwd.x)
		var pos := aim + fwd * randf_range(3.0, 7.0) + side_v * randf_range(-3.5, 3.5)
		pos.y = battle.map.height_at(pos) + 0.3
		_impact = pos


## Face along the velocity and bank into turns; both fade to a clean nose-down dive.
func _pose(old_dir: Vector3, new_dir: Vector3, dt: float) -> void:
	if _vel.length() < 0.1:
		return
	Fx._face(self, _vel)
	var yaw_rate := Vector2(old_dir.x, old_dir.z).angle_to(Vector2(new_dir.x, new_dir.z)) / maxf(dt, 0.001)
	_bank = lerpf(_bank, clampf(yaw_rate * 0.45, -0.7, 0.7), minf(1.0, dt * 5.0))
	rotate_object_local(Vector3(0.0, 0.0, 1.0), _bank)


## Infantry below blaze away at the drone; each steady rifleman adds a small chance.
## The bomber is big and shootable from further out, but higher up and much slower, so
## its per-tick chance is lower — over its long, slow pass it still ends up somewhat
## easier to bring down than an FPV, without dying to every group it transits.
func _ground_fire() -> void:
	var per := 0.008 if heavy else 0.025
	var reach := 38.0 if heavy else 35.0
	var chance := 0.0
	for u in battle.units:
		if u.side == side or u.is_vehicle or not u.is_effective():
			continue
		if Vector2(u.position.x - position.x, u.position.z - position.z).length() < reach:
			chance += per * u.alive_count()
	if randf() < minf(chance, 0.3 if heavy else 0.35):
		battle.fx.explosion(position, 0.9 if heavy else 0.5)
		_finish()


func _strike() -> void:
	var pos := _impact
	battle.fx.explosion(pos, 1.2)
	if _will_hit and target.is_targetable() and target.is_vehicle:
		target.take_penetration(FPV_PEN, pos, true, null)
	battle.blast(pos, 4.0, 0.85, 50.0, 0.0, true, 35.0, 1.5, "fpv")
	_finish()


## Ponderous level flight: in from the home edge, a slow pass over the target dropping
## bombs on a timer, then straight home. Bombs aim at where the target is at release,
## so a ~2 s fall punishes anything that stays put and spares anything that runs.
func _sim_bomber(dt: float) -> void:
	_t += dt
	_sim_bombs(dt)
	if target != null and target.is_targetable():
		target_pos = target.aim_point()  # dead target: keep bombing its last position
	var done_dropping := _dropping and _bombs_left <= 0
	var goal := Vector3(_home.x, 0.0, _home.z) if done_dropping else target_pos
	var flat := Vector2(goal.x - position.x, goal.z - position.z)
	if done_dropping and flat.length() < 6.0 and _falling.is_empty():
		_finish()
		return
	if not _dropping and flat.length() < 5.0:
		_dropping = true
		_drop_tick = 0.3
	if _dropping and _bombs_left > 0:
		_drop_tick -= dt
		if _drop_tick <= 0.0:
			_drop_tick = BOMB_INTERVAL
			_release()
	# Slow to a creeping drift while the string goes out, then push for the edge.
	var want_speed := 4.0 if _dropping and _bombs_left > 0 else speed
	var want := Vector3.ZERO
	if flat.length() > 1.0:
		want = Vector3(flat.x, 0.0, flat.y).normalized() * want_speed
	_vel = _vel.move_toward(want, 7.0 * dt)
	position += _vel * dt
	position.y = altitude + 0.4 * sin(_t * 1.6)
	if _vel.length() > 1.0:
		Fx._face(self, _vel)
	_tick -= dt
	if _tick <= 0.0:
		_tick = 0.5
		_ground_fire()


## Drop one bomb off the rack. Impact point and fall time are fixed at release, and the
## blast goes through battle.schedule so it still lands if the bomber is then shot down.
func _release() -> void:
	_bombs_left -= 1
	var start := position
	if not _racked.is_empty():
		var rb: MeshInstance3D = _racked.pop_back()
		start = rb.global_position
		rb.queue_free()
	var a := randf() * TAU
	var r := sqrt(randf()) * BOMB_SCATTER
	var aim := target_pos + Vector3(cos(a) * r, 0.0, sin(a) * r)
	aim.y = battle.map.height_at(aim)
	var fall := sqrt(2.0 * maxf(1.0, start.y - aim.y) / BOMB_GRAVITY)
	var b := battle
	b.schedule(maxf(0.0, fall - 0.75), func() -> void: b.sfx.bomb_whistle(aim))
	b.schedule(fall, func() -> void:
		b.fx.explosion(aim, 1.7)
		b.blast(aim, BOMB_RADIUS, 0.75, 55.0, BOMB_PEN, true, BOMB_STRUCT, 3.0, "bomb"))
	var mi := MeshInstance3D.new()
	mi.mesh = MeshFactory.bomber_bomb()
	battle.add_child(mi)
	mi.global_position = start
	_falling.append({"node": mi, "from": start, "to": aim, "t": 0.0, "fall": fall})


## Visual fall of released bombs: straight-line drift onto the locked impact point with
## true gravity on the vertical, so the mesh lands exactly when the scheduled blast fires.
func _sim_bombs(dt: float) -> void:
	for i in range(_falling.size() - 1, -1, -1):
		var f := _falling[i]
		f["t"] = float(f["t"]) + dt
		var t: float = f["t"]
		var fall: float = f["fall"]
		var node: MeshInstance3D = f["node"]
		if t >= fall:
			node.queue_free()
			_falling.remove_at(i)
			continue
		var from: Vector3 = f["from"]
		var to: Vector3 = f["to"]
		var k := t / fall
		node.global_position = Vector3(lerpf(from.x, to.x, k),
				from.y - 0.5 * BOMB_GRAVITY * t * t, lerpf(from.z, to.z, k))


func _sim_recon(dt: float) -> void:
	var flat := Vector3(target_pos.x - position.x, 0.0, target_pos.z - position.z)
	if not _orbiting and flat.length() > 21.0:
		position += flat.normalized() * speed * dt
		position.y = altitude
		return
	if not _orbiting:
		_orbiting = true
		_angle = atan2(-flat.z, -flat.x)
	_angle += dt * 0.6
	var orbit := target_pos + Vector3(cos(_angle) * 20.0, altitude, sin(_angle) * 20.0)
	position = position.lerp(orbit, minf(1.0, dt * 2.0))
	loiter_left -= dt
	_tick -= dt
	if _tick <= 0.0:
		_tick = 0.5
		var skill := 0.8 if side == Game.UA else 0.55
		for u in battle.units:
			if u.side == side or not u.is_targetable():
				continue
			if Vector2(u.position.x - target_pos.x, u.position.z - target_pos.z).length() > RECON_RADIUS:
				continue
			if randf() < skill * (1.0 - u.conceal_value() * 0.6):
				battle.mark_seen(u, side)
	if loiter_left <= 0.0:
		_finish()


func _finish() -> void:
	done = true
	# Bombs still falling live under battle, not under this node; their scheduled
	# blasts land regardless, so only the orphaned meshes need freeing.
	for f in _falling:
		(f["node"] as MeshInstance3D).queue_free()
	_falling.clear()
	battle.drones.erase(self)
	queue_free()
