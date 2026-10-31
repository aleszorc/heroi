class_name BattleMap
extends RefCounted
## Grid model of the battlefield: terrain types, cover, line of sight, heights and pathfinding.
## The world is centred on the origin; +X is east, +Z is south (towards the Ukrainian rear).

enum T { OPEN, FIELD, ROAD, TREES, BUILDING, TRENCH, GULLY, CRATER, RUBBLE, WRECK }

const W := 120
const H := 120
const CELL := 2.0
const HALF := W * CELL * 0.5

## cover: protection from fire (Combat applies it as (1 - cover)^Defs.COVER.hit_power).
## conceal: resistance to being spotted. inf / veh: path cost multiplier, 0 = impassable.
## los: visibility kept per cell crossed (trees count every cell, see los()).
const PROPS := {
	T.OPEN: {"cover": 0.0, "conceal": 0.10, "inf": 1.0, "veh": 1.0, "los": 1.0},
	T.FIELD: {"cover": 0.05, "conceal": 0.20, "inf": 1.2, "veh": 1.3, "los": 1.0},
	T.ROAD: {"cover": 0.0, "conceal": 0.0, "inf": 0.9, "veh": 0.6, "los": 1.0},
	T.TREES: {"cover": 0.55, "conceal": 0.75, "inf": 1.5, "veh": 4.0, "los": 0.5},
	T.BUILDING: {"cover": 0.70, "conceal": 0.80, "inf": 1.6, "veh": 0.0, "los": 0.0},
	T.TRENCH: {"cover": 0.75, "conceal": 0.65, "inf": 1.1, "veh": 3.0, "los": 1.0},
	T.GULLY: {"cover": 0.45, "conceal": 0.50, "inf": 1.3, "veh": 2.5, "los": 1.0},
	T.CRATER: {"cover": 0.35, "conceal": 0.30, "inf": 1.4, "veh": 2.0, "los": 1.0},
	T.RUBBLE: {"cover": 0.50, "conceal": 0.50, "inf": 1.6, "veh": 3.0, "los": 0.85},
	T.WRECK: {"cover": 0.60, "conceal": 0.50, "inf": 1.3, "veh": 0.0, "los": 0.5},
}

## Obstacles a soldier can hide behind, by the protection they give from that side.
const SHIELD := {T.BUILDING: 0.8, T.WRECK: 0.7, T.RUBBLE: 0.55, T.TREES: 0.3}

var cells := PackedByteArray()
## Cells closed to movement regardless of terrain: intact house walls.
var blocked := PackedByteArray()
## Blocked cells infantry can still clamber through slowly: window openings and
## walls chipped low enough to climb over. Never passable for vehicles.
var climb := PackedByteArray()
var cover := PackedFloat32Array()
var conceal := PackedFloat32Array()
var los_keep := PackedFloat32Array()
var smoke_until := PackedFloat32Array()
var heights := PackedFloat32Array()
## Per-corner crater bookkeeping: cumulative dig below the base ground and the
## current thrown-earth rim lift above it. `heights` always equals the base
## terrain height minus crater_depth plus crater_rim, so overlapping blasts
## deepen one hole instead of stacking geometry.
var crater_depth := PackedFloat32Array()
var crater_rim := PackedFloat32Array()
## Simulation clock, kept in sync by Battle so smoke can expire.
var now := 0.0

var _astar_inf := AStarGrid2D.new()
var _astar_veh := AStarGrid2D.new()
var _paths_ready := false


func _init() -> void:
	var n := W * H
	cells.resize(n)
	blocked.resize(n)
	climb.resize(n)
	cover.resize(n)
	conceal.resize(n)
	los_keep.resize(n)
	smoke_until.resize(n)
	heights.resize((W + 1) * (H + 1))
	crater_depth.resize((W + 1) * (H + 1))
	crater_rim.resize((W + 1) * (H + 1))
	for y in H:
		for x in W:
			set_cell(Vector2i(x, y), T.OPEN)


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(
		clampi(int(floor((p.x + HALF) / CELL)), 0, W - 1),
		clampi(int(floor((p.z + HALF) / CELL)), 0, H - 1))


