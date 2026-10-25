class_name MapView
extends Node3D
## Builds the static scenery for a BattleMap: ground, trees, buildings, wrecks and props.
## The map sits on a raised board like a tabletop diorama.

const BOARD_DEPTH := 2.0
## Ground chunk side in cells: the 120x120 map becomes a 10x10 grid of chunk
## meshes, so a blast rebuilds at most four small meshes, never the whole ground.
const CHUNK := 12

## Crater colouring: charred at the scorched centre, dark wet mud at the lip and rim.
const SCORCHED := Color(0.085, 0.07, 0.06)
const DISTURBED := Color(0.20, 0.155, 0.11)
## Spoil dirt thrown up around trenches: churned mud fading out over ~2 cells.
const TRENCH_DIRT := Color(0.24, 0.185, 0.125)

## Crater meshes merge instead of stacking: a new hole whose centre is closer than
## CRATER_MERGE x the summed rim radii to a live crater would interpenetrate rim
##-through-rim, so it grows that crater instead of spawning a second mesh. Distinct
## but touching craters still both exist — real crater fields overlap at the edges.
const CRATER_MERGE := 0.55
## Each merged hit widens the hole by CRATER_GROW until the rim radius saturates at
## CRATER_R_CAP (a churned artillery-sized pit), and wets it darker toward TONE_MIN.
const CRATER_GROW := 1.16
const CRATER_R_CAP := 4.0
const CRATER_TONE_STEP := 0.94
const CRATER_TONE_MIN := 0.72

var _map: BattleMap
var _chunks: Array[MeshInstance3D] = []
## Per-corner spoil-dirt strength around trench cells, built once (trenches never
## change at runtime). Indexed like crater_depth: y * (W + 1) + x.
var _trench_dirt := PackedFloat32Array()
## Bush multimesh and world positions, so bushes can be re-seated when the ground
## under them is dug out by a blast.
var _bush_mm: MultiMesh
var _bush_xf: Array = []
## Registry of live crater meshes — build-time scattered and runtime blast holes
## alike — so overlapping blasts grow one hole instead of stacking meshes. Entries:
## pos (Vector3), r (world rim radius), basis (yaw + elliptical scale), tone, and
## either mi (runtime MeshInstance3D) or mm+idx (a scattered multimesh instance).
var _craters: Array = []


func build(map: BattleMap, mission: Dictionary) -> void:
	_map = map
	_build_trench_dirt(map)
	_build_ground(map)
	_build_board()
	_build_trees(map)
	_build_scatter(map)
	for w: Array in mission.get("wrecks", []):
		var kind: String = w[0]
		var pos: Vector3 = w[1]
		var parts := MeshFactory.vehicle(kind, true)
		var hull := MeshInstance3D.new()
		hull.mesh = parts["hull"]
		hull.position = Vector3(pos.x, map.height_at(pos), pos.z)
		hull.rotation = Vector3(0.0, float(w[2]), 0.04)
		add_child(hull)
		var turret := MeshInstance3D.new()
		turret.mesh = parts["turret"]
		turret.position = parts["turret_pos"]
		turret.rotation = Vector3(0.15, 0.9, 0.1)
		hull.add_child(turret)
	for p: Vector3 in mission.get("poles", []):
		var mi := MeshInstance3D.new()
		mi.mesh = MeshFactory.pole()
		mi.position = Vector3(p.x, map.height_at(p), p.z)
		mi.rotation.z = randf_range(-0.06, 0.06)
		add_child(mi)


func _ground_color(t: int, x: int, y: int) -> Color:
	match t:
		BattleMap.T.FIELD:
			return Color(0.40, 0.33, 0.24) if y % 2 == 0 else Color(0.35, 0.29, 0.21)
		BattleMap.T.ROAD:
			return Color(0.46, 0.41, 0.33)
		BattleMap.T.TREES:
			return Color(0.30, 0.32, 0.20)
		BattleMap.T.BUILDING:
			return Color(0.33, 0.31, 0.28)
		BattleMap.T.TRENCH:
			return Color(0.21, 0.16, 0.11)
		BattleMap.T.GULLY:
			return Color(0.34, 0.36, 0.23)
		BattleMap.T.CRATER:
			return Color(0.19, 0.15, 0.11)
		BattleMap.T.RUBBLE:
			return Color(0.40, 0.37, 0.33)
		BattleMap.T.WRECK:
			return Color(0.22, 0.20, 0.18)
	return Color(0.42, 0.44, 0.28) if (x + y) % 7 != 0 else Color(0.45, 0.45, 0.29)


