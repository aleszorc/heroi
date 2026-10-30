class_name Building
extends Node3D
## A destructible house made of 1 m wall segments, window sills and lintels, a door
## frame and a roof (gable, hip or flat with a parapet). Explosions chip the tops off
## walls or blow pieces out as physics debris. Breached walls open new ways in and let
## fire through; when too many walls fall the roof caves in onto whoever is inside,
## and a gutted house becomes a heap of rubble.
##
## Every piece is physically carried: lintels sit on their sill and jambs, gable
## triangles on the end wall, the chimney on its roof slab, parapets on the wall
## tops. When a piece loses its support it drops as debris (`_drop_unsupported`).
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
	## Upper part of a window opening, or trim (door frame); does not stop movement
	## and never counts as a standing wall.
	var lintel := false
	## Wall slot (1 m of wall) this piece belongs to, and the grid cell it stands in.
	var slot := -1
	var cell := Vector2i(-1, -1)
	var alive := true
	var shape: CollisionShape3D
	## Custom geometry instead of a box (gable prism, hip roof solid).
	var mesh: Mesh
	## Support groups [min_alive, [pieces]]: when any group drops below its minimum
	## of still-standing carriers the piece falls.
	var supports: Array = []
	## Height of the top face as built; a carrier chipped below it carries nothing.
	var top0 := 0.0


const WALL_H := 2.8
const THICK := 0.3
## Roof eaves reach this far past the wall face.
const OVERHANG := 0.3
const ROOF_T := 0.15
## A wall slot lower than this no longer stops a man climbing over.
const PASSABLE_HEIGHT := 0.8
## A wall slot no taller than this (a window sill, a wall chipped low) can still be
## climbed through, slowly. Anything taller is a real wall.
const CLIMB_HEIGHT := 1.2
const ROOF_FAILS_AT := 0.6
const COLLAPSES_AT := 0.3
const SNOW := Color(0.86, 0.88, 0.92)

enum Roof { GABLE, HIP, FLAT, CAVED, NONE }

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
## Per slot: position along the wall (Vector2), its topmost piece and its sill.
var _slot_pos := {}
var _slot_top := {}
var _slot_sill := {}
## Slot indices of each of the four walls (0 north, 1 east, 2 south, 3 west).
var _wall_of: Array = [[], [], [], []]
var _door_wall := -1
var _door_slots: Array[int] = []
## Wall the caved-in roof leans on; its slots are built full height.
var _lean_wall := -1
var _mesh: MeshInstance3D
var _rubble: MeshInstance3D
var _body: StaticBody3D
var _wall := Color.WHITE
var _trim := Color(0.28, 0.22, 0.17)
var _winter := false


func setup(b: Battle, r: Rect2, ruin: float, seed: int, brick: bool) -> void:
	battle = b
	map = b.map
	rect = r
	position = Vector3(r.get_center().x, map.height_at(Vector3(r.get_center().x, 0.0, r.get_center().y)), r.get_center().y)
	_winter = String(b.mission.get("season", "summer")) == "winter"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	_wall = _pick_wall_color(rng, brick)
	var hp := 130.0 if brick else 90.0
	var style := _pick_roof(rng, ruin, brick)
	if style == Roof.CAVED:
		var span_x := rect.size.x <= rect.size.y
		_lean_wall = ([1, 3] if span_x else [0, 2])[rng.randi() % 2]
	_find_cells()
	_make_walls(rng, ruin, hp)
	_make_door_frame(hp)
	_make_roof(rng, ruin, style)
	_prune_unsupported()
	_mesh = MeshInstance3D.new()
	add_child(_mesh)
	_rubble = MeshInstance3D.new()
	add_child(_rubble)
	_body = StaticBody3D.new()
	add_child(_body)
	for p in pieces:
		if p.alive:
			_add_shape(p)
	# Plinth and floor in one slab, a little proud of the walls: the foundation
	# that stays when everything above it has gone.
	var floor_b := MeshFactory.Builder.new()
	floor_b.box(Vector3(r.size.x + 0.4, 0.25, r.size.y + 0.4), Vector3(0.0, 0.125, 0.0), Color(0.34, 0.33, 0.31).darkened(rng.randf_range(0.0, 0.1)))
	for i in int(ruin * 10):
		_rubble_box(floor_b, rng, 0.6 + ruin * 0.4)
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_b.build()
	add_child(floor_mi)
	_rebuild_mesh()
	_update_map()


