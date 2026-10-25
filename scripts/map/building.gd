class_name Building
extends Node3D
## A destructible house made of 1 m wall segments, window sills and lintels, and roof slabs.
## Explosions chip the tops off walls or blow pieces out as physics debris. Breached walls
## open new ways in and let fire through; when too many walls fall the roof caves in onto
## whoever is inside, and a gutted house becomes a heap of rubble.
##
## On the grid, border cells holding intact wall are blocked; interior cells are open.
## Infantry go in freely through the door opening and breaches, and can climb in slowly
## through windows or over walls chipped low; vehicles never enter.


class Piece:
	var size := Vector3.ONE
	## Transform relative to the building origin.
	var xform := Transform3D.IDENTITY
	var color := Color.WHITE
	var hp := 100.0
	var max_hp := 100.0
	var roof := false
	## Upper part of a window opening; does not stop movement.
	var lintel := false
	## Wall slot (1 m of wall) this piece belongs to, and the grid cell it stands in.
	var slot := -1
	var cell := Vector2i(-1, -1)
	var alive := true
	var shape: CollisionShape3D


const WALL_H := 2.8
const THICK := 0.3
## A wall slot lower than this no longer stops a man climbing over.
const PASSABLE_HEIGHT := 0.8
## A wall slot no taller than this (a window sill, a wall chipped low) can still be
## climbed through, slowly. Anything taller is a real wall.
const CLIMB_HEIGHT := 1.2
const ROOF_FAILS_AT := 0.6
const COLLAPSES_AT := 0.3

var battle: Battle
var map: BattleMap
var rect := Rect2()
var pieces: Array[Piece] = []
var roof_down := false
var collapsed := false
var _wall_slots := 0
var _cells: Array[Vector2i] = []
var _border := {}
var _slot_cells := {}
var _mesh: MeshInstance3D
var _rubble: MeshInstance3D
var _body: StaticBody3D
var _wall := Color.WHITE


func setup(b: Battle, r: Rect2, ruin: float, seed: int, brick: bool) -> void:
	battle = b
	map = b.map
	rect = r
	position = Vector3(r.get_center().x, map.height_at(Vector3(r.get_center().x, 0.0, r.get_center().y)), r.get_center().y)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	_wall = Color(0.55, 0.34, 0.26) if brick else Color(0.74, 0.71, 0.63)
	var hp := 130.0 if brick else 90.0
	_find_cells()
	_make_walls(rng, ruin, hp)
	_make_roof(rng, ruin)
	_mesh = MeshInstance3D.new()
	add_child(_mesh)
	_rubble = MeshInstance3D.new()
	add_child(_rubble)
	_body = StaticBody3D.new()
	add_child(_body)
	for p in pieces:
		if p.alive:
			_add_shape(p)
	var floor_b := MeshFactory.Builder.new()
	floor_b.box(Vector3(r.size.x, 0.2, r.size.y), Vector3(0.0, 0.1, 0.0), Color(0.36, 0.34, 0.3))
	for i in int(ruin * 9):
		_rubble_box(floor_b, rng, 0.6)
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_b.build()
	add_child(floor_mi)
	_rebuild_mesh()
	_update_map()


func _find_cells() -> void:
	var a := map.world_to_cell(Vector3(rect.position.x + 0.5, 0.0, rect.position.y + 0.5))
	var e := map.world_to_cell(Vector3(rect.end.x - 0.5, 0.0, rect.end.y - 0.5))
	for y in range(a.y, e.y + 1):
		for x in range(a.x, e.x + 1):
			var c := Vector2i(x, y)
			_cells.append(c)
			if x == a.x or x == e.x or y == a.y or y == e.y:
				_border[c] = true


## Grid cell a wall piece at local position lp stands in (nudged inwards off the edge).
func _cell_of(lp: Vector3) -> Vector2i:
	var inward := -Vector3(lp.x, 0.0, lp.z).normalized() * 0.6
	return map.world_to_cell(position + lp + inward)


