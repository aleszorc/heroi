class_name Fx
extends Node3D
## Visual effects. Tracers are thin glowing boxes; everything gaseous (smoke screens,
## explosions, dust, fire, missile trails) is made of 3D puffs from the Puffs system.

var puffs: Puffs
## Audio sibling; explosions and order markers sound from here so every caller is covered.
var sfx: Sfx
var _tracer := BoxMesh.new()
var _ring := TorusMesh.new()
## Sustained emitters: {kind, pos, node, until, acc}.
var _emitters: Array[Dictionary] = []
## Flying missiles that leave smoke trails: {node, last}.
var _missiles: Array[Dictionary] = []
var _time := 0.0


func _ready() -> void:
	puffs = Puffs.new()
	add_child(puffs)
	_tracer.size = Vector3(0.08, 0.08, 1.8)
	_ring.inner_radius = 0.85
	_ring.outer_radius = 1.0
	_ring.rings = 20
	_ring.ring_segments = 3


static func _rand_dir() -> Vector3:
	return Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()


static func _grey(lo: float, hi: float, a := 1.0) -> Color:
	var v := randf_range(lo, hi)
	return Color(v, v * 0.98, v * 0.95, a)


# --- Shots ---

func shot(from: Vector3, to: Vector3, w: Dictionary, wid := "") -> void:
	var kind: String = w["fx"]
	var spd: float = w["speed"]
	if kind == "bullet":
		muzzle_flash(from, (to - from).normalized(), wid)
	else:
		muzzle(from, 0.9)
	match kind:
		"bullet":
			_projectile(from, to, Color(1.0, 0.82, 0.45), spd, 1.0, false)
		"shell":
			_projectile(from, to, Color(1.0, 0.62, 0.3), spd, 1.8, false)
			if float(w["blast"]) >= 4.0:
				gun_blast(from)
		_:
			_projectile(from, to, Color(1.0, 0.92, 0.75), spd, 1.4, true)


func _projectile(from: Vector3, to: Vector3, color: Color, spd: float, thick: float, trail: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _tracer
	mi.material_override = MeshFactory.unshaded(color)
	add_child(mi)
	mi.global_position = from
	_face(mi, to - from)
	mi.scale = Vector3(thick, thick, 0.35 if trail else 1.0)
	if trail:
		_missiles.append({"node": mi, "last": from})
	var tw := mi.create_tween()
	tw.tween_property(mi, "global_position", to, maxf(from.distance_to(to) / spd, 0.05))
	tw.tween_callback(mi.queue_free)


## Big-gun muzzle flash (shells, rockets, missiles): the original round glow plus smoke.
func muzzle(pos: Vector3, size: float) -> void:
	puffs.glow.emit(pos, Vector3.ZERO, 0.07, size * 0.6, size, Color(1.0, 0.85, 0.4), 0.0, 0.0)
	if size > 0.5:
		for i in 3:
			puffs.smoke.emit(pos, _rand_dir() * 0.8, randf_range(0.8, 1.4), 0.3, 1.0, _grey(0.55, 0.7, 0.8), 2.0, 0.3)


## Small-arms muzzle fire: a 1-2 frame directional flash (hot core, short jet along the
## barrel, faint star spikes) plus one quick wisp of powder smoke. Sized per weapon class;
## machine guns leave a brief flickering emitter so a burst strobes. All unshaded glow
## puffs, so the flash reads in shadow.
func muzzle_flash(pos: Vector3, dir: Vector3, wid := "") -> void:
	if dir.length_squared() < 0.01:
		dir = Vector3.FORWARD
	var s := 0.26
	match wid:
		"pkm", "coax":
			s = 0.34
			_emitters.append({"kind": "flash", "pos": pos, "dir": dir,
					"until": _time + 0.16, "acc": 0.0, "s": s})
		"sniper":
			s = 0.48
	_flash(pos, dir, s)
	puffs.smoke.emit(pos + dir * 0.15, dir * randf_range(0.4, 0.8) + Vector3.UP * 0.3,
			randf_range(0.5, 0.8), 0.07, randf_range(0.25, 0.4), _grey(0.6, 0.75, 0.35), 2.5, 0.4)


## One flash: 4 glow puffs, each alive ~0.05 s.
func _flash(pos: Vector3, dir: Vector3, s: float) -> void:
	puffs.glow.emit(pos, Vector3.ZERO, 0.05, s * 0.8, s, Color(1.0, 0.93, 0.6), 0.0, 0.0)
	puffs.glow.emit(pos + dir * s * 0.9, dir * 1.5, 0.05, s * 0.45, s * 0.6,
			Color(1.0, 0.72, 0.3), 0.0, 0.0)
	var side := dir.cross(Vector3.UP)
	side = Vector3.RIGHT if side.length_squared() < 0.01 else side.normalized()
	for sgn: float in [1.0, -1.0]:
		puffs.glow.emit(pos + side * sgn * s * 0.45, side * sgn * 0.8, 0.04, s * 0.3, s * 0.4,
				Color(1.0, 0.7, 0.3, 0.9), 0.0, 0.0)


## The flicker an MG burst keeps up for a few rounds after the first flash.
func _emit_flash(e: Dictionary, dt: float) -> void:
	e["acc"] = float(e["acc"]) + dt
	while float(e["acc"]) >= 0.055:
		e["acc"] = float(e["acc"]) - 0.055
		if randf() < 0.75:
			_flash(e["pos"], e["dir"], float(e["s"]) * randf_range(0.65, 1.0))


## Big guns kick up a ring of dust under the muzzle.
func gun_blast(pos: Vector3) -> void:
	for i in 12:
		var a := i * TAU / 12.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		puffs.smoke.emit(Vector3(pos.x, maxf(0.3, pos.y - 1.5), pos.z) + dir, dir * randf_range(4.0, 7.0), randf_range(1.2, 2.2), 0.6, 2.0, Color(0.5, 0.44, 0.34, 0.9), 2.5, 0.2)


# --- Explosions, dust, fire ---

func explosion(pos: Vector3, size: float) -> void:
	if sfx != null:
		sfx.explosion(pos, size)
	for i in int(5 + size * 4):
		puffs.glow.emit(pos + _rand_dir() * size * 0.4, _rand_dir() * size * 3.0 + Vector3.UP * size, randf_range(0.12, 0.3), size * 0.6, size * 2.0, Color(1.0, randf_range(0.6, 0.85), 0.3), 4.0, 2.0)
	for i in int(5 + size * 5):
		var v := _rand_dir() * randf_range(1.5, 4.0) * sqrt(size)
		v.y = absf(v.y) + 1.5
		puffs.smoke.emit(pos + Vector3.UP * 0.3, v, randf_range(2.5, 5.0), size * 0.5, size * randf_range(2.0, 3.0), _grey(0.2, 0.32), 1.5, 1.0)
	for i in int(4 + size * 4):
		var a := randf() * TAU
		var v := Vector3(cos(a), 0.15, sin(a)) * randf_range(3.0, 6.0) * sqrt(size)
		puffs.smoke.emit(pos + Vector3.UP * 0.2, v, randf_range(1.5, 3.0), size * 0.4, size * 1.8, Color(0.45, 0.38, 0.29), 2.0, 0.2)
	# Clods of earth thrown up and falling back.
	for i in int(4 + size * 3):
		var v := Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1)) * 3.0 * sqrt(size) + Vector3.UP * randf_range(5.0, 9.0) * sqrt(size)
		puffs.smoke.emit(pos, v, randf_range(0.9, 1.4), 0.25, 0.2, Color(0.28, 0.22, 0.16), 0.1, -12.0)


