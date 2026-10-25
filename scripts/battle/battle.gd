class_name Battle
extends Node3D
## Owns the simulation: map, units, support assets, AI, victory locations and the clock.

enum Phase { SETUP, BATTLE, ENDED }

signal message(text: String, color: Color)
signal ended(victory: bool, title: String, summary: String)

const SIGHT := 260.0
## Debris chunks still simulated; older ones are frozen in place, the oldest removed.
const DEBRIS_ACTIVE := 160
const DEBRIS_MAX := 500
const DEBRIS_SETTLE_TIME := 8.0

var map: BattleMap
var mission: Dictionary
var units: Array[Unit] = []
var vls: Array[VictoryLocation] = []
var buildings: Array[Building] = []
var drones: Array[Drone] = []
var units_root: Node3D
var fx: Fx
var view: MapView
var ai: EnemyAI
var support: Support
var phase := Phase.SETUP
var time := 0.0
## Hard ceiling on battle length (sim seconds); no mission may exceed it.
const TIME_CAP := 600.0
var time_limit := TIME_CAP
var deploy_rect := Rect2()
var stats := {"men_lost": [0, 0], "men_total": [0, 0], "vehicles_lost": [0, 0], "died_of_wounds": [0, 0]}

var _scheduled: Array = []
var _probe := false
var _spot_i := 0
var _end_check := 0.0
var _deploy_mesh: MeshInstance3D
var _debris: Array[RigidBody3D] = []
var _debris_born: Array[float] = []
## Drifting smoke screens for line of sight: {pos, until}.
var _smoke_clouds: Array[Dictionary] = []
var _smoke_tick := 0.0
## Live hand grenades: {node, from, to, t, flight, vel, landed}.
var _grenades: Array[Dictionary] = []
const GRENADE_FUSE := 3.6


func setup(m: Dictionary) -> void:
	mission = m
	_probe = Game.has_arg("probe")
	if Game.has_arg("log"):
		message.connect(func(text: String, _c: Color) -> void: print("[%s] %s" % [clock_text(time), text]))
		ended.connect(func(_v: bool, title: String, summary: String) -> void: print(title, "\n", summary))
	Game.paused = true
	Game.speed = 1.0
	map = BattleMap.new()
	var paint: Callable = m["paint"]
	paint.call(map)
	for b: Array in m.get("buildings", []):
		var r: Rect2 = b[0]
		map.paint_rect(r.position.x, r.position.y, r.end.x, r.end.y, BattleMap.T.BUILDING)
	for w: Array in m.get("wrecks", []):
		var p: Vector3 = w[1]
		map.paint_disc(Vector2(p.x, p.z), 2.6, BattleMap.T.WRECK)
	map.finalize()
	view = MapView.new()
	add_child(view)
	view.build(map, m)
	_build_ground()
	fx = Fx.new()
	add_child(fx)
	for b: Array in m.get("buildings", []):
		var house := Building.new()
		add_child(house)
		house.setup(self, b[0], float(b[1]), int(b[2]), bool(b[3]))
		buildings.append(house)
	units_root = Node3D.new()
	add_child(units_root)
	support = Support.new(self)
	ai = EnemyAI.new(self, m["waves"])
	time_limit = minf(float(m["time_limit"]), TIME_CAP)
	deploy_rect = m["deploy"]
	for vd: Array in m["vls"]:
		var vl := VictoryLocation.new()
		add_child(vl)
		vl.setup(self, vd[0], vd[1], vd[2])
		vls.append(vl)
	for ud: Array in m["ua_units"]:
		spawn(ud[0], Game.UA, ud[2], ud[1])
	_build_deploy_zone()


func spawn(id: String, side: int, pos: Vector3, unit_name: String) -> Unit:
	var u: Unit
	if Defs.UNITS[id].get("vehicle", false):
		u = VehicleUnit.new()
	else:
		u = InfantryUnit.new()
	units_root.add_child(u)
	u.setup(self, id, side, pos, unit_name)
	units.append(u)
	stats["men_total"][side] += u.total_count()
	return u


## Physics floor for debris (layer 1). Buildings add their own wall colliders.
func _build_ground() -> void:
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	ground.add_child(cs)
	add_child(ground)


