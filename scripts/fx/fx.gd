class_name Fx
extends Node3D
## Visual effects. Tracers are thin glowing boxes; everything gaseous (smoke screens,
## explosions, dust, fire, missile trails) is made of 3D puffs from the Puffs system.

var puffs: Puffs
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

func shot(from: Vector3, to: Vector3, w: Dictionary) -> void:
	var kind: String = w["fx"]
	var spd: float = w["speed"]
	muzzle(from, 0.35 if kind == "bullet" else 0.9)
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


func muzzle(pos: Vector3, size: float) -> void:
	puffs.glow.emit(pos, Vector3.ZERO, 0.07, size * 0.6, size, Color(1.0, 0.85, 0.4), 0.0, 0.0)
	if size > 0.5:
		for i in 3:
			puffs.smoke.emit(pos, _rand_dir() * 0.8, randf_range(0.8, 1.4), 0.3, 1.0, _grey(0.55, 0.7, 0.8), 2.0, 0.3)


## Big guns kick up a ring of dust under the muzzle.
func gun_blast(pos: Vector3) -> void:
	for i in 12:
		var a := i * TAU / 12.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		puffs.smoke.emit(Vector3(pos.x, maxf(0.3, pos.y - 1.5), pos.z) + dir, dir * randf_range(4.0, 7.0), randf_range(1.2, 2.2), 0.6, 2.0, Color(0.5, 0.44, 0.34, 0.9), 2.5, 0.2)


# --- Explosions, dust, fire ---

func explosion(pos: Vector3, size: float) -> void:
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


func crater(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = MeshFactory.crater()
	add_child(mi)
	mi.global_position = pos + Vector3.UP * 0.02
	mi.rotation.y = randf() * TAU


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
	# Dense burst for the first two seconds, then a steady feed.
	var rate := 34.0 if age < 2.0 else 6.0
	e["acc"] = float(e["acc"]) + rate * dt
	var center: Vector3 = e["pos"]
	center += Puffs.WIND * age
	while float(e["acc"]) >= 1.0:
		e["acc"] = float(e["acc"]) - 1.0
		var a := randf() * TAU
		var out := Vector3(cos(a), 0.0, sin(a))
		var v := out * randf_range(1.0, 3.5) + Vector3.UP * randf_range(0.1, 0.5)
		var p := center + out * randf_range(0.0, 1.5) + Vector3.UP * 0.6
		var tone := _grey(0.62, 0.8)
		tone.b += 0.03
		puffs.smoke.emit(p, v, randf_range(18.0, 28.0), 0.6, randf_range(2.2, 4.8), tone, 0.35, 0.03)


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