func _pick_wall_color(rng: RandomNumberGenerator, brick: bool) -> Color:
	var palette: Array = ([Color(0.55, 0.34, 0.26), Color(0.50, 0.30, 0.24), Color(0.60, 0.40, 0.30), Color(0.46, 0.33, 0.28)] if brick
			else [Color(0.78, 0.76, 0.70), Color(0.74, 0.71, 0.63), Color(0.70, 0.74, 0.68), Color(0.78, 0.70, 0.52), Color(0.66, 0.70, 0.72)])
	return palette[rng.randi() % palette.size()]


func _pick_roof(rng: RandomNumberGenerator, ruin: float, brick: bool) -> int:
	if ruin >= 0.6:
		return Roof.NONE
	if ruin >= 0.35:
		return Roof.CAVED
	var r := rng.randf()
	if brick:
		return Roof.FLAT if r < 0.4 else (Roof.GABLE if r < 0.78 else Roof.HIP)
	return Roof.GABLE if r < 0.62 else Roof.HIP


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
	_door_wall = rng.randi() % 4
	# Window rhythm differs per house: every second or third metre, shifted.
	var period := 3 if rng.randf() < 0.7 else 2
	var phase := rng.randi() % period
	var sooty := ruin >= 0.35
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
		if wi == _door_wall:
			var dp := a.lerp(e, (n / 2 + 0.5) / n)
			door_cell = _cell_of(Vector3(dp.x, 0.0, dp.y))
		for s in n:
			var slot := _wall_slots
			_wall_slots += 1
			_wall_of[wi].append(slot)
			var p2 := a.lerp(e, (s + 0.5) / n)
			_slot_pos[slot] = p2
			var size := Vector3(seg, WALL_H, THICK) if along_x else Vector3(THICK, WALL_H, seg)
			var cell := _cell_of(Vector3(p2.x, 0.0, p2.y))
			_slot_cells[slot] = cell
			if cell == door_cell:
				_door_slots.append(slot)
				continue
			var col := _wall.darkened(rng.randf_range(0.0, 0.08))
			if sooty and rng.randf() < 0.5:
				col = col.darkened(rng.randf_range(0.15, 0.4))
			var h := WALL_H
			if wi != _lean_wall and rng.randf() < ruin * 0.6:
				h = rng.randf_range(0.2, 1.6)
			var window := h >= WALL_H and n >= 4 and s > 0 and s < n - 1 and s % period == phase
			if window:
				var sill := _add_piece(Vector3(size.x, 0.9, size.z), Vector3(p2.x, 0.45, p2.y), col, hp, slot, cell, false)
				var lintel := _add_piece(Vector3(size.x, 0.7, size.z), Vector3(p2.x, WALL_H - 0.35, p2.y), col, hp * 0.6, slot, cell, true)
				_slot_sill[slot] = sill
				_slot_top[slot] = lintel
			else:
				_slot_top[slot] = _add_piece(Vector3(size.x, h, size.z), Vector3(p2.x, h * 0.5, p2.y), col, hp * h / WALL_H, slot, cell, false)
	# A lintel rests on its sill and on the jambs either side: it falls with the
	# sill, or when both neighbouring slots are gone.
	for slot: int in _slot_sill.keys():
		var lintel: Piece = _slot_top[slot]
		lintel.supports.append([1, [_slot_sill[slot]]])
		var jambs: Array = []
		for ns: int in [slot - 1, slot + 1]:
			if _full(ns):
				jambs.append(_slot_top[ns])
		if not jambs.is_empty():
			lintel.supports.append([1, jambs])


## Whether a wall slot was built to full height (it can carry what sits on the wall top).
func _full(slot: int) -> bool:
	return _slot_top.has(slot) and (_slot_top[slot] as Piece).top0 >= WALL_H - 0.1


## Build-time pass: a piece that was never carried (a gable over a mostly ruined end
## wall, say) is dropped silently instead of falling as debris on the first blast.
func _prune_unsupported() -> void:
	var kept: Array[Piece] = []
	for p in pieces:
		var ok := true
		for group: Array in p.supports:
			var n := 0
			for c: Piece in group[1]:
				if c.alive:
					n += 1
			if n < int(group[0]):
				ok = false
		if ok:
			kept.append(p)
		else:
			p.alive = false
	pieces = kept