## A tumbling chunk of masonry. Collides with the ground, walls and other debris.
func spawn_debris(xf: Transform3D, size: Vector3, color: Color, vel: Vector3) -> void:
	if size.x * size.y * size.z < 0.002:
		return
	var rb := RigidBody3D.new()
	rb.mass = clampf(size.x * size.y * size.z * 1800.0, 2.0, 400.0)
	rb.collision_layer = 2
	rb.collision_mask = 3
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = MeshFactory.lit(color)
	rb.add_child(mi)
	add_child(rb)
	rb.global_transform = xf
	rb.linear_velocity = vel
	rb.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))
	_debris.append(rb)
	_debris_born.append(time)


## Freezes settled debris so physics cost stays flat however much gets knocked down.
func _manage_debris() -> void:
	var active := 0
	for i in range(_debris.size() - 1, -1, -1):
		var rb := _debris[i]
		if rb.freeze:
			continue
		if time - _debris_born[i] > DEBRIS_SETTLE_TIME or rb.sleeping or active >= DEBRIS_ACTIVE:
			rb.freeze = true
		else:
			active += 1
	while _debris.size() > DEBRIS_MAX:
		_debris[0].queue_free()
		_debris.remove_at(0)
		_debris_born.remove_at(0)


## A smoke screen: visible cloud plus a matching patch of blocked sight that drifts with it.
## A hand grenade: high lob, bounces and rolls, then goes off on its fuse.
func throw_grenade(from: Vector3, to: Vector3, _side: int) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = MeshFactory.grenade()
	add_child(mi)
	mi.global_position = from
	var d := Vector2(to.x - from.x, to.z - from.z).length()
	_grenades.append({"node": mi, "from": from, "to": to, "t": 0.0, "flight": clampf(d / 13.0, 0.6, 1.5), "vel": Vector3.ZERO, "landed": false, "arc": d * 0.25 + 1.0})


func _sim_grenades(dt: float) -> void:
	for i in range(_grenades.size() - 1, -1, -1):
		var g := _grenades[i]
		var node: MeshInstance3D = g["node"]
		g["t"] = float(g["t"]) + dt
		var t: float = g["t"]
		var flight: float = g["flight"]
		var from: Vector3 = g["from"]
		var to: Vector3 = g["to"]
		if not g["landed"]:
			var k := minf(1.0, t / flight)
			node.global_position = from.lerp(to, k) + Vector3.UP * 4.0 * float(g["arc"]) * k * (1.0 - k)
			node.rotation += Vector3(9.0, 4.0, 0.0) * dt
			if k >= 1.0:
				g["landed"] = true
				var dir := Vector3(to.x - from.x, 0.0, to.z - from.z).normalized()
				g["vel"] = dir * randf_range(1.0, 3.0)
				_grenade_alarm(to)
		else:
			var v: Vector3 = g["vel"]
			var np := node.global_position + v * dt
			np.y = map.height_at(np) + 0.06
			node.global_position = np
			g["vel"] = v * exp(-3.5 * dt)
		if t >= GRENADE_FUSE:
			var pos := node.global_position
			node.queue_free()
			_grenades.remove_at(i)
			fx.explosion(pos, 1.1)
			blast(pos, 6.0, 0.7, 45.0, 0.0, false, 30.0, 1.5)


## Men who see a grenade land near them throw themselves flat away from it.
func _grenade_alarm(at: Vector3) -> void:
	for u in units:
		if not (u is InfantryUnit) or not u.is_targetable():
			continue
		for s in (u as InfantryUnit).members:
			var away := Vector3(s.position.x - at.x, 0.0, s.position.z - at.z)
			if s.alive and away.length() < 7.0 and randf() < 0.75:
				var dir := away if away.length() > 0.3 else Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1))
				schedule(randf_range(0.15, 0.6), func() -> void: s.dive(dir))
			if s.alive and away.length() < 7.0 and u.side == Game.UA:
				notify(u, "Grenade!", true)


func on_died_of_wounds(u: Unit) -> void:
	stats["died_of_wounds"][u.side] += 1


