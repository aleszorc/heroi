class_name MapView
extends Node3D
## Builds the static scenery for a BattleMap: ground, trees, buildings, wrecks and props.
## The map sits on a raised board like a tabletop diorama.

const BOARD_DEPTH := 2.0
## Ground chunk side in cells: the 120x120 map becomes a 10x10 grid of chunk
## meshes, so a blast rebuilds at most four small meshes, never the whole ground.
const CHUNK := 12

## Spoil dirt thrown up around trenches: churned mud fading out over ~2 cells.
const TRENCH_DIRT := Color(0.24, 0.185, 0.125)

## Ground palette per season. `open` and `field` carry two tones each (the field's
## alternate by row as plough or stubble stripes). Summer is green steppe under ripe
## grain, autumn the olive-and-ochre late steppe with yellow-brown stubble, winter a
## snow cover with dirty churned roads, mud the dark rasputitsa with dead grass.
const GROUND := {
	"summer": {"open": [Color(0.38, 0.46, 0.24), Color(0.41, 0.47, 0.25)], "field": [Color(0.58, 0.50, 0.26), Color(0.53, 0.46, 0.24)],
		"road": Color(0.48, 0.43, 0.34), "trees": Color(0.27, 0.34, 0.18), "building": Color(0.33, 0.31, 0.28), "trench": Color(0.21, 0.16, 0.11),
		"gully": Color(0.33, 0.40, 0.22), "crater": Color(0.19, 0.15, 0.11), "rubble": Color(0.40, 0.37, 0.33), "wreck": Color(0.22, 0.20, 0.18)},
	"autumn": {"open": [Color(0.42, 0.44, 0.28), Color(0.45, 0.45, 0.29)], "field": [Color(0.50, 0.42, 0.24), Color(0.44, 0.37, 0.22)],
		"road": Color(0.46, 0.41, 0.33), "trees": Color(0.30, 0.32, 0.20), "building": Color(0.33, 0.31, 0.28), "trench": Color(0.21, 0.16, 0.11),
		"gully": Color(0.34, 0.36, 0.23), "crater": Color(0.19, 0.15, 0.11), "rubble": Color(0.40, 0.37, 0.33), "wreck": Color(0.22, 0.20, 0.18)},
	"winter": {"open": [Color(0.80, 0.82, 0.86), Color(0.76, 0.78, 0.83)], "field": [Color(0.72, 0.72, 0.73), Color(0.80, 0.81, 0.85)],
		"road": Color(0.46, 0.43, 0.40), "trees": Color(0.62, 0.63, 0.63), "building": Color(0.42, 0.40, 0.38), "trench": Color(0.21, 0.16, 0.11),
		"gully": Color(0.66, 0.68, 0.71), "crater": Color(0.19, 0.15, 0.11), "rubble": Color(0.56, 0.54, 0.51), "wreck": Color(0.22, 0.20, 0.18)},
	"mud": {"open": [Color(0.34, 0.32, 0.20), Color(0.37, 0.34, 0.21)], "field": [Color(0.27, 0.21, 0.15), Color(0.24, 0.19, 0.14)],
		"road": Color(0.30, 0.26, 0.21), "trees": Color(0.25, 0.25, 0.16), "building": Color(0.31, 0.29, 0.26), "trench": Color(0.19, 0.145, 0.10),
		"gully": Color(0.26, 0.26, 0.17), "crater": Color(0.17, 0.13, 0.10), "rubble": Color(0.38, 0.35, 0.31), "wreck": Color(0.22, 0.20, 0.18)},
}

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
var _season := "summer"
var _palette: Dictionary = GROUND["summer"]
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
	_season = String(mission.get("season", "summer"))
	_palette = GROUND.get(_season, GROUND["summer"])
	_build_trench_dirt(map)
	_build_ground(map)
	_build_board()
	_build_trees(map)
	_build_scatter(map)
	# Dug-in positions face the enemy: south when the player attacks north-held
	# trenches, north everywhere else.
	_build_fieldworks(map, Vector2i(0, 1) if String(mission.get("kind", "")) == "assault" else Vector2i(0, -1))
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
			return _palette["field"][y % 2]
		BattleMap.T.ROAD:
			return _palette["road"]
		BattleMap.T.TREES:
			return _palette["trees"]
		BattleMap.T.BUILDING:
			return _palette["building"]
		BattleMap.T.TRENCH:
			return _palette["trench"]
		BattleMap.T.GULLY:
			return _palette["gully"]
		BattleMap.T.CRATER:
			return _palette["crater"]
		BattleMap.T.RUBBLE:
			return _palette["rubble"]
		BattleMap.T.WRECK:
			return _palette["wreck"]
	return _palette["open"][0] if (x + y) % 7 != 0 else _palette["open"][1]


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


