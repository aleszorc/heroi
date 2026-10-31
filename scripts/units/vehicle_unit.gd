class_name VehicleUnit
extends Unit
## A single armoured vehicle with a rotating turret and several weapons.

const TURN_RATE := 1.3
const TURRET_RATE := 1.4
const ACCEL := 2.2
const BRAKE := 5.0
## Suspension spring: stiffness and damping of hull pitch and roll.
const SPRING_K := 35.0
const SPRING_D := 6.0

var hull: MeshInstance3D
var turret: MeshInstance3D
var muzzle := Vector3.ZERO
var turret_yaw := 0.0
var cooldowns := {}
var immobile := false
var gun_out := false
var reversing := false
var crew := 3
var _aim_unit: Unit = null
## Signed ground speed (negative when reversing) and the hull's sway.
var speed_now := 0.0
var _pitch := 0.0
var _roll := 0.0
var _pitch_v := 0.0
var _roll_v := 0.0
var _yaw_rate := 0.0
var _dust_acc := 0.0
## Timers for acting without orders (pace re-pick, FPV dodge).
var _auto_tick := 0.0
var _next_dodge := 0.0


func _build() -> void:
	var parts := MeshFactory.vehicle(String(def["mesh"]))
	hull = MeshInstance3D.new()
	hull.mesh = parts["hull"]
	add_child(hull)
	turret = MeshInstance3D.new()
	turret.mesh = parts["turret"]
	turret.position = parts["turret_pos"]
	hull.add_child(turret)
	muzzle = parts["muzzle"]
	crew = def["crew"]
	for w: String in def["weapons"]:
		cooldowns[w] = Game.rng.randf_range(0.5, 2.0)
	hull.rotation.y = heading


func alive_count() -> int:
	return 0 if state == State.DESTROYED else crew


func total_count() -> int:
	return int(def["crew"])


func _weapon_ids() -> Array[String]:
	var out: Array[String] = []
	out.assign(def["weapons"])
	return out


func armor_side() -> float:
	return float(def["armor"][1])


func status_text() -> String:
	if state == State.DESTROYED:
		return "Destroyed"
	if immobile:
		return "Immobilized"
	if gun_out:
		return "Weapons out"
	return STATE_NAMES[state]


func cover_here() -> float:
	return 0.0


func conceal_value() -> float:
	var c := map.conceal_at(position) * 0.5
	if battle.time - last_moved < 2.0:
		c *= 0.4
	if battle.time - last_fired < 3.0:
		c *= 0.4
	return c


func _can_drive() -> bool:
	return not immobile


func _on_path_set(target: Vector3) -> void:
	var to := Vector3(target.x - position.x, 0.0, target.z - position.z)
	# Short moves to the rear are driven in reverse, keeping the thick front armour to the enemy.
	reversing = to.length() < 45.0 and forward().dot(to.normalized()) < -0.3


func _speed() -> float:
	var s: float = def["speed"]
	if pace != Pace.RUN:
		s *= 0.7
	if reversing:
		s *= 0.5
	return s * map.speed_factor(position, true)


## Acting without orders: re-pick the pace mid-drive and scramble away from an FPV.
func _auto_tactics() -> void:
	if not arrived:
		if battle.time >= pace_lock:
			pace = _choose_pace()
		return
	if not can_move() or battle.time < _next_dodge:
		return
	var fpv := incoming_fpv()
	if fpv == null:
		return
	var away := Vector3(position.x - fpv.position.x, 0.0, position.z - fpv.position.z)
	away = away.normalized() if away.length() > 1.0 else forward()
	for dir: Vector3 in [away, Vector3(-away.z, 0.0, away.x), Vector3(away.z, 0.0, -away.x)]:
		if _set_path(position + dir * 24.0):
			pace = Pace.RUN
			pace_lock = battle.time + 8.0
			_next_dodge = battle.time + 12.0
			return