## Door posts and a head beam over the opening, carried by the jambs beside it.
func _make_door_frame(hp: float) -> void:
	if _door_slots.is_empty():
		return
	var lo: int = _door_slots.min()
	var hi: int = _door_slots.max()
	var a: Vector2 = _slot_pos[lo]
	var e: Vector2 = _slot_pos[hi]
	var along_x := _door_wall % 2 == 0
	var dir := (e - a).normalized() if hi != lo else (Vector2(1, 0) if along_x else Vector2(0, 1))
	var w := a.distance_to(e) + 1.0
	var mid := (a + e) * 0.5
	var jambs: Array = []
	for ns: int in [lo - 1, hi + 1]:
		if _full(ns):
			jambs.append(_slot_top[ns])
	var head_size := Vector3(w, 0.5, THICK) if along_x else Vector3(THICK, 0.5, w)
	var head := _add_piece(head_size, Vector3(mid.x, WALL_H - 0.25, mid.y), _wall.darkened(0.04), hp * 0.6, -1, Vector2i(-1, -1), true)
	if not jambs.is_empty():
		head.supports.append([1, jambs])
	for side: float in [-1.0, 1.0]:
		var pp := mid + dir * side * (w * 0.5 - 0.07)
		var post_size := Vector3(0.14, WALL_H - 0.5, THICK + 0.08) if along_x else Vector3(THICK + 0.08, WALL_H - 0.5, 0.14)
		var post := _add_piece(post_size, Vector3(pp.x, (WALL_H - 0.5) * 0.5, pp.y), _trim, hp * 0.4, -1, Vector2i(-1, -1), true)
		var jamb_slot := lo - 1 if side < 0.0 else hi + 1
		if _full(jamb_slot):
			post.supports.append([1, [_slot_top[jamb_slot]]])


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
	p.top0 = pos.y + size.y * 0.5
	pieces.append(p)
	return p


func _roof_piece(size: Vector3, xform: Transform3D, col: Color, hp: float) -> Piece:
	var p := _add_piece(size, xform.origin, col, hp, -1, Vector2i(-1, -1), false)
	p.xform = xform
	p.roof = true
	return p


## Roof colour: tile red-brown, slate grey or rusty tin; snow-dusted in winter.
func _roof_color(rng: RandomNumberGenerator, style: int) -> Color:
	var c: Color
	if style == Roof.FLAT:
		c = Color(0.24, 0.23, 0.22)
	else:
		var r := rng.randf()
		c = Color(0.50, 0.30, 0.22) if r < 0.4 else (Color(0.38, 0.40, 0.42) if r < 0.7 else Color(0.46, 0.38, 0.30))
	return c.lerp(SNOW, 0.82) if _winter else c


func _make_roof(rng: RandomNumberGenerator, ruin: float, style: int) -> void:
	match style:
		Roof.NONE:
			roof_down = true
		Roof.CAVED:
			roof_down = true
			_make_caved_roof(rng)
		Roof.FLAT:
			_make_flat_roof(rng)
		Roof.HIP:
			_make_hip_roof(rng)
		_:
			_make_gable_roof(rng, ruin)