## A burst of dust, e.g. masonry crumbling.
func dust(pos: Vector3, amount: int, size: float) -> void:
	for i in amount:
		var v := _rand_dir() * randf_range(0.5, 2.0)
		v.y = absf(v.y)
		puffs.smoke.emit(pos + _rand_dir() * size * 0.5, v, randf_range(2.0, 4.0), size * 0.5, size * 1.8, Color(0.58, 0.54, 0.47), 1.2, 0.3)


## A running bootstep kicks a puff of dust off the ground.
func step_dust(pos: Vector3) -> void:
	puffs.smoke.emit(pos + Vector3(0.0, 0.08, 0.0),
			Vector3(randf_range(-0.3, 0.3), 0.6, randf_range(-0.3, 0.3)),
			randf_range(0.45, 0.75), 0.1, 0.4, Color(0.5, 0.45, 0.36, 0.45), 1.5, 0.4)


## Track dust behind a moving vehicle.
func track_dust(pos: Vector3, speed: float) -> void:
	puffs.smoke.emit(pos + Vector3(randf_range(-0.5, 0.5), 0.3, randf_range(-0.5, 0.5)), Vector3.UP * 0.5, randf_range(1.5, 2.5) + speed * 0.1, 0.6, 2.0 + speed * 0.15, Color(0.5, 0.45, 0.36, 0.75), 1.0, 0.25)


func exhaust(pos: Vector3) -> void:
	puffs.smoke.emit(pos, Vector3.UP * 1.0, randf_range(1.0, 1.8), 0.3, 1.2, _grey(0.15, 0.22, 0.8), 1.0, 0.8)


## A smoke grenade: a thick billowing burst, then the canister keeps feeding the cloud.
func smoke_screen(pos: Vector3, duration: float) -> void:
	_emitters.append({"kind": "smoke", "pos": pos, "until": _time + duration, "acc": 0.0, "start": _time})


## Endless fire and black smoke for a burning wreck; follows `node`.
func burn(node: Node3D) -> void:
	_emitters.append({"kind": "fire", "node": node, "until": INF, "acc": 0.0, "start": _time})