func add_smoke_cloud(pos: Vector3, duration: float) -> void:
	fx.smoke_screen(pos, duration)
	_smoke_clouds.append({"pos": pos, "until": time + duration + 6.0})


func _drift_smoke(dt: float) -> void:
	_smoke_tick -= dt
	if _smoke_tick > 0.0:
		return
	_smoke_tick = 0.5
	for i in range(_smoke_clouds.size() - 1, -1, -1):
		var c := _smoke_clouds[i]
		if time > float(c["until"]):
			_smoke_clouds.remove_at(i)
			continue
		var p: Vector3 = c["pos"]
		p += Puffs.WIND * 0.5
		c["pos"] = p
		map.add_smoke(p, 9.0, 0.8)


func _build_deploy_zone() -> void:
	_deploy_mesh = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = deploy_rect.size
	_deploy_mesh.mesh = plane
	_deploy_mesh.material_override = MeshFactory.unshaded(Color(0.3, 0.6, 1.0, 0.13), true)
	_deploy_mesh.position = Vector3(deploy_rect.get_center().x, 0.6, deploy_rect.get_center().y)
	add_child(_deploy_mesh)


func in_deploy_zone(p: Vector3) -> bool:
	return deploy_rect.has_point(Vector2(p.x, p.z))


func start_battle() -> void:
	if phase != Phase.SETUP:
		return
	phase = Phase.BATTLE
	Game.paused = false
	_deploy_mesh.visible = false
	var kind := String(mission.get("kind", "defend"))
	var go := "Take the objectives." if kind == "assault" else ("Reach the objectives first." if kind == "meeting" else "Hold the line.")
	notify_msg("Battle started. %s" % go, Color(0.85, 0.92, 1.0))


func _process(delta: float) -> void:
	var dt := Game.sim_delta(delta) if phase == Phase.BATTLE else 0.0
	PhysicsServer3D.set_active(dt > 0.0)
	if dt > 0.0:
		# Large frame spikes are split so fast units never skip past path points.
		var steps := int(ceil(dt / 0.05))
		for i in steps:
			_step(dt / steps)
	for u in units:
		u.update_visuals(delta)


func _step(dt: float) -> void:
	time += dt
	map.now = time
	_run_scheduled()
	for u in units:
		u.sim(dt)
	for d in drones.duplicate():
		d.sim(dt)
	ai.sim(dt)
	support.sim(dt)
	for vl in vls:
		vl.sim(dt)
	_spot_step()
	_drift_smoke(dt)
	_sim_grenades(dt)
	if _probe:
		_probe_walls()
	_end_check -= dt
	if _end_check <= 0.0:
		_end_check = 1.0
		_manage_debris()
		_check_end()


## Dev probe (`-- probe`): asserts that no live soldier ever stands inside an
## intact-wall cell. Per-man movement must keep them out; a hit is a regression.
func _probe_walls() -> void:
	for u in units:
		if not (u is InfantryUnit):
			continue
		for s in (u as InfantryUnit).members:
			if s.alive and not map.is_passable(s.position, false):
				push_error("PROBE wall clip: %s man inside wall cell at %v, t=%.1f" % [u.display_name, s.position, time])


# --- Scheduling (runs on simulation time, so pausing freezes it) ---

func schedule(delay: float, fn: Callable) -> void:
	_scheduled.append([time + delay, fn])


func _run_scheduled() -> void:
	if _scheduled.is_empty():
		return
	var due: Array = []
	var keep: Array = []
	for s: Array in _scheduled:
		if float(s[0]) <= time:
			due.append(s)
		else:
			keep.append(s)
	_scheduled = keep
	for s: Array in due:
		var fn: Callable = s[1]
		fn.call()


# --- Spotting ---

## Checks a few units per step, so every unit is re-evaluated several times a second.
func _spot_step() -> void:
	var n := units.size()
	if n == 0:
		return
	for k in maxi(1, ceili(n / 6.0)):
		_spot_i = (_spot_i + 1) % n
		_spot(units[_spot_i])