func _sim_move(dt: float) -> void:
	_auto_tick -= dt
	if _auto_tick <= 0.0:
		_auto_tick = 0.7
		_auto_tactics()
	if immobile and not arrived:
		_halt()
	var target_speed := 0.0
	var prev_heading := heading
	if not arrived:
		var target := path[path_i]
		var to := Vector3(target.x - position.x, 0.0, target.z - position.z)
		var d := to.length()
		var last := path_i == path.size() - 1
		if d < (1.5 if last else 3.0):
			path_i += 1
			if path_i >= path.size():
				_reach_end()
		else:
			var desired := yaw_to(to)
			if reversing:
				desired = wrapf(desired + PI, -PI, PI)
			var diff := wrapf(desired - heading, -PI, PI)
			heading += clampf(diff, -TURN_RATE * dt, TURN_RATE * dt)
			# Slow for sharp turns and for the final stop, so it rolls in rather than halting dead.
			target_speed = 0.0 if absf(diff) > 1.0 else _speed() * (1.0 - absf(diff) * 0.6)
			if last:
				target_speed = minf(target_speed, d * 0.8 + 0.5)
			if reversing:
				target_speed = -target_speed
	elif is_guarding() and not immobile:
		# Defending vehicles pivot to put their front armour towards the chosen facing.
		var turn := wrapf(yaw_to(guard_dir) - heading, -PI, PI)
		heading += clampf(turn, -TURN_RATE * 0.6 * dt, TURN_RATE * 0.6 * dt)
	var rate := ACCEL if absf(target_speed) > absf(speed_now) else BRAKE
	var before := speed_now
	speed_now = move_toward(speed_now, target_speed, rate * dt)
	var accel := (speed_now - before) / maxf(dt, 0.0001)
	_yaw_rate = wrapf(heading - prev_heading, -PI, PI) / maxf(dt, 0.0001)
	if absf(speed_now) > 0.05:
		position += forward() * speed_now * dt
		position.x = clampf(position.x, -BattleMap.HALF + 2.0, BattleMap.HALF - 2.0)
		position.z = clampf(position.z, -BattleMap.HALF + 2.0, BattleMap.HALF - 2.0)
		last_moved = battle.time
	_suspension(dt, accel)
	_aim_turret(dt)
	_emit_dust(dt)


## Hull follows the ground slope and rocks on its springs when accelerating, braking,
## turning or firing.
func _suspension(dt: float, accel: float) -> void:
	var f := forward()
	var r := Vector3(cos(heading), 0.0, -sin(heading))
	var hf := map.height_at(position + f * 2.6)
	var hb := map.height_at(position - f * 2.6)
	var hr := map.height_at(position + r * 1.4)
	var hl := map.height_at(position - r * 1.4)
	position.y = (hf + hb + hr + hl) * 0.25
	var want_pitch := atan2(hf - hb, 5.2) + clampf(accel, -6.0, 6.0) * 0.012
	var want_roll := atan2(hl - hr, 2.8) + clampf(_yaw_rate * speed_now, -6.0, 6.0) * 0.012
	_pitch_v += ((want_pitch - _pitch) * SPRING_K - _pitch_v * SPRING_D) * dt
	_roll_v += ((want_roll - _roll) * SPRING_K - _roll_v * SPRING_D) * dt
	_pitch += _pitch_v * dt
	_roll += _roll_v * dt
	hull.rotation = Vector3(_pitch, heading, _roll)


## Recoil of a heavy gun pushes the hull back on its springs, away from where the turret points.
func _kick(strength: float) -> void:
	var aim_yaw := turret_yaw
	_pitch_v += cos(aim_yaw) * strength
	_roll_v += -sin(aim_yaw) * strength


func _emit_dust(dt: float) -> void:
	var spd := absf(speed_now)
	if spd < 1.0 or state == State.DESTROYED:
		return
	_dust_acc += dt * spd * 0.9
	var r := Vector3(cos(heading), 0.0, -sin(heading))
	while _dust_acc >= 1.0:
		_dust_acc -= 1.0
		var side_sign := 1.0 if randf() < 0.5 else -1.0
		battle.fx.track_dust(position - forward() * 3.0 + r * 1.4 * side_sign, spd)
		if randf() < 0.3:
			battle.fx.exhaust(position - forward() * 2.8 + Vector3.UP * 1.8)


func _aim_turret(dt: float) -> void:
	var aim_at := position + forward() * 10.0
	if fire_target != null and fire_target.is_targetable():
		aim_at = fire_target.position
	elif _aim_unit != null and _aim_unit.is_targetable():
		aim_at = _aim_unit.position
	var want := wrapf(yaw_to(aim_at - position) - heading, -PI, PI)
	var diff := wrapf(want - turret_yaw, -PI, PI)
	turret_yaw += clampf(diff, -TURRET_RATE * dt, TURRET_RATE * dt)
	turret.rotation.y = turret_yaw


func _turret_on(p: Vector3) -> bool:
	var want := wrapf(yaw_to(p - position) - heading, -PI, PI)
	return absf(wrapf(want - turret_yaw, -PI, PI)) < 0.12