func cell_to_world(c: Vector2i) -> Vector3:
	return Vector3((c.x + 0.5) * CELL - HALF, 0.0, (c.y + 0.5) * CELL - HALF)


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < W and c.y < H


func type_at(p: Vector3) -> int:
	var c := world_to_cell(p)
	return cells[c.y * W + c.x]


func cover_at(p: Vector3) -> float:
	var c := world_to_cell(p)
	return cover[c.y * W + c.x]


func conceal_at(p: Vector3) -> float:
	var c := world_to_cell(p)
	var i := c.y * W + c.x
	if smoke_until[i] > now:
		return maxf(conceal[i], 0.85)
	return conceal[i]


## Movement speed multiplier for the terrain under p.
func speed_factor(p: Vector3, vehicle: bool) -> float:
	var c := world_to_cell(p)
	var i := c.y * W + c.x
	if not vehicle and blocked[i] == 1 and climb[i] == 1:
		# Clambering through a window or over a low broken wall.
		return 0.4
	var pr: Dictionary = PROPS[cells[i]]
	var cost: float = pr["veh"] if vehicle else pr["inf"]
	if cost <= 0.0:
		return 0.5
	return clampf(1.0 / cost, 0.3, 1.15)


func set_cell(c: Vector2i, t: int) -> void:
	var i := c.y * W + c.x
	cells[i] = t
	var pr: Dictionary = PROPS[t]
	cover[i] = pr["cover"]
	conceal[i] = pr["conceal"]
	los_keep[i] = pr["los"]
	if _paths_ready:
		_apply_cost(c)


## Opens or closes a cell to movement (walls going up or being blown out).
func set_blocked(c: Vector2i, b: bool) -> void:
	blocked[c.y * W + c.x] = 1 if b else 0
	if _paths_ready:
		_apply_cost(c)


## Marks a blocked cell as climbable for infantry (windows, low broken walls).
func set_climb(c: Vector2i, b: bool) -> void:
	climb[c.y * W + c.x] = 1 if b else 0
	if _paths_ready:
		_apply_cost(c)


# --- Painting (used by missions, world coordinates) ---

func paint_rect(x0: float, z0: float, x1: float, z1: float, t: int) -> void:
	var a := world_to_cell(Vector3(minf(x0, x1), 0.0, minf(z0, z1)))
	var b := world_to_cell(Vector3(maxf(x0, x1) - 0.01, 0.0, maxf(z0, z1) - 0.01))
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			set_cell(Vector2i(x, y), t)


func paint_line(a: Vector2, b: Vector2, width: float, t: int) -> void:
	var steps := int(a.distance_to(b) / (CELL * 0.5)) + 1
	for s in steps + 1:
		paint_disc(a.lerp(b, float(s) / steps), width * 0.5, t)


## Paints a disc; when only_on is given, only cells of those types change.
func paint_disc(center: Vector2, r: float, t: int, only_on: Array = []) -> void:
	var c := world_to_cell(Vector3(center.x, 0.0, center.y))
	var rc := int(ceil(r / CELL))
	for y in range(c.y - rc, c.y + rc + 1):
		for x in range(c.x - rc, c.x + rc + 1):
			var cc := Vector2i(x, y)
			if not in_bounds(cc):
				continue
			var w := cell_to_world(cc)
			if Vector2(w.x, w.z).distance_to(center) > maxf(r, CELL * 0.5):
				continue
			if not only_on.is_empty() and not only_on.has(int(cells[y * W + x])):
				continue
			set_cell(cc, t)


## Turns open ground hit by a big explosion into crater cover; `r` scales the
## footprint with the blast.
func mark_crater(p: Vector3, r := 1.5) -> void:
	paint_disc(Vector2(p.x, p.z), r, T.CRATER, [T.OPEN, T.FIELD, T.ROAD])