func _process(delta: float) -> void:
	var dt := Game.sim_delta(delta)
	if dt <= 0.0:
		return
	_time += dt
	for i in range(_emitters.size() - 1, -1, -1):
		var e := _emitters[i]
		if _time > float(e["until"]):
			_emitters.remove_at(i)
			continue
		match String(e["kind"]):
			"smoke":
				_emit_smoke(e, dt)
			"fire":
				_emit_fire(e, dt)
			"flash":
				_emit_flash(e, dt)
	for i in range(_missiles.size() - 1, -1, -1):
		var m := _missiles[i]
		if not is_instance_valid(m["node"]):
			_missiles.remove_at(i)
			continue
		var node: Node3D = m["node"]
		var now := node.global_position
		var last: Vector3 = m["last"]
		var steps := int(now.distance_to(last) / 0.8)
		for k in steps:
			puffs.smoke.emit(last.lerp(now, float(k) / steps), _rand_dir() * 0.2, randf_range(1.2, 2.2), 0.25, 0.9, _grey(0.78, 0.88, 0.85), 1.0, 0.2)
		if steps > 0:
			m["last"] = now


func _emit_smoke(e: Dictionary, dt: float) -> void:
	var age := _time - float(e["start"])
	# Dense burst while the cloud establishes itself, then a steady feed.
	var rate := 26.0 if age < 3.5 else 6.0
	e["acc"] = float(e["acc"]) + rate * dt
	var center: Vector3 = e["pos"]
	center += Puffs.WIND * age
	# The cloud frontier advances because fresh smoke appears there already thick, not
	# because lone puffs fly out and inflate later: spawn inside a disc that grows to
	# the sight-blocking radius, each puff near-stationary and at full size within ~2 s.
	var reach := lerpf(0.8, 6.5, minf(age / 3.5, 1.0))
	while float(e["acc"]) >= 1.0:
		e["acc"] = float(e["acc"]) - 1.0
		var a := randf() * TAU
		var out := Vector3(cos(a), 0.0, sin(a))
		var r := sqrt(randf()) * reach
		var p := center + out * r + Vector3.UP * randf_range(0.3, 1.3)
		var v := out * randf_range(0.2, 0.8) + Vector3.UP * randf_range(0.1, 0.4)
		var tone := _grey(0.62, 0.8)
		tone.b += 0.03
		puffs.smoke.emit(p, v, randf_range(18.0, 28.0), 0.9, randf_range(2.6, 4.6), tone,
				0.9, 0.04, randf_range(1.2, 2.4))
	# The canister itself keeps billowing: a quick, narrow column at the centre.
	e["jet"] = float(e.get("jet", 0.0)) + dt
	while float(e["jet"]) >= 0.12:
		e["jet"] = float(e["jet"]) - 0.12
		puffs.smoke.emit(center + Vector3.UP * 0.3,
				Vector3.UP * randf_range(1.5, 2.5) + _rand_dir() * 0.4,
				randf_range(3.5, 5.5), 0.35, randf_range(1.6, 2.4), _grey(0.68, 0.84),
				1.2, 0.15, randf_range(0.8, 1.4))


func _emit_fire(e: Dictionary, dt: float) -> void:
	if not is_instance_valid(e["node"]):
		e["until"] = 0.0
		return
	var node: Node3D = e["node"]
	var base := node.global_position + Vector3.UP * 1.4
	e["acc"] = float(e["acc"]) + dt
	while float(e["acc"]) >= 0.12:
		e["acc"] = float(e["acc"]) - 0.12
		puffs.glow.emit(base + Vector3(randf_range(-0.8, 0.8), 0.0, randf_range(-0.8, 0.8)), Vector3.UP * randf_range(1.0, 2.0), randf_range(0.4, 0.7), 0.7, 1.3, Color(1.0, randf_range(0.45, 0.7), 0.15), 1.0, 1.5)
		if randf() < 0.45:
			puffs.smoke.emit(base + Vector3.UP * 0.8, Vector3.UP * randf_range(1.5, 2.5), randf_range(6.0, 9.0), 0.8, randf_range(3.5, 5.0), _grey(0.1, 0.17), 0.4, 0.6)


func order_marker(pos: Vector3, color: Color) -> void:
	if sfx != null:
		sfx.ui_tick()
	var mi := MeshInstance3D.new()
	mi.mesh = _ring
	mi.material_override = MeshFactory.unshaded(color, true)
	add_child(mi)
	mi.global_position = pos + Vector3.UP * 0.3
	mi.scale = Vector3(3.0, 0.2, 3.0)
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3(0.6, 0.2, 0.6), 0.35)
	tw.tween_callback(mi.queue_free)


static func _face(node: Node3D, dir: Vector3) -> void:
	if dir.length() < 0.01:
		return
	var up := Vector3.UP if absf(dir.normalized().y) < 0.98 else Vector3.FORWARD
	node.look_at(node.global_position + dir, up)
