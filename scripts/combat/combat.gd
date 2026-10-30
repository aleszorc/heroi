class_name Combat
extends RefCounted
## Resolves aimed shots and area fire. Effects land after the projectile's flight time.

## Below this visibility a shooter has no line of sight.
const MIN_VIS := 0.15


## Fires one volley at a unit. Returns false (nothing fired) when there is no line of sight.
static func fire(b: Battle, shooter: Unit, from: Vector3, wid: String, target: Unit, acc_mod: float) -> bool:
	var w: Dictionary = Defs.WEAPONS[wid]
	var aim := target.aim_point()
	var vis := b.map.los(from, aim)
	if vis < MIN_VIS:
		return false
	var d := from.distance_to(aim)
	var range_f := clampf(1.0 - pow(d / float(w["range"]), 2.0) * 0.75, 0.1, 1.0)
	var p := float(w["acc"]) * acc_mod * range_f * (0.4 + 0.6 * vis)
	# Cover as the target sees this shooter: ground cover faces the threat the unit took
	# it against, so fire from the flank or rear of a trench or wood edge bites harder.
	var cov := 0.0
	if target.is_vehicle:
		p = minf(0.95, p * 1.8)
	else:
		cov = b.map.cover_from(aim, from, target.cover_front())
		p *= pow(1.0 - cov, float(Defs.COVER["hit_power"])) * target.exposure_at(aim)
		if not target.arrived and target.pace == Unit.Pace.RUN:
			p *= 1.15
	# Badly aimed fire (a pinned or moving shooter, extreme range) suppresses less too.
	var supp_mod := (1.0 - float(Defs.SUPPRESSION["shooter_state"]) * (1.0 - clampf(acc_mod, 0.0, 1.0))) \
			* (1.0 - float(Defs.SUPPRESSION["range"]) * (1.0 - range_f))
	var hit := randf() < p
	var impact := aim
	# Shells aimed at men inside a house mostly strike the wall in front of them.
	var wall := aim
	if float(w["blast"]) > 0.0 and not target.is_vehicle and randf() < 0.7:
		wall = b.map.wall_entry(from, aim)
	if wall != aim:
		impact = wall
		hit = false
	elif not hit:
		var miss := (1.0 + d * 0.02) * (float(Defs.COVER["blast_miss"]) if float(w["blast"]) > 0.0 else 1.0)
		impact += Vector3(randf_range(-miss, miss), randf_range(-0.8, 0.3), randf_range(-miss, miss))
		impact.y = maxf(impact.y, b.map.height_at(impact) + 0.1)
	b.fx.shot(from, impact, w, wid)
	b.sfx.shot(from, wid)
	b.schedule(d / float(w["speed"]), func() -> void: _impact(b, shooter, w, target, impact, hit, from, cov, supp_mod))
	return true


static func _impact(b: Battle, shooter: Unit, w: Dictionary, target: Unit, pos: Vector3, hit: bool, src: Vector3, cov: float, supp_mod: float) -> void:
	var blast: float = w["blast"]
	var supp: float = w["supp"]
	var pen: float = w["pen"]
	if blast > 0.0:
		b.fx.explosion(pos, blast * 0.45)
	if target.is_targetable():
		target.receive_suppression(supp * supp_mod * (1.0 - cov * float(Defs.SUPPRESSION["impact_cover"])))
		if hit:
			if target.is_vehicle:
				if pen > 0.0:
					target.take_penetration(pen, src, false, shooter)
				else:
					target.take_hit(pos, shooter)
			elif blast <= 0.0:
				target.take_hit(pos, shooter)
	if blast > 0.0:
		var st: Array = w.get("struct", [0.0, 0.0])
		b.blast(pos, blast, 0.75, supp * 0.5, 0.0, false, st[0], st[1], "blast:%s" % String(w["name"]))
	else:
		b.sfx.bullet_crack(pos)
		b.suppress_area(pos, 5.0, supp * 0.35, target, shooter.side)