## Gable roof: two slopes of three butted slabs each, their undersides passing
## exactly through the wall-top outer edges and meeting at the ridge, a ridge cap
## over the joint, prism gable triangles flush under the slopes, and a chimney.
func _make_gable_roof(rng: RandomNumberGenerator, _ruin: float) -> void:
	var roof := _roof_color(rng, Roof.GABLE)
	var span_x := rect.size.x <= rect.size.y
	var half := (rect.size.x if span_x else rect.size.y) * 0.5
	var long := rect.size.y if span_x else rect.size.x
	var depth := long + 2.0 * OVERHANG
	var rise := clampf(half * 0.42, 1.0, 2.0)
	var angle := atan2(rise, half)
	var slope_len := (half + OVERHANG) / cos(angle)
	var slabs: Array = []
	for sx: float in [-1.0, 1.0]:
		for k in 3:
			var along := -depth * 0.5 + depth * (k + 0.5) / 3.0
			# Underside from the eave to the ridge, the slab's thickness above it.
			var eave_y := WALL_H - OVERHANG * tan(angle)
			var mid := Vector2(sx * (half + OVERHANG) * 0.5, (eave_y + WALL_H + rise) * 0.5)
			var centre := mid + Vector2(sx * sin(angle), cos(angle)) * ROOF_T * 0.5
			var size := Vector3(slope_len, ROOF_T, depth / 3.0) if span_x else Vector3(depth / 3.0, ROOF_T, slope_len)
			var tilt := Basis(Vector3.BACK, -angle * sx) if span_x else Basis(Vector3.RIGHT, angle * sx)
			var at := Vector3(centre.x, centre.y, along) if span_x else Vector3(along, centre.y, centre.x)
			slabs.append(_roof_piece(size, Transform3D(tilt, at), roof.darkened(k * 0.03 + (0.05 if sx > 0.0 else 0.0)), 60.0))
	# Ridge cap over the slab joint.
	var ridge_top := WALL_H + rise + ROOF_T / cos(angle)
	var cap_size := Vector3(0.4, 0.18, depth + 0.04) if span_x else Vector3(depth + 0.04, 0.18, 0.4)
	var cap := _roof_piece(cap_size, Transform3D(Basis.IDENTITY, Vector3(0.0, ridge_top + 0.01, 0.0)), roof.darkened(0.12), 30.0)
	cap.supports.append([2, slabs])
	# Gable triangles: a prism each, base on the end wall, apex just under the ridge.
	for se: float in [-1.0, 1.0]:
		var wi := (0 if se < 0.0 else 2) if span_x else (3 if se < 0.0 else 1)
		var prism := PrismMesh.new()
		prism.size = Vector3(half * 2.0, rise - 0.02, THICK)
		prism.left_to_right = 0.5
		var basis := Basis.IDENTITY if span_x else Basis(Vector3.UP, PI * 0.5)
		var at := Vector3(0.0, WALL_H + (rise - 0.02) * 0.5, se * long * 0.5) if span_x else Vector3(se * long * 0.5, WALL_H + (rise - 0.02) * 0.5, 0.0)
		var g := _roof_piece(Vector3(half * 2.0, rise, THICK) if span_x else Vector3(THICK, rise, half * 2.0), Transform3D(basis, at), _wall.darkened(0.06), 45.0)
		g.mesh = prism
		_carried_by_wall(g, wi)
	if rng.randf() < 0.65:
		var k := rng.randi() % 3
		var along := -depth * 0.5 + depth * (k + 0.5) / 3.0 + rng.randf_range(-0.5, 0.5)
		var off := 0.45 * (1.0 if rng.randf() < 0.5 else -1.0)
		var slab_top := WALL_H + rise - absf(off) * tan(angle) + ROOF_T / cos(angle)
		var at := Vector3(off, slab_top + 0.2, along) if span_x else Vector3(along, slab_top + 0.2, off)
		_chimney(at, slabs[(3 if off > 0.0 else 0) + k], rng)


## Hip roof: one lofted solid from the eave rectangle up to the short ridge, every
## slope at the same pitch, plus a ridge cap and chimney.
func _make_hip_roof(rng: RandomNumberGenerator) -> void:
	var roof := _roof_color(rng, Roof.HIP)
	var hx := rect.size.x * 0.5 + OVERHANG
	var hz := rect.size.y * 0.5 + OVERHANG
	var short := minf(hx, hz)
	var rise := clampf(short * 0.4, 0.9, 1.6)
	var rl := absf(hx - hz)
	var e := 0.02
	var bottom := PackedVector2Array([Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)])
	var top := (PackedVector2Array([Vector2(-rl, -e), Vector2(rl, -e), Vector2(rl, e), Vector2(-rl, e)]) if hx >= hz
			else PackedVector2Array([Vector2(-e, -rl), Vector2(e, -rl), Vector2(e, rl), Vector2(-e, rl)]))
	var hb := MeshFactory.Builder.new()
	hb.loft(bottom, top, -rise * 0.5, rise * 0.5, roof)
	var p := _roof_piece(Vector3(hx * 2.0, rise, hz * 2.0), Transform3D(Basis.IDENTITY, Vector3(0.0, WALL_H + rise * 0.5, 0.0)), roof, 110.0)
	p.mesh = hb.build()
	if rl > 0.3:
		var cap_size := Vector3(rl * 2.0 + 0.3, 0.16, 0.36) if hx >= hz else Vector3(0.36, 0.16, rl * 2.0 + 0.3)
		var cap := _roof_piece(cap_size, Transform3D(Basis.IDENTITY, Vector3(0.0, WALL_H + rise + 0.02, 0.0)), roof.darkened(0.12), 30.0)
		cap.supports.append([1, [p]])
	if rng.randf() < 0.6:
		var along := rng.randf_range(-rl * 0.6, rl * 0.6)
		var pitch := rise / short
		var off := 0.5
		var slab_top := WALL_H + rise - off * pitch
		var at := Vector3(along, slab_top + 0.2, off) if hx >= hz else Vector3(off, slab_top + 0.2, along)
		_chimney(at, p, rng)


