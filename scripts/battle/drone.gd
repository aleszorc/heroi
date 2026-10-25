class_name Drone
extends Node3D
## A recon quadcopter that circles an area revealing enemies, or an FPV kamikaze drone
## that hunts one unit. Infantry under an FPV's path may shoot it down.

const RECON_RADIUS := 55.0
const FPV_PEN := 350.0

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
	if not target.is_targetable():
		battle.fx.explosion(Vector3(position.x, battle.map.height_at(position), position.z), 0.8)
		_finish()
		return
	var aim := target.aim_point()
	if _warn != null:
		_warn.global_position = aim + Vector3.UP * 4.0
	var flat := Vector2(aim.x - position.x, aim.z - position.z).length()
	# Cruise at altitude, then dive over the last 30 m.
	var goal_y := altitude if flat > 30.0 else lerpf(aim.y, altitude, flat / 30.0)
	var to := Vector3(aim.x, goal_y, aim.z) - position
	if (aim - position).length() < 1.6:
		_strike()
		return
	position += to.normalized() * minf(speed * dt, to.length())
	if to.length() > 0.1:
		Fx._face(self, to)
	_tick -= dt
	if _tick <= 0.0:
		_tick = 0.5
		_ground_fire()


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
	var p := 0.8
	if not target.is_vehicle:
		var t := battle.map.type_at(target.position)
		if t == BattleMap.T.BUILDING or t == BattleMap.T.TRENCH:
			p = 0.55
	elif not target.arrived:
		p = 0.7
	var hit := randf() < p
	var pos := target.aim_point()
	if not hit:
		pos = target.position + Vector3(randf_range(-5.0, 5.0), 0.0, randf_range(-5.0, 5.0))
		pos.y = battle.map.height_at(pos) + 0.3
	battle.fx.explosion(pos, 1.2)
	if hit and target.is_vehicle:
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