func _spot(target: Unit) -> void:
	var obs := 1 - target.side
	if not target.is_targetable():
		target.seen[obs] = false
		return
	var elapsed := clampf(time - target.last_spot_check, 0.0, 1.0)
	target.last_spot_check = time
	var conceal := target.conceal_value()
	var recently := time - target.last_seen[obs] < 6.0
	var found := false
	for o in units:
		if o.side != obs or not o.is_targetable():
			continue
		var d := o.position.distance_to(target.position)
		if d > SIGHT:
			continue
		var vis := map.los(o.position, target.position)
		if vis < Combat.MIN_VIS:
			continue
		if d < 10.0 + 35.0 * (1.0 - conceal):
			found = true
			break
		var p := clampf(vis * (1.0 - conceal) * (1.0 - d / SIGHT * 0.6) * (2.0 if recently else 1.0), 0.0, 1.0)
		# p is the chance per half second; scale it to the time since the last check.
		if randf() < 1.0 - pow(1.0 - p, elapsed / 0.5):
			found = true
			break
	if found:
		mark_seen(target, obs)
	target.seen[obs] = time - target.last_seen[obs] < 2.5


func mark_seen(u: Unit, obs: int) -> void:
	if obs == Game.UA and not u.ever_seen[obs] and u.is_vehicle:
		notify_msg("Contact: %s spotted!" % String(u.def["name"]), Color(1.0, 0.7, 0.4))
	u.last_seen[obs] = time
	u.known_pos[obs] = u.position
	u.ever_seen[obs] = true
	u.seen[obs] = true


# --- Effects on units ---

## Explosion: casualties and suppression around pos, armour damage for vehicles close in,
## and structural damage to buildings when struct_power > 0.
func blast(pos: Vector3, radius: float, lethal: float, supp: float, pen: float, top: bool, struct_power := 0.0, struct_radius := 0.0) -> void:
	for u in units:
		if u.is_targetable():
			u.apply_blast(pos, radius, lethal, supp, pen, top)
	if struct_power > 0.0:
		for b in buildings:
			if b.near(pos, struct_radius):
				b.damage(pos, struct_power, struct_radius)
	if radius >= 4.0 and map.type_at(pos) != BattleMap.T.BUILDING:
		map.mark_crater(pos, clampf(radius * 0.45, 1.5, 3.2))
		# Dig the real heightfield and rebuild only the touched ground chunks.
		view.refresh_ground(map.deform_crater(pos, radius))


## A structure is coming down (roof cave-in or full collapse, Building): every
## soldier inside the footprint takes a direct hit roll, and every unit in or
## near the house is heavily suppressed — masonry falling around your ears.
func structural_casualties(area: Rect2, hit_chance: float, supp: float) -> void:
	var center := Vector3(area.get_center().x, 0.0, area.get_center().y)
	var r := maxf(area.size.x, area.size.y) * 0.5 + 8.0
	for u in units:
		if not u.is_targetable():
			continue
		if u is InfantryUnit:
			(u as InfantryUnit).struck_by_collapse(area, hit_chance)
		var d := u.distance_to_point(center)
		if d < r:
			u.receive_suppression(supp * (1.0 - 0.5 * d / r))


func suppress_area(pos: Vector3, r: float, amount: float, exclude: Unit, from_side: int) -> void:
	for u in units:
		if u == exclude or u.side == from_side or not u.is_targetable():
			continue
		var d := u.distance_to_point(pos)
		if d < r:
			u.receive_suppression(amount * (1.0 - d / r))


func pick_unit(p: Vector3, side: int, need_seen: bool) -> Unit:
	var best: Unit = null
	var best_d := 6.0
	for u in units:
		if u.side != side or not u.is_targetable():
			continue
		if need_seen and not u.seen[Game.UA]:
			continue
		var d := u.distance_to_point(p)
		if d < best_d:
			best_d = d
			best = u
	return best


# --- Events and messages ---

func notify(u: Unit, text: String, urgent: bool) -> void:
	if u.side == Game.UA:
		message.emit(text, Color(1.0, 0.45, 0.35) if urgent else Color(1.0, 0.8, 0.45))


## Message about any unit; enemy news shows in green because it is good for the player.
func notify_any(u: Unit, text: String) -> void:
	if u.side == Game.UA:
		message.emit(text, Color(1.0, 0.55, 0.4))
	elif u.ever_seen[Game.UA]:
		message.emit(text, Color(0.6, 0.95, 0.55))


