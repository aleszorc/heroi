class_name Springs
## Exact damped springs for procedural animation, after Daniel Holden's "Spring Roll
## Call" (theorangeduck.com/page/spring-roll-call). Every update is closed-form, so the
## result is identical at any framerate and under `fast` 4x time; dt = 0 is a no-op.
##
## The one tuning knob is `halflife`: seconds for the remaining distance to the goal to
## halve (settled to the eye in ~4 halflives). Unlike lerp/move_toward smoothing, the
## springs carry velocity, so a change of goal accelerates in and eases out with no
## kink — the difference between robotic and fluid blends.

const LN2 := 0.69314718056


## Exact damper: the fraction of the way to the goal covered in dt.
## `x = lerpf(x, goal, Springs.alpha(halflife, dt))` replaces `lerpf(x, goal, dt * k)`.
static func alpha(halflife: float, dt: float) -> float:
	return 1.0 - exp(-LN2 * dt / (halflife + 1e-5))


static func damping(halflife: float) -> float:
	return (4.0 * LN2) / (halflife + 1e-5)


## Quaternion -> scaled angle-axis (log map), picking the shortest arc.
static func q_to_sav(q: Quaternion) -> Vector3:
	var qq := q if q.w >= 0.0 else -q
	var im := Vector3(qq.x, qq.y, qq.z)
	var l := im.length()
	if l < 1e-6:
		return im * 2.0
	return im * (2.0 * atan2(l, qq.w) / l)


## Scaled angle-axis -> quaternion (exp map).
static func q_from_sav(v: Vector3) -> Quaternion:
	var a := v.length()
	if a < 1e-6:
		return Quaternion(v.x * 0.5, v.y * 0.5, v.z * 0.5, 1.0).normalized()
	var s := sin(a * 0.5) / a
	return Quaternion(v.x * s, v.y * s, v.z * s, cos(a * 0.5))


## Critically damped spring on a scalar: tracks a moving goal as fast as possible
## without overshoot.
class Flt:
	var x := 0.0
	var v := 0.0

	func _init(x0 := 0.0) -> void:
		x = x0

	func set_to(val: float) -> void:
		x = val
		v = 0.0

	func track(goal: float, halflife: float, dt: float) -> float:
		var y := 2.0 * 0.69314718056 / (halflife + 1e-5)
		var j0 := x - goal
		var j1 := v + j0 * y
		var e := exp(-y * dt)
		x = e * (j0 + j1 * dt) + goal
		v = e * (v - j1 * y * dt)
		return x


## Critically damped spring on a Vector3.
class Vec:
	var x := Vector3.ZERO
	var v := Vector3.ZERO

	func set_to(val: Vector3) -> void:
		x = val
		v = Vector3.ZERO

	func track(goal: Vector3, halflife: float, dt: float) -> Vector3:
		var y := 2.0 * 0.69314718056 / (halflife + 1e-5)
		var j0 := x - goal
		var j1 := v + j0 * y
		var e := exp(-y * dt)
		x = e * (j0 + j1 * dt) + goal
		v = e * (v - j1 * y * dt)
		return x


## Critically damped spring on a rotation: the offset from the goal decays to identity,
## carried by an angular velocity, so snapping the goal never snaps the output.
class Quat:
	var q := Quaternion.IDENTITY
	var v := Vector3.ZERO

	func set_to(val: Quaternion) -> void:
		q = val
		v = Vector3.ZERO

	func track(goal: Quaternion, halflife: float, dt: float) -> Quaternion:
		var y := 2.0 * 0.69314718056 / (halflife + 1e-5)
		var j0 := Springs.q_to_sav(q * goal.inverse())
		var j1 := v + j0 * y
		var e := exp(-y * dt)
		q = Springs.q_from_sav(e * (j0 + j1 * dt)) * goal
		v = e * (v - j1 * y * dt)
		return q