## Flat roof behind a parapet: brick houses and farm sheds.
func _make_flat_roof(rng: RandomNumberGenerator) -> void:
	var roof := _roof_color(rng, Roof.FLAT)
	var w := rect.size.x
	var d := rect.size.y
	_roof_piece(Vector3(w, 0.2, d), Transform3D(Basis.IDENTITY, Vector3(0.0, WALL_H + 0.1, 0.0)), roof, 60.0)
	var hx := w * 0.5
	var hz := d * 0.5
	for wi in 4:
		var along_x := wi % 2 == 0
		var size := Vector3(w + THICK, 0.45, THICK) if along_x else Vector3(THICK, 0.45, d + THICK)
		var at := Vector3(0.0, WALL_H + 0.225, -hz if wi == 0 else hz) if along_x else Vector3(hx if wi == 1 else -hx, WALL_H + 0.225, 0.0)
		var par := _roof_piece(size, Transform3D(Basis.IDENTITY, at), _wall.darkened(rng.randf_range(0.02, 0.1)), 40.0)
		_carried_by_wall(par, wi)


## A caved-in gable roof: one or two slope sections still lean from the top of a
## standing eave wall down to the floor inside; everything else is gone.
func _make_caved_roof(rng: RandomNumberGenerator) -> void:
	var roof := _roof_color(rng, Roof.GABLE).darkened(0.15)
	var span_x := rect.size.x <= rect.size.y
	var half := (rect.size.x if span_x else rect.size.y) * 0.5
	var long := rect.size.y if span_x else rect.size.x
	var rise := clampf(half * 0.42, 1.0, 2.0)
	var slope_len := (half + OVERHANG) / cos(atan2(rise, half))
	var sx := 1.0 if (_lean_wall == 1 or _lean_wall == 2) else -1.0
	var order := [0, 1, 2]
	order.shuffle()
	var keep := rng.randi_range(1, 2)
	for i in keep:
		var k: int = order[i]
		var along := -long * 0.5 + long * (k + 0.5) / 3.0
		var sec := long / 3.0 * rng.randf_range(0.8, 1.0)
		var drop := WALL_H - 0.25
		var reach_max := 2.0 * half - 0.7
		var len := slope_len * rng.randf_range(0.7, 1.0)
		var reach := minf(sqrt(maxf(len * len - drop * drop, 0.1)), reach_max)
		len = sqrt(reach * reach + drop * drop)
		var beta := atan2(drop, reach)
		# Bottom face from the floor up to the inner edge of the wall top.
		var top := Vector2(sx * (half - THICK + 0.04), WALL_H)
		var foot := Vector2(sx * (half - THICK + 0.04 - reach), 0.25)
		var mid := (top + foot) * 0.5
		var centre := mid + Vector2(-sx * sin(beta), cos(beta)) * ROOF_T * 0.5
		var size := Vector3(len, ROOF_T, sec) if span_x else Vector3(sec, ROOF_T, len)
		var tilt := Basis(Vector3.BACK, sx * beta) if span_x else Basis(Vector3.RIGHT, -sx * beta)
		var at := Vector3(centre.x, centre.y, along) if span_x else Vector3(along, centre.y, centre.x)
		var slab := _roof_piece(size, Transform3D(tilt, at), roof.darkened(k * 0.04), 60.0)
		# Carried by the wall slots under its upper edge.
		var carriers: Array = []
		for slot: int in _wall_of[_lean_wall]:
			var sp: Vector2 = _slot_pos[slot]
			var a := sp.y if span_x else sp.x
			if absf(a - along) <= sec * 0.5 + 0.5 and _full(slot):
				carriers.append(_slot_top[slot])
		slab.supports.append([maxi(1, carriers.size() / 2), carriers])