func _make_walls(rng: RandomNumberGenerator, ruin: float, hp: float) -> void:
	var hx := rect.size.x * 0.5
	var hz := rect.size.y * 0.5
	var corners: Array[Vector2] = [Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)]
	var door_wall := rng.randi() % 4
	for wi in 4:
		var a := corners[wi]
		var e := corners[(wi + 1) % 4]
		var length := a.distance_to(e)
		var n := maxi(1, int(round(length)))
		var along_x := absf(e.x - a.x) > 0.1
		var seg := length / n + 0.02
		# The door opening covers every slot standing in one grid cell, so the
		# visible gap in the wall matches the walkable cell exactly.
		var door_cell := Vector2i(-9, -9)
		if wi == door_wall:
			var dp := a.lerp(e, (n / 2 + 0.5) / n)
			door_cell = _cell_of(Vector3(dp.x, 0.0, dp.y))
		for s in n:
			var slot := _wall_slots
			_wall_slots += 1
			var p2 := a.lerp(e, (s + 0.5) / n)
			var size := Vector3(seg, WALL_H, THICK) if along_x else Vector3(THICK, WALL_H, seg)
			var cell := _cell_of(Vector3(p2.x, 0.0, p2.y))
			_slot_cells[slot] = cell
			if cell == door_cell:
				continue
			var col := _wall.darkened(rng.randf_range(0.0, 0.08))
			var h := WALL_H
			if rng.randf() < ruin * 0.6:
				h = rng.randf_range(0.2, 1.6)
			if h >= WALL_H and s % 3 == 1:
				_add_piece(Vector3(size.x, 0.9, size.z), Vector3(p2.x, 0.45, p2.y), col, hp, slot, cell, false)
				_add_piece(Vector3(size.x, 0.7, size.z), Vector3(p2.x, WALL_H - 0.35, p2.y), col, hp * 0.6, slot, cell, true)
			else:
				_add_piece(Vector3(size.x, h, size.z), Vector3(p2.x, h * 0.5, p2.y), col, hp * h / WALL_H, slot, cell, false)


func _add_piece(size: Vector3, pos: Vector3, col: Color, hp: float, slot: int, cell: Vector2i, lintel: bool) -> Piece:
	var p := Piece.new()
	p.size = size
	p.xform = Transform3D(Basis.IDENTITY, pos)
	p.color = col
	p.hp = hp
	p.max_hp = hp
	p.slot = slot
	p.cell = cell
	p.lintel = lintel
	pieces.append(p)
	return p


## Gable roof as six slabs (two slopes, three sections each) whose ridge runs along
## the house's long axis, eaves resting on the wall tops with a 0.3 m overhang, plus
## gable infill closing the triangles above the end walls. A broken slab if ruined.
func _make_roof(rng: RandomNumberGenerator, ruin: float) -> void:
	var roof := Color(0.38, 0.40, 0.42) if rng.randf() < 0.5 else Color(0.48, 0.30, 0.22)
	if ruin >= 0.6:
		roof_down = true
		return
	if ruin >= 0.35:
		var p := _add_piece(Vector3(rect.size.x * 0.6, 0.15, rect.size.y * 0.9), Vector3.ZERO, roof, 60.0, -1, Vector2i(-1, -1), false)
		p.xform = Transform3D(Basis(Vector3.BACK, 0.25), Vector3(-rect.size.x * 0.2, WALL_H - 0.4, 0.0))
		p.roof = true
		return
	# Slopes span the shorter side; the ridge runs along the longer one.
	var span_x := rect.size.x <= rect.size.y
	var half := (rect.size.x if span_x else rect.size.y) * 0.5 + 0.3
	var depth := (rect.size.y if span_x else rect.size.x) + 0.6
	var rise := 1.6
	var angle := atan2(rise, half)
	var slope_len := sqrt(half * half + rise * rise)
	for sx: float in [-1.0, 1.0]:
		for k in 3:
			# Each slab's centre line runs from the eave (±half, WALL_H) to the
			# ridge (0, WALL_H + rise), so the slopes meet exactly at the ridge.
			var along := -depth * 0.5 + depth * (k + 0.5) / 3.0
			var size := Vector3(slope_len, 0.15, depth / 3.0 + 0.02) if span_x else Vector3(depth / 3.0 + 0.02, 0.15, slope_len)
			var p := _add_piece(size, Vector3.ZERO, roof.darkened(k * 0.03), 60.0, -1, Vector2i(-1, -1), false)
			var tilt := Basis(Vector3.BACK, -angle * sx) if span_x else Basis(Vector3.RIGHT, angle * sx)
			var at := Vector3(sx * half * 0.5, WALL_H + rise * 0.5, along) if span_x else Vector3(along, WALL_H + rise * 0.5, sx * half * 0.5)
			p.xform = Transform3D(tilt, at)
			p.roof = true
	# Gable triangles: stacked wall-coloured boxes narrowing with the pitch.
	var g_width := rect.size.x if span_x else rect.size.y
	var g_half := (rect.size.y if span_x else rect.size.x) * 0.5
	for se: float in [-1.0, 1.0]:
		for g in 3:
			var f := (g + 0.5) / 3.0
			var w := g_width * (1.0 - f)
			var size := Vector3(w, rise / 3.0, THICK) if span_x else Vector3(THICK, rise / 3.0, w)
			var at := Vector3(0.0, WALL_H + rise * f, se * g_half) if span_x else Vector3(se * g_half, WALL_H + rise * f, 0.0)
			var p := _add_piece(size, at, _wall.darkened(0.06), 45.0, -1, Vector2i(-1, -1), false)
			p.roof = true


