class_name BattleMap
extends RefCounted
## Grid model of the battlefield: terrain types, cover, line of sight, heights and pathfinding.
## The world is centred on the origin; +X is east, +Z is south (towards the Ukrainian rear).

enum T { OPEN, FIELD, ROAD, TREES, BUILDING, TRENCH, GULLY, CRATER, RUBBLE, WRECK }

const W := 120
const H := 120
const CELL := 2.0
const HALF := W * CELL * 0.5

## cover: share of hits the terrain stops. conceal: resistance to being spotted.
## inf / veh: path cost multiplier, 0 = impassable. los: visibility kept per cell crossed.
const PROPS := {
	T.OPEN: {"cover": 0.0, "conceal": 0.10, "inf": 1.0, "veh": 1.0, "los": 1.0},
	T.FIELD: {"cover": 0.05, "conceal": 0.20, "inf": 1.2, "veh": 1.3, "los": 1.0},
	T.ROAD: {"cover": 0.0, "conceal": 0.0, "inf": 0.9, "veh": 0.6, "los": 1.0},
	T.TREES: {"cover": 0.45, "conceal": 0.70, "inf": 1.5, "veh": 4.0, "los": 0.72},
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
var cover := PackedFloat32Array()
var conceal := PackedFloat32Array()
var los_keep := PackedFloat32Array()
var smoke_until := PackedFloat32Array()
var heights := PackedFloat32Array()
## Simulation clock, kept in sync by Battle so smoke can expire.
var now := 0.0

var _astar_inf := AStarGrid2D.new()
var _astar_veh := AStarGrid2D.new()
var _paths_ready := false


func _init() -> void:
	var n := W * H
	cells.resize(n)
	blocked.resize(n)
	cover.resize(n)
	conceal.resize(n)
	los_keep.resize(n)
	smoke_until.resize(n)
	heights.resize((W + 1) * (H + 1))
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
	var pr: Dictionary = PROPS[type_at(p)]
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


## Turns open ground hit by a big explosion into crater cover.
func mark_crater(p: Vector3) -> void:
	paint_disc(Vector2(p.x, p.z), 1.5, T.CRATER, [T.OPEN, T.FIELD, T.ROAD])


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
	var pr: Dictionary = PROPS[cells[c.y * W + c.x]]
	var ci: float = pr["inf"]
	var cv: float = pr["veh"]
	var wall := blocked[c.y * W + c.x] == 1
	_astar_inf.set_point_solid(c, ci <= 0.0 or wall)
	if ci > 0.0:
		_astar_inf.set_point_weight_scale(c, ci)
	_astar_veh.set_point_solid(c, cv <= 0.0 or wall)
	if cv > 0.0:
		_astar_veh.set_point_weight_scale(c, cv)


## Corner heights: trenches and gullies are sunk into the ground, craters dimple it.
func _build_heights() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in H + 1:
		for x in W + 1:
			var trench := 0
			var gully := 0
			var crater := 0
			for d: Vector2i in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
				var c := Vector2i(x, y) + d
				if not in_bounds(c):
					continue
				match int(cells[c.y * W + c.x]):
					T.TRENCH:
						trench += 1
					T.GULLY:
						gully += 1
					T.CRATER:
						crater += 1
			var h := rng.randf_range(-0.05, 0.05)
			if gully >= 2:
				h -= 1.4
			elif trench >= 2:
				h = -0.9
			elif crater >= 1:
				h -= 0.35
			heights[y * (W + 1) + x] = h


func corner_height(x: int, y: int) -> float:
	return heights[y * (W + 1) + x]


func height_at(p: Vector3) -> float:
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


## Visibility from a to b, 0..1. Buildings block, trees and smoke thin it out.
## Cells within 2 of either end are ignored so units can see out of windows and treeline edges.
func los(a: Vector3, b: Vector3) -> float:
	var ca := world_to_cell(a)
	var cb := world_to_cell(b)
	if ca == cb:
		return 1.0
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
		if maxi(absi(x - ca.x), absi(y - ca.y)) <= 2 or maxi(absi(x - cb.x), absi(y - cb.y)) <= 2:
			continue
		var i := y * W + x
		vis *= los_keep[i]
		if smoke_until[i] > now:
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
## in and whatever stands between them.
func cover_from(p: Vector3, from: Vector3) -> float:
	return maxf(cover_at(p), shield_at(p, from))


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
## Cells in `taken` are skipped so a squad spreads out.
func best_cover_near(p: Vector3, radius_cells: int, taken: Dictionary, threat := Vector3.INF) -> Vector3:
	var c := world_to_cell(p)
	var best := c
	var best_score := -INF
	for y in range(c.y - radius_cells, c.y + radius_cells + 1):
		for x in range(c.x - radius_cells, c.x + radius_cells + 1):
			var cc := Vector2i(x, y)
			if not in_bounds(cc) or taken.has(cc) or _astar_inf.is_point_solid(cc):
				continue
			var value := cover[y * W + x]
			if threat != Vector3.INF:
				value = maxf(value, shield_at(cell_to_world(cc), threat))
			var score := value * 10.0 - Vector2(cc - c).length() * 0.8
			if score > best_score:
				best_score = score
				best = cc
	taken[best] = true
	return cell_to_world(best) + Vector3(randf_range(-0.4, 0.4), 0.0, randf_range(-0.4, 0.4))
