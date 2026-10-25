class_name VictoryLocation
extends Node3D
## A capturable position, held by whichever side alone has steady troops inside the radius.

const RADIUS := 16.0
const CAPTURE_TIME := 8.0

var battle: Battle
var loc_name := ""
var owner_side := -1
var progress := 0.0
var contested := false
var _top_mat := StandardMaterial3D.new()
var _bottom_mat := StandardMaterial3D.new()
var _ring_mat := StandardMaterial3D.new()


func setup(b: Battle, n: String, pos: Vector3, start_owner: int) -> void:
	battle = b
	loc_name = n
	position = Vector3(pos.x, b.map.height_at(pos), pos.z)
	var pole := MeshInstance3D.new()
	pole.mesh = MeshFactory.flag_pole()
	add_child(pole)
	for i in 2:
		var cloth := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.8, 0.55, 0.05)
		cloth.mesh = box
		cloth.position = Vector3(0.95, 5.65 - i * 0.55, 0.0)
		cloth.material_override = _top_mat if i == 0 else _bottom_mat
		add_child(cloth)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = RADIUS - 0.35
	torus.outer_radius = RADIUS
	torus.rings = 48
	torus.ring_segments = 3
	ring.mesh = torus
	ring.scale = Vector3(1.0, 0.05, 1.0)
	ring.position.y = 0.3
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring.material_override = _ring_mat
	add_child(ring)
	var label := Unit._make_label()
	label.text = n.to_upper()
	label.position.y = 7.5
	label.modulate = Color(0.95, 0.95, 0.85)
	add_child(label)
	_set_owner(start_owner, false)


func _set_owner(s: int, announce: bool) -> void:
	owner_side = s
	var top := Color(0.5, 0.5, 0.5)
	var bottom := top
	if s == Game.UA:
		top = Color(0.0, 0.36, 0.72)
		bottom = Color(1.0, 0.84, 0.0)
	elif s == Game.RU:
		top = Color(0.8, 0.15, 0.12)
		bottom = top
	_top_mat.albedo_color = top
	_bottom_mat.albedo_color = bottom
	var rc := Color(0.7, 0.7, 0.7) if s < 0 else Game.SIDE_COLORS[s]
	rc.a = 0.5
	_ring_mat.albedo_color = rc
	if announce:
		if s == Game.UA:
			battle.notify_msg("%s retaken!" % loc_name, Color(0.6, 0.85, 1.0))
		else:
			battle.notify_msg("%s captured by the enemy!" % loc_name, Color(1.0, 0.4, 0.3))


func sim(dt: float) -> void:
	var present: Array[int] = [0, 0]
	for u in battle.units:
		if u.is_effective() and Vector2(u.position.x - position.x, u.position.z - position.z).length() <= RADIUS:
			present[u.side] += 1
	contested = present[0] > 0 and present[1] > 0
	var claimant := -1
	if present[0] > 0 and present[1] == 0:
		claimant = Game.UA
	elif present[1] > 0 and present[0] == 0:
		claimant = Game.RU
	if claimant >= 0 and claimant != owner_side:
		progress += dt / CAPTURE_TIME
		if progress >= 1.0:
			progress = 0.0
			_set_owner(claimant, true)
	else:
		progress = maxf(0.0, progress - dt / CAPTURE_TIME)