func _chimney(at: Vector3, slab: Piece, rng: RandomNumberGenerator) -> void:
	var brick := Color(0.42, 0.30, 0.26) if rng.randf() < 0.6 else Color(0.60, 0.58, 0.54)
	var stack := _roof_piece(Vector3(0.5, 1.1, 0.5), Transform3D(Basis.IDENTITY, at + Vector3(0.0, 0.25, 0.0)), brick, 25.0)
	stack.supports.append([1, [slab]])
	var cap := _roof_piece(Vector3(0.62, 0.1, 0.62), Transform3D(Basis.IDENTITY, at + Vector3(0.0, 0.85, 0.0)), brick.darkened(0.2), 10.0)
	cap.supports.append([1, [stack]])


## A piece standing on wall `wi` needs at least half of that wall's slots at full height.
func _carried_by_wall(p: Piece, wi: int) -> void:
	var tops: Array = []
	for slot: int in _wall_of[wi]:
		if _full(slot):
			tops.append(_slot_top[slot])
	p.supports.append([maxi(1, int(ceil((_wall_of[wi] as Array).size() * 0.5))), tops])


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
			if p.mesh != null:
				b.add_mesh(p.mesh, p.xform, p.color)
			else:
				var m := BoxMesh.new()
				m.size = p.size
				b.add(m, p.xform, p.color)
			any = true
	_mesh.mesh = b.build() if any else null


func _rubble_box(b: MeshFactory.Builder, rng: RandomNumberGenerator, scale: float) -> void:
	var hx := rect.size.x * 0.5
	var hz := rect.size.y * 0.5
	var size := Vector3(rng.randf_range(0.4, 1.2), rng.randf_range(0.2, 0.6), rng.randf_range(0.4, 1.2)) * scale
	b.box(size, Vector3(rng.randf_range(-hx, hx), 0.25 + size.y * 0.3, rng.randf_range(-hz, hz)), _wall.darkened(rng.randf_range(0.15, 0.3)), Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * PI, 0.0))


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


## Blows a piece out as several tumbling chunks (or lets it drop when `fall`).
func _break(p: Piece, blast: Vector3, dmg: float, fall := false) -> void:
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
		var v: Vector3
		if fall:
			v = Vector3(randf_range(-0.6, 0.6), -0.5, randf_range(-0.6, 0.6))
		else:
			var away := (xf.origin - blast)
			away.y = 0.0
			v = away.normalized() * force * randf_range(0.6, 1.2) + Vector3.UP * force * randf_range(0.3, 0.8)
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


## A carrier still carries while it stands at (nearly) its built height.
func _carries(p: Piece) -> bool:
	return p.alive and p.xform.origin.y + p.size.y * 0.5 >= p.top0 - 0.25


## Drops every piece whose support groups no longer hold it, cascading (a lintel
## takes the chimney-less gable with it, a gable its ridge cap, and so on).
func _drop_unsupported() -> void:
	var again := true
	while again:
		again = false
		for p in pieces:
			if not p.alive or p.supports.is_empty():
				continue
			for group: Array in p.supports:
				var n := 0
				for c: Piece in group[1]:
					if _carries(c):
						n += 1
				if n < int(group[0]):
					_break(p, position + p.xform.origin, 30.0, true)
					again = true
					break


func _standing_walls() -> float:
	var standing := {}
	for p in pieces:
		if p.alive and not p.roof and not p.lintel and p.size.y > 1.2:
			standing[p.slot] = true
	return float(standing.size()) / maxf(1.0, _wall_slots)


func _check_structure() -> void:
	_drop_unsupported()
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
	_drop_unsupported()
	if had_roof:
		battle.fx.dust(position + Vector3.UP * 1.5, 12, 2.5)
		battle.sfx.collapse(position)
		# Falling beams and tiles strike everyone sheltering under them: 45% of
		# the men inside go down (the usual blast kill/wound split), and units in
		# or near the house are heavily suppressed.
		battle.structural_casualties(rect, 0.45, 50.0)


## Gutted: the remaining walls fall, the house becomes a rubble heap.
func _collapse() -> void:
	collapsed = true
	for p in pieces:
		if p.alive and (p.lintel or p.size.y > 1.4):
			_break(p, position + Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1)), 60.0)
	_drop_unsupported()
	var b := MeshFactory.Builder.new()
	var rng := RandomNumberGenerator.new()
	for i in int(rect.size.x * rect.size.y * 0.3):
		_rubble_box(b, rng, 1.2)
	_rubble.mesh = b.build()
	battle.fx.dust(position + Vector3.UP, 16, 3.0)
	battle.sfx.collapse(position)
	# The walls come down on whoever is still inside: worse than the roof alone.
	battle.structural_casualties(rect, 0.7, 70.0)


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