func _add_shape(p: Piece) -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = p.size
	cs.shape = box
	cs.transform = p.xform
	_body.add_child(cs)
	p.shape = cs


func _rebuild_mesh() -> void:
	var b := MeshFactory.Builder.new()
	var any := false
	for p in pieces:
		if p.alive:
			var m := BoxMesh.new()
			m.size = p.size
			b.add(m, p.xform, p.color)
			any = true
	_mesh.mesh = b.build() if any else null


func _rubble_box(b: MeshFactory.Builder, rng: RandomNumberGenerator, scale: float) -> void:
	var hx := rect.size.x * 0.5
	var hz := rect.size.y * 0.5
	var size := Vector3(rng.randf_range(0.4, 1.2), rng.randf_range(0.2, 0.6), rng.randf_range(0.4, 1.2)) * scale
	b.box(size, Vector3(rng.randf_range(-hx, hx), size.y * 0.4, rng.randf_range(-hz, hz)), _wall.darkened(rng.randf_range(0.15, 0.3)), Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * PI, 0.0))


# --- Damage ---

func near(pos: Vector3, radius: float) -> bool:
	var grown := rect.grow(radius + 1.0)
	return grown.has_point(Vector2(pos.x, pos.z))


## An explosion of structural `power` (hit points at the centre) reaching `radius` metres.
func damage(pos: Vector3, power: float, radius: float) -> void:
	if collapsed:
		return
	var local := pos - position
	var changed := false
	for p in pieces:
		if not p.alive:
			continue
		var d: float
		if p.roof:
			d = maxf(0.0, local.distance_to(p.xform.origin) - maxf(p.size.x, p.size.z) * 0.4)
		else:
			var q := (local - p.xform.origin).abs() - p.size * 0.5
			d = Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length()
		if d > radius:
			continue
		var dmg := power * (1.0 - d / radius)
		p.hp -= dmg
		changed = true
		if p.hp <= 0.0:
			_break(p, pos, dmg)
		elif not p.roof and not p.lintel and dmg > 12.0:
			_chip(p, pos)
	if not changed:
		return
	_check_structure()
	_rebuild_mesh()
	_update_map()


## Blows a piece out as several tumbling chunks.
func _break(p: Piece, blast: Vector3, dmg: float) -> void:
	p.alive = false
	if p.shape:
		p.shape.queue_free()
		p.shape = null
	var world := global_transform * p.xform
	var long_axis := 0 if p.size.x >= p.size.z else 2
	var pieces_n := clampi(int(p.size.x * p.size.y * p.size.z * 6.0), 2, 4)
	var force := clampf(dmg / 25.0, 1.5, 7.0)
	for k in pieces_n:
		var size := p.size
		size[long_axis] = p.size[long_axis] / pieces_n
		size.y = p.size.y * randf_range(0.5, 1.0)
		size *= randf_range(0.75, 0.95)
		var offset := Vector3.ZERO
		offset[long_axis] = (k + 0.5) / pieces_n * p.size[long_axis] - p.size[long_axis] * 0.5
		var xf := Transform3D(world.basis, world * offset)
		var away := (xf.origin - blast)
		away.y = 0.0
		var v := away.normalized() * force * randf_range(0.6, 1.2) + Vector3.UP * force * randf_range(0.3, 0.8)
		battle.spawn_debris(xf, size, p.color, v)
	battle.fx.dust(world.origin, 4, 1.4)


