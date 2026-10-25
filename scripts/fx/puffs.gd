class_name Puffs
extends Node3D
## Volumetric-looking smoke, dust and flame built from faceted 3D puffs (the same style as
## the tree crowns). Each puff is a particle with velocity, drag, lift and wind; it swells,
## drifts and dissolves. Two pools: lit puffs (smoke, dust), which take light and cast
## shadows, and glowing unshaded puffs (flame, muzzle flash).
## Everything is drawn as two MultiMeshes and updated in one buffer write per frame.

const WIND := Vector3(0.5, 0.0, 0.2)


## One MultiMesh worth of puffs, stored as parallel arrays for speed.
class Pool:
	var mm := MultiMesh.new()
	var buffer := PackedFloat32Array()
	var cap := 0
	var n := 0
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var age := PackedFloat32Array()
	var life := PackedFloat32Array()
	var s0 := PackedFloat32Array()
	var s1 := PackedFloat32Array()
	var drag := PackedFloat32Array()
	var lift := PackedFloat32Array()
	var col := PackedColorArray()
	var rot := PackedInt32Array()
	var swell := PackedFloat32Array()

	func _init(capacity: int, mesh: Mesh) -> void:
		cap = capacity
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = cap
		mm.visible_instance_count = 0
		buffer.resize(cap * 16)
		# Packed arrays are values: each must be resized by name, not through a loop variable.
		pos.resize(cap)
		vel.resize(cap)
		age.resize(cap)
		life.resize(cap)
		s0.resize(cap)
		s1.resize(cap)
		drag.resize(cap)
		lift.resize(cap)
		col.resize(cap)
		rot.resize(cap)
		swell.resize(cap)

	## `swl` is the time to reach full size; 0 (the default) means grow over the whole life.
	func emit(p: Vector3, v: Vector3, lifetime: float, size_from: float, size_to: float, c: Color, drg: float, lft: float, swl := 0.0) -> void:
		if n >= cap:
			return
		pos[n] = p
		vel[n] = v
		age[n] = 0.0
		life[n] = lifetime
		s0[n] = size_from
		s1[n] = size_to
		col[n] = c
		drag[n] = drg
		lift[n] = lft
		rot[n] = randi() % Puffs.BASES.size()
		swell[n] = swl if swl > 0.0 else lifetime
		n += 1

	func _remove(i: int) -> void:
		n -= 1
		pos[i] = pos[n]
		vel[i] = vel[n]
		age[i] = age[n]
		life[i] = life[n]
		s0[i] = s0[n]
		s1[i] = s1[n]
		col[i] = col[n]
		drag[i] = drag[n]
		lift[i] = lift[n]
		rot[i] = rot[n]
		swell[i] = swell[n]

	func update(dt: float, wind: Vector3) -> void:
		var i := 0
		while i < n:
			age[i] += dt
			if age[i] >= life[i]:
				_remove(i)
				continue
			var v := vel[i]
			v.y += lift[i] * dt
			# Drag relaxes the puff towards the wind, so smoke drifts with the breeze.
			v = v.lerp(wind + Vector3(0.0, v.y, 0.0), minf(1.0, drag[i] * dt))
			vel[i] = v
			pos[i] += v * dt
			if pos[i].y < 0.1 and v.y < 0.0:
				pos[i].y = 0.1
				vel[i] = Vector3(v.x * 0.5, 0.0, v.z * 0.5)
			i += 1
		for k in n:
			var t := age[k] / life[k]
			# Swell quickly (over `swell` seconds), then dissolve and shrink a little at the end.
			var ts := minf(age[k] / swell[k], 1.0)
			var size := lerpf(s0[k], s1[k], 1.0 - pow(1.0 - ts, 2.5))
			var fade := smoothstep(0.6, 1.0, t)
			size *= 1.0 - 0.35 * fade
			var b: Basis = Puffs.BASES[rot[k]]
			var p := pos[k]
			var o := k * 16
			buffer[o] = b.x.x * size
			buffer[o + 1] = b.y.x * size
			buffer[o + 2] = b.z.x * size
			buffer[o + 3] = p.x
			buffer[o + 4] = b.x.y * size
			buffer[o + 5] = b.y.y * size
			buffer[o + 6] = b.z.y * size
			buffer[o + 7] = p.y
			buffer[o + 8] = b.x.z * size
			buffer[o + 9] = b.y.z * size
			buffer[o + 10] = b.z.z * size
			buffer[o + 11] = p.z
			var c := col[k]
			buffer[o + 12] = c.r
			buffer[o + 13] = c.g
			buffer[o + 14] = c.b
			buffer[o + 15] = c.a * (1.0 - fade)
		mm.buffer = buffer
		mm.visible_instance_count = n


## Random orientations, so identical puffs show different facets.
static var BASES: Array[Basis] = []

var smoke: Pool
var glow: Pool


func _ready() -> void:
	if BASES.is_empty():
		for i in 16:
			BASES.append(Basis(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized(), randf() * TAU))
	var mesh := MeshFactory.puff()
	smoke = Pool.new(2600, mesh)
	glow = Pool.new(500, mesh)
	var lit := StandardMaterial3D.new()
	lit.vertex_color_use_as_albedo = true
	lit.vertex_color_is_srgb = true
	lit.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	lit.roughness = 1.0
	_add_pool(smoke, lit, true)
	var hot := StandardMaterial3D.new()
	hot.vertex_color_use_as_albedo = true
	hot.vertex_color_is_srgb = true
	hot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hot.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	_add_pool(glow, hot, false)


func _add_pool(pool: Pool, mat: Material, shadows: bool) -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = pool.mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Puffs wander far from the node origin; never cull the pool as a whole.
	mmi.custom_aabb = AABB(Vector3(-300, -50, -300), Vector3(600, 200, 600))
	add_child(mmi)


func _process(delta: float) -> void:
	var dt := Game.sim_delta(delta)
	if dt <= 0.0:
		return
	smoke.update(dt, WIND)
	glow.update(dt, WIND)