## Crater deformation: a shallow scorched dimple under the crater MESH, which is
## what carries the visual (MapView.spawn_crater). A lone hit dishes ~0.3 so the
## mesh sits in a slight hollow, soldiers duck into it and the ground never
## z-fights the mesh; repeated hits deepen it toward CRATER_SAT and never beyond,
## so saturation fire churns the field flat-bottomed instead of digging to the
## mantle or piling geometry.
const CRATER_SAT := 0.6
const CRATER_RIM_MAX := 0.12
## Ground soft enough to dig. A corner deforms only when every cell touching it is
## soft, so buildings, trenches, gullies, rubble and treelines keep their built heights.
const CRATER_SOFT := [T.OPEN, T.FIELD, T.ROAD, T.CRATER]


## Dishes the shallow crater dimple into the heightfield, with a slight rim lift,
## both scaled by the blast radius. Returns the affected cell rect so the view can
## rebuild just those ground chunks.
func deform_crater(p: Vector3, blast_radius: float) -> Rect2i:
	var dish_r := clampf(blast_radius * 0.45, 1.5, 3.2)
	var depth := clampf(blast_radius * 0.05, 0.24, 0.3)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(int(p.x * 7.3), int(p.z * 7.3)))
	_apply_crater(Vector2(p.x, p.z), dish_r, depth, 0.35 * depth, rng)
	var rim_r := dish_r * 1.45
	var cx0 := maxi(int(floor((p.x - rim_r + HALF) / CELL)) - 1, 0)
	var cy0 := maxi(int(floor((p.z - rim_r + HALF) / CELL)) - 1, 0)
	var cx1 := mini(int(ceil((p.x + rim_r + HALF) / CELL)) + 1, W - 1)
	var cy1 := mini(int(ceil((p.z + rim_r + HALF) / CELL)) + 1, H - 1)
	return Rect2i(cx0, cy0, cx1 - cx0 + 1, cy1 - cy0 + 1)


## The shared dish-and-rim profile, used by runtime blasts and painted shell holes
## alike. Inside dish_r the ground sinks on a parabolic bowl (any older rim caught
## in the dish is blasted flat first); from dish_r out to 1.45x the thrown earth
## rises into a ragged lip that peaks just outside the dish edge.
func _apply_crater(center: Vector2, dish_r: float, depth: float, rim_h: float, rng: RandomNumberGenerator) -> void:
	var rim_r := dish_r * 1.45
	var cx0 := maxi(int(floor((center.x - rim_r + HALF) / CELL)), 0)
	var cy0 := maxi(int(floor((center.y - rim_r + HALF) / CELL)), 0)
	var cx1 := mini(int(ceil((center.x + rim_r + HALF) / CELL)), W)
	var cy1 := mini(int(ceil((center.y + rim_r + HALF) / CELL)), H)
	for y in range(cy0, cy1 + 1):
		for x in range(cx0, cx1 + 1):
			if not _corner_diggable(x, y):
				continue
			var i := y * (W + 1) + x
			var d := Vector2(x * CELL - HALF, y * CELL - HALF).distance_to(center)
			if d < dish_r:
				heights[i] -= crater_rim[i]
				crater_rim[i] = 0.0
				var add := depth * (1.0 - pow(d / dish_r, 2.0)) * rng.randf_range(0.8, 1.2)
				var new_depth := minf(crater_depth[i] + add, CRATER_SAT)
				heights[i] -= new_depth - crater_depth[i]
				crater_depth[i] = new_depth
			elif d < rim_r:
				var t := (d - dish_r) / (rim_r - dish_r)
				var add := rim_h * sin(t * PI) * rng.randf_range(0.7, 1.3)
				var new_rim := minf(crater_rim[i] + add, CRATER_RIM_MAX)
				heights[i] += new_rim - crater_rim[i]
				crater_rim[i] = new_rim


func _corner_diggable(x: int, y: int) -> bool:
	for d: Vector2i in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
		var c := Vector2i(x, y) + d
		if not in_bounds(c):
			continue
		if not CRATER_SOFT.has(int(cells[c.y * W + c.x])):
			return false
	return true


func add_smoke(p: Vector3, r: float, duration: float) -> void:
	var c := world_to_cell(p)
	var rc := int(ceil(r / CELL))
	for y in range(c.y - rc, c.y + rc + 1):
		for x in range(c.x - rc, c.x + rc + 1):
			var cc := Vector2i(x, y)
			if in_bounds(cc) and Vector2(cc - c).length() * CELL <= r:
				smoke_until[y * W + x] = now + duration