func _sim_fire(dt: float) -> void:
	if gun_out or state >= State.PANICKED:
		return
	var from := turret.global_transform * muzzle
	var acc := _accuracy()
	for wid: String in cooldowns.keys():
		cooldowns[wid] = float(cooldowns[wid]) - dt
		if float(cooldowns[wid]) > 0.0:
			continue
		var w: Dictionary = Defs.WEAPONS[wid]
		if w.get("halt", false) and not arrived:
			cooldowns[wid] = 0.5
			continue
		var t := pick_target(w, position)
		if t == null:
			cooldowns[wid] = 0.5
			continue
		_aim_unit = t
		if not _turret_on(t.position):
			cooldowns[wid] = 0.2
			continue
		if Combat.fire(battle, self, from, wid, t, acc):
			cooldowns[wid] = float(w["reload"]) * Game.rng.randf_range(0.9, 1.2)
			last_fired = battle.time
			_kick(clampf(float(w["blast"]) * 0.15, 0.0, 0.7))
		else:
			cooldowns[wid] = 0.6


func aim_point() -> Vector3:
	return position + Vector3.UP * 1.3


func distance_to_point(p: Vector3) -> float:
	return maxf(0.0, Vector2(position.x - p.x, position.z - p.z).length() - 1.5)


func take_hit(_pos: Vector3, _shooter: Unit) -> void:
	receive_suppression(5.0)


func take_penetration(pen: float, src: Vector3, top: bool, shooter: Unit) -> void:
	if state == State.DESTROYED:
		return
	var armor: Array = def["armor"]
	var value: float
	if top:
		if def.get("cage", false) and Game.rng.randf() < 0.4:
			return
		value = armor[2]
	else:
		var to_src := Vector3(src.x - position.x, 0.0, src.z - position.z).normalized()
		value = armor[0] if forward().dot(to_src) > 0.64 else armor[1]
	if pen * Game.rng.randf_range(0.85, 1.15) < value:
		receive_suppression(25.0)
		return
	var r := Game.rng.randf()
	if r < 0.55:
		_destroy(shooter)
	elif r < 0.72:
		immobile = true
	elif r < 0.88:
		gun_out = true
	else:
		crew -= 1
		morale_hit(25.0)
		if crew <= 0:
			_destroy(shooter)


func _destroy(shooter: Unit) -> void:
	state = State.DESTROYED
	var parts := MeshFactory.vehicle(String(def["mesh"]), true)
	hull.mesh = parts["hull"]
	turret.mesh = parts["turret"]
	turret.rotation = Vector3(randf_range(0.05, 0.25), turret_yaw + randf_range(-0.5, 0.5), randf_range(-0.2, 0.2))
	battle.fx.explosion(position + Vector3.UP, 3.0)
	battle.fx.burn(self)
	speed_now = 0.0
	# Ammunition cook-off: carousel-loaded tanks famously throw their turret.
	if def_id == "ru_t72" or randf() < 0.15:
		_toss_turret(parts["turret"])
	if shooter != null:
		shooter.kills += 1
	battle.on_unit_lost(self)


func _toss_turret(mesh: Mesh) -> void:
	var xf := turret.global_transform
	turret.visible = false
	var rb := RigidBody3D.new()
	rb.mass = 2000.0
	rb.collision_layer = 2
	rb.collision_mask = 3
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.4, 0.9, 2.6)
	cs.shape = box
	cs.position.y = 0.3
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	rb.add_child(mi)
	battle.add_child(rb)
	rb.global_transform = xf
	rb.linear_velocity = Vector3(randf_range(-3, 3), randf_range(9, 14), randf_range(-3, 3))
	rb.angular_velocity = Vector3(randf_range(-3, 3), randf_range(-2, 2), randf_range(-3, 3))
	battle.fx.explosion(xf.origin, 2.5)


func apply_blast(pos: Vector3, radius: float, _lethal: float, supp: float, pen: float, top: bool) -> void:
	var d := Vector2(position.x - pos.x, position.z - pos.z).length()
	if pen > 0.0 and d < maxf(radius * 0.4, 2.5):
		take_penetration(pen, pos, top, null)
	elif d < radius * 2.0:
		receive_suppression(supp)


func teleport(p: Vector3) -> void:
	super.teleport(p)
	order_stop()


func _set_body_visible(v: bool) -> void:
	hull.visible = v