func _build_ground(map: BattleMap) -> void:
	var n := BattleMap.W / CHUNK
	for cy in n:
		for cx in n:
			var mi := MeshInstance3D.new()
			mi.mesh = _chunk_mesh(cx, cy)
			add_child(mi)
			_chunks.append(mi)


## One CHUNK x CHUNK patch of ground quads, vertex-coloured per corner so crater
## scorch grades smoothly from charred centre to disturbed-earth rim.
func _chunk_mesh(cx: int, cy: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var c := BattleMap.CELL
	for y in range(cy * CHUNK, (cy + 1) * CHUNK):
		for x in range(cx * CHUNK, (cx + 1) * CHUNK):
			var t: int = _map.cells[y * BattleMap.W + x]
			var col := _ground_color(t, x, y) * _cell_shade(x, y)
			col.a = 1.0
			if t == BattleMap.T.TRENCH:
				# A dug fieldwork, not a dip: flat floor at full depth and sheer
				# revetment walls standing on the cell boundary under the berm lip.
				_trench_cell(st, x, y, col)
				continue
			var x0 := x * c - BattleMap.HALF
			var z0 := y * c - BattleMap.HALF
			var v00 := Vector3(x0, _map.corner_height(x, y), z0)
			var v10 := Vector3(x0 + c, _map.corner_height(x + 1, y), z0)
			var v01 := Vector3(x0, _map.corner_height(x, y + 1), z0 + c)
			var v11 := Vector3(x0 + c, _map.corner_height(x + 1, y + 1), z0 + c)
			var c00 := _vert_color(col, x, y)
			var c10 := _vert_color(col, x + 1, y)
			var c01 := _vert_color(col, x, y + 1)
			var c11 := _vert_color(col, x + 1, y + 1)
			st.set_color(c00)
			st.add_vertex(v00)
			st.set_color(c10)
			st.add_vertex(v10)
			st.set_color(c11)
			st.add_vertex(v11)
			st.set_color(c00)
			st.add_vertex(v00)
			st.set_color(c11)
			st.add_vertex(v11)
			st.set_color(c01)
			st.add_vertex(v01)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, MeshFactory.material())
	return mesh


## Cut-earth revetment colouring for the trench walls, darkening towards the floor.
const REVET_TOP := Color(0.25, 0.19, 0.13)
const REVET_BOTTOM := Color(0.11, 0.085, 0.06)


## One trench cell: a flat floor quad at -TRENCH_DEPTH, and a near-vertical wall
## quad on every edge facing a non-trench neighbour, from the bermed lip corners
## straight down to the floor — the cut reads as revetted earth, not a bank.
func _trench_cell(st: SurfaceTool, x: int, y: int, floor_col: Color) -> void:
	var c := BattleMap.CELL
	var x0 := x * c - BattleMap.HALF
	var z0 := y * c - BattleMap.HALF
	var yf := -BattleMap.TRENCH_DEPTH
	var fc := floor_col.darkened(0.22)
	fc.a = 1.0
	st.set_color(fc)
	st.add_vertex(Vector3(x0, yf, z0))
	st.set_color(fc)
	st.add_vertex(Vector3(x0 + c, yf, z0))
	st.set_color(fc)
	st.add_vertex(Vector3(x0 + c, yf, z0 + c))
	st.set_color(fc)
	st.add_vertex(Vector3(x0, yf, z0))
	st.set_color(fc)
	st.add_vertex(Vector3(x0 + c, yf, z0 + c))
	st.set_color(fc)
	st.add_vertex(Vector3(x0, yf, z0 + c))
	# Edges listed clockwise from above, so each wall faces into the trench.
	var edges: Array = [
		[Vector2i(0, -1), Vector2i(x, y), Vector2i(x + 1, y)],
		[Vector2i(1, 0), Vector2i(x + 1, y), Vector2i(x + 1, y + 1)],
		[Vector2i(0, 1), Vector2i(x + 1, y + 1), Vector2i(x, y + 1)],
		[Vector2i(-1, 0), Vector2i(x, y + 1), Vector2i(x, y)],
	]
	var shade := _cell_shade(x, y)
	for e: Array in edges:
		var n: Vector2i = Vector2i(x, y) + (e[0] as Vector2i)
		if _map.in_bounds(n) and _map.cells[n.y * BattleMap.W + n.x] == BattleMap.T.TRENCH:
			continue
		var ca: Vector2i = e[1]
		var cb: Vector2i = e[2]
		var a_top := Vector3(ca.x * c - BattleMap.HALF, _map.corner_height(ca.x, ca.y), ca.y * c - BattleMap.HALF)
		var b_top := Vector3(cb.x * c - BattleMap.HALF, _map.corner_height(cb.x, cb.y), cb.y * c - BattleMap.HALF)
		var a_bot := Vector3(a_top.x, yf, a_top.z)
		var b_bot := Vector3(b_top.x, yf, b_top.z)
		var ct := REVET_TOP * shade
		var cb2 := REVET_BOTTOM * shade
		ct.a = 1.0
		cb2.a = 1.0
		st.set_color(ct)
		st.add_vertex(a_top)
		st.set_color(ct)
		st.add_vertex(b_top)
		st.set_color(cb2)
		st.add_vertex(b_bot)
		st.set_color(ct)
		st.add_vertex(a_top)
		st.set_color(cb2)
		st.add_vertex(b_bot)
		st.set_color(cb2)
		st.add_vertex(a_bot)