# --- Finalising: heights and pathfinding ---

func finalize() -> void:
	_build_heights()
	for a: AStarGrid2D in [_astar_inf, _astar_veh]:
		a.region = Rect2i(0, 0, W, H)
		a.cell_size = Vector2.ONE
		a.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		a.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
		a.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
		a.update()
	_paths_ready = true
	for y in H:
		for x in W:
			_apply_cost(Vector2i(x, y))


func _apply_cost(c: Vector2i) -> void:
	var i := c.y * W + c.x
	var pr: Dictionary = PROPS[cells[i]]
	var ci: float = pr["inf"]
	var cv: float = pr["veh"]
	var wall := blocked[i] == 1
	var cl := climb[i] == 1
	_astar_inf.set_point_solid(c, ci <= 0.0 or (wall and not cl))
	if ci > 0.0:
		# A climb cell is open to infantry but costly: going through the window
		# is the way in only when no door or breach is close.
		_astar_inf.set_point_weight_scale(c, ci * 3.0 if wall and cl else ci)
	_astar_veh.set_point_solid(c, cv <= 0.0 or wall)
	if cv > 0.0:
		_astar_veh.set_point_weight_scale(c, cv)


## Trench floor sink in world units: ~1.7 m of real digging drawn at the soldiers'
## 1.25x scale, so a standing man is roughly head-level with the ground.
const TRENCH_DEPTH := 2.1

## Corner heights: gullies are sunk, trench lips rise into a spoil berm, painted
## shell holes get the same dish-and-rim profile as runtime blasts so pre-war
## shelling and fresh hits read as one system. The trench cut itself is NOT in
## the corner heights: a trench cell is a sheer-sided hole whose flat floor comes
## from height_at and whose near-vertical walls are drawn by MapView on the cell
## boundary, so the lip stays crisp instead of a 50-degree bank.
func _build_heights() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in H + 1:
		for x in W + 1:
			var trench := 0
			var gully := 0
			for d: Vector2i in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
				var c := Vector2i(x, y) + d
				if not in_bounds(c):
					continue
				match int(cells[c.y * W + c.x]):
					T.TRENCH:
						trench += 1
					T.GULLY:
						gully += 1
			var h := rng.randf_range(-0.05, 0.05)
			if gully >= 2:
				h -= 1.4
			elif trench >= 1:
				# Spoil berm: every lip corner of the cut rises, so the parapet
				# reads from the camera and the revetment wall below it is sheer.
				h += rng.randf_range(0.22, 0.34)
			heights[y * (W + 1) + x] = h
	# Painted shell holes: one shallow dish per CRATER cell; where the painting
	# clusters, the dishes overlap and deepen toward CRATER_SAT like saturation
	# fire. Kept subtle — the crater mesh MapView seats in each dish carries the
	# look, the dent only grounds it.
	for y in H:
		for x in W:
			if cells[y * W + x] != T.CRATER:
				continue
			var p := cell_to_world(Vector2i(x, y))
			var c2 := Vector2(p.x + rng.randf_range(-0.5, 0.5), p.z + rng.randf_range(-0.5, 0.5))
			_apply_crater(c2, 2.2, 0.18, 0.04, rng)


func corner_height(x: int, y: int) -> float:
	return heights[y * (W + 1) + x]


func height_at(p: Vector3) -> float:
	# A trench cell is a sheer-sided cut: a flat floor at full depth, the walls
	# standing on the cell boundary rather than sloping through the corners.
	var cc := world_to_cell(p)
	if cells[cc.y * W + cc.x] == T.TRENCH:
		return -TRENCH_DEPTH
	var fx := clampf((p.x + HALF) / CELL, 0.0, W - 0.001)
	var fz := clampf((p.z + HALF) / CELL, 0.0, H - 0.001)
	var x0 := int(fx)
	var z0 := int(fz)
	var tx := fx - x0
	var tz := fz - z0
	var top := lerpf(corner_height(x0, z0), corner_height(x0 + 1, z0), tx)
	var bottom := lerpf(corner_height(x0, z0 + 1), corner_height(x0 + 1, z0 + 1), tx)
	return lerpf(top, bottom, tz)