## Knocks the top off a wall segment; the broken part falls away as debris.
func _chip(p: Piece, blast: Vector3) -> void:
	var keep := clampf(p.hp / p.max_hp, 0.25, 1.0) * p.size.y
	if keep > p.size.y - 0.15:
		return
	var bottom := p.xform.origin.y - p.size.y * 0.5
	var lost := p.size.y - keep
	var top := Transform3D(Basis.IDENTITY, Vector3(p.xform.origin.x, bottom + keep + lost * 0.5, p.xform.origin.z))
	p.size.y = keep
	p.xform.origin.y = bottom + keep * 0.5
	if p.shape:
		(p.shape.shape as BoxShape3D).size = p.size
		p.shape.transform = p.xform
	var away := global_transform * top.origin - blast
	away.y = 0.0
	battle.spawn_debris(global_transform * top, Vector3(p.size.x, lost, p.size.z), p.color, away.normalized() * 3.0 + Vector3.UP * 2.0)
	battle.fx.dust(global_transform * top.origin, 2, 1.0)


func _standing_walls() -> float:
	var standing := {}
	for p in pieces:
		if p.alive and not p.roof and not p.lintel and p.size.y > 1.2:
			standing[p.slot] = true
	return float(standing.size()) / maxf(1.0, _wall_slots)


func _check_structure() -> void:
	var standing := _standing_walls()
	if not roof_down and standing < ROOF_FAILS_AT:
		_collapse_roof()
	if standing < COLLAPSES_AT:
		_collapse()


func _collapse_roof() -> void:
	roof_down = true
	var had_roof := false
	for p in pieces:
		if p.alive and p.roof:
			had_roof = true
			p.alive = false
			if p.shape:
				p.shape.queue_free()
				p.shape = null
			battle.spawn_debris(global_transform * p.xform, p.size, p.color, Vector3(randf_range(-1, 1), -1.0, randf_range(-1, 1)))
	if had_roof:
		battle.fx.dust(position + Vector3.UP * 1.5, 12, 2.5)
		battle.notify_msg("A roof has caved in!", Color(1.0, 0.75, 0.45))
		# Falling beams and tiles hurt whoever sheltered inside.
		battle.blast(position + Vector3.UP, maxf(rect.size.x, rect.size.y) * 0.5, 0.3, 60.0, 0.0, true)


## Gutted: the remaining walls fall, the house becomes a rubble heap.
func _collapse() -> void:
	collapsed = true
	for p in pieces:
		if p.alive and (p.lintel or p.size.y > 1.4):
			_break(p, position + Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1)), 60.0)
	var b := MeshFactory.Builder.new()
	var rng := RandomNumberGenerator.new()
	for i in int(rect.size.x * rect.size.y * 0.3):
		_rubble_box(b, rng, 1.2)
	_rubble.mesh = b.build()
	battle.fx.dust(position + Vector3.UP, 16, 3.0)


## 2 = freely passable (door, breach), 1 = climbable (window sill, wall chipped
## low), 0 = blocked by intact wall. Lintels never stop movement.
func _slot_state(slot: int) -> int:
	var tallest := 0.0
	for p in pieces:
		if p.alive and p.slot == slot and not p.lintel:
			tallest = maxf(tallest, p.size.y)
	if tallest < PASSABLE_HEIGHT:
		return 2
	if tallest <= CLIMB_HEIGHT:
		return 1
	return 0


## Grid upkeep: intact walls block movement, doors and breaches open their cells
## freely, window cells are slow climbs, breaches become rubble you can see and
## walk through. A cell holds two wall slots; its best opening decides.
func _update_map() -> void:
	if collapsed:
		for c in _cells:
			map.set_cell(c, BattleMap.T.RUBBLE)
			map.set_blocked(c, false)
			map.set_climb(c, false)
		return
	var state := {}
	var breached := {}
	for slot: int in _slot_cells.keys():
		var c: Vector2i = _slot_cells[slot]
		var st := _slot_state(slot)
		state[c] = maxi(st, int(state.get(c, 0)))
		if st == 2:
			for p in pieces:
				if p.slot == slot and not p.alive:
					breached[c] = true
	for c: Vector2i in _border.keys():
		var st := int(state.get(c, 0))
		map.set_blocked(c, st < 2)
		map.set_climb(c, st == 1)
		if breached.has(c):
			map.set_cell(c, BattleMap.T.RUBBLE)