## Deterministic per-cell shade jitter: stable across chunk rebuilds, so a blast
## never makes untouched neighbouring cells flicker to a different tint.
func _cell_shade(x: int, y: int) -> float:
	return 0.93 + 0.13 * fmod(absf(sin(float(x) * 12.9898 + float(y) * 78.233) * 43758.5453), 1.0)


## Spoil dirt around trenches: each trench cell splats dirt onto the ground corners
## around it — full strength on the lip, fading over two cells, jittered per corner
## so the churned band has a ragged, muddy edge instead of a neat rectangle.
func _build_trench_dirt(map: BattleMap) -> void:
	var cw := BattleMap.W + 1
	_trench_dirt.resize(cw * (BattleMap.H + 1))
	for y in BattleMap.H:
		for x in BattleMap.W:
			if map.cells[y * BattleMap.W + x] != BattleMap.T.TRENCH:
				continue
			for dy in range(-2, 4):
				for dx in range(-2, 4):
					var gx := x + dx
					var gy := y + dy
					if gx < 0 or gy < 0 or gx > BattleMap.W or gy > BattleMap.H:
						continue
					# Chebyshev distance from the cell's own corner rectangle.
					var d := maxi(maxi(-dx, dx - 1), maxi(-dy, dy - 1))
					var s := [1.0, 0.55, 0.22][mini(d, 2)] as float
					var j := 0.65 + 0.5 * fmod(absf(sin(float(gx) * 127.1 + float(gy) * 311.7) * 43758.5453), 1.0)
					var i := gy * cw + gx
					_trench_dirt[i] = maxf(_trench_dirt[i], minf(s * j, 1.0))


## Base cell colour blended toward crater colouring by how deep this corner was dug:
## disturbed earth first, grading to scorched char at the deep centre. A rim corner
## picks up a lighter disturbed-earth cast from the thrown-up spoil.
func _vert_color(base: Color, x: int, y: int) -> Color:
	var i := y * (BattleMap.W + 1) + x
	var col := base
	if i < _trench_dirt.size():
		var dirt := _trench_dirt[i]
		if dirt > 0.0:
			col = col.lerp(TRENCH_DIRT, dirt * 0.85)
	var dig: float = _map.crater_depth[i]
	if dig > 0.0:
		var t := clampf(dig / 0.3, 0.0, 1.0)
		col = col.lerp(DISTURBED, minf(t * 2.0, 1.0))
		if t > 0.5:
			col = col.lerp(SCORCHED, (t - 0.5) * 2.0)
	var rim: float = _map.crater_rim[i]
	if rim > 0.0:
		col = col.lerp(DISTURBED, clampf(rim / 0.1, 0.0, 1.0) * 0.7)
	col.a = 1.0
	return col


## Rebuilds only the ground chunks that overlap the given cell rect (a blast
## touches at most four) and re-seats bushes standing on the reshaped ground.
func refresh_ground(cells: Rect2i) -> void:
	# A blast off the board edge deforms nothing and yields an empty rect.
	if _map == null or _chunks.is_empty() or cells.size.x <= 0 or cells.size.y <= 0:
		return
	var n := BattleMap.W / CHUNK
	var c0x := clampi(cells.position.x / CHUNK, 0, n - 1)
	var c0y := clampi(cells.position.y / CHUNK, 0, n - 1)
	var c1x := clampi((cells.position.x + cells.size.x - 1) / CHUNK, 0, n - 1)
	var c1y := clampi((cells.position.y + cells.size.y - 1) / CHUNK, 0, n - 1)
	for cy in range(c0y, c1y + 1):
		for cx in range(c0x, c1x + 1):
			_chunks[cy * n + cx].mesh = _chunk_mesh(cx, cy)
	if _bush_mm == null:
		return
	var x0 := cells.position.x * BattleMap.CELL - BattleMap.HALF
	var z0 := cells.position.y * BattleMap.CELL - BattleMap.HALF
	var area := Rect2(x0, z0, cells.size.x * BattleMap.CELL, cells.size.y * BattleMap.CELL)
	for i in _bush_xf.size():
		var xf: Transform3D = _bush_xf[i]
		if not area.has_point(Vector2(xf.origin.x, xf.origin.z)):
			continue
		xf.origin.y = _map.height_at(xf.origin)
		_bush_xf[i] = xf
		_bush_mm.set_instance_transform(i, xf)