## Base cell colour, with trench spoil dirt. Craters leave the ground colour alone:
## tinting corners smears brown halos across the 2 m quads, so the crater mesh and
## the heightfield dimple carry the look on their own.
func _vert_color(base: Color, x: int, y: int) -> Color:
	var col := base
	var i := y * (BattleMap.W + 1) + x
	if i < _trench_dirt.size():
		var dirt := _trench_dirt[i]
		if dirt > 0.0:
			col = col.lerp(TRENCH_DIRT, dirt * 0.85)
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
		_multimesh(MeshFactory.tree(v, _season), xforms[v])


func _build_scatter(map: BattleMap) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var bushes: Array = []
	for y in BattleMap.H:
		for x in BattleMap.W:
			var t: int = map.cells[y * BattleMap.W + x]
			var p := map.cell_to_world(Vector2i(x, y))
			if (t == BattleMap.T.OPEN or t == BattleMap.T.GULLY) and rng.randf() < 0.035:
				p += Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8))
				p.y = map.height_at(p)
				var s := rng.randf_range(0.7, 1.4)
				bushes.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), p))
			elif t == BattleMap.T.CRATER:
				# Every dimpled CRATER cell gets the same crater object runtime blasts
				# use, so pre-war shelling and fresh hits are one system; where the
				# painting clusters, the merge rule grows one hole instead of piling
				# bowls on top of each other.
				p += Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
				_add_crater(p, rng.randi() % MeshFactory.CRATER_VARIANTS, rng.randf_range(0.7, 1.0), rng)
	_bush_mm = _multimesh(MeshFactory.bush(_season), bushes)
	_bush_xf = bushes
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


## Sandbag fieldworks on the trenches, from the cut's own geometry. Along every lip
## that faces open ground: a two-course parapet on the berm crest of the enemy-facing
## lip, with a three-course firing bay every few metres; a thinner single-course
## parados behind; a bag wall capping each open trench end; now and then a stack
## revetting the inner face at floor level, and a few bags dropped on the spoil.
## Four MultiMeshes (one per bag variant) with per-instance tone.
func _build_fieldworks(map: BattleMap, fire: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var xf: Array = [[], [], [], []]
	var tone: Array = [[], [], [], []]
	var c := BattleMap.CELL
	var edges: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for y in BattleMap.H:
		for x in BattleMap.W:
			if map.cells[y * BattleMap.W + x] != BattleMap.T.TRENCH:
				continue
			var cell := Vector2i(x, y)
			var centre := map.cell_to_world(cell)
			var open: Array[Vector2i] = []
			for e in edges:
				var n := cell + e
				if not map.in_bounds(n) or map.cells[n.y * BattleMap.W + n.x] != BattleMap.T.TRENCH:
					open.append(e)
			var is_end := open.size() >= 3
			for e in open:
				var out := Vector3(e.x, 0.0, e.y)
				# A run of bags lies along the edge, so it is turned 90 degrees for
				# east/west edges; local +X maps onto the lip direction.
				var yaw := (0.0 if e.y != 0 else PI * 0.5) + rng.randf_range(-0.1, 0.1)
				var variant := -1
				var dist := 0.32
				if e == fire:
					if rng.randf() < 0.92:
						variant = 1 if (x + y) % 3 == 0 and rng.randf() < 0.7 else 0
				elif e == -fire:
					if rng.randf() < 0.45:
						variant = 3 if rng.randf() < 0.7 else 0
				elif is_end:
					if rng.randf() < 0.85:
						variant = 0
				elif rng.randf() < 0.25:
					variant = 3
				if variant >= 0:
					var q := centre + out * (c * 0.5 + dist)
					q.y = map.height_at(q) + 0.02
					xf[variant].append(Transform3D(Basis(Vector3.UP, yaw), q))
					tone[variant].append(rng.randf_range(0.86, 1.08))
				if e == fire and rng.randf() < 0.28:
					# Revetment stacked against the inner face of the fire-side wall.
					var q := centre + out * (c * 0.5 - 0.24)
					q.y = -BattleMap.TRENCH_DEPTH + 0.02
					xf[3].append(Transform3D(Basis(Vector3.UP, yaw), q))
					tone[3].append(rng.randf_range(0.8, 0.95))
				if rng.randf() < 0.18:
					# A bag that rolled off the parapet onto the spoil.
					var q := centre + out * (c * 0.5 + rng.randf_range(0.7, 1.6)) + Vector3(rng.randf_range(-0.8, 0.8), 0.0, 0.0).rotated(Vector3.UP, yaw)
					q.y = map.height_at(q) + 0.02
					xf[2].append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), q))
					tone[2].append(rng.randf_range(0.8, 1.05))
	for v in MeshFactory.SANDBAG_VARIANTS:
		var cols: Array = []
		for t: float in tone[v]:
			cols.append(Color(t, t, t))
		_multimesh(MeshFactory.sandbags(v), xf[v], cols)


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
