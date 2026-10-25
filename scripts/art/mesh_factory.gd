class_name MeshFactory
extends RefCounted
## Procedural low-poly art. Every model is primitives baked into one flat-shaded,
## vertex-coloured mesh, so each object costs a single draw call. Models face -Z.

const UA_COLORS := {"uniform": Color(0.43, 0.45, 0.31), "vest": Color(0.34, 0.36, 0.25), "helmet": Color(0.31, 0.34, 0.24), "tape": Color(0.98, 0.84, 0.12)}
const RU_COLORS := {"uniform": Color(0.36, 0.40, 0.33), "vest": Color(0.29, 0.32, 0.27), "helmet": Color(0.27, 0.31, 0.25), "tape": Color(0.88, 0.16, 0.12)}
const SKIN := Color(0.80, 0.63, 0.50)
const BOOT := Color(0.14, 0.12, 0.10)
const GUN := Color(0.12, 0.12, 0.12)
const TRACK := Color(0.15, 0.14, 0.12)
const WHEEL := Color(0.22, 0.22, 0.19)
const CHAR := Color(0.12, 0.11, 0.10)

static var _cache := {}
static var _material: StandardMaterial3D
static var _unshaded := {}
static var _lit := {}
static var _skin: Skin


## Collects primitives into one mesh. `base` transforms everything; `tint` recolours (burnt wrecks, bodies).
class Builder:
	var st := SurfaceTool.new()
	var base := Transform3D.IDENTITY
	var tint := Color.BLACK
	var tint_amount := 0.0
	## Skeleton bone every following primitive is rigidly bound to; -1 = not skinned.
	var bone := -1

	func _init() -> void:
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_smooth_group(-1)

	func add(prim: PrimitiveMesh, xf: Transform3D, color: Color) -> void:
		var arrays := prim.get_mesh_arrays()
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var t := base * xf
		st.set_color(color.lerp(tint, tint_amount))
		if bone >= 0:
			st.set_bones(PackedInt32Array([bone, 0, 0, 0]))
			st.set_weights(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
		if idx.is_empty():
			for v in verts:
				st.add_vertex(t * v)
		else:
			for i in idx:
				st.add_vertex(t * verts[i])

	func box(size: Vector3, pos: Vector3, color: Color, rot := Vector3.ZERO) -> void:
		var m := BoxMesh.new()
		m.size = size
		add(m, Transform3D(Basis.from_euler(rot), pos), color)

	func cyl(r_top: float, r_bottom: float, height: float, pos: Vector3, color: Color, rot := Vector3.ZERO, segments := 6) -> void:
		var m := CylinderMesh.new()
		m.top_radius = r_top
		m.bottom_radius = r_bottom
		m.height = height
		m.radial_segments = segments
		m.rings = 0
		add(m, Transform3D(Basis.from_euler(rot), pos), color)

	func ball(radius: float, pos: Vector3, color: Color, scale := Vector3.ONE, segments := 6, rings := 3) -> void:
		var m := SphereMesh.new()
		m.radius = radius
		m.height = radius * 2.0
		m.radial_segments = segments
		m.rings = rings
		add(m, Transform3D(Basis.from_scale(scale), pos), color)

	func prism(size: Vector3, pos: Vector3, color: Color, rot := Vector3.ZERO) -> void:
		var m := PrismMesh.new()
		m.size = size
		add(m, Transform3D(Basis.from_euler(rot), pos), color)

	## One triangle, wound so it faces along out_n (Godot treats clockwise as front).
	func tri(a: Vector3, b: Vector3, c: Vector3, out_n: Vector3, color: Color) -> void:
		if (b - a).cross(c - a).dot(out_n) > 0.0:
			var tmp := b
			b = c
			c = tmp
		st.set_color(color.lerp(tint, tint_amount))
		if bone >= 0:
			st.set_bones(PackedInt32Array([bone, 0, 0, 0]))
			st.set_weights(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
		st.add_vertex(base * a)
		st.add_vertex(base * b)
		st.add_vertex(base * c)

	## Side-profile solid: polygon of (z, y) points pushed across x0..x1. This is how
	## hulls get their real silhouette (glacis angles, sloped roofs, rear plates).
	func extrude_x(profile: PackedVector2Array, x0: float, x1: float, color: Color, xf := Transform3D.IDENTITY) -> void:
		var pts := profile.duplicate()
		if MeshFactory.signed_area(pts) < 0.0:
			pts.reverse()
		var n := pts.size()
		for i in n:
			var p := pts[i]
			var q := pts[(i + 1) % n]
			var e := q - p
			var nrm := xf.basis * Vector3(0.0, -e.x, e.y)
			var a := xf * Vector3(x0, p.y, p.x)
			var b := xf * Vector3(x1, p.y, p.x)
			var c := xf * Vector3(x1, q.y, q.x)
			var d := xf * Vector3(x0, q.y, q.x)
			tri(a, b, c, nrm, color)
			tri(a, c, d, nrm, color)
		var idx := Geometry2D.triangulate_polygon(pts)
		for k in range(0, idx.size(), 3):
			var p0 := pts[idx[k]]
			var p1 := pts[idx[k + 1]]
			var p2 := pts[idx[k + 2]]
			for side: Array in [[x0, -1.0], [x1, 1.0]]:
				var x: float = side[0]
				tri(xf * Vector3(x, p0.y, p0.x), xf * Vector3(x, p1.y, p1.x), xf * Vector3(x, p2.y, p2.x), xf.basis * Vector3(float(side[1]), 0.0, 0.0), color)

	## Tapered solid between two top-view outlines of (x, z) points at heights y0 and y1:
	## turrets, cupolas, mantlets.
	func loft(bottom: PackedVector2Array, top: PackedVector2Array, y0: float, y1: float, color: Color, xf := Transform3D.IDENTITY) -> void:
		var n := bottom.size()
		var center := Vector3.ZERO
		for i in n:
			center += Vector3(bottom[i].x, y0, bottom[i].y) + Vector3(top[i].x, y1, top[i].y)
		center /= n * 2.0
		for i in n:
			var j := (i + 1) % n
			var b0 := Vector3(bottom[i].x, y0, bottom[i].y)
			var b1 := Vector3(bottom[j].x, y0, bottom[j].y)
			var t0 := Vector3(top[i].x, y1, top[i].y)
			var t1 := Vector3(top[j].x, y1, top[j].y)
			var out := (b0 + b1 + t0 + t1) * 0.25 - center
			tri(xf * b0, xf * b1, xf * t1, xf.basis * out, color)
			tri(xf * b0, xf * t1, xf * t0, xf.basis * out, color)
		for cap: Array in [[bottom, y0, -1.0], [top, y1, 1.0]]:
			var poly: PackedVector2Array = cap[0]
			var y: float = cap[1]
			var idx := Geometry2D.triangulate_polygon(poly)
			if idx.is_empty():
				poly = poly.duplicate()
				poly.reverse()
				idx = Geometry2D.triangulate_polygon(poly)
			for k in range(0, idx.size(), 3):
				var a := Vector3(poly[idx[k]].x, y, poly[idx[k]].y)
				var b := Vector3(poly[idx[k + 1]].x, y, poly[idx[k + 1]].y)
				var c := Vector3(poly[idx[k + 2]].x, y, poly[idx[k + 2]].y)
				tri(xf * a, xf * b, xf * c, xf.basis * Vector3(0.0, float(cap[2]), 0.0), color)

	func build() -> ArrayMesh:
		st.generate_normals()
		var mesh := st.commit()
		mesh.surface_set_material(0, MeshFactory.material())
		return mesh


static func material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.vertex_color_use_as_albedo = true
		_material.vertex_color_is_srgb = true
		_material.roughness = 1.0
	return _material


## Plain lit colour, for debris chunks.
static func lit(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if _lit.has(key):
		return _lit[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	_lit[key] = m
	return m


static func unshaded(color: Color, no_depth := false) -> StandardMaterial3D:
	var key := "%s_%s" % [color.to_html(), no_depth]
	if _unshaded.has(key):
		return _unshaded[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = no_depth
	_unshaded[key] = m
	return m


# --- Soldiers ---

## Soldier skeleton: [name, parent, rest position in model space before SOLDIER_SCALE].
## Arms hang straight down at rest; IK bends them onto the weapon at runtime.
## WEAPON is the gun (origin at the pistol grip, muzzle towards -Z), parented to the chest.
## BASE never moves and carries the team disc, so the disc stays flat when he goes prone.
const SOLDIER_BONES := [
	["root", -1, Vector3(0.0, 0.0, 0.0)],
	["hips", 0, Vector3(0.0, 0.95, 0.0)],
	["spine", 1, Vector3(0.0, 1.05, 0.0)],
	["chest", 2, Vector3(0.0, 1.28, 0.0)],
	["head", 3, Vector3(0.0, 1.5, 0.0)],
	["upperarm_l", 3, Vector3(-0.2, 1.45, 0.0)],
	["forearm_l", 5, Vector3(-0.2, 1.16, 0.0)],
	["hand_l", 6, Vector3(-0.2, 0.9, 0.0)],
	["upperarm_r", 3, Vector3(0.2, 1.45, 0.0)],
	["forearm_r", 8, Vector3(0.2, 1.16, 0.0)],
	["hand_r", 9, Vector3(0.2, 0.9, 0.0)],
	["thigh_l", 1, Vector3(-0.1, 0.93, 0.0)],
	["shin_l", 11, Vector3(-0.1, 0.5, 0.0)],
	["foot_l", 12, Vector3(-0.1, 0.09, 0.0)],
	["thigh_r", 1, Vector3(0.1, 0.93, 0.0)],
	["shin_r", 14, Vector3(0.1, 0.5, 0.0)],
	["foot_r", 15, Vector3(0.1, 0.09, 0.0)],
	["weapon", 3, Vector3(0.12, 1.18, -0.22)],
	["base", -1, Vector3(0.0, 0.0, 0.0)],
]
## Figures are drawn 25% oversize so they read on a phone screen.
const SOLDIER_SCALE := 1.25
## Where the hands hold each weapon and where it fires from, in weapon space (unscaled).
const WEAPON_POINTS := {
	"ak": {"grip": Vector3(0.0, -0.02, 0.02), "fore": Vector3(0.0, 0.03, -0.3), "muzzle": Vector3(0.0, 0.07, -0.68)},
	"pkm": {"grip": Vector3(0.0, -0.02, 0.03), "fore": Vector3(0.0, 0.02, -0.22), "muzzle": Vector3(0.0, 0.07, -0.8)},
	"sniper": {"grip": Vector3(0.0, -0.02, 0.02), "fore": Vector3(0.0, 0.03, -0.34), "muzzle": Vector3(0.0, 0.07, -0.86)},
	"rpg": {"grip": Vector3(0.0, -0.02, 0.0), "fore": Vector3(0.0, -0.02, -0.22), "muzzle": Vector3(0.0, 0.12, -0.95)},
}


static func weapon_points(weapon: String) -> Dictionary:
	return WEAPON_POINTS.get(weapon, WEAPON_POINTS["ak"])


## Bone rest offset from its parent, scaled.
static func soldier_bone_offset(i: int) -> Vector3:
	var bone: Array = SOLDIER_BONES[i]
	var parent: int = bone[1]
	var origin: Vector3 = bone[2]
	if parent >= 0:
		var parent_bone: Array = SOLDIER_BONES[parent]
		origin -= parent_bone[2]
	return origin * SOLDIER_SCALE


## All soldiers share one rest pose, so one skin serves every skeleton.
static func soldier_skin(skel: Skeleton3D) -> Skin:
	if _skin == null:
		_skin = skel.create_skin_from_rest_transforms()
	return _skin


## Ring of n points (x, z) around a centre, for lofting limbs.
static func ring(cx: float, cz: float, rx: float, rz: float, n := 6) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in n:
		var a := (k + 0.5) * TAU / n
		out.append(Vector2(cx + sin(a) * rx, cz + cos(a) * rz))
	return out


## Uniform palettes per side; the variant shifts shades so a squad isn't a row of clones.
## Few, strongly separated colors (shirt / trousers / charcoal gear / skin): the contrast
## does the work, not greebles.
static func _palette(side: int, variant: int) -> Dictionary:
	var shifts: Array[float] = [0.0, 0.05, -0.04, 0.02]
	var shift := shifts[variant % 4]
	var out := {
		"gear": Color(0.16, 0.17, 0.16).lightened(maxf(0.0, shift)),
		"gear2": Color(0.11, 0.115, 0.11),
		"skin": SKIN.lightened(shift * 0.5),
		"boot": Color(0.13, 0.13, 0.125),
		"gun": Color(0.1, 0.1, 0.1),
	}
	if side == 0:
		out["shirt"] = Color(0.45, 0.46, 0.31).lightened(shift)
		out["pants"] = Color(0.36, 0.38, 0.28).lightened(shift)
		out["helmet"] = [Color(0.42, 0.43, 0.3), Color(0.2, 0.21, 0.2), Color(0.36, 0.39, 0.28), Color(0.45, 0.42, 0.3)][variant % 4]
		out["tape"] = Color(0.98, 0.84, 0.12)
		# Rolled sleeves: bare forearms mark Ukrainians at any zoom.
		out["sleeves"] = false
		out["mag"] = Color(0.12, 0.12, 0.11)
		out["furniture"] = Color(0.12, 0.12, 0.11)
	else:
		out["shirt"] = Color(0.37, 0.4, 0.31).lightened(shift)
		out["pants"] = Color(0.31, 0.34, 0.27).lightened(shift)
		out["helmet"] = [Color(0.33, 0.36, 0.27), Color(0.27, 0.3, 0.25), Color(0.36, 0.38, 0.28), Color(0.3, 0.33, 0.26)][variant % 4]
		out["tape"] = Color(0.88, 0.16, 0.12)
		out["sleeves"] = true
		out["mag"] = Color(0.42, 0.22, 0.16)
		out["furniture"] = Color(0.14, 0.13, 0.12)
	return out


## Clean low-poly soldier: few large volumes, strong color blocking, and accessories kept
## to what reads at game zoom — plate carrier, one pouch row, radio, thigh rig, headset
## helmet. Joint-filling balls match their surrounding color exactly, so they are
## invisible until a limb bends and they close the gap.
static func soldier(side: int, weapon: String, dead := false, variant := 0) -> ArrayMesh:
	var key := "soldier_%d_%s_%s_%d" % [side, weapon, dead, variant]
	if _cache.has(key):
		return _cache[key]
	var c := _palette(side, variant)
	var shirt: Color = c["shirt"]
	var pants: Color = c["pants"]
	var gear: Color = c["gear"]
	var gear2: Color = c["gear2"]
	var skin: Color = c["skin"]
	var helmet: Color = c["helmet"]
	var tape: Color = c["tape"]
	var boot: Color = c["boot"]
	var arm_lo: Color = shirt if bool(c["sleeves"]) else skin
	var b := Builder.new()
	b.base = Transform3D(Basis.from_scale(Vector3.ONE * SOLDIER_SCALE), Vector3.ZERO)
	if dead:
		b.tint = Color(0.22, 0.2, 0.17)
		b.tint_amount = 0.4

	for leg: Array in [[-1.0, 11, 12, 13], [1.0, 14, 15, 16]]:
		var sx: float = leg[0]
		var x := 0.1 * sx
		b.bone = leg[1]
		b.ball(0.095, Vector3(x, 0.9, 0.0), pants, Vector3(1.0, 1.15, 1.0))
		b.loft(ring(x, 0.0, 0.08, 0.09), ring(x, 0.0, 0.105, 0.115), 0.52, 0.92, pants)
		b.loft(ring(x, 0.0, 0.084, 0.094), ring(x, 0.0, 0.086, 0.096), 0.74, 0.78, gear2)
		if sx > 0.0:
			# Thigh holster on the right, flat pouch on the left: quiet asymmetry.
			b.box(Vector3(0.05, 0.16, 0.08), Vector3(x + 0.1, 0.66, -0.01), gear)
			b.box(Vector3(0.03, 0.05, 0.03), Vector3(x + 0.1, 0.76, 0.02), gear2)
		else:
			b.box(Vector3(0.04, 0.13, 0.1), Vector3(x - 0.1, 0.66, 0.0), gear)
		b.bone = leg[2]
		# The dark knee pad is also the joint cover.
		b.ball(0.082, Vector3(x, 0.52, -0.012), gear, Vector3(1.0, 1.2, 1.0))
		b.loft(ring(x, 0.005, 0.062, 0.075), ring(x, 0.005, 0.075, 0.09), 0.3, 0.5, pants)
		b.loft(ring(x, 0.005, 0.058, 0.068), ring(x, 0.005, 0.063, 0.073), 0.14, 0.31, boot)
		b.bone = leg[3]
		b.box(Vector3(0.1, 0.03, 0.24), Vector3(x, 0.015, -0.045), gear2)
		b.loft(ring(x, -0.045, 0.048, 0.1), ring(x, -0.055, 0.038, 0.07), 0.03, 0.1, boot)
		b.loft(ring(x, 0.005, 0.05, 0.06), ring(x, 0.005, 0.055, 0.066), 0.08, 0.17, boot)

	b.bone = 1
	b.loft(ring(0.0, 0.0, 0.165, 0.105, 8), ring(0.0, 0.0, 0.175, 0.115, 8), 0.84, 1.0, pants)
	b.loft(ring(0.0, 0.0, 0.178, 0.118, 8), ring(0.0, 0.0, 0.18, 0.12, 8), 0.97, 1.01, gear2)

	b.bone = 2
	b.loft(ring(0.0, 0.0, 0.16, 0.1, 8), ring(0.0, 0.0, 0.18, 0.11, 8), 1.0, 1.2, shirt)
	# One magazine-pouch row on the cummerbund, dividers implied by two dark strips.
	b.box(Vector3(0.26, 0.13, 0.055), Vector3(0.0, 1.09, -0.135), gear)
	for px: float in [-0.045, 0.045]:
		b.box(Vector3(0.012, 0.135, 0.012), Vector3(px, 1.09, -0.163), gear2)

	b.bone = 3
	b.loft(ring(0.0, 0.0, 0.18, 0.11, 8), ring(0.0, 0.0, 0.205, 0.12, 8), 1.18, 1.42, shirt)
	b.loft(ring(0.0, 0.0, 0.205, 0.12, 8), ring(0.0, 0.0, 0.12, 0.085, 8), 1.42, 1.5, shirt)
	# Plate carrier: one wrapping mass plus front and back plates.
	b.loft(ring(0.0, 0.005, 0.195, 0.133, 8), ring(0.0, 0.0, 0.2, 0.138, 8), 1.13, 1.38, gear)
	b.box(Vector3(0.28, 0.24, 0.04), Vector3(0.0, 1.27, -0.15), gear.lightened(0.05))
	b.box(Vector3(0.28, 0.26, 0.04), Vector3(0.0, 1.27, 0.15), gear.lightened(0.03))
	b.box(Vector3(0.055, 0.1, 0.05), Vector3(-0.13, 1.31, -0.17), gear2)
	b.cyl(0.006, 0.006, 0.2, Vector3(-0.13, 1.47, -0.17), c["gun"], Vector3.ZERO, 4)
	b.box(Vector3(0.02, 0.02, 0.012), Vector3(-0.13, 1.34, -0.198), Color(0.75, 0.2, 0.15))
	if variant % 2 == 0:
		b.box(Vector3(0.26, 0.28, 0.12), Vector3(0.0, 1.24, 0.26), gear.lightened(0.02))
		b.box(Vector3(0.26, 0.07, 0.1), Vector3(0.0, 1.42, 0.25), gear2)
	if weapon == "stugna":
		b.cyl(0.08, 0.08, 1.15, Vector3(0.05, 1.35, 0.27), Color(0.28, 0.32, 0.22), Vector3(0.25, 0.0, 0.5), 8)

	b.bone = 4
	b.cyl(0.05, 0.055, 0.09, Vector3(0.0, 1.53, 0.0), skin, Vector3.ZERO, 6)
	var face := gear2 if variant == 3 else skin
	b.ball(0.105, Vector3(0.0, 1.63, 0.005), face, Vector3(0.95, 1.08, 1.0), 8, 4)
	b.ball(0.147, Vector3(0.0, 1.683, 0.005), helmet, Vector3(1.0, 0.85, 1.08), 8, 4)
	b.loft(ring(0.0, 0.005, 0.149, 0.157, 10), ring(0.0, 0.005, 0.144, 0.152, 10), 1.615, 1.655, helmet.darkened(0.1))
	b.box(Vector3(0.05, 0.05, 0.045), Vector3(0.0, 1.705, -0.145), gear2)
	for hx: float in [-0.142, 0.142]:
		b.box(Vector3(0.016, 0.028, 0.13), Vector3(hx, 1.675, 0.0), gear2)
	for hx: float in [-0.118, 0.118]:
		# Headset ear cups.
		b.cyl(0.045, 0.045, 0.028, Vector3(hx, 1.6, 0.015), gear2, Vector3(0.0, 0.0, PI / 2), 8)

	for arm: Array in [[-1.0, 5, 6, 7], [1.0, 8, 9, 10]]:
		var sx: float = arm[0]
		var x := 0.2 * sx
		b.bone = arm[1]
		b.ball(0.08, Vector3(x, 1.44, 0.0), shirt, Vector3(1.05, 1.15, 1.0))
		b.loft(ring(x, 0.0, 0.06, 0.066), ring(x, 0.0, 0.072, 0.078), 1.27, 1.44, shirt)
		b.loft(ring(x, 0.0, 0.062, 0.068), ring(x, 0.0, 0.064, 0.07), 1.25, 1.285, shirt.darkened(0.06))
		b.loft(ring(x, 0.0, 0.048, 0.054), ring(x, 0.0, 0.057, 0.062), 1.15, 1.27, arm_lo)
		if sx < 0.0:
			b.loft(ring(x, 0.0, 0.068, 0.074), ring(x, 0.0, 0.07, 0.076), 1.33, 1.39, tape)
		b.bone = arm[2]
		b.ball(0.054, Vector3(x, 1.16, 0.0), arm_lo)
		b.loft(ring(x, 0.0, 0.04, 0.045), ring(x, 0.0, 0.052, 0.057), 0.95, 1.17, arm_lo)
		b.loft(ring(x, 0.0, 0.046, 0.05), ring(x, 0.0, 0.05, 0.054), 0.9, 0.97, gear)
		b.bone = arm[3]
		b.box(Vector3(0.055, 0.085, 0.075), Vector3(x, 0.855, -0.005), gear)
		b.box(Vector3(0.028, 0.045, 0.028), Vector3(x - 0.045 * sx, 0.87, -0.03), gear)

	b.bone = 17
	_weapon_mesh(b, weapon, c, side, Vector3(0.12, 1.18, -0.22))
	var mesh := b.build()
	_cache[key] = mesh
	return mesh


## Weapons modelled from their real layout, around the pistol grip at `o`.
static func _weapon_mesh(b: Builder, weapon: String, c: Dictionary, side: int, o: Vector3) -> void:
	var gun: Color = c["gun"]
	var mag: Color = c["mag"]
	var wood := Color(0.42, 0.27, 0.16)
	var z90 := Vector3(PI / 2, 0.0, 0.0)
	match weapon:
		"pkm":
			b.box(Vector3(0.06, 0.1, 0.36), o + Vector3(0.0, 0.06, -0.06), gun)
			b.box(Vector3(0.055, 0.025, 0.24), o + Vector3(0.0, 0.12, -0.08), gun.lightened(0.05))
			b.box(Vector3(0.03, 0.09, 0.04), o + Vector3(0.0, -0.03, 0.03), gun, Vector3(0.3, 0.0, 0.0))
			b.box(Vector3(0.08, 0.11, 0.14), o + Vector3(0.03, -0.05, -0.12), Color(0.3, 0.33, 0.24))
			b.cyl(0.016, 0.016, 0.5, o + Vector3(0.0, 0.07, -0.47), gun, z90, 6)
			b.cyl(0.022, 0.018, 0.08, o + Vector3(0.0, 0.07, -0.76), gun, z90, 6)
			b.box(Vector3(0.015, 0.015, 0.3), o + Vector3(-0.02, 0.04, -0.45), gun)
			b.box(Vector3(0.015, 0.015, 0.3), o + Vector3(0.02, 0.04, -0.45), gun)
			b.box(Vector3(0.02, 0.06, 0.02), o + Vector3(0.0, 0.15, -0.2), gun)
			b.box(Vector3(0.04, 0.03, 0.28), o + Vector3(0.0, 0.07, 0.2), gun)
			b.box(Vector3(0.04, 0.03, 0.25), o + Vector3(0.0, -0.02, 0.2), gun, Vector3(-0.25, 0.0, 0.0))
			b.box(Vector3(0.045, 0.13, 0.03), o + Vector3(0.0, 0.02, 0.34), gun)
		"sniper":
			b.box(Vector3(0.045, 0.07, 0.3), o + Vector3(0.0, 0.06, -0.06), gun)
			b.box(Vector3(0.03, 0.09, 0.04), o + Vector3(0.0, -0.03, 0.03), wood, Vector3(0.3, 0.0, 0.0))
			b.box(Vector3(0.025, 0.09, 0.06), o + Vector3(0.0, -0.01, -0.12), gun)
			b.box(Vector3(0.05, 0.055, 0.25), o + Vector3(0.0, 0.055, -0.34), wood)
			b.cyl(0.012, 0.012, 0.42, o + Vector3(0.0, 0.07, -0.66), gun, z90, 6)
			b.cyl(0.018, 0.016, 0.06, o + Vector3(0.0, 0.07, -0.86), gun, z90, 6)
			# Thumbhole stock and cheek rest.
			b.box(Vector3(0.04, 0.03, 0.3), o + Vector3(0.0, 0.08, 0.22), wood)
			b.box(Vector3(0.04, 0.03, 0.26), o + Vector3(0.0, -0.03, 0.22), wood, Vector3(-0.2, 0.0, 0.0))
			b.box(Vector3(0.04, 0.14, 0.03), o + Vector3(0.0, 0.02, 0.37), wood)
			# PSO-1 scope on its side rail.
			b.cyl(0.022, 0.022, 0.22, o + Vector3(-0.035, 0.14, -0.05), gun, z90, 8)
			b.cyl(0.027, 0.027, 0.04, o + Vector3(-0.035, 0.14, -0.17), gun, z90, 8)
			b.box(Vector3(0.03, 0.04, 0.06), o + Vector3(-0.035, 0.105, -0.05), gun)
		"rpg":
			var tube := Color(0.17, 0.17, 0.16)
			# Launcher: thin tube, wooden heat guard at the shoulder, flared venturi.
			b.cyl(0.042, 0.042, 0.78, o + Vector3(0.0, 0.12, -0.06), tube, z90, 8)
			b.cyl(0.056, 0.056, 0.2, o + Vector3(0.0, 0.12, 0.16), wood, z90, 8)
			b.cyl(0.075, 0.048, 0.14, o + Vector3(0.0, 0.12, 0.42), tube, z90, 8)
			b.cyl(0.08, 0.08, 0.016, o + Vector3(0.0, 0.12, 0.49), tube, z90, 8)
			b.box(Vector3(0.03, 0.1, 0.04), o + Vector3(0.0, 0.04, 0.02), gun, Vector3(0.2, 0.0, 0.0))
			b.box(Vector3(0.03, 0.09, 0.04), o + Vector3(0.0, 0.045, -0.2), gun, Vector3(0.15, 0.0, 0.0))
			b.box(Vector3(0.028, 0.07, 0.09), o + Vector3(-0.05, 0.18, -0.1), gun)
			b.box(Vector3(0.015, 0.05, 0.015), o + Vector3(0.0, 0.19, -0.38), tube)
			# PG-7 grenade: needle fuze, ogive swelling to the 85 mm bulb, boat-tail
			# back to the booster that sits in the muzzle.
			var g7 := Color(0.3, 0.33, 0.24)
			b.cyl(0.026, 0.026, 0.2, o + Vector3(0.0, 0.12, -0.55), g7, z90, 8)
			b.cyl(0.026, 0.08, 0.12, o + Vector3(0.0, 0.12, -0.71), g7, z90, 8)
			b.cyl(0.08, 0.028, 0.13, o + Vector3(0.0, 0.12, -0.835), g7.darkened(0.05), z90, 8)
			b.cyl(0.012, 0.012, 0.06, o + Vector3(0.0, 0.12, -0.93), tube, z90, 5)
		_:
			# AK-74 family. Ukrainian rifles are upgraded: black furniture, rail and red dot.
			b.box(Vector3(0.05, 0.08, 0.32), o + Vector3(0.0, 0.06, -0.05), gun)
			b.box(Vector3(0.046, 0.02, 0.28), o + Vector3(0.0, 0.105, -0.04), gun.lightened(0.06))
			b.box(Vector3(0.03, 0.09, 0.04), o + Vector3(0.0, -0.03, 0.03), c["furniture"], Vector3(0.3, 0.0, 0.0))
			# Curved magazine: convex edge towards the muzzle, kicking further forward
			# as it drops (rotation +X tips the bottom towards -Z).
			b.box(Vector3(0.032, 0.1, 0.06), o + Vector3(0.0, -0.025, -0.1), mag, Vector3(0.25, 0.0, 0.0))
			b.box(Vector3(0.03, 0.095, 0.055), o + Vector3(0.0, -0.105, -0.135), mag, Vector3(0.6, 0.0, 0.0))
			b.box(Vector3(0.05, 0.05, 0.2), o + Vector3(0.0, 0.05, -0.31), c["furniture"])
			b.box(Vector3(0.035, 0.03, 0.18), o + Vector3(0.0, 0.1, -0.3), c["furniture"])
			b.cyl(0.012, 0.012, 0.2, o + Vector3(0.0, 0.07, -0.5), gun, z90, 6)
			b.box(Vector3(0.02, 0.05, 0.02), o + Vector3(0.0, 0.1, -0.55), gun)
			b.cyl(0.018, 0.018, 0.08, o + Vector3(0.0, 0.07, -0.64), gun, z90, 6)
			b.box(Vector3(0.04, 0.09, 0.24), o + Vector3(0.0, 0.035, 0.21), c["furniture"])
			b.box(Vector3(0.04, 0.13, 0.03), o + Vector3(0.0, 0.02, 0.34), c["furniture"])
			if side == 0:
				b.box(Vector3(0.04, 0.012, 0.16), o + Vector3(0.0, 0.122, -0.06), gun)
				b.box(Vector3(0.035, 0.045, 0.06), o + Vector3(0.0, 0.15, -0.06), gun)
				b.box(Vector3(0.025, 0.025, 0.005), o + Vector3(0.0, 0.155, -0.092), Color(0.6, 0.1, 0.1))


# --- Vehicles ---

## Returns {hull, turret: ArrayMesh, turret_pos: Vector3, muzzle: Vector3 (turret space)}.
static func vehicle(kind: String, burnt := false) -> Dictionary:
	var key := "veh_%s_%s" % [kind, burnt]
	if _cache.has(key):
		return _cache[key]
	var h := Builder.new()
	var t := Builder.new()
	if burnt:
		for b: Builder in [h, t]:
			b.tint = CHAR
			b.tint_amount = 0.72
	var out: Dictionary
	match kind:
		"bmp2":
			out = _bmp2(h, t)
		"t72":
			out = _t72(h, t)
		"mtlb":
			out = _mtlb(h, t)
		_:
			out = _bradley(h, t)
	out["hull"] = h.build()
	out["turret"] = t.build()
	_cache[key] = out
	return out


static func signed_area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p := pts[i]
		var q := pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


## Top-view outline (x, z) of n points: an oval with a fuller front (-z) than rear.
static func blob(rx: float, r_front: float, r_back: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in n:
		var a := (k + 0.5) * TAU / n
		var z := cos(a)
		out.append(Vector2(sin(a) * rx, z * (r_back if z > 0.0 else r_front)))
	return out


## Point a fraction t along a profile edge from a to b, pushed `lift` out of the surface.
## Used to lay armour bricks, ribs and plates flat on sloped plates.
static func on_slope(a: Vector2, b: Vector2, t: float, lift: float) -> Vector3:
	var p := a.lerp(b, t)
	var e := (b - a).normalized()
	var n := Vector2(-e.y, e.x)
	if n.y < 0.0:
		n = -n
	p += n * lift
	return Vector3(0.0, p.y, p.x)


## Rotation about X that lays a flat box onto the slope from a to b (profile (z, y)).
static func slope_tilt(a: Vector2, b: Vector2) -> float:
	return atan2(b.y - a.y, b.x - a.x) * -1.0


## Tracks and running gear on both sides.
## cfg: hx (track centre x), w (track width), outline (side profile of the track loop),
## wheels (z list), wheel_r, idler/sprocket [z, y, r], rollers (z list), roller_y.
static func _running_gear(h: Builder, cfg: Dictionary, hull_color: Color) -> void:
	var hx: float = cfg["hx"]
	var w: float = cfg["w"]
	var outline: PackedVector2Array = cfg["outline"]
	var wr: float = cfg["wheel_r"]
	var rubber := Color(0.1, 0.1, 0.09)
	var steel := hull_color.darkened(0.15)
	for sx: float in [-1.0, 1.0]:
		var inner := (hx - w * 0.5) * sx
		var outer := (hx + w * 0.5) * sx
		h.extrude_x(outline, minf(inner, outer), maxf(inner, outer), TRACK)
		# Track shoes: cleats along the top and bottom runs.
		var top_y: float = outline[outline.size() - 1].y
		var z0: float = outline[outline.size() - 1].x
		var z1: float = outline[outline.size() - 2].x
		var steps := int((z1 - z0) / 0.32)
		for k in steps:
			h.box(Vector3(w + 0.02, 0.05, 0.1), Vector3(hx * sx, top_y + 0.01, z0 + (k + 0.5) * 0.32), Color(0.2, 0.19, 0.17))
		# Road wheels: rubber tyre, steel disc, hub. They sit inside the track loop,
		# standing just proud of it so the side view shows them.
		var wx := (hx + w * 0.5 - 0.08) * sx
		for z: float in cfg["wheels"]:
			h.cyl(wr, wr, 0.2, Vector3(wx, wr + 0.04, z), rubber, Vector3(0.0, 0.0, PI / 2), 14)
			h.cyl(wr * 0.82, wr * 0.82, 0.24, Vector3(wx, wr + 0.04, z), steel, Vector3(0.0, 0.0, PI / 2), 14)
			h.cyl(wr * 0.3, wr * 0.3, 0.3, Vector3(wx, wr + 0.04, z), steel.darkened(0.2), Vector3(0.0, 0.0, PI / 2), 8)
		for key: String in ["idler", "sprocket"]:
			var g: Array = cfg[key]
			h.cyl(float(g[2]), float(g[2]), 0.26, Vector3(wx, float(g[1]), float(g[0])), steel.darkened(0.1), Vector3(0.0, 0.0, PI / 2), 12)
			if key == "sprocket":
				for k in 10:
					var a := k * TAU / 10.0
					h.box(Vector3(0.3, 0.07, 0.07), Vector3(wx, float(g[1]) + sin(a) * float(g[2]), float(g[0]) + cos(a) * float(g[2])), steel.darkened(0.3), Vector3(a, 0.0, 0.0))
		for z: float in cfg.get("rollers", []):
			h.cyl(0.1, 0.1, 0.2, Vector3(wx - 0.05 * sx, float(cfg["roller_y"]), z), steel, Vector3(0.0, 0.0, PI / 2), 8)


static func _smoke_launchers(t: Builder, x: float, y: float, z: float, count: int, color: Color) -> void:
	for k in count:
		t.cyl(0.05, 0.05, 0.32, Vector3(x, y + k * 0.11, z), color, Vector3(-0.5, 0.0, 0.0), 6)


## T-72B3: low cast turret with Kontakt-5 wedges, 125 mm gun, Sosna-U sight, fuel drums,
## unditching log, six big road wheels, rear sprocket, and a welded anti-drone cage.
static func _t72(h: Builder, t: Builder) -> Dictionary:
	var g := Color(0.33, 0.36, 0.25)
	var era := g.darkened(0.08)
	var rust := Color(0.40, 0.31, 0.22)
	var nose_lo := Vector2(-3.45, 0.85)
	var nose_hi := Vector2(-2.25, 1.45)
	h.extrude_x(PackedVector2Array([Vector2(-3.2, 0.45), nose_lo, nose_hi, Vector2(3.3, 1.45), Vector2(3.45, 0.6), Vector2(3.2, 0.45)]), -1.1, 1.1, g)
	# Kontakt-5 bricks covering the upper glacis.
	var tilt := slope_tilt(nose_lo, nose_hi)
	for i in 6:
		for j in 2:
			var p := on_slope(nose_lo, nose_hi, (j + 0.5) / 2.0, 0.07)
			h.box(Vector3(0.34, 0.1, 0.6), Vector3(-0.95 + i * 0.38, p.y, p.z), era, Vector3(tilt, 0.0, 0.0))
	for sx: float in [-1.0, 1.0]:
		h.box(Vector3(0.64, 0.05, 6.75), Vector3(1.42 * sx, 1.1, 0.05), g)
		h.box(Vector3(0.05, 0.42, 5.6), Vector3(1.75 * sx, 0.9, -0.1), Color(0.16, 0.16, 0.14))
		for k in 3:
			h.box(Vector3(0.5, 0.3, 0.78), Vector3(1.4 * sx, 1.28, 0.95 + k * 0.85), g.darkened(0.06))
		h.box(Vector3(0.12, 0.12, 0.2), Vector3(0.95 * sx, 1.5, -2.35), Color(0.75, 0.75, 0.6))
	for sx: float in [-1.0, 1.0]:
		h.cyl(0.3, 0.3, 0.85, Vector3(0.55 * sx, 1.15, 3.7), Color(0.3, 0.32, 0.22), Vector3(0.0, 0.0, PI / 2), 10)
	h.cyl(0.12, 0.12, 3.0, Vector3(0.0, 1.62, 3.3), Color(0.35, 0.27, 0.18), Vector3(0.0, 0.0, PI / 2), 6)
	h.box(Vector3(1.6, 0.05, 1.2), Vector3(0.0, 1.48, 2.3), Color(0.15, 0.15, 0.13))
	_running_gear(h, {
		"hx": 1.39, "w": 0.58,
		"outline": PackedVector2Array([Vector2(-3.35, 0.55), Vector2(-2.85, 0.04), Vector2(2.75, 0.04), Vector2(3.45, 0.62), Vector2(3.1, 1.03), Vector2(-3.1, 1.03)]),
		"wheels": [-2.35, -1.43, -0.51, 0.41, 1.33, 2.25], "wheel_r": 0.37,
		"idler": [-3.05, 0.55, 0.3], "sprocket": [3.1, 0.62, 0.33],
		"rollers": [-1.45, 0.0, 1.45], "roller_y": 0.98,
	}, g)

	t.loft(blob(1.55, 1.75, 1.25, 14), blob(1.15, 1.25, 0.95, 14), 0.0, 0.62, g)
	for sx: float in [-1.0, 1.0]:
		t.box(Vector3(0.95, 0.34, 0.62), Vector3(0.78 * sx, 0.42, -1.3), era, Vector3(-0.35, 0.55 * sx, 0.0))
		t.box(Vector3(0.7, 0.12, 0.6), Vector3(0.65 * sx, 0.66, -0.8), era, Vector3(-0.1, 0.0, 0.0))
		_smoke_launchers(t, 1.18 * sx, 0.3, -0.45, 4, g.darkened(0.2))
		t.box(Vector3(0.3, 0.4, 0.9), Vector3(1.32 * sx, 0.3, 0.55), g.darkened(0.06))
	t.box(Vector3(0.6, 0.48, 0.55), Vector3(0.0, 0.32, -1.4), g.darkened(0.05))
	var barrel := g.darkened(0.12)
	t.cyl(0.085, 0.085, 4.8, Vector3(0.0, 0.33, -3.7), barrel, Vector3(PI / 2, 0.0, 0.0), 8)
	for z: float in [-2.0, -3.1, -4.2, -5.3]:
		t.cyl(0.11, 0.11, 0.75, Vector3(0.0, 0.33, z), barrel.lightened(0.04), Vector3(PI / 2, 0.0, 0.0), 8)
	t.cyl(0.15, 0.15, 0.45, Vector3(0.0, 0.33, -2.6), barrel, Vector3(PI / 2, 0.0, 0.0), 8)
	# Commander's cupola with Kord MG, gunner's hatch, Sosna-U sight box, snorkel tube.
	t.cyl(0.38, 0.4, 0.2, Vector3(0.55, 0.72, 0.25), g)
	t.box(Vector3(0.14, 0.18, 0.6), Vector3(0.55, 0.9, -0.05), GUN)
	t.cyl(0.025, 0.025, 0.9, Vector3(0.55, 0.92, -0.7), GUN, Vector3(PI / 2, 0.0, 0.0), 5)
	t.cyl(0.32, 0.32, 0.1, Vector3(-0.5, 0.67, 0.3), g.darkened(0.04))
	t.box(Vector3(0.42, 0.38, 0.45), Vector3(-0.48, 0.82, -0.5), g.darkened(0.08))
	t.box(Vector3(0.32, 0.22, 0.03), Vector3(-0.48, 0.84, -0.74), Color(0.08, 0.1, 0.12))
	t.cyl(0.09, 0.09, 1.7, Vector3(0.0, 0.45, 1.25), Color(0.3, 0.32, 0.23), Vector3(0.0, 0.0, PI / 2), 6)
	# Improvised anti-drone cage welded over the turret.
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			t.box(Vector3(0.06, 1.15, 0.06), Vector3(sx * 1.25, 0.95, sz * 1.15 + 0.1), rust)
	for i in 6:
		t.box(Vector3(2.6, 0.05, 0.05), Vector3(0.0, 1.52, -1.05 + i * 0.46), rust)
	for i in 5:
		t.box(Vector3(0.05, 0.05, 2.4), Vector3(-1.25 + i * 0.625, 1.52, 0.1), rust)
	return {"turret_pos": Vector3(0.0, 1.45, 0.25), "muzzle": Vector3(0.0, 0.33, -6.1)}


## BMP-2: sharp wedge nose with ribbed glacis and folded trim vane, front sprocket, low
## two-man turret with long thin 2A42 and the Konkurs launcher on the roof, bulged rear doors.
static func _bmp2(h: Builder, t: Builder) -> Dictionary:
	var g := Color(0.34, 0.38, 0.26)
	var nose := Vector2(-3.37, 0.75)
	var glacis_top := Vector2(-1.65, 1.62)
	h.extrude_x(PackedVector2Array([Vector2(-3.0, 0.42), nose, Vector2(-2.98, 0.95), Vector2(3.33, 0.95), Vector2(3.37, 0.5), Vector2(3.1, 0.42)]), -1.15, 1.15, g)
	h.extrude_x(PackedVector2Array([Vector2(-2.98, 0.95), glacis_top, Vector2(1.1, 1.78), Vector2(3.3, 1.55), Vector2(3.33, 0.95)]), -1.5, 1.5, g)
	var tilt := slope_tilt(nose, glacis_top)
	for i in 6:
		var p := on_slope(nose, glacis_top, 0.3 + i * 0.12, 0.03)
		h.box(Vector3(2.7, 0.05, 0.06), p, g.darkened(0.1), Vector3(tilt, 0.0, 0.0))
	var vane := on_slope(nose, glacis_top, 0.28, 0.07)
	h.box(Vector3(2.6, 0.05, 0.7), vane, g.darkened(0.05), Vector3(tilt, 0.0, 0.0))
	for sx: float in [-1.0, 1.0]:
		h.box(Vector3(0.2, 0.16, 0.16), Vector3(1.1 * sx, 1.05, -2.95), Color(0.75, 0.75, 0.6))
		h.box(Vector3(0.85, 0.85, 0.2), Vector3(0.5 * sx, 0.95, 3.4), g.darkened(0.05))
		h.box(Vector3(0.75, 0.06, 0.85), Vector3(0.62 * sx, 1.74, 1.5), g.darkened(0.08))
		h.box(Vector3(0.75, 0.06, 0.85), Vector3(0.62 * sx, 1.66, 2.5), g.darkened(0.08))
	h.box(Vector3(0.9, 0.04, 0.9), Vector3(0.55, 1.5, -2.0), Color(0.15, 0.15, 0.13), Vector3(tilt * 0.5, 0.0, 0.0))
	h.box(Vector3(0.5, 0.2, 0.5), Vector3(-0.75, 1.6, -1.45), g.darkened(0.06))
	_running_gear(h, {
		"hx": 1.33, "w": 0.3,
		"outline": PackedVector2Array([Vector2(-3.15, 0.65), Vector2(-2.6, 0.03), Vector2(2.75, 0.03), Vector2(3.25, 0.52), Vector2(3.0, 0.9), Vector2(-2.95, 0.92)]),
		"wheels": [-2.2, -1.34, -0.48, 0.38, 1.24, 2.1], "wheel_r": 0.3,
		"idler": [3.0, 0.52, 0.27], "sprocket": [-2.95, 0.65, 0.27],
		"rollers": [-1.3, 0.1, 1.5], "roller_y": 0.86,
	}, g)

	t.loft(blob(0.95, 1.0, 0.95, 8), blob(0.7, 0.7, 0.75, 8), 0.0, 0.5, g)
	t.box(Vector3(0.5, 0.36, 0.38), Vector3(0.0, 0.22, -0.95), g.darkened(0.05))
	t.cyl(0.075, 0.075, 0.9, Vector3(0.0, 0.22, -1.5), GUN, Vector3(PI / 2, 0.0, 0.0), 8)
	t.cyl(0.045, 0.045, 3.0, Vector3(0.0, 0.22, -2.4), GUN, Vector3(PI / 2, 0.0, 0.0), 6)
	t.cyl(0.065, 0.065, 0.22, Vector3(0.0, 0.22, -3.85), GUN, Vector3(PI / 2, 0.0, 0.0), 6)
	t.cyl(0.03, 0.03, 0.5, Vector3(-0.22, 0.2, -1.2), GUN, Vector3(PI / 2, 0.0, 0.0), 5)
	# Konkurs ATGM launch tube on its roof bracket.
	t.box(Vector3(0.12, 0.3, 0.12), Vector3(0.0, 0.62, -0.05), GUN)
	t.cyl(0.085, 0.085, 1.25, Vector3(0.0, 0.82, -0.15), Color(0.3, 0.34, 0.24), Vector3(PI / 2 - 0.08, 0.0, 0.0), 8)
	for sx: float in [-1.0, 1.0]:
		t.cyl(0.26, 0.26, 0.08, Vector3(0.38 * sx, 0.53, 0.15), g.darkened(0.04))
		_smoke_launchers(t, 0.88 * sx, 0.2, 0.35, 3, g.darkened(0.2))
	t.box(Vector3(0.28, 0.24, 0.3), Vector3(-0.42, 0.62, -0.38), g.darkened(0.08))
	return {"turret_pos": Vector3(0.0, 1.7, -0.2), "muzzle": Vector3(0.0, 0.22, -3.95)}


## MT-LB: flat armoured tractor; sloped cab front with two armoured windows, small MG
## turret front right, flat track resting on six wheels with no return rollers.
static func _mtlb(h: Builder, t: Builder) -> Dictionary:
	var g := Color(0.36, 0.39, 0.27)
	var cab_lo := Vector2(-3.2, 0.8)
	var cab_hi := Vector2(-2.45, 1.55)
	h.extrude_x(PackedVector2Array([Vector2(-3.05, 0.42), cab_lo, Vector2(3.2, 0.8), Vector2(3.22, 0.42)]), -1.05, 1.05, g)
	h.extrude_x(PackedVector2Array([cab_lo, cab_hi, Vector2(3.2, 1.55), Vector2(3.22, 0.8)]), -1.43, 1.43, g)
	var tilt := slope_tilt(cab_lo, cab_hi)
	for sx: float in [-1.0, 1.0]:
		var w := on_slope(cab_lo, cab_hi, 0.62, 0.03)
		h.box(Vector3(0.62, 0.04, 0.3), Vector3(0.6 * sx, w.y, w.z), Color(0.08, 0.1, 0.12), Vector3(tilt, 0.0, 0.0))
		var s := on_slope(cab_lo, cab_hi, 0.82, 0.07)
		h.box(Vector3(0.7, 0.05, 0.22), Vector3(0.6 * sx, s.y, s.z), g.darkened(0.08), Vector3(tilt, 0.0, 0.0))
		h.box(Vector3(0.18, 0.14, 0.14), Vector3(1.15 * sx, 0.95, -3.1), Color(0.75, 0.75, 0.6))
		h.box(Vector3(1.0, 0.06, 1.3), Vector3(0.6 * sx, 1.58, 1.7), g.darkened(0.08))
		h.box(Vector3(0.85, 0.75, 0.08), Vector3(0.5 * sx, 1.05, 3.24), g.darkened(0.05))
	h.cyl(0.08, 0.08, 0.9, Vector3(-1.48, 1.15, 0.3), Color(0.2, 0.18, 0.15), Vector3(PI / 2, 0.0, 0.0), 6)
	h.box(Vector3(0.6, 0.06, 0.8), Vector3(-0.6, 1.58, -1.7), g.darkened(0.1))
	_running_gear(h, {
		"hx": 1.25, "w": 0.35,
		"outline": PackedVector2Array([Vector2(-3.15, 0.6), Vector2(-2.6, 0.03), Vector2(2.75, 0.03), Vector2(3.25, 0.45), Vector2(3.05, 0.72), Vector2(-2.95, 0.76)]),
		"wheels": [-2.25, -1.35, -0.45, 0.45, 1.35, 2.25], "wheel_r": 0.32,
		"idler": [3.0, 0.45, 0.25], "sprocket": [-2.95, 0.6, 0.27],
	}, g)
	t.cyl(0.38, 0.42, 0.36, Vector3(0.0, 0.18, 0.0), g, Vector3.ZERO, 10)
	t.ball(0.32, Vector3(0.0, 0.36, 0.0), g, Vector3(1.0, 0.45, 1.0), 10, 4)
	t.box(Vector3(0.16, 0.16, 0.3), Vector3(0.0, 0.2, -0.42), g.darkened(0.08))
	t.cyl(0.025, 0.025, 0.9, Vector3(0.0, 0.2, -0.95), GUN, Vector3(PI / 2, 0.0, 0.0), 5)
	return {"turret_pos": Vector3(0.6, 1.55, -1.95), "muzzle": Vector3(0.0, 0.2, -1.4)}


## M2A2 Bradley: tall slab-sided hull with a long sloped glacis, bolted applique tiles and
## spaced skirts, front sprocket, two-man turret offset right with the twin TOW box on its
## left, 25 mm chain gun, stowage bustle and rear ramp.
static func _bradley(h: Builder, t: Builder) -> Dictionary:
	var g := Color(0.37, 0.39, 0.27)
	var tile := g.lightened(0.05)
	var white := Color(0.9, 0.9, 0.88)
	var glacis_lo := Vector2(-3.27, 0.95)
	var glacis_hi := Vector2(-2.05, 1.98)
	h.extrude_x(PackedVector2Array([Vector2(-3.0, 0.45), glacis_lo, Vector2(3.27, 0.95), Vector2(3.27, 0.45)]), -1.2, 1.2, g)
	h.extrude_x(PackedVector2Array([glacis_lo, glacis_hi, Vector2(3.15, 1.98), Vector2(3.27, 1.8), Vector2(3.27, 0.95)]), -1.58, 1.58, g)
	var tilt := slope_tilt(glacis_lo, glacis_hi)
	var plate := on_slope(glacis_lo, glacis_hi, 0.5, 0.04)
	h.box(Vector3(2.9, 0.06, 1.3), plate, tile, Vector3(tilt, 0.0, 0.0))
	var grille := on_slope(glacis_lo, glacis_hi, 0.85, 0.08)
	h.box(Vector3(0.9, 0.04, 0.35), Vector3(0.75, grille.y, grille.z), Color(0.15, 0.15, 0.13), Vector3(tilt, 0.0, 0.0))
	for sx: float in [-1.0, 1.0]:
		# Applique armour tiles on the hull sides.
		for row in 2:
			for k in 8:
				h.box(Vector3(0.05, 0.4, 0.58), Vector3(1.6 * sx, 1.25 + row * 0.46, -1.95 + k * 0.64), tile.darkened((k + row) % 2 * 0.04))
		h.box(Vector3(0.07, 0.45, 5.9), Vector3(1.64 * sx, 0.76, 0.05), g.darkened(0.08))
		for k in 10:
			h.box(Vector3(0.03, 0.05, 0.05), Vector3(1.68 * sx, 0.92, -2.6 + k * 0.58), g.darkened(0.25))
		# Ukrainian white cross recognition marking.
		h.box(Vector3(0.03, 0.42, 0.1), Vector3(1.69 * sx, 0.76, -1.6), white)
		h.box(Vector3(0.03, 0.1, 0.42), Vector3(1.69 * sx, 0.76, -1.6), white)
		h.box(Vector3(0.25, 0.2, 0.18), Vector3(1.25 * sx, 1.05, -3.2), Color(0.75, 0.75, 0.6))
	h.box(Vector3(1.9, 1.2, 0.1), Vector3(0.0, 1.2, 3.3), g.darkened(0.06))
	_running_gear(h, {
		"hx": 1.3, "w": 0.53,
		"outline": PackedVector2Array([Vector2(-3.2, 0.75), Vector2(-2.65, 0.03), Vector2(2.75, 0.03), Vector2(3.25, 0.55), Vector2(3.0, 1.0), Vector2(-2.95, 1.02)]),
		"wheels": [-2.25, -1.37, -0.49, 0.39, 1.27, 2.15], "wheel_r": 0.31,
		"idler": [2.95, 0.55, 0.3], "sprocket": [-2.95, 0.75, 0.3],
		"rollers": [-1.3, 0.1, 1.5], "roller_y": 0.98,
	}, g)

	var bottom := PackedVector2Array([Vector2(-0.95, -1.1), Vector2(0.95, -1.1), Vector2(1.1, -0.6), Vector2(1.1, 0.9), Vector2(-1.1, 0.9), Vector2(-1.1, -0.6)])
	var top := PackedVector2Array([Vector2(-0.75, -0.75), Vector2(0.75, -0.75), Vector2(0.9, -0.4), Vector2(0.9, 0.75), Vector2(-0.9, 0.75), Vector2(-0.9, -0.4)])
	t.loft(bottom, top, 0.0, 0.78, g)
	for sx: float in [-1.0, 1.0]:
		t.box(Vector3(0.05, 0.5, 1.2), Vector3(1.04 * sx, 0.38, 0.15), tile, Vector3(0.0, 0.0, 0.12 * sx))
		_smoke_launchers(t, 0.85 * sx, 0.45, -0.95, 4, g.darkened(0.2))
	t.box(Vector3(0.34, 0.32, 0.5), Vector3(-0.15, 0.35, -1.25), g.darkened(0.05))
	t.cyl(0.04, 0.04, 2.0, Vector3(-0.15, 0.35, -2.4), GUN, Vector3(PI / 2, 0.0, 0.0), 6)
	t.cyl(0.065, 0.065, 0.22, Vector3(-0.15, 0.35, -3.35), GUN, Vector3(PI / 2, 0.0, 0.0), 6)
	t.box(Vector3(0.36, 0.3, 0.42), Vector3(0.45, 0.9, -0.45), g.darkened(0.08))
	t.box(Vector3(0.28, 0.2, 0.03), Vector3(0.45, 0.92, -0.67), Color(0.08, 0.1, 0.12))
	# Twin TOW launcher box on the turret's left side.
	t.box(Vector3(0.52, 0.46, 1.35), Vector3(-1.38, 0.45, 0.1), g.darkened(0.05))
	for k in 2:
		t.cyl(0.16, 0.16, 0.04, Vector3(-1.38, 0.33 + k * 0.24, -0.58), Color(0.12, 0.12, 0.11), Vector3(PI / 2, 0.0, 0.0), 10)
	t.box(Vector3(2.0, 0.35, 0.55), Vector3(0.0, 0.3, 1.2), g.darkened(0.12))
	for sx: float in [-1.0, 1.0]:
		t.cyl(0.015, 0.015, 2.2, Vector3(0.75 * sx, 1.85, 0.7), GUN, Vector3.ZERO, 4)
	return {"turret_pos": Vector3(0.35, 1.98, -0.35), "muzzle": Vector3(-0.15, 0.35, -3.45)}


# --- Scenery ---

## Variants 0-2 are leafy late-autumn trees, 3 is a shell-shattered stump.
static func tree(variant: int) -> ArrayMesh:
	var key := "tree_%d" % variant
	if _cache.has(key):
		return _cache[key]
	var b := Builder.new()
	var bark := Color(0.27, 0.22, 0.17)
	if variant == 3:
		b.cyl(0.14, 0.22, 1.9, Vector3(0.0, 0.95, 0.0), bark)
		b.cyl(0.05, 0.12, 1.4, Vector3(0.35, 1.9, 0.0), bark, Vector3(0.0, 0.0, -0.7))
		b.cyl(0.04, 0.09, 0.9, Vector3(-0.25, 2.0, 0.1), bark, Vector3(0.3, 0.0, 0.6))
	else:
		var leaves: Array[Color] = [Color(0.40, 0.41, 0.20), Color(0.50, 0.43, 0.19), Color(0.34, 0.37, 0.21)]
		var leaf := leaves[variant]
		b.cyl(0.11, 0.2, 3.2, Vector3(0.0, 1.6, 0.0), bark)
		b.ball(1.5, Vector3(0.0, 3.7, 0.0), leaf, Vector3(1.0, 0.9, 1.0))
		b.ball(1.1, Vector3(0.7, 4.3, 0.3), leaf.lightened(0.06), Vector3.ONE, 5)
		b.ball(1.0, Vector3(-0.6, 3.3, -0.4), leaf.darkened(0.08), Vector3.ONE, 5)
	var mesh := b.build()
	_cache[key] = mesh
	return mesh


static func pole() -> ArrayMesh:
	if _cache.has("pole"):
		return _cache["pole"]
	var b := Builder.new()
	var wood := Color(0.33, 0.27, 0.2)
	b.cyl(0.12, 0.16, 8.0, Vector3(0.0, 4.0, 0.0), wood)
	b.box(Vector3(1.8, 0.12, 0.12), Vector3(0.0, 7.5, 0.0), wood)
	var mesh := b.build()
	_cache["pole"] = mesh
	return mesh


static func sandbags() -> ArrayMesh:
	if _cache.has("sandbags"):
		return _cache["sandbags"]
	var b := Builder.new()
	var bag := Color(0.55, 0.5, 0.38)
	for i in 3:
		b.box(Vector3(0.62, 0.25, 0.4), Vector3(-0.66 + i * 0.66, 0.12, 0.0), bag.darkened(i * 0.04))
	for i in 2:
		b.box(Vector3(0.62, 0.25, 0.4), Vector3(-0.33 + i * 0.66, 0.37, 0.0), bag.darkened(0.06))
	var mesh := b.build()
	_cache["sandbags"] = mesh
	return mesh


static func bush() -> ArrayMesh:
	if _cache.has("bush"):
		return _cache["bush"]
	var b := Builder.new()
	b.ball(0.7, Vector3(0.0, 0.35, 0.0), Color(0.36, 0.37, 0.2), Vector3(1.0, 0.7, 1.0), 5)
	b.ball(0.5, Vector3(0.5, 0.3, 0.2), Color(0.42, 0.38, 0.2), Vector3(1.0, 0.7, 1.0), 5)
	var mesh := b.build()
	_cache["bush"] = mesh
	return mesh


static func crater() -> ArrayMesh:
	if _cache.has("crater"):
		return _cache["crater"]
	var b := Builder.new()
	b.cyl(1.6, 1.6, 0.06, Vector3(0.0, 0.03, 0.0), Color(0.18, 0.15, 0.12), Vector3.ZERO, 8)
	for i in 7:
		var a := i * TAU / 7.0
		b.box(Vector3(0.6, 0.25, 0.4), Vector3(cos(a) * 1.8, 0.1, sin(a) * 1.8), Color(0.33, 0.27, 0.2), Vector3(0.0, -a, 0.0))
	var mesh := b.build()
	_cache["crater"] = mesh
	return mesh


## Quadcopter, drawn double size so it is visible from the camera.
## Recon is a Mavic-ish camera drone; FPV is a racing X-frame with an RPG warhead slung under.
static func drone(fpv: bool) -> ArrayMesh:
	var key := "drone_%s" % fpv
	if _cache.has(key):
		return _cache[key]
	var b := Builder.new()
	b.base = Transform3D(Basis.from_scale(Vector3.ONE * 2.0), Vector3.ZERO)
	if not fpv:
		var body := Color(0.55, 0.56, 0.58)
		b.box(Vector3(0.3, 0.12, 0.4), Vector3.ZERO, body)
		for a: float in [PI / 4, 3 * PI / 4, 5 * PI / 4, 7 * PI / 4]:
			b.box(Vector3(0.5, 0.04, 0.05), Vector3(cos(a) * 0.25, 0.0, sin(a) * 0.25), body, Vector3(0.0, -a, 0.0))
			b.cyl(0.14, 0.14, 0.02, Vector3(cos(a) * 0.45, 0.06, sin(a) * 0.45), Color(0.3, 0.3, 0.3), Vector3.ZERO, 8)
		var mesh := b.build()
		_cache[key] = mesh
		return mesh
	# Flat carbon X-frame: thin centre plate, four slim diagonal arms, motors at the tips
	# and big two-blade props, each box at its own yaw so the discs read as spinning.
	var carbon := Color(0.09, 0.09, 0.1)
	var prop := Color(0.82, 0.5, 0.14)
	b.box(Vector3(0.2, 0.025, 0.3), Vector3.ZERO, carbon)
	b.box(Vector3(0.14, 0.025, 0.2), Vector3(0.0, 0.035, 0.0), carbon.lightened(0.08))
	var spins: Array[float] = [0.3, 1.4, 0.9, 2.0]
	for k in 4:
		var a := PI / 4 + k * PI / 2
		var tip := Vector3(cos(a) * 0.46, 0.0, sin(a) * 0.46)
		b.box(Vector3(0.5, 0.02, 0.045), Vector3(cos(a) * 0.24, 0.0, sin(a) * 0.24), carbon, Vector3(0.0, -a, 0.0))
		b.cyl(0.04, 0.045, 0.07, tip + Vector3(0.0, 0.04, 0.0), Color(0.2, 0.2, 0.22), Vector3.ZERO, 6)
		b.box(Vector3(0.42, 0.01, 0.045), tip + Vector3(0.0, 0.085, 0.0), prop, Vector3(0.0, -a + spins[k], 0.0))
		b.cyl(0.015, 0.015, 0.02, tip + Vector3(0.0, 0.09, 0.0), carbon, Vector3.ZERO, 5)
	# Lipo battery strapped on top, with a yellow strap band.
	b.box(Vector3(0.13, 0.08, 0.24), Vector3(0.0, 0.095, 0.02), Color(0.2, 0.24, 0.3))
	b.box(Vector3(0.14, 0.085, 0.035), Vector3(0.0, 0.095, 0.02), Color(0.9, 0.78, 0.15))
	# Camera pod at the nose, tilted ~30 degrees up for forward flight.
	var cam_tilt := Vector3(0.5, 0.0, 0.0)
	b.box(Vector3(0.09, 0.08, 0.06), Vector3(0.0, 0.045, -0.16), carbon.lightened(0.05), cam_tilt)
	b.box(Vector3(0.035, 0.035, 0.02), Vector3(0.0, 0.064, -0.195), Color(0.1, 0.12, 0.2), cam_tilt)
	# Two whip antennas swept back off the tail.
	for ax: float in [-0.05, 0.05]:
		b.cyl(0.008, 0.008, 0.22, Vector3(ax, 0.1, 0.2), Color(0.85, 0.85, 0.88), Vector3(0.8, 0.0, ax * 4.0), 4)
	# RPG warhead slung underneath, nose forward and slightly down: booster tube,
	# ogive swelling to the bulb, cone to the fuze tip.
	var olive := Color(0.33, 0.36, 0.22)
	var wh := Vector3(PI / 2 - 0.35, 0.0, 0.0)
	var d := Vector3(0.0, -sin(0.35), -cos(0.35))
	var c0 := Vector3(0.0, -0.08, 0.04)
	b.box(Vector3(0.03, 0.07, 0.12), Vector3(0.0, -0.035, 0.03), carbon)
	b.cyl(0.015, 0.015, 0.08, c0 - d * 0.14, olive.darkened(0.12), wh, 6)
	b.cyl(0.03, 0.03, 0.22, c0, olive, wh, 8)
	b.cyl(0.03, 0.065, 0.1, c0 + d * 0.16, olive, wh, 8)
	b.cyl(0.065, 0.012, 0.12, c0 + d * 0.27, olive.darkened(0.06), wh, 8)
	var mesh := b.build()
	_cache[key] = mesh
	return mesh


static func flag_pole() -> ArrayMesh:
	if _cache.has("flag_pole"):
		return _cache["flag_pole"]
	var b := Builder.new()
	b.cyl(0.06, 0.08, 6.0, Vector3(0.0, 3.0, 0.0), Color(0.55, 0.55, 0.52))
	b.box(Vector3(1.0, 0.25, 1.0), Vector3(0.0, 0.12, 0.0), Color(0.55, 0.5, 0.38))
	var mesh := b.build()
	_cache["flag_pole"] = mesh
	return mesh


## One faceted puff of smoke, dust or flame (white; tinted per instance). Unit diameter.
static func puff() -> ArrayMesh:
	if _cache.has("puff"):
		return _cache["puff"]
	var b := Builder.new()
	b.ball(0.5, Vector3.ZERO, Color.WHITE, Vector3.ONE, 8, 5)
	var mesh := b.build()
	_cache["puff"] = mesh
	return mesh


static func grenade() -> ArrayMesh:
	if _cache.has("grenade"):
		return _cache["grenade"]
	var b := Builder.new()
	b.base = Transform3D(Basis.from_scale(Vector3.ONE * 1.6), Vector3.ZERO)
	b.ball(0.05, Vector3.ZERO, Color(0.25, 0.3, 0.2), Vector3(1.0, 1.15, 1.0), 6, 4)
	b.box(Vector3(0.015, 0.07, 0.02), Vector3(0.03, 0.04, 0.0), Color(0.5, 0.5, 0.48))
	b.cyl(0.015, 0.015, 0.03, Vector3(0.0, 0.065, 0.0), Color(0.5, 0.5, 0.48), Vector3.ZERO, 6)
	var mesh := b.build()
	_cache["grenade"] = mesh
	return mesh


static var _blob_mesh: QuadMesh


## Soft dark disc laid on the ground under a soldier: the contact shadow that keeps
## him attached to the terrain. Scaled per man; grows when he lies down.
static func blob_shadow() -> QuadMesh:
	if _blob_mesh == null:
		_blob_mesh = QuadMesh.new()
		_blob_mesh.size = Vector2.ONE
		_blob_mesh.orientation = PlaneMesh.FACE_Y
		var tex := GradientTexture2D.new()
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(0.5, 0.0)
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
		g.colors = PackedColorArray([Color(0, 0, 0, 0.42), Color(0, 0, 0, 0.3), Color(0, 0, 0, 0.0)])
		tex.gradient = g
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_texture = tex
		_blob_mesh.material = m
	return _blob_mesh