## Earth sides of the diorama board and a dark table beneath.
func _build_board() -> void:
	var size := BattleMap.HALF * 2.0
	var earth := MeshFactory.Builder.new()
	var dirt := Color(0.24, 0.19, 0.14)
	for i in 4:
		var horizontal := i < 2
		var s := -1.0 if i % 2 == 0 else 1.0
		var dims := Vector3(size + 0.6, BOARD_DEPTH, 0.3) if horizontal else Vector3(0.3, BOARD_DEPTH, size + 0.6)
		var pos := Vector3(0.0, -BOARD_DEPTH * 0.5, s * (BattleMap.HALF + 0.15)) if horizontal else Vector3(s * (BattleMap.HALF + 0.15), -BOARD_DEPTH * 0.5, 0.0)
		earth.box(dims, pos, dirt)
	var sides := MeshInstance3D.new()
	sides.mesh = earth.build()
	add_child(sides)
	var table := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2000, 2000)
	table.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.17, 0.18, 0.17)
	mat.roughness = 1.0
	table.material_override = mat
	table.position.y = -BOARD_DEPTH
	add_child(table)


func _build_trees(map: BattleMap) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var xforms: Array = [[], [], [], []]
	for y in BattleMap.H:
		for x in BattleMap.W:
			if map.cells[y * BattleMap.W + x] != BattleMap.T.TREES or rng.randf() > 0.8:
				continue
			var v := 3 if rng.randf() < 0.15 else rng.randi() % 3
			var p := map.cell_to_world(Vector2i(x, y)) + Vector3(rng.randf_range(-0.7, 0.7), 0.0, rng.randf_range(-0.7, 0.7))
			p.y = map.height_at(p)
			var s := rng.randf_range(0.85, 1.25)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.15), s))
			xforms[v].append(Transform3D(basis, p))
	for v in 4:
		_multimesh(MeshFactory.tree(v), xforms[v])


func _build_scatter(map: BattleMap) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var bushes: Array = []
	var bags: Array = []
	for y in BattleMap.H:
		for x in BattleMap.W:
			var t: int = map.cells[y * BattleMap.W + x]
			var p := map.cell_to_world(Vector2i(x, y))
			if (t == BattleMap.T.OPEN or t == BattleMap.T.GULLY) and rng.randf() < 0.035:
				p += Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8))
				p.y = map.height_at(p)
				var s := rng.randf_range(0.7, 1.4)
				bushes.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), p))
			elif t == BattleMap.T.TRENCH and y > 0 and map.cells[(y - 1) * BattleMap.W + x] != BattleMap.T.TRENCH and rng.randf() < 0.6:
				# Parapet on the spoil-berm crest along the enemy-facing lip.
				var q := p + Vector3(0.0, 0.0, -3.0)
				q.y = map.height_at(q) + 0.02
				bags.append(Transform3D(Basis(Vector3.UP, rng.randf_range(-0.15, 0.15)), q))
			elif t == BattleMap.T.CRATER and rng.randf() < 0.45:
				# Rimmed shell-hole meshes dress the dimpled CRATER cells; where the
				# painting clusters, the merge rule grows one hole instead of piling
				# rims on top of each other.
				p += Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
				_add_crater(p, rng.randi() % MeshFactory.CRATER_VARIANTS, rng.randf_range(0.55, 0.95), rng)
	_bush_mm = _multimesh(MeshFactory.bush(), bushes)
	_bush_xf = bushes
	_multimesh(MeshFactory.sandbags(), bags)
	# One multimesh per crater variant; instance colors carry per-hole tone.
	var per_variant: Array = []
	for v in MeshFactory.CRATER_VARIANTS:
		per_variant.append([])
	for c: Dictionary in _craters:
		per_variant[c["variant"]].append(c)
	for v in MeshFactory.CRATER_VARIANTS:
		var recs: Array = per_variant[v]
		var xfs: Array = []
		var cols: Array = []
		for c: Dictionary in recs:
			xfs.append(Transform3D(c["basis"], c["pos"]))
			cols.append(Color(c["tone"], c["tone"], c["tone"]))
		var mm := _multimesh(MeshFactory.crater(v), xfs, cols)
		for i in recs.size():
			recs[i]["mm"] = mm
			recs[i]["idx"] = i