func is_passable(p: Vector3, vehicle: bool) -> bool:
	var a := _astar_veh if vehicle else _astar_inf
	return not a.is_point_solid(world_to_cell(p))


## Whether a man may take one small step from `a` to `b`. The destination cell must
## be open to infantry (doors, breaches and climbable windows are open; intact wall
## is solid), and a diagonal step may not cut past a solid corner. If `a` is itself
## inside a solid cell (which movement should never allow), any step into an open
## cell is still permitted so nobody can be sealed in. This is the one gate all
## per-soldier movement goes through: steering, dives, drags and dead-body slides.
func infantry_step_open(a: Vector3, b: Vector3) -> bool:
	var ca := world_to_cell(a)
	var cb := world_to_cell(b)
	if ca == cb:
		return true
	if _astar_inf.is_point_solid(cb):
		return false
	if ca.x != cb.x and ca.y != cb.y \
			and (_astar_inf.is_point_solid(Vector2i(ca.x, cb.y)) or _astar_inf.is_point_solid(Vector2i(cb.x, ca.y))):
		return false
	return true


## Blocked-but-climbable cell under p: a window opening or a wall chipped low.
func is_climb_at(p: Vector3) -> bool:
	var c := world_to_cell(p)
	var i := c.y * W + c.x
	return blocked[i] == 1 and climb[i] == 1


## Path in world space, excluding the start. Empty if unreachable.
## The grid path is string-pulled into straight runs, so units walk natural lines
## instead of grid staircases, without cutting through costlier terrain the search avoided.
func find_path(from: Vector3, to: Vector3, vehicle: bool) -> PackedVector3Array:
	var astar := _astar_veh if vehicle else _astar_inf
	var a := _nearest_open(world_to_cell(from), astar)
	var b := _nearest_open(world_to_cell(to), astar)
	var out := PackedVector3Array()
	if a.x < 0 or b.x < 0:
		return out
	var ids := astar.get_id_path(a, b)
	if ids.is_empty():
		return out
	var i := 0
	while i < ids.size() - 1:
		var j := i + 1
		var worst := _cost(ids[j], astar)
		while j + 1 < ids.size():
			var next_worst := maxf(worst, _cost(ids[j + 1], astar))
			if not _clear_line(ids[i], ids[j + 1], next_worst, astar):
				break
			worst = next_worst
			j += 1
		if j < ids.size() - 1:
			out.append(cell_to_world(ids[j]))
		i = j
	var end := to if b == world_to_cell(to) else cell_to_world(b)
	end.y = 0.0
	out.append(end)
	return out


## Where a unit at `from` should go to fire on `target` (Defs.ATTACK): a reachable cell
## within `rng` of it with line of sight of at least `min_vis`. Candidates are the cells
## within `radius_cells` that can be walked to in a straight line (stepping round a
## corner) and every cell of the path towards the target; the shortest walk wins, less
## `cover_m` metres per unit of cover for infantry. Vector3.INF when there is none.
func firing_spot(from: Vector3, target: Vector3, rng: float, vehicle: bool, min_vis: float,
		radius_cells: int, cover_m: float) -> Vector3:
	var astar := _astar_veh if vehicle else _astar_inf
	var c := world_to_cell(from)
	var cover_w := 0.0 if vehicle else cover_m
	var best := Vector3.INF
	var best_score := INF
	for y in range(c.y - radius_cells, c.y + radius_cells + 1):
		for x in range(c.x - radius_cells, c.x + radius_cells + 1):
			var cc := Vector2i(x, y)
			if not in_bounds(cc) or astar.is_point_solid(cc):
				continue
			var p := cell_to_world(cc)
			var walk := Vector2(cc - c).length() * CELL
			var score := walk - cover[y * W + x] * cover_w
			if score >= best_score or Vector2(p.x - target.x, p.z - target.z).length() > rng:
				continue
			if cc != c and not _clear_line(c, cc, INF, astar):
				continue
			if los(p, target) >= min_vis:
				best_score = score
				best = p
	var a := _nearest_open(c, astar)
	var b := _nearest_open(world_to_cell(target), astar)
	if a.x < 0 or b.x < 0:
		return best
	var ids := astar.get_id_path(a, b)
	var walk := 0.0
	for k in ids.size():
		if k > 0:
			walk += Vector2(ids[k] - ids[k - 1]).length() * CELL
		if walk - cover_w >= best_score:
			break
		var cc: Vector2i = ids[k]
		var p := cell_to_world(cc)
		var score := walk - cover[cc.y * W + cc.x] * cover_w
		if score >= best_score or Vector2(p.x - target.x, p.z - target.z).length() > rng:
			continue
		if los(p, target) >= min_vis:
			best_score = score
			best = p
	return best