func notify_msg(text: String, color: Color) -> void:
	message.emit(text, color)


func on_casualty(u: Unit) -> void:
	stats["men_lost"][u.side] += 1
	for o in units:
		if o != u and o.side == u.side and o.is_targetable() and o.position.distance_to(u.position) < 35.0:
			o.morale_hit(2.0)


func on_unit_lost(u: Unit) -> void:
	if u.is_vehicle and u.state == Unit.State.DESTROYED:
		stats["vehicles_lost"][u.side] += 1
		stats["men_lost"][u.side] += u.total_count()
		if u.side == Game.UA:
			notify_msg("%s destroyed!" % u.display_name, Color(1.0, 0.35, 0.3))
		else:
			notify_msg("Enemy %s destroyed!" % String(u.def["name"]), Color(0.6, 0.95, 0.55))
	elif u.side == Game.UA:
		notify_msg("%s lost" % u.display_name, Color(1.0, 0.35, 0.3))
	for o in units:
		if o != u and o.side == u.side and o.is_targetable() and o.position.distance_to(u.position) < 50.0:
			o.morale_hit(6.0)


# --- Victory ---

func held_count(side: int) -> int:
	var n := 0
	for vl in vls:
		if vl.owner_side == side:
			n += 1
	return n


func _check_end() -> void:
	var kind := String(mission.get("kind", "defend"))
	var ua_alive := 0
	for u in units:
		if u.side == Game.UA and u.is_targetable() and u.state != Unit.State.ROUTED:
			ua_alive += 1
	if ua_alive == 0:
		_finish(false, "Your force has been destroyed.")
	elif ai.all_spawned() and ai.alive_count() == 0:
		var cleared := "The assault has been broken."
		if kind == "assault":
			cleared = "The position has been cleared."
		elif kind == "meeting":
			cleared = "The enemy force is destroyed. The field is yours."
		_finish(true, cleared)
	elif time >= time_limit:
		var held := held_count(Game.UA)
		var win := held * 2 > vls.size()
		match kind:
			"assault":
				_finish(win, "Objectives taken: %d of %d." % [held, vls.size()] if win else "The attack failed. You hold %d of %d positions." % [held, vls.size()])
			"meeting":
				_finish(win, "You control the field: %d of %d positions." % [held, vls.size()] if win else "The enemy controls the field. You hold %d of %d positions." % [held, vls.size()])
			_:
				if win:
					_finish(true, "You held %d of %d positions." % [held, vls.size()])
				else:
					_finish(false, "The enemy took %d of %d positions." % [vls.size() - held, vls.size()])


func _finish(victory: bool, reason: String) -> void:
	phase = Phase.ENDED
	Game.paused = true
	var lost: Array = stats["men_lost"]
	var total: Array = stats["men_total"]
	var veh: Array = stats["vehicles_lost"]
	var cas := _casualty_breakdown(Game.UA)
	var summary := "%s\n\nYour losses: %d of %d men, %d vehicles\n   killed %d, wounded %d (%d treated)\nEnemy losses: %d of %d men, %d vehicles\nTime: %s" % [
		reason, lost[0], total[0], veh[0], cas[0], cas[1], cas[2], lost[1], total[1], veh[1], clock_text(time)]
	ended.emit(victory, "VICTORY" if victory else "DEFEAT", summary)


## [killed, wounded, treated] among a side's infantry.
func _casualty_breakdown(side: int) -> Array[int]:
	var out: Array[int] = [0, 0, 0]
	for u in units:
		if u.side != side or not (u is InfantryUnit):
			continue
		for s in (u as InfantryUnit).members:
			if s.wounded:
				out[1] += 1
				if s.stabilized:
					out[2] += 1
			elif s.killed and not s.alive:
				out[0] += 1
	return out


static func clock_text(t: float) -> String:
	var s := maxi(0, int(t))
	return "%02d:%02d" % [s / 60, s % 60]


func add_drone(d: Drone) -> void:
	drones.append(d)
	add_child(d)