## A fresh shell-hole mesh at runtime, sized by the blast that dug it. When the hit
## lands on a live crater (merge rule above) that crater grows and darkens instead,
## so repeated shelling of one spot deepens one hole, never a stack of rims.
func spawn_crater(pos: Vector3, blast_radius := 4.0) -> void:
	if _map == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var scale := clampf(blast_radius * 0.2, 0.6, 1.5)
	var c := _add_crater(pos, rng.randi() % MeshFactory.CRATER_VARIANTS, scale, rng)
	if c["mm"] != null or c["mi"] != null:
		# Merged into a live crater: _add_crater already grew its mesh.
		return
	# A brand-new hole: give it its own MeshInstance3D (bounded — merging keeps the
	# count down) with a tone-bucketed material for per-instance colour variation.
	var mi := MeshInstance3D.new()
	mi.mesh = MeshFactory.crater(c["variant"])
	mi.material_override = MeshFactory.tone_material(c["tone"])
	mi.transform = Transform3D(c["basis"], c["pos"])
	add_child(mi)
	c["mi"] = mi


## Registers one crater: merges into a too-close live crater (returning it, grown)
## or appends a new record with per-instance yaw, elliptical XZ scale and tone.
## A new record has neither mm nor mi yet — the caller gives it its visual.
func _add_crater(pos: Vector3, variant: int, scale: float, rng: RandomNumberGenerator) -> Dictionary:
	var r_new: float = MeshFactory.CRATER_R[variant] * scale
	var best := {}
	var best_d := INF
	for c: Dictionary in _craters:
		var d := Vector2(c["pos"].x - pos.x, c["pos"].z - pos.z).length()
		if d < CRATER_MERGE * (c["r"] + r_new) and d < best_d:
			best = c
			best_d = d
	if not best.is_empty():
		_grow_crater(best, pos)
		return best
	var sx := scale * rng.randf_range(0.85, 1.15)
	var sz := scale * rng.randf_range(0.85, 1.15)
	var sy := scale * rng.randf_range(0.8, 1.05)
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sx, sy, sz))
	var r := MeshFactory.CRATER_R[variant] * maxf(sx, sz)
	var p := pos
	p.y = _crater_seat(pos, r)
	var c := {"pos": p, "r": r, "basis": basis, "variant": variant,
			"tone": rng.randf_range(0.86, 1.06), "mm": null, "mi": null, "idx": -1}
	_craters.append(c)
	return c


## Widen, re-seat and re-darken a live crater that took another hit. The rim radius
## saturates at CRATER_R_CAP; the centre drifts a little toward the new impact so
## repeated shelling reads as one churned pit, not a mesh pinned to the first hit.
func _grow_crater(c: Dictionary, hit: Vector3) -> void:
	if c["r"] < CRATER_R_CAP:
		var g := minf(CRATER_GROW, CRATER_R_CAP / c["r"])
		c["r"] *= g
		c["basis"] = (c["basis"] as Basis).scaled(Vector3(g, minf(g, 1.08), g))
	c["tone"] = maxf(c["tone"] * CRATER_TONE_STEP, CRATER_TONE_MIN)
	var p: Vector3 = c["pos"]
	p.x = lerpf(p.x, hit.x, 0.2)
	p.z = lerpf(p.z, hit.z, 0.2)
	p.y = _crater_seat(p, c["r"])
	c["pos"] = p
	var xf := Transform3D(c["basis"], p)
	if c["mi"] != null:
		c["mi"].transform = xf
		c["mi"].material_override = MeshFactory.tone_material(c["tone"])
	elif c["mm"] != null:
		c["mm"].set_instance_transform(c["idx"], xf)
		c["mm"].set_instance_color(c["idx"], Color(c["tone"], c["tone"], c["tone"]))


## Where the mesh base sits: on the ground at the rim ring, not at the dimpled
## centre — the lip must stand proud of the field while the charred floor hangs
## down into the shallow heightfield dish beneath it.
func _crater_seat(pos: Vector3, r: float) -> float:
	var h := 0.0
	for k in 4:
		var a := k * TAU / 4.0
		h += _map.height_at(pos + Vector3(cos(a), 0.0, sin(a)) * r)
	h *= 0.25
	return minf(h, _map.height_at(pos) + 0.22) + 0.02


func _multimesh(mesh: Mesh, list: Array, colors: Array = []) -> MultiMesh:
	if list.is_empty():
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
		if not colors.is_empty():
			mm.set_instance_color(i, colors[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)
	return mm
