class_name Drone
extends Node3D
## A recon quadcopter that circles an area revealing enemies, or an FPV kamikaze drone
## that hunts one unit. Infantry under an FPV's path may shoot it down.

const RECON_RADIUS := 55.0
const FPV_PEN := 350.0
const COMMIT_DIST := 26.0  # flat distance at which the FPV rolls its hit and dives
const HIT_DIST := 2.2
const DIVE_SPEED := 46.0
const TURN_RATE := 3.2  # rad/s of steering authority at cruise
const DIVE_TURN_RATE := 7.0

var battle: Battle
var side := 0
var fpv := false
var target: Unit = null
var target_pos := Vector3.ZERO
var altitude := 30.0
var speed := 20.0
var loiter_left := 0.0
var done := false
var _tick := 0.0
var _angle := 0.0
var _orbiting := false
var _warn: Label3D

# FPV flight state.
var _vel := Vector3.ZERO
var _t := 0.0  # sim-time flight clock (wobble phase)
var _committed := false
var _will_hit := false
var _impact := Vector3.ZERO  # locked detonation point; tracks the aim while a hit target lives
var _bank := 0.0


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
	if s == Game.RU:
		# Warning marker over the hunted unit: the player has seconds to react.
		_warn = Unit._make_label()
		_warn.text = "FPV!"
		_warn.font_size = 34
		_warn.modulate = Color(1.0, 0.3, 0.25)
		_warn.top_level = true
		add_child(_warn)


func _common(start: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = MeshFactory.drone(fpv)
	add_child(mi)
	position = Vector3(start.x, altitude, start.z)


func sim(dt: float) -> void:
	if done:
		return
	if fpv:
		_sim_fpv(dt)
	else:
		_sim_recon(dt)


func _sim_fpv(dt: float) -> void:
	_t += dt
	if target.is_targetable():
		var aim := target.aim_point()
		if _warn != null:
			_warn.global_position = aim + Vector3.UP * 4.0
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


## Infantry within 35 m blaze away at the drone; each steady rifleman adds a small chance.
func _ground_fire() -> void:
	var chance := 0.0
	for u in battle.units:
		if u.side == side or u.is_vehicle or not u.is_effective():
			continue
		if Vector2(u.position.x - position.x, u.position.z - position.z).length() < 35.0:
			chance += 0.025 * u.alive_count()
	if randf() < minf(chance, 0.35):
		battle.fx.explosion(position, 0.5)
		battle.notify_msg("FPV drone shot down!" if side == Game.RU else "Our FPV was shot down", Color(0.75, 0.9, 1.0))
		_finish()


func _strike() -> void:
	var pos := _impact
	battle.fx.explosion(pos, 1.2)
	if _will_hit and target.is_targetable() and target.is_vehicle:
		target.take_penetration(FPV_PEN, pos, true, null)
	battle.blast(pos, 4.0, 0.85, 50.0, 0.0, true, 35.0, 1.5)
	_finish()


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
	battle.drones.erase(self)
	queue_free()