func _cost(c: Vector2i, astar: AStarGrid2D) -> float:
	return astar.get_point_weight_scale(c)


## True if a straight run between two cells crosses only open cells no costlier than max_cost.
func _clear_line(a: Vector2i, b: Vector2i, max_cost: float, astar: AStarGrid2D) -> bool:
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx + dy
	var x := a.x
	var y := a.y
	while not (x == b.x and y == b.y):
		var e2 := 2 * err
		var step_x := e2 >= dy
		var step_y := e2 <= dx
		if step_x and step_y:
			# Diagonal step: both side cells must be open too, or we'd clip a corner.
			if astar.is_point_solid(Vector2i(x + sx, y)) or astar.is_point_solid(Vector2i(x, y + sy)):
				return false
		if step_x:
			err += dy
			x += sx
		if step_y:
			err += dx
			y += sy
		var c := Vector2i(x, y)
		if astar.is_point_solid(c) or astar.get_point_weight_scale(c) > max_cost + 0.01:
			return false
	return true


func _nearest_open(c: Vector2i, astar: AStarGrid2D) -> Vector2i:
	if not astar.is_point_solid(c):
		return c
	for r in range(1, 8):
		for y in range(c.y - r, c.y + r + 1):
			for x in range(c.x - r, c.x + r + 1):
				var cc := Vector2i(x, y)
				if in_bounds(cc) and not astar.is_point_solid(cc):
					return cc
	return Vector2i(-1, -1)


## Visibility for an observer at a looking at b, 0..1. Buildings block, trees and
## smoke thin it out. Cells within 2 of either end are ignored so units can see out of
## (and into) windows and past the wreck they shelter behind. Trees are different:
## every tree cell on the line counts, so a wood 3+ cells deep cannot be seen or shot
## through, and a man a few cells inside it is nearly invisible from outside. Only
## the observer's own edge of the wood is open to him: standing in trees, the tree
## cells next to him are free, so he can see and shoot out while staying hidden.
func los(a: Vector3, b: Vector3) -> float:
	var ca := world_to_cell(a)
	var cb := world_to_cell(b)
	if ca == cb:
		return 1.0
	var a_in_trees := cells[ca.y * W + ca.x] == T.TREES
	var dx := absi(cb.x - ca.x)
	var dy := -absi(cb.y - ca.y)
	var sx := 1 if ca.x < cb.x else -1
	var sy := 1 if ca.y < cb.y else -1
	var err := dx + dy
	var x := ca.x
	var y := ca.y
	var vis := 1.0
	while true:
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy
		if x == cb.x and y == cb.y:
			break
		var i := y * W + x
		var near_a := maxi(absi(x - ca.x), absi(y - ca.y))
		var near_b := maxi(absi(x - cb.x), absi(y - cb.y))
		if cells[i] == T.TREES:
			if not (a_in_trees and near_a <= 1):
				vis *= los_keep[i]
		elif near_a > 2 and near_b > 2:
			vis *= los_keep[i]
		if smoke_until[i] > now and near_a > 2 and near_b > 2:
			vis *= 0.3
		if vis < 0.1:
			return 0.0
	return vis


