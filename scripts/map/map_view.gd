class_name MapView
extends Node3D
## Builds the static scenery for a BattleMap: ground, trees, buildings, wrecks and props.
## The map sits on a raised board like a tabletop diorama.

const BOARD_DEPTH := 2.0
## Ground chunk side in cells: the 120x120 map becomes a 10x10 grid of chunk
## meshes, so a blast rebuilds at most four small meshes, never the whole ground.
const CHUNK := 12

## Crater colouring: charred at the scorched centre, disturbed earth at the lip and rim.
const SCORCHED := Color(0.12, 0.10, 0.09)
const DISTURBED := Color(0.31, 0.25, 0.18)

var _map: BattleMap
var _chunks: Array[MeshInstance3D] = []
## Bush multimesh and world positions, so bushes can be re-seated when the ground
## under them is dug out by a blast.
var _bush_mm: MultiMesh
var _bush_xf: Array = []


func build(map: BattleMap, mission: Dictionary) -> void:
	_map = map
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
			return Color(0.30, 0.25, 0.19)
		BattleMap.T.GULLY:
			return Color(0.34, 0.36, 0.23)
		BattleMap.T.CRATER:
			return Color(0.25, 0.21, 0.17)
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


## Deterministic per-cell shade jitter: stable across chunk rebuilds, so a blast
## never makes untouched neighbouring cells flicker to a different tint.
func _cell_shade(x: int, y: int) -> float:
	return 0.93 + 0.13 * fmod(absf(sin(float(x) * 12.9898 + float(y) * 78.233) * 43758.5453), 1.0)


## Base cell colour blended toward crater colouring by how deep this corner was dug:
## disturbed earth first, grading to scorched char at the deep centre. A rim corner
## picks up a lighter disturbed-earth cast from the thrown-up spoil.
func _vert_color(base: Color, x: int, y: int) -> Color:
	var i := y * (BattleMap.W + 1) + x
	var dig: float = _map.crater_depth[i]
	var col := base
	if dig > 0.0:
		var t := clampf(dig / 0.55, 0.0, 1.0)
		col = col.lerp(DISTURBED, minf(t * 2.0, 1.0))
		if t > 0.5:
			col = col.lerp(SCORCHED, (t - 0.5) * 2.0)
	var rim: float = _map.crater_rim[i]
	if rim > 0.0:
		col = col.lerp(DISTURBED, clampf(rim / 0.18, 0.0, 1.0) * 0.7)
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
	_bush_mm = _multimesh(MeshFactory.bush(), bushes)
	_bush_xf = bushes
	_multimesh(MeshFactory.sandbags(), bags)


func _multimesh(mesh: Mesh, list: Array) -> MultiMesh:
	if list.is_empty():
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)
	return mm
