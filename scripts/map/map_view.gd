class_name MapView
extends Node3D
## Builds the static scenery for a BattleMap: ground, trees, buildings, wrecks and props.
## The map sits on a raised board like a tabletop diorama.

const BOARD_DEPTH := 2.0


func build(map: BattleMap, mission: Dictionary) -> void:
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
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var c := BattleMap.CELL
	for y in BattleMap.H:
		for x in BattleMap.W:
			var t: int = map.cells[y * BattleMap.W + x]
			var col := _ground_color(t, x, y) * rng.randf_range(0.93, 1.06)
			col.a = 1.0
			var x0 := x * c - BattleMap.HALF
			var z0 := y * c - BattleMap.HALF
			var v00 := Vector3(x0, map.corner_height(x, y), z0)
			var v10 := Vector3(x0 + c, map.corner_height(x + 1, y), z0)
			var v01 := Vector3(x0, map.corner_height(x, y + 1), z0 + c)
			var v11 := Vector3(x0 + c, map.corner_height(x + 1, y + 1), z0 + c)
			st.set_color(col)
			st.add_vertex(v00)
			st.add_vertex(v10)
			st.add_vertex(v11)
			st.add_vertex(v00)
			st.add_vertex(v11)
			st.add_vertex(v01)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, MeshFactory.material())
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)


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
	var craters: Array = []
	for v in MeshFactory.CRATER_VARIANTS:
		craters.append([])
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
				# Rim-and-scorch meshes dress the dimpled shell holes.
				p += Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
				p.y = map.height_at(p) + 0.04
				var cs := rng.randf_range(0.55, 0.95)
				var cb := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * cs)
				craters[rng.randi() % MeshFactory.CRATER_VARIANTS].append(Transform3D(cb, p))
	_multimesh(MeshFactory.bush(), bushes)
	_multimesh(MeshFactory.sandbags(), bags)
	for v in MeshFactory.CRATER_VARIANTS:
		_multimesh(MeshFactory.crater(v), craters[v])


## A fresh shell hole at runtime, sized by the blast that dug it.
func spawn_crater(pos: Vector3, blast_radius := 4.0) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = MeshFactory.crater()
	add_child(mi)
	var s := clampf(blast_radius * 0.2, 0.6, 1.4) * randf_range(0.85, 1.15)
	mi.scale = Vector3(s, s * randf_range(0.85, 1.1), s)
	mi.position = pos + Vector3.UP * 0.02
	mi.rotation.y = randf() * TAU


func _multimesh(mesh: Mesh, list: Array) -> void:
	if list.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	add_child(mmi)