## Protection from obstacles between p and a threat at `from`, looking 1-3 m out from p.
## This is what makes a man safe behind a wall, a wreck or a heap of rubble.
func shield_at(p: Vector3, from: Vector3) -> float:
	var dir := Vector3(from.x - p.x, 0.0, from.z - p.z)
	if dir.length() < 3.0:
		return 0.0
	dir = dir.normalized()
	var own := world_to_cell(p)
	var best := 0.0
	for dist: float in [1.4, 2.6]:
		var c := world_to_cell(p + dir * dist)
		if c == own:
			continue
		var i := c.y * W + c.x
		var v: float = SHIELD.get(int(cells[i]), 0.0)
		if blocked[i] == 1:
			v = 0.85
		best = maxf(best, v)
	return best


## Cover for a target at p against a shooter at `from`: the better of the ground he is
## in and whatever stands between them. `front` is the direction the ground cover was
## taken against (Unit.cover_front): a trench or a wood edge protects in full inside
## Defs.COVER.flank_arc of it and only flank_keep of that from straight behind.
## Buildings protect all round; walls and wrecks are directional by themselves.
func cover_from(p: Vector3, from: Vector3, front := Vector3.ZERO) -> float:
	var c := cover_at(p)
	if front != Vector3.ZERO and c > 0.0 and type_at(p) != T.BUILDING:
		var to := Vector3(from.x - p.x, 0.0, from.z - p.z)
		if to.length() > 0.5:
			var cos_arc := cos(float(Defs.COVER["flank_arc"]))
			var t := clampf((cos_arc - to.normalized().dot(front)) / (cos_arc + 1.0), 0.0, 1.0)
			c *= lerpf(1.0, float(Defs.COVER["flank_keep"]), t)
	return maxf(c, shield_at(p, from))


## Where a shell aimed at a target inside a building really lands: the wall on the
## shooter's side. Returns `to` when the target is not inside a building.
func wall_entry(from: Vector3, to: Vector3) -> Vector3:
	if type_at(to) != T.BUILDING or type_at(from) == T.BUILDING:
		return to
	var dir := Vector3(from.x - to.x, 0.0, from.z - to.z)
	var dist := dir.length()
	dir = dir.normalized()
	var q := to
	var d := 0.0
	while d < dist and type_at(q) == T.BUILDING:
		d += 0.5
		q = to + dir * d
	return to + dir * maxf(0.0, d - 0.6) + Vector3.UP * 1.2


## Best cover cell near p for one soldier, facing a threat at `threat` when given.
## Cells in `taken` are skipped so a squad spreads out, and cells on the far side
## of an intact wall are never offered — a man must be able to walk there.
## With `by_conceal` the search scores concealment instead of protection
## (shoot-and-move displacement wants to vanish, not to be shot at).
func best_cover_near(p: Vector3, radius_cells: int, taken: Dictionary, threat := Vector3.INF, by_conceal := false) -> Vector3:
	var c := world_to_cell(p)
	var best := c
	var best_score := -INF
	for y in range(c.y - radius_cells, c.y + radius_cells + 1):
		for x in range(c.x - radius_cells, c.x + radius_cells + 1):
			var cc := Vector2i(x, y)
			if not in_bounds(cc) or taken.has(cc) or _astar_inf.is_point_solid(cc):
				continue
			if cc != c and not _clear_line(c, cc, INF, _astar_inf):
				continue
			var value := conceal[y * W + x] if by_conceal else cover[y * W + x]
			if threat != Vector3.INF and not by_conceal:
				value = maxf(value, shield_at(cell_to_world(cc), threat))
			var score := value * 10.0 - Vector2(cc - c).length() * 0.8
			if score > best_score:
				best_score = score
				best = cc
	taken[best] = true
	# The adjacent cells are blocked too, so men sharing one `taken` dict spread out
	# (two cells = 4 m along a line, 2.8 m diagonally) instead of stacking on one bush.
	taken[best + Vector2i(1, 0)] = true
	taken[best + Vector2i(-1, 0)] = true
	taken[best + Vector2i(0, 1)] = true
	taken[best + Vector2i(0, -1)] = true
	return cell_to_world(best) + Vector3(Game.rng.randf_range(-0.4, 0.4), 0.0, Game.rng.randf_range(-0.4, 0.4))
