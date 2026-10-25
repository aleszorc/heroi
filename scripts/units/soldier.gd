class_name Soldier
extends Node3D
## One infantryman: a detailed skinned low-poly figure, posed procedurally every frame and
## moved by steering physics (acceleration, arrival, separation, sliding along walls).
##
## Legs, hips, spine and head are posed directly. The weapon is its own bone, carried in a
## blend of poses (low ready, port arms when running, shouldered when aiming, prone, cowering).
## Both arms are then solved with two-bone IK so the right hand holds the pistol grip and the
## left hand the handguard, whatever the body is doing.
##
## His squad sets `want_crouch` / `want_prone` from the cover around him; the body blends
## between running, walking, crouch-walking, crawling, kneeling, lying prone, ducking behind
## cover and rising to fire. Death plays a physics-flavoured fall, and blasts throw the body.
##
## All blends run on exact damped springs (Springs helper) and pose-formula switches are
## inertialized (_inertialize), so motion stays velocity-continuous at any framerate.
##
## BEHAVIOUR STATE MACHINE (`st`, enum ST). Events (die, expire, recover, task and action
## starts) change the underlying facts; `_update_state()` derives the one authoritative
## state from them every animation tick, so it can never desynchronize. Transitions:
##
##   IDLE        -> MOVING          squad feeds him a goal and he picks up speed
##               -> FIRING          target in the engage window (engage_until / just shot)
##               -> RELOADING/THROWING  magazine dry / grenade decision
##               -> DIVING          saw a grenade land (dive())
##               -> HIT_REACT       effective fire arrived (hit_the_dirt())
##               -> COWERING        squad panicked in cover
##               -> RESCUING        assigned a casualty (task "go"/"drag"/"aid")
##               -> HIT_FALLING     struck (die())
##   MOVING      -> IDLE/FIRING/DIVING/HIT_REACT/RESCUING/HIT_FALLING  as above
##   FIRING      -> RELOADING/IDLE/MOVING/HIT_FALLING
##   RELOADING/THROWING/DIVING/HIT_REACT -> back to IDLE/MOVING when the action ends
##   RESCUING    -> IDLE            job done or cancelled (_cancel_task)
##   HIT_FALLING -> DEAD            killed and the body has settled      (terminal)
##               -> WOUNDED         the hit wounded instead of killing
##   WOUNDED     -> BEING_DRAGGED   a comrade grabbed his vest (carried_by set)
##               -> HIT_FALLING     bled out or finished off (expire(): killed)
##   BEING_DRAGGED -> WOUNDED       dropped in cover (carried_by cleared)
##   WOUNDED     -> STABILIZED      first aid finished (stabilized set)
##   STABILIZED  -> GETTING_UP      recover() after Defs.WOUNDED_FIGHT recover_time
##               -> HIT_FALLING     hit again while down
##   GETTING_UP  -> IDLE            on his feet as walking wounded (walking_wounded flag
##                                  then modifies IDLE/MOVING/FIRING: slower, less accurate)

enum B { ROOT, HIPS, SPINE, CHEST, HEAD, UARM_L, FARM_L, HAND_L, UARM_R, FARM_R, HAND_R,
		THIGH_L, SHIN_L, FOOT_L, THIGH_R, SHIN_R, FOOT_R, WEAPON, BASE }

## Behaviour states; see the transition table above.
enum ST { IDLE, MOVING, FIRING, RELOADING, THROWING, DIVING, HIT_REACT, COWERING,
		RESCUING, HIT_FALLING, DEAD, WOUNDED, BEING_DRAGGED, STABILIZED, GETTING_UP }

const BONE_COUNT := 19
const RUN_SPEED := 4.0
const WALK_SPEED := 1.9
const CROUCH_SPEED := 1.2
const CRAWL_SPEED := 0.6

## Weapon carry poses relative to the chest: [position (unscaled), rotation (Euler)].
const W_LOW := [Vector3(0.1, -0.12, -0.26), Vector3(-0.45, 0.15, 0.0)]
const W_PORT := [Vector3(0.02, -0.02, -0.22), Vector3(0.45, 0.75, 0.55)]
const W_AIM := [Vector3(0.12, 0.2, -0.44), Vector3(0.0, 0.0, 0.0)]
const W_AIM_RPG := [Vector3(0.16, 0.1, -0.2), Vector3(0.0, 0.0, 0.0)]
const W_PRONE := [Vector3(0.1, 0.36, 0.13), Vector3(PI / 2, 0.0, 0.0)]
const W_COWER := [Vector3(0.05, -0.18, -0.16), Vector3(-1.2, 0.3, 0.2)]
## Dropped weapon: lying flat beside the body (the chest's Z axis is vertical when he is down).
const W_DEAD := [Vector3(0.5, 0.05, 0.0), Vector3(0.0, PI / 2, 0.0)]
const W_RELOAD := [Vector3(0.05, -0.08, -0.22), Vector3(-0.2, 0.3, 0.6)]
## Relaxed carries, used when no enemy is about. Researched positions: patrol sling
## (muzzle well down on the chest), Sul-style close carry (muzzle at the ground, used
## around teammates), relaxed low carry, and the RPG humped on the shoulder.
const W_PATROL := [Vector3(0.05, -0.2, -0.18), Vector3(-0.95, 0.25, 0.1)]
const W_SUL := [Vector3(0.08, -0.12, -0.2), Vector3(-1.25, 0.05, 0.0)]
const W_CARRY_LOW := [Vector3(0.1, -0.16, -0.24), Vector3(-0.7, 0.2, 0.05)]
const W_RPG_SHOULDER := [Vector3(0.14, 0.32, 0.05), Vector3(0.35, 0.0, 0.0)]
## Magazine: [volleys before a reload, reload seconds].
const MAGS := {"ak": [10, 2.6], "pkm": [10, 6.0], "sniper": [10, 3.0], "rpg": [1, 4.0], "stugna": [1, 6.0]}
## Distance from a dragged man's body origin to the rescuer's feet.
const DRAG_DISTANCE := 1.7
## Gait: the fraction of the stride cycle each foot spends in the air, and when.
const SWING := [Vector2(0.05, 0.45), Vector2(0.55, 0.95)]
## Height of the ankle joint above the ground.
const ANKLE_H := 0.1125
## Half the stance width between the feet.
const FOOT_LATERAL := 0.15

static var _offsets: Array[Vector3] = []

var weapon := ""
## Authoritative behaviour state; derived in _update_state(), read by the squad.
var st := ST.IDLE
var alive := true
var killed := false
var cooldown := 0.0
## Formation slot: x = lateral offset, y = distance back along the leader's trail.
var slot := Vector2.ZERO
var cover_pos := Vector3.ZERO
var vel := Vector3.ZERO
var facing := 0.0
## Yaw he turns to when standing still: his target, or the threat.
var aim_yaw := 0.0
var want_crouch := 0.0
var want_prone := 0.0
## Ducked soldiers hide behind something and must rise before they can shoot.
var ducked := false
var cowering := false
## He wants to fire until this sim time, so he rises from cover.
var engage_until := -99.0
var last_shot := -99.0
var crouch := 0.0
var prone := 0.0
## Fire team (0 or 1) for bounding overwatch.
var team := 0
## Each man reacts to an order with his own small delay and walks at his own pace.
var start_at := 0.0
var pace := 1.0
## Where he waits while his team covers the other one's bound.
var hold_pos := Vector3.ZERO
## His own next cover spot during a bounding rush (INF when none).
var rush_pos := Vector3.INF

## Down but alive: lying wounded, bleeding until stabilized by first aid.
var wounded := false
var bleed := 0.0
var stabilized := false
var rescuer: Soldier = null
var carried_by: Soldier = null
## Back on his feet after treatment: fights on at reduced accuracy and speed
## (Defs.WOUNDED_FIGHT). `wounded` stays true so the debrief still counts him.
var walking_wounded := false
## Seconds lain stabilized; at Defs.WOUNDED_FIGHT recover_time he gets up.
var recover_t := 0.0
## After reacting to effective fire he keeps flat until this sim time.
var stay_low_until := -99.0
## Rescue job: "" (none), "go" (run to the casualty), "drag" (pull him to cover), "aid".
var task := ""
var patient: Soldier = null
var drag_to := Vector3.INF
var task_timer := 0.0
## Short animated actions: "" (none), "throw", "reload", "dive", "react", "getup",
## "hopdown" / "clamber" (crossing a trench lip: quick jump in, slower climb out).
var action := ""
var action_t := 0.0
var action_len := 0.0
var throw_at := Vector3.ZERO
var thrown := false
var grenades := 0
var ammo := 0
## World point he keeps facing whatever way he moves (dragging, first aid). INF = none.
var face_point := Vector3.INF
## World points his hands reach for instead of the weapon (rescue work). Empty = weapon.
var hand_targets: Array[Vector3] = []
## Rifle slung on his back to free both hands.
var slung := false
## Leader hand signal: "" (none), "point" (arm thrust at gesture_point), "halt"
## (raised fist), "rally" (arm circled overhead). Blended onto the right arm.
var gesture := ""
var gesture_t := 0.0
var gesture_len := 0.0
var gesture_point := Vector3.INF
## Effects hook for footstep dust; set by the squad.
var fx: Fx = null
## Weapon handling. The squad sets `alert` when enemies are known nearby; each man has
## his own relaxed carry style and ready angles, so no two hold the rifle alike.
var alert := false
var carry_style := 0
var _relax := 1.0
var _carry_rot := Vector3.ZERO
var _fidget_timer := 0.0
var _fidget := 0.0
var _sway_seed := randf() * 100.0

var _side := 0
var _variant := 0
var _points: Dictionary
var _skel: Skeleton3D
var _mesh: MeshInstance3D
var _phase := 0.0
var _recoil := 0.0
var _q: Array[Quaternion] = []
var _root_pos := Vector3.ZERO
var _w_pos := Vector3.ZERO
var _muzzle_sk := Vector3(0.0, 1.5, -0.8)
var _death_q: Array[Quaternion] = []
var _death_root := Vector3.ZERO
var _death_w := Vector3.ZERO
var _dead_t := 0.0
var _face_down := true
var _splay := 0.0
var _toss := Vector3.ZERO
var _toss_y := 0.0
var _toss_vy := 0.0
var _settled := false
## Death variety: each man gets his own randomized rest pose, fall speed, a yaw spin
## while falling, and (for blast throws) a limp tumble that blends out on landing.
var _dead_pose: Array[Quaternion] = []
var _fall_rate := 1.8
var _spin := 0.0
var _tumble_axis := Vector3.RIGHT
var _tumble_rate := 0.0
var _tumble_phase := 0.0
## Getting up as walking wounded: blend from the captured lying pose to the live pose.
var _recover_q: Array[Quaternion] = []
var _recover_root := Vector3.ZERO
var _recover_blend := 1.0
var _seed := randf() * TAU
var _clock := 0.0
var _turn_rate := 0.0
var _accel := 0.0
var _last_speed := 0.0
var _aim_blend := 0.0
## Spring-smoothed blends (Springs.Flt carries velocity, so stance, aim and relax
## changes accelerate in and ease out instead of moving linearly and stopping dead).
var _crouch_sp := Springs.Flt.new()
var _prone_sp := Springs.Flt.new()
var _aim_sp := Springs.Flt.new()
var _relax_sp := Springs.Flt.new(1.0)
## Root dip on hard stops and vault landings: a spring kicked by deceleration.
var _dip_sp := Springs.Flt.new()
## Staged torso pitch of the prone transition (chest down last, up first); the weapon
## and arm poles follow this rather than raw `prone` so the hands brace realistically.
var _prone_vis := 0.0
## Weapon pose lag: the carried weapon chases its target pose on a short spring, so
## carry changes flow into each other and turns drag the muzzle a hair behind.
var _w_sp_pos := Springs.Vec.new()
var _w_sp_rot := Springs.Quat.new()
var _w_sp_init := false
## Inertialization: when the pose formula switches discontinuously (an action starts or
## ends, hands leave the weapon, the leg rig changes mode) the visible pose carries on
## from where it was and the captured per-bone offset decays to zero on a spring.
var _off_rot := PackedVector3Array()
var _off_vel := PackedVector3Array()
var _off_root := Vector3.ZERO
var _off_root_v := Vector3.ZERO
var _off_w := Vector3.ZERO
var _off_w_v := Vector3.ZERO
var _inert_t := 0.0
var _pose_sig := ""
var _sig_ready := false
var _legs_mode := 0
## Last frame's visible pose, as actually applied to the skeleton.
var _last_q: Array[Quaternion] = []
var _last_root := Vector3.ZERO
var _last_w := Vector3.ZERO
var _blob: MeshInstance3D
var _push := Vector3.ZERO
var _hand_r_sk := Vector3(0.25, 1.4, -0.3)
## Foot planting (world space): where each foot is nailed down, which foot is swinging,
## and the little repositioning step taken while standing. 0 = left, 1 = right.
var _plant: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _plant_yaw: Array[float] = [0.0, 0.0]
var _swing_from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _swing_yaw0: Array[float] = [0.0, 0.0]
var _swinging: Array[bool] = [false, false]
var _feet_ready := false
var _idle_step := -1
var _idle_t := 0.0
var _step_len := 0.7
## Trench-lip vault: scripted start and landing points while "hopdown"/"clamber" runs.
var _vault_from := Vector3.ZERO
var _vault_to := Vector3.ZERO


func setup(side: int, weapon_id: String) -> void:
	_side = side
	weapon = weapon_id
	_variant = randi() % 4
	_points = MeshFactory.weapon_points(weapon_id)
	if _offsets.is_empty():
		for i in BONE_COUNT:
			_offsets.append(MeshFactory.soldier_bone_offset(i))
	_skel = Skeleton3D.new()
	add_child(_skel)
	var bones: Array = MeshFactory.SOLDIER_BONES
	for i in BONE_COUNT:
		_skel.add_bone(String(bones[i][0]))
	for i in BONE_COUNT:
		var parent: int = bones[i][1]
		if parent >= 0:
			_skel.set_bone_parent(i, parent)
		_skel.set_bone_rest(i, Transform3D(Basis.IDENTITY, _offsets[i]))
	_skel.reset_bone_poses()
	_mesh = MeshInstance3D.new()
	_mesh.mesh = MeshFactory.soldier(side, weapon_id, false, _variant)
	_skel.add_child(_mesh)
	_mesh.skeleton = NodePath("..")
	_mesh.skin = MeshFactory.soldier_skin(_skel)
	_q.resize(BONE_COUNT)
	_q.fill(Quaternion.IDENTITY)
	_off_rot.resize(BONE_COUNT)
	_off_vel.resize(BONE_COUNT)
	_last_q.resize(BONE_COUNT)
	_last_q.fill(Quaternion.IDENTITY)
	_blob = MeshInstance3D.new()
	_blob.mesh = MeshFactory.blob_shadow()
	_blob.top_level = true
	add_child(_blob)
	var mag: Array = MAGS.get(weapon_id, [10, 2.6])
	ammo = mag[0]
	grenades = 2 if weapon_id == "ak" else 0
	match weapon_id:
		"pkm":
			carry_style = 0
		"rpg":
			carry_style = 3
		"sniper":
			carry_style = randi() % 2
		_:
			carry_style = randi() % 3
	_carry_rot = Vector3(randf_range(-0.07, 0.07), randf_range(-0.09, 0.09), randf_range(-0.05, 0.05))
	_fidget_timer = randf_range(4.0, 14.0)


# --- Queries ---

## Share of his body offered to a shooter: crouching and lying down shrink it.
func exposure() -> float:
	return (1.0 - 0.3 * crouch) * (1.0 - 0.5 * prone)


func center() -> Vector3:
	var h := lerpf(lerpf(1.1, 0.75, crouch), 0.25, prone)
	return position + Vector3.UP * h


## Muzzle of his weapon in world space, from the last solved pose.
func muzzle() -> Vector3:
	return global_transform * _muzzle_sk


## Up and steady enough to shoot. Ducked men must rise out of cover first.
func can_fire() -> bool:
	if not alive or cowering or action != "" or task != "":
		return false
	if prone > 0.15 and prone < 0.85:
		return false
	if ducked and crouch > 0.65:
		return false
	return Vector2(vel.x, vel.z).length() < 2.5


## Top speed allowed by his current stance; getting up from prone takes a moment.
## Walking wounded hobble at a fraction of it (Defs.WOUNDED_FIGHT).
func speed_cap() -> float:
	var cap := RUN_SPEED * 1.15
	if want_crouch > 0.5:
		cap = CROUCH_SPEED * 1.3
	cap = lerpf(cap, CRAWL_SPEED * 1.3, prone)
	if want_prone < 0.5 and prone > 0.05:
		cap *= 1.0 - prone
	if walking_wounded:
		cap *= float(Defs.WOUNDED_FIGHT["speed"])
	return cap


func snap_stance() -> void:
	crouch = want_crouch
	prone = want_prone
	_crouch_sp.set_to(want_crouch)
	_prone_sp.set_to(want_prone)


## Forgets the planted feet (teleports, deployment); they replant where he stands.
func reset_gait() -> void:
	_feet_ready = false
	_idle_step = -1


func fired(sim_time: float) -> void:
	last_shot = sim_time
	_recoil = 1.0
	ammo -= 1
	if ammo <= 0:
		_start_action("reload", float(MAGS.get(weapon, [10, 2.6])[1]))


func busy() -> bool:
	return task != "" or action != ""


func _start_action(kind: String, length: float) -> void:
	action = kind
	action_t = 0.0
	action_len = length


func start_throw(at: Vector3) -> void:
	_start_action("throw", 1.0)
	throw_at = at
	thrown = false
	grenades -= 1


## Throws himself flat away from a grenade.
func dive(away: Vector3) -> void:
	if not alive or task != "":
		return
	_start_action("dive", 0.9)
	away.y = 0.0
	vel = away.normalized() * 4.5
	facing = atan2(-away.x, -away.z)
	rotation.y = facing
	want_prone = 1.0


## Snap reaction to effective fire (ST.HIT_REACT): lunges to the nearest micro-cover
## (or simply away from the threat) and drops flat, facing the threat to return fire.
## Men already flat, busy, or standing in hard cover (trench, building, wall) skip it.
func hit_the_dirt(threat_pos: Vector3, map: BattleMap, sim_time: float) -> void:
	if not alive or busy() or prone > 0.6:
		return
	var t := map.type_at(position)
	if t == BattleMap.T.TRENCH or t == BattleMap.T.BUILDING or map.shield_at(position, threat_pos) >= 0.45:
		return
	var spot := map.best_cover_near(position, 1, {}, threat_pos)
	var to := Vector3(spot.x - position.x, 0.0, spot.z - position.z)
	var dir: Vector3
	if to.length() > 0.4 and to.length() < 2.6:
		dir = to.normalized()
	else:
		dir = Vector3(position.x - threat_pos.x, 0.0, position.z - threat_pos.z).normalized() \
				if _flat_len(position, threat_pos) > 0.5 else Vector3(randf_range(-1, 1), 0.0, randf_range(-1, 1)).normalized()
	_start_action("react", 0.55)
	vel = dir * 3.5
	want_prone = 1.0
	aim_yaw = atan2(-(threat_pos.x - position.x), -(threat_pos.z - position.z))
	facing = aim_yaw
	rotation.y = facing
	stay_low_until = sim_time + float(Defs.REACT["stay_low"])


static func _flat_len(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Plays a brief leader hand signal, blended onto the right arm (see `gesture`).
func signal_gesture(kind: String, point: Vector3, length := 1.3) -> void:
	if not alive or cowering or prone > 0.3 or task != "":
		return
	gesture = kind
	gesture_t = 0.0
	gesture_len = length
	gesture_point = point


## A stabilized casualty gets back up and rejoins the fight as walking wounded
## (ST.GETTING_UP -> IDLE with the walking_wounded flag).
func recover() -> void:
	if alive or not wounded or not stabilized or killed:
		return
	alive = true
	walking_wounded = true
	carried_by = null
	rescuer = null
	recover_t = 0.0
	_settled = false
	# Blend from however he lies now to the live pose over the get-up action.
	_recover_q = _q.duplicate()
	_recover_root = _root_pos
	_recover_blend = 0.0
	_inert_t = 0.0
	_sig_ready = false
	_w_sp_init = false
	prone = 1.0
	want_prone = 0.0
	want_crouch = 0.5
	cover_pos = position
	vel = Vector3.ZERO
	reset_gait()
	_start_action("getup", 1.4)


## Derives `st` from the authoritative facts. Called every animation tick; the
## transition table lives in the class header.
func _update_state(sim_time: float) -> void:
	if not alive:
		if killed:
			st = ST.DEAD if _settled else ST.HIT_FALLING
		elif _dead_t < 1.0:
			st = ST.HIT_FALLING
		elif carried_by != null:
			st = ST.BEING_DRAGGED
		elif stabilized:
			st = ST.STABILIZED
		else:
			st = ST.WOUNDED
		return
	match action:
		"reload":
			st = ST.RELOADING
			return
		"throw":
			st = ST.THROWING
			return
		"dive":
			st = ST.DIVING
			return
		"react":
			st = ST.HIT_REACT
			return
		"getup":
			st = ST.GETTING_UP
			return
	if cowering:
		st = ST.COWERING
	elif task != "":
		st = ST.RESCUING
	elif sim_time < engage_until or sim_time - last_shot < 1.5:
		st = ST.FIRING
	elif Vector2(vel.x, vel.z).length() > 0.4:
		st = ST.MOVING
	else:
		st = ST.IDLE


## Right hand in world space (where a grenade leaves from).
func hand_point() -> Vector3:
	return global_transform * _hand_r_sk


## Crossing a trench lip (called from steer): scripts a short move from the lip to a
## landing point just past it, as a quick hop down into the cut or a slower clamber
## out over the revetment. Steering is suspended while it plays; the man cannot fire.
func _start_vault(np: Vector3, map: BattleMap) -> void:
	var down := map.type_at(np) == BattleMap.T.TRENCH
	var dir := Vector3(np.x - position.x, 0.0, np.z - position.z).normalized()
	_vault_from = position
	var land := np + dir * 0.55
	_vault_to = Vector3(land.x, map.height_at(land), land.z)
	vel = dir * (1.4 if down else 0.5)
	_start_action("hopdown" if down else "clamber", 0.45 if down else 0.85)


func _tick_action(dt: float) -> void:
	if action == "":
		return
	action_t += dt
	if action_t >= action_len:
		if action == "reload":
			ammo = int(MAGS.get(weapon, [10, 2.6])[0])
		elif action == "hopdown" or action == "clamber":
			# Landed on the far side of the lip: replant the feet where he stands,
			# knees taking the landing with a springy dip.
			position = _vault_to
			vel = Vector3.ZERO
			reset_gait()
			_dip_sp.v += 1.3 if action == "hopdown" else 0.6
		action = ""


# --- Physics ---

## Steers towards goal with limited acceleration. `push` keeps him apart from others.
## `feed` is the squad's own velocity: a man in formation moves with it and only gently
## corrects towards his place, which keeps the file flowing instead of surging and halting.
func steer(dt: float, goal: Vector3, max_speed: float, push: Vector3, map: BattleMap, feed := Vector3.ZERO) -> void:
	if dt <= 0.0:
		return
	if action == "dive" or action == "react":
		# Thrown flat: momentum only, sliding to a stop. Never through a wall.
		vel *= exp(-2.5 * dt)
		var dp := position + vel * dt
		if map.infantry_step_open(position, dp):
			position = Vector3(dp.x, map.height_at(dp), dp.z)
		return
	if action == "hopdown" or action == "clamber":
		# Crossing a trench lip: the body is scripted from lip to landing.
		var vt := clampf(action_t / maxf(action_len, 0.001), 0.0, 1.0)
		var ve := vt * vt * (3.0 - 2.0 * vt)
		var vp := _vault_from.lerp(_vault_to, ve)
		if action == "hopdown":
			# Steps off and drops: late fall with a shallow arc off the lip.
			vp.y = lerpf(_vault_from.y, _vault_to.y, ve * ve) + sin(PI * ve) * 0.25
		else:
			# Mantles up the revetment first, then steps out over the berm.
			vp.y = lerpf(_vault_from.y, _vault_to.y, minf(1.0, ve * 1.3))
		position = vp
		return
	if action == "getup":
		# Rising to his feet: rooted until he is up.
		vel = Vector3.ZERO
		return
	var to := Vector3(goal.x - position.x, 0.0, goal.z - position.z)
	var d := to.length()
	var desired := Vector3.ZERO
	if feed.length() > 0.05:
		desired = feed + to * 0.9
	elif d > 0.15:
		# Arrive: ease off over the last couple of metres instead of stopping dead.
		desired = to / d * minf(max_speed, d * 1.2)
	# Spacing pushes are smoothed so neighbours drift apart rather than jostle.
	_push = _push.lerp(push, Springs.alpha(0.17, dt))
	desired += _push
	max_speed *= pace
	if desired.length() > max_speed:
		desired = desired.normalized() * max_speed
	var accel := 2.0 + max_speed * 1.1
	vel = vel.move_toward(desired, accel * dt)
	if map.is_climb_at(position) and vel.length() > RUN_SPEED * 0.4:
		# Clambering through a window or over a chipped wall: slow going.
		vel = vel.normalized() * RUN_SPEED * 0.4
	var step := vel * dt
	var np := position + step
	if not map.infantry_step_open(position, np):
		# Slide along walls rather than stopping; an intact wall cell is never
		# crossed — the only ways in are doors, breaches and window climbs.
		var nx := position + Vector3(step.x, 0.0, 0.0)
		var nz := position + Vector3(0.0, 0.0, step.z)
		if map.infantry_step_open(position, nx):
			np = nx
			vel.z = 0.0
		elif map.infantry_step_open(position, nz):
			np = nz
			vel.x = 0.0
		else:
			np = position
			vel = Vector3.ZERO
	# Nobody walks off the battlefield, whatever the steering wants.
	np.x = clampf(np.x, -BattleMap.HALF + 0.6, BattleMap.HALF - 0.6)
	np.z = clampf(np.z, -BattleMap.HALF + 0.6, BattleMap.HALF - 0.6)
	if (map.type_at(np) == BattleMap.T.TRENCH) != (map.type_at(position) == BattleMap.T.TRENCH) \
			and Vector2(np.x - position.x, np.z - position.z).length() > 0.001:
		# Stepping over a trench lip: a quick hop down, or a slower clamber out.
		# Moving along the trench floor stays ordinary walking.
		_start_vault(np, map)
		return
	position = Vector3(np.x, map.height_at(np), np.z)
	var speed := Vector2(vel.x, vel.z).length()
	_accel = lerpf(_accel, (speed - _last_speed) / dt, Springs.alpha(0.12, dt))
	_last_speed = speed
	var want := aim_yaw
	if face_point != Vector3.INF:
		want = atan2(-(face_point.x - position.x), -(face_point.z - position.z))
	elif speed > 0.4:
		want = atan2(-vel.x, -vel.z)
	# Turn like a body, not a turret: eased and rate-limited, slower when lying down.
	var max_turn := lerpf(5.0, 1.5, prone) * dt
	var diff := wrapf(want - facing, -PI, PI)
	var turn := clampf(diff * Springs.alpha(0.09, dt), -max_turn, max_turn)
	_turn_rate = lerpf(_turn_rate, turn / dt, Springs.alpha(0.09, dt))
	facing += turn
	rotation.y = facing


## Struck down: killed, or wounded and left bleeding (ST.HIT_FALLING). `knock` is the
## impulse from the incoming shot or blast and `up_speed` throws the body ballistically;
## each fall gets its own randomized rest pose, fall speed, yaw spin and (airborne) tumble.
func die(knock: Vector3, up_speed: float, is_wounded := false) -> void:
	if not alive:
		return
	alive = false
	wounded = is_wounded
	killed = not is_wounded
	stabilized = false
	walking_wounded = false
	recover_t = 0.0
	bleed = float(Defs.WOUNDED_FIGHT["bleed_time"])
	action = ""
	task = ""
	gesture = ""
	face_point = Vector3.INF
	hand_targets.clear()
	slung = false
	_recover_blend = 1.0
	_inert_t = 0.0
	_sig_ready = false
	_death_q = _q.duplicate()
	_death_root = _root_pos
	_death_w = _w_pos
	# The wounded end up on their backs, where comrades can grab them.
	_face_down = randf() < 0.5 and not is_wounded
	_splay = randf_range(-0.3, 0.3)
	_toss = knock
	_toss_vy = up_speed
	_dead_t = 0.0
	_settled = false
	vel = Vector3.ZERO
	# Crumples fold fast on the spot; knocked-back falls are slower and travel.
	_fall_rate = randf_range(1.4, 2.6)
	_spin = randf_range(-1.6, 1.6) * (0.4 if is_wounded else 1.0)
	if up_speed > 1.0:
		# Blast throw: limp tumble around a random horizontal axis while airborne.
		var a := randf() * TAU
		_tumble_axis = Vector3(cos(a), 0.0, sin(a))
		_tumble_rate = randf_range(4.0, 10.0) * (-1.0 if randf() < 0.5 else 1.0)
		_spin = randf_range(-4.0, 4.0)
	else:
		_tumble_rate = 0.0
	_tumble_phase = 0.0
	_make_dead_pose()
	if knock.length() > 0.5:
		facing = atan2(-knock.x, -knock.z) + (0.0 if _face_down else PI)
		rotation.y = facing
	if not is_wounded:
		_mesh.mesh = MeshFactory.soldier(_side, weapon, true, _variant)


## Builds this man's own rest pose: the base sprawl with every limb angle jittered,
## so no two bodies settle alike.
func _make_dead_pose() -> void:
	var dir := 1.0 if _face_down else -1.0
	var p: Array[Quaternion] = []
	p.resize(BONE_COUNT)
	p.fill(Quaternion.IDENTITY)
	var j := func(v: float) -> float: return v * randf_range(0.55, 1.5)
	p[B.ROOT] = _qe(-PI * 0.5 * dir, 0.0, _splay * 0.3)
	p[B.SPINE] = _qe(j.call(0.05), 0.0, _splay * 0.2)
	p[B.CHEST] = _qe(j.call(0.05), 0.0, _splay * 0.2)
	# Limbs splay sideways in the ground plane so they lie flat whichever way he fell.
	p[B.HEAD] = _qe(0.15 * dir, 0.0, j.call(0.5) + _splay)
	p[B.THIGH_L] = _qe(randf_range(-0.1, 0.35), 0.0, j.call(-0.3) + _splay * 0.3)
	p[B.SHIN_L] = _qe(randf_range(-0.5, 0.0), 0.0, j.call(0.15))
	p[B.THIGH_R] = _qe(randf_range(-0.1, 0.35), 0.0, j.call(0.25))
	p[B.SHIN_R] = _qe(randf_range(-0.5, 0.0), 0.0, j.call(-0.1))
	p[B.FOOT_L] = _qe(-0.8 * dir, 0.0, 0.0)
	p[B.FOOT_R] = _qe(-0.8 * dir, 0.0, 0.0)
	p[B.UARM_L] = _qe(randf_range(-0.3, 1.2), 0.0, j.call(-1.3) - _splay)
	p[B.FARM_L] = _qe(randf_range(0.0, 0.6), 0.0, j.call(-0.5))
	p[B.UARM_R] = _qe(randf_range(-0.3, 1.2), 0.0, j.call(0.9))
	p[B.FARM_R] = _qe(randf_range(0.0, 0.6), 0.0, j.call(0.6))
	var wd := _pose_t(W_DEAD)
	p[B.WEAPON] = Quaternion(wd.basis.orthonormalized())
	_dead_pose = p


## A wounded man dies: bled out, or hit again.
func expire() -> void:
	if not wounded:
		return
	wounded = false
	killed = true
	carried_by = null
	_settled = false
	_mesh.mesh = MeshFactory.soldier(_side, weapon, true, _variant)


# --- Animation ---

## Advances and applies the pose. dt is simulation time, so pausing freezes him.
func animate(dt: float, sim_time: float, map: BattleMap) -> void:
	_update_state(sim_time)
	# Contact shadow rides the ground under him, wider when he is down.
	var flat := prone if alive else 1.0
	_blob.global_position = Vector3(position.x, map.height_at(position) + 0.03, position.z)
	_blob.scale = Vector3.ONE * (0.85 + 0.8 * flat)
	if not alive:
		_animate_dead(dt, map)
		return
	_tick_action(dt)
	if gesture != "":
		gesture_t += dt
		if gesture_t >= gesture_len or prone > 0.3 or cowering:
			gesture = ""
	# Stances blend on critically damped springs: going flat is urgent (and urgent-er
	# when diving), getting back up is deliberate.
	var p_hl := (0.07 if action == "dive" or action == "react" else 0.18) if want_prone > prone else 0.32
	prone = clampf(_prone_sp.track(want_prone, p_hl, dt), 0.0, 1.0)
	crouch = clampf(_crouch_sp.track(want_crouch, 0.12, dt), 0.0, 1.0)
	if action == "hopdown" or action == "clamber":
		# Knees bend over the lip: a dip into the hop, a low pull over the climb.
		var vp := clampf(action_t / maxf(action_len, 0.001), 0.0, 1.0)
		crouch = maxf(crouch, sin(PI * vp) * (0.55 if action == "hopdown" else 0.8))
	var speed := Vector2(vel.x, vel.z).length()
	# Step length grows with speed; the cadence then follows the distance actually
	# covered, so the feet and the ground never disagree. Walking wounded limp short.
	_step_len = clampf(0.5 + speed * 0.27, 0.55, 1.35) * (1.0 - 0.3 * crouch) * (1.0 - 0.5 * prone)
	if walking_wounded:
		_step_len *= 0.78
	if speed > 0.15:
		_phase = fmod(_phase + speed * dt / (2.0 * _step_len) * TAU, TAU)
	# Recoil decays exponentially: a hard kick with a soft tail, no kink at the end.
	_recoil *= exp(-dt * 6.0)
	_clock += dt
	var aiming := sim_time - last_shot < 1.5 or sim_time < engage_until
	_aim_blend = clampf(_aim_sp.track(1.0 if aiming else 0.0, 0.1, dt), 0.0, 1.0)
	var want_relax := 0.0 if alert or aiming or cowering or prone > 0.3 else 1.0
	# Snapping alert is quick; easing back into a relaxed carry takes its time.
	_relax = clampf(_relax_sp.track(want_relax, 0.12 if want_relax < _relax else 0.45, dt), 0.0, 1.0)
	# Now and then a relaxed man shifts his grip and checks the weapon.
	if _relax > 0.7 and action == "" and task == "":
		_fidget_timer -= dt
		if _fidget_timer <= 0.0:
			_fidget_timer = randf_range(8.0, 22.0)
			_fidget = 1.0
	_fidget = maxf(0.0, _fidget - dt / 1.3)
	_body_pose(speed, dt, map)
	_hands_on_weapon(speed, dt)
	if _recover_blend < 1.0:
		# Getting up: ease from the captured lying pose into the live one.
		_recover_blend = minf(1.0, _recover_blend + dt / 1.2)
		var e := _recover_blend * _recover_blend * (3.0 - 2.0 * _recover_blend)
		for i in BONE_COUNT:
			_q[i] = _recover_q[i].slerp(_q[i], e)
		_root_pos = _recover_root.lerp(_root_pos, e)
	_inertialize(dt)
	_apply()


## Hides the seams where the pose formula switches (actions starting and ending, hands
## leaving the weapon for rescue work, cowering, slinging, the leg rig changing mode):
## on a switch the gap between last frame's visible pose and the new computed pose is
## captured per bone and decays to zero on a spring, so the body carries on from where
## it was instead of popping. _q holds the visible pose after this, which is also what
## die() and recover() capture for their own blends.
func _inertialize(dt: float) -> void:
	# want_prone is in the signature because the transition stages differ by direction:
	# reversing mid-transition switches curve sets, and the capture hides that step.
	var sig := "%s|%d|%d|%d|%d|%d" % [action, _legs_mode, int(cowering), int(slung), int(hand_targets.is_empty()), int(want_prone > 0.5)]
	if not _sig_ready:
		_sig_ready = true
		_pose_sig = sig
		return
	if sig != _pose_sig:
		_pose_sig = sig
		for i in BONE_COUNT:
			_off_rot[i] = Springs.q_to_sav(_last_q[i] * _q[i].inverse())
		_off_root = _last_root - _root_pos
		_off_w = _last_w - _w_pos
		_inert_t = 0.7
	if _inert_t <= 0.0:
		return
	_inert_t -= dt
	var y := Springs.damping(0.12) * 0.5
	var e := exp(-y * dt)
	for i in BONE_COUNT:
		var o := _off_rot[i]
		var ov := _off_vel[i]
		var j1 := ov + o * y
		o = e * (o + j1 * dt)
		ov = e * (ov - j1 * y * dt)
		_off_rot[i] = o
		_off_vel[i] = ov
		_q[i] = Springs.q_from_sav(o) * _q[i]
	var j1r := _off_root_v + _off_root * y
	_off_root = e * (_off_root + j1r * dt)
	_off_root_v = e * (_off_root_v - j1r * y * dt)
	_root_pos += _off_root
	var j1w := _off_w_v + _off_w * y
	_off_w = e * (_off_w + j1w * dt)
	_off_w_v = e * (_off_w_v - j1w * y * dt)
	_w_pos += _off_w


static func _qe(x: float, y: float, z: float) -> Quaternion:
	return Quaternion.from_euler(Vector3(x, y, z))


## Torso, head and root from stance and gait; legs by mode: prone, crawling and kneeling
## keep scripted poses, everything upright stands on IK-planted feet.
func _body_pose(speed: float, dt: float, map: BattleMap) -> void:
	var moving := minf(1.0, speed * 2.0)
	var run := clampf((speed - 1.6) / 2.4, 0.0, 1.0)
	var sw := sin(_phase)
	var still := 1.0 - moving
	var p := prone
	# Going down or getting up passes through a crouch.
	var transit := 1.0 - absf(2.0 * p - 1.0) if p > 0.02 and p < 0.98 else 0.0
	var c := maxf(crouch, transit) * (1.0 - p)
	# The prone transition is staged like a real one. Down: sink through a kneel, legs
	# slide back, chest lowers last. Up: push-up (chest arches off the ground), knees
	# drawn forward under the body, hips rising through all-fours and kneel heights,
	# torso un-pitching gradually the whole way. `sink` is the hips' own height curve:
	# the root is DERIVED from it further down, so pitching can never fling the body.
	var rising := want_prone < 0.5
	var sink := smoothstep(0.05, 0.75, p) if rising else smoothstep(0.2, 0.75, p)
	var legs_back := smoothstep(0.55, 0.95, p) if rising else smoothstep(0.3, 0.8, p)
	var pitch := smoothstep(0.1, 0.9, p) if rising else smoothstep(0.45, 0.97, p)
	_prone_vis = pitch

	var hips_yaw := sw * (0.1 + 0.06 * run) * moving * (1.0 - p)
	var spine := -0.06 * moving - 0.22 * run
	spine += sin(_clock * 1.7 + _seed) * 0.02 * still
	var sway := sin(_clock * 0.4 + _seed) * 0.03 * still
	spine -= c * lerpf(0.4, 0.12, still)
	spine += _recoil * 0.06
	var look := sin(_clock * 0.55 + _seed) * 0.55 * (1.0 - _aim_blend) * (1.0 - 0.6 * run)
	var head := -spine * 0.7 - 0.12 * _aim_blend
	if cowering:
		spine -= 0.5 * (1.0 - p)
		head -= 0.4
		look = 0.0
	var lean_side := -clampf(_turn_rate * speed * 0.05, -0.28, 0.28) * (1.0 - p)
	var lean_fwd := -clampf(_accel, -4.0, 4.0) * 0.025 * (1.0 - p)
	# Hard stops and vault landings sink the body on a spring; it dips, catches
	# itself, and rises back — the knees visibly taking the weight.
	var dip := clampf(_dip_sp.track(clampf(-_accel * 0.03, 0.0, 0.12), 0.1, dt), -0.04, 0.2) * (1.0 - p)
	if walking_wounded:
		# A limp: the body dips and rolls onto the good leg once per stride,
		# shoulders hunched over the wound.
		lean_side += maxf(0.0, sw) * 0.12 * moving * (1.0 - p)
		spine -= 0.1 * (1.0 - p)
	var cl := sw * moving

	# The pelvis rolls with each pull of the crawl; the torso pitch follows the staged
	# `pitch`, so the chest is the last thing down and the first thing up.
	_q[B.ROOT] = _qe(-PI * 0.5 * pitch + lean_fwd, 0.08 * cl * p, lean_side + sway)
	# Hips roll onto the stance leg; the chest counter-rolls and the head stays level
	# against the body's lean, the way a walking body actually stacks itself.
	_q[B.HIPS] = _qe(0.0, hips_yaw, cl * (0.04 * (1.0 - p) + 0.1 * p))
	var sp := lerpf(spine, 0.2, pitch)
	if rising:
		# Push-up arch: on the way up the chest leads, back extended off the ground.
		sp -= 0.45 * sin(PI * smoothstep(0.45, 1.0, p))
	_q[B.SPINE] = _qe(sp * 0.5, -hips_yaw * 0.6, 0.0)
	_q[B.CHEST] = _qe(sp * 0.5, -hips_yaw * 0.7 + 0.15 * _aim_blend * (1.0 - p), -cl * 0.05 * (1.0 - p))
	_q[B.HEAD] = _qe(lerpf(head, 0.9, pitch), look - 0.15 * _aim_blend * (1.0 - p), -(lean_side + sway) * 0.55 * (1.0 - p))
	_q[B.BASE] = Quaternion.IDENTITY

	if p > 0.02 or (c > 0.6 and speed < 0.25):
		_legs_mode = 0
		var bob0 := -(1.0 - cos(2.0 * _phase)) * 0.025 * moving
		# A crawl is not a glide: the body surges forward with each pull and almost
		# stops between, lifting slightly onto the elbows as it pulls.
		var surge := sin(2.0 * _phase) * 0.045 * moving * p
		var lift := (1.0 - cos(2.0 * _phase)) * 0.015 * moving * p
		# The hips are the anchor of the transition, pivoting over the knees: their
		# height runs flat -> all-fours -> kneel -> stand on `sink`, their forward
		# position comes home on the same curve, and the root is derived by removing
		# the pitched hip offset. (Moving the root directly levers the body up around
		# the feet like a drawbridge — the "jumping up" look.)
		var hr := _offsets[B.HIPS].y
		var pr := PI * 0.5 * pitch
		var hips_y := lerpf(hr + bob0 - c * lerpf(0.32, 0.5, still), 0.22 + lift, sink)
		var hips_z := (0.95 - hr) * sink + surge
		_root_pos = Vector3(0.0, hips_y - hr * cos(pr) - dip, hips_z + hr * sin(pr))
		# While the hips are low with the legs no longer back (all-fours, kneel) the
		# legs must fold completely — knees under him — or the shins stab the ground.
		var ck := maxf(c, minf(1.0, sink * (1.0 - legs_back) * 1.2))
		_legs_scripted(legs_back, ck, still, moving, run)
		_feet_ready = false
	else:
		_legs_mode = 1
		# The body sinks a little as each foot passes under it, rides lower at a
		# crouch, and shifts its weight over the stance foot.
		var bob := -(1.0 - cos(2.0 * _phase)) * 0.028 * moving * (1.0 + 0.6 * run)
		_root_pos = Vector3(sin(_phase) * 0.035 * moving, bob - 0.05 - crouch * 0.33 - dip, 0.0)
		_legs_ik(speed, run, dt, map)


## Prone, crawling, kneeling and the transitions between them.
func _legs_scripted(p: float, c: float, still: float, moving: float, run: float) -> void:
	var sw := sin(_phase)
	var cs := cos(_phase)
	var cl := sw * moving
	var amp := (0.35 + 0.45 * run) * moving
	var knee := (0.25 + 0.9 * run) * moving
	var tl := sw * amp + c * lerpf(0.75, 1.45, still)
	var sl := -knee * maxf(0.0, cs) + c * lerpf(-1.1, -1.55, still)
	var tr := -sw * amp + c * lerpf(0.75, 0.25, still)
	var sr := -knee * maxf(0.0, -cs) + c * lerpf(-1.1, -1.9, still)
	var fl := 0.25 * maxf(0.0, -sw) * moving
	var fr := 0.25 * maxf(0.0, sw) * moving + c * still * 0.9
	_q[B.THIGH_L] = _qe(lerpf(tl, 0.05, p), 0.0, p * (-0.12 - 0.5 * maxf(0.0, cl)))
	_q[B.SHIN_L] = _qe(lerpf(sl, -0.1, p), 0.0, p * 0.9 * maxf(0.0, cl))
	_q[B.FOOT_L] = _qe(lerpf(fl, -0.6, p), 0.0, 0.0)
	_q[B.THIGH_R] = _qe(lerpf(tr, 0.05, p), 0.0, p * (0.12 + 0.5 * maxf(0.0, -cl)))
	_q[B.SHIN_R] = _qe(lerpf(sr, -0.1, p), 0.0, -p * 0.9 * maxf(0.0, -cl))
	_q[B.FOOT_R] = _qe(lerpf(fr, -0.6, p), 0.0, 0.0)


## Where foot f rests under the body: a stance-width apart, on the ground.
func _rest_spot(f: int, map: BattleMap) -> Vector3:
	var right := Vector3(cos(facing), 0.0, -sin(facing))
	var p := position + right * FOOT_LATERAL * (-1.0 if f == 0 else 1.0)
	p.y = map.height_at(p) + ANKLE_H
	return p


## Where a swinging foot will land: ahead of its rest spot along the travel direction.
func _swing_target(f: int, dir: Vector3, run: float, map: BattleMap) -> Vector3:
	var p := _rest_spot(f, map) + dir * _step_len * (0.45 + 0.1 * run)
	p.y = map.height_at(p) + ANKLE_H
	return p


## Each foot is a world point nailed to the ground through its stance half of the cycle
## and stepped to a predicted landing in its swing half; two-bone IK bends the knee to
## reach it. Feet cannot slide, and knees bend exactly as much as the step demands.
func _legs_ik(speed: float, run: float, dt: float, map: BattleMap) -> void:
	var moving := speed > 0.15
	if not _feet_ready:
		_feet_ready = true
		_idle_step = -1
		for f in 2:
			_plant[f] = _rest_spot(f, map)
			_plant_yaw[f] = facing
			_swinging[f] = false
	var cyc := fposmod(_phase / TAU, 1.0)
	var dir := Vector3(vel.x, 0.0, vel.z) / speed if speed > 0.3 else Vector3(-sin(facing), 0.0, -cos(facing))
	var foot: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var fyaw: Array[float] = [0.0, 0.0]
	var fpitch: Array[float] = [0.0, 0.0]
	for f in 2:
		var w: Vector2 = SWING[f]
		var in_window := cyc >= w.x and cyc < w.y
		if moving:
			_idle_step = -1
			if in_window and not _swinging[f]:
				_swinging[f] = true
				_swing_from[f] = _plant[f]
				_swing_yaw0[f] = _plant_yaw[f]
		if _swinging[f] and (not in_window or not moving):
			# Heel strike: down, and nailed there until its next turn.
			_swinging[f] = false
			_plant[f] = _swing_target(f, dir, run, map)
			_plant_yaw[f] = facing
			if fx != null and speed > 2.0 and randf() < 0.6:
				fx.step_dust(_plant[f])
		if _swinging[f]:
			var t := clampf((cyc - w.x) / (w.y - w.x), 0.0, 1.0)
			var e := t * t * (3.0 - 2.0 * t)
			var target := _swing_target(f, dir, run, map)
			var pos := _swing_from[f].lerp(target, e)
			pos.y += sin(PI * t) * (0.06 + 0.09 * run + speed * 0.015)
			foot[f] = pos
			fyaw[f] = lerp_angle(_swing_yaw0[f], facing, e)
			fpitch[f] = lerpf(0.45, -0.25, e) * minf(1.0, speed)
		else:
			var pl := _plant[f]
			pl.y = map.height_at(pl) + ANKLE_H
			_plant[f] = pl
			foot[f] = pl
			fyaw[f] = _plant_yaw[f]
	if not moving:
		_idle_feet(dt, map, foot, fyaw)
	var inv := global_transform.affine_inverse()
	var hips_t := Transform3D(Basis(_q[B.ROOT]), _root_pos) * Transform3D(Basis(_q[B.HIPS]), _offsets[B.HIPS])
	for f in 2:
		var tgt: Vector3 = inv * foot[f]
		var fb: Basis = inv.basis * (Basis(Vector3.UP, fyaw[f]) * Basis(Vector3.RIGHT, fpitch[f]))
		var pole := Vector3(-0.12 if f == 0 else 0.12, -0.4, -1.0)
		_solve_limb([B.THIGH_L, B.THIGH_R][f], hips_t, tgt, pole, fb)


## Standing still: a foot left behind or twisted by a turn takes one small step home.
## One foot at a time, so turning in place reads as a shuffle, not a pivot.
func _idle_feet(dt: float, map: BattleMap, foot: Array[Vector3], fyaw: Array[float]) -> void:
	if _idle_step < 0:
		var worst := -1
		var worst_d := 0.26
		for f in 2:
			var rest := _rest_spot(f, map)
			var d := Vector2(_plant[f].x - rest.x, _plant[f].z - rest.z).length() \
					+ absf(wrapf(facing - _plant_yaw[f], -PI, PI)) * 0.35
			if d > worst_d:
				worst_d = d
				worst = f
		if worst >= 0:
			_idle_step = worst
			_idle_t = 0.0
			_swing_from[worst] = _plant[worst]
			_swing_yaw0[worst] = _plant_yaw[worst]
	if _idle_step >= 0:
		var f := _idle_step
		_idle_t += dt / 0.26
		var t := minf(_idle_t, 1.0)
		var e := t * t * (3.0 - 2.0 * t)
		var target := _rest_spot(f, map)
		var pos := _swing_from[f].lerp(target, e)
		pos.y += sin(PI * t) * 0.05
		foot[f] = pos
		fyaw[f] = lerp_angle(_swing_yaw0[f], facing, e)
		if t >= 1.0:
			_plant[f] = target
			_plant_yaw[f] = facing
			_idle_step = -1


static func _pose_t(pose: Array) -> Transform3D:
	var pos: Vector3 = pose[0]
	var rot: Vector3 = pose[1]
	return Transform3D(Basis.from_euler(rot), pos * MeshFactory.SOLDIER_SCALE)


static func _lerp_t(a: Transform3D, b: Transform3D, w: float) -> Transform3D:
	var q := Quaternion(a.basis.orthonormalized()).slerp(Quaternion(b.basis.orthonormalized()), w)
	return Transform3D(Basis(q), a.origin.lerp(b.origin, w))


## Chest transform in skeleton space, from the root down the spine.
func _chest_t() -> Transform3D:
	var t := Transform3D(Basis(_q[B.ROOT]), _root_pos)
	t = t * Transform3D(Basis(_q[B.HIPS]), _offsets[B.HIPS])
	t = t * Transform3D(Basis(_q[B.SPINE]), _offsets[B.SPINE])
	return t * Transform3D(Basis(_q[B.CHEST]), _offsets[B.CHEST])


## Places the weapon for his stance, then bends both arms onto it.
func _hands_on_weapon(speed: float, dt: float) -> void:
	# (relax state advanced in animate; this reads _relax, _fidget and carry_style)
	var run := clampf((speed - 1.6) / 2.4, 0.0, 1.0)
	var w := _pose_t(W_LOW)
	# Personal ready angles, then the man's own relaxed carry when nothing is about.
	w.basis = w.basis * Basis.from_euler(_carry_rot)
	var relax_pose: Transform3D
	match carry_style:
		1:
			relax_pose = _pose_t(W_PATROL)
		2:
			relax_pose = _pose_t(W_SUL)
		3:
			relax_pose = _pose_t(W_RPG_SHOULDER)
		_:
			relax_pose = _pose_t(W_CARRY_LOW)
	relax_pose.basis = relax_pose.basis * Basis.from_euler(_carry_rot * 1.5)
	w = _lerp_t(w, relax_pose, _relax * (1.0 - run))
	w = _lerp_t(w, _pose_t(W_PORT), run * (1.0 - _aim_blend))
	w = _lerp_t(w, _pose_t(W_AIM_RPG if weapon == "rpg" else W_AIM), _aim_blend)
	w = _lerp_t(w, _pose_t(W_PRONE), _prone_vis)
	if cowering:
		w = _pose_t(W_COWER)
	if slung:
		# Rifle across the back, muzzle up over the left shoulder.
		w = Transform3D(Basis.looking_at(Vector3(-0.6, 0.8, 0.0).normalized(), Vector3.BACK), Vector3(0.0, 0.0, 0.22) * MeshFactory.SOLDIER_SCALE)
	var phase := action_t / maxf(action_len, 0.001)
	if action == "reload":
		w = _lerp_t(w, _pose_t(W_RELOAD), sin(PI * clampf(phase * 1.2, 0.0, 1.0)))
	# Recoil kicks the weapon back into the shoulder and the muzzle up.
	w.origin += w.basis.z * 0.05 * _recoil
	w.basis = w.basis * Basis(Vector3.RIGHT, 0.08 * _recoil)
	if prone > 0.5 and speed > 0.2:
		# Crawl cradle: the rifle works forward in pulses, riding the alternating
		# elbows and rolling with the pelvis, so the arms visibly do the crawling.
		var pull := maxf(0.0, sin(2.0 * _phase))
		w.origin += Vector3(sin(_phase) * 0.025, (1.0 - cos(2.0 * _phase)) * 0.02, -pull * 0.05)
		w.basis = w.basis * Basis(Vector3.BACK, sin(_phase) * 0.1)
	# The weapon is never frozen: slow personal sway, a bounce with the stride, and
	# the occasional grip-shift dipping the muzzle while the hand checks the magazine.
	var steady := 1.0 - _aim_blend * 0.75
	var moving01 := minf(1.0, speed)
	w.origin += Vector3(sin(_clock * 0.9 + _sway_seed), sin(_clock * 1.4 + _sway_seed * 1.7), sin(_clock * 0.7 + _sway_seed * 2.3)) * (0.008 + 0.016 * _relax) * steady
	w.origin += Vector3(0.0, sin(2.0 * _phase) * 0.018 * moving01, 0.0)
	w.basis = w.basis * Basis(Vector3.RIGHT, sin(_clock * 1.1 + _sway_seed) * 0.035 * steady)
	var fidget_amp := sin(PI * clampf(1.0 - _fidget, 0.0, 1.0)) if _fidget > 0.0 else 0.0
	w.basis = w.basis * Basis(Vector3.RIGHT, -0.22 * fidget_amp)
	# FPS-style weapon lag: turning drags the muzzle a hair behind the body's yaw,
	# accelerating eases the weapon back towards the chest, and the whole carried pose
	# chases its target on a short spring — so carry changes flow instead of switching.
	w.basis = w.basis.rotated(Vector3.UP, -clampf(_turn_rate * 0.045, -0.1, 0.1) * steady)
	w.origin.z += clampf(_accel * 0.005, -0.025, 0.025) * steady
	if dt > 0.0:
		if not _w_sp_init:
			_w_sp_init = true
			_w_sp_pos.set_to(w.origin)
			_w_sp_rot.set_to(Quaternion(w.basis.orthonormalized()))
		w.origin = _w_sp_pos.track(w.origin, 0.05, dt)
		w.basis = Basis(_w_sp_rot.track(Quaternion(w.basis.orthonormalized()), 0.05, dt))
	_q[B.WEAPON] = Quaternion(w.basis.orthonormalized())
	_w_pos = w.origin
	var chest := _chest_t()
	var wt := chest * w
	var s := MeshFactory.SOLDIER_SCALE
	_muzzle_sk = wt * (Vector3(_points["muzzle"]) * s)
	var p := _prone_vis
	var pole_r := Vector3(0.7, -0.6, 0.4).lerp(Vector3(0.6, 0.0, -1.0), p)
	var pole_l := Vector3(-0.5, -0.8, 0.0).lerp(Vector3(-0.6, 0.0, -1.0), p)
	if not hand_targets.is_empty():
		var inv := global_transform.affine_inverse()
		var wobble := Vector3(0.0, sin(_clock * 6.0) * 0.03, 0.0) if task == "aid" else Vector3.ZERO
		_solve_limb(B.UARM_R, chest, inv * hand_targets[0] + wobble, Vector3(0.7, -0.4, 0.3), chest.basis)
		_solve_limb(B.UARM_L, chest, inv * hand_targets[hand_targets.size() - 1] - wobble, Vector3(-0.7, -0.4, 0.3), chest.basis)
		return
	if cowering:
		# Hands clamped over the helmet.
		var top := chest.basis
		_solve_limb(B.UARM_R, chest, chest * (Vector3(0.1, 0.42, -0.05) * s), Vector3(0.8, 0.2, 0.0), top)
		_solve_limb(B.UARM_L, chest, chest * (Vector3(-0.1, 0.42, -0.05) * s), Vector3(-0.8, 0.2, 0.0), top)
		return
	var grip := wt * (Vector3(_points["grip"]) * s)
	var fore := wt * (Vector3(_points["fore"]) * s)
	if fidget_amp > 0.0:
		# Support hand slides back to the magazine well during the grip-shift.
		fore = fore.lerp(wt * (Vector3(0.0, -0.07, -0.06) * s), fidget_amp)
	if action == "throw":
		# Wind up behind the head, whip forward, follow through.
		var back := chest * (Vector3(0.22, 0.38, 0.28) * s)
		var front := chest * (Vector3(0.12, 0.3, -0.5) * s)
		grip = back.lerp(front, smoothstep(0.35, 0.6, phase)) if phase < 0.8 else front.lerp(grip, (phase - 0.8) / 0.2)
	elif action == "reload":
		# Support hand: off the magazine, down to the vest pouch, back with a fresh one.
		var pouch := chest * (Vector3(-0.08, -0.12, -0.2) * s)
		var well := wt * (Vector3(0.0, -0.08, -0.1) * s)
		fore = well.lerp(pouch, sin(PI * clampf((phase - 0.2) / 0.5, 0.0, 1.0)))
	_hand_r_sk = grip
	_solve_limb(B.UARM_R, chest, grip, pole_r, wt.basis)
	_solve_limb(B.UARM_L, chest, fore, pole_l, wt.basis)
	# Patrol-sling men take the support hand off entirely: the free arm hangs and
	# swings with the stride, the sling notionally bearing the weight.
	if carry_style == 1 and action == "" and weapon == "ak":
		var free := _relax * (1.0 - _aim_blend) * (1.0 - prone) * (1.0 - run)
		if free > 0.01:
			var sw := sin(_phase)
			var fwd := -sw * 0.45 * moving01
			var qa := _qe(fwd + 0.06, 0.0, 0.12)
			var qf := _qe(0.3 + maxf(0.0, fwd) * 0.35, 0.0, 0.0)
			_q[B.UARM_L] = _q[B.UARM_L].slerp(qa, free)
			_q[B.FARM_L] = _q[B.FARM_L].slerp(qf, free)
			_q[B.HAND_L] = _q[B.HAND_L].slerp(Quaternion.IDENTITY, free)
	if gesture != "":
		_gesture_arm(chest, s)


## Leader hand signals: re-solves the right arm towards the gesture pose, blended in
## and out over 0.25 s so the hand leaves the grip and returns smoothly.
func _gesture_arm(chest: Transform3D, s: float) -> void:
	var gb := minf(minf(gesture_t / 0.25, (gesture_len - gesture_t) / 0.25), 1.0)
	gb = clampf(gb, 0.0, 1.0)
	if gb <= 0.01:
		return
	gb = gb * gb * (3.0 - 2.0 * gb)
	var target: Vector3
	match gesture:
		"point":
			# Arm thrust straight out at shoulder height towards the point.
			var dir := gesture_point - global_position
			dir.y = 0.0
			dir = dir.normalized() if dir.length() > 0.3 else Vector3(-sin(facing), 0.0, -cos(facing))
			target = global_transform.affine_inverse() * (global_position + dir * 0.78 + Vector3.UP * 1.5)
		"halt":
			# Fist raised straight overhead.
			target = chest * (Vector3(0.14, 0.52, 0.04) * s)
		_:
			# Rally: the arm circles overhead.
			var a := gesture_t * 6.5
			target = chest * (Vector3(0.05 + sin(a) * 0.2, 0.52, cos(a) * 0.2 - 0.04) * s)
	var blended := _hand_r_sk.lerp(target, gb)
	_solve_limb(B.UARM_R, chest, blended, Vector3(0.9, 0.1, 0.1), chest.basis)


## Two-bone IK for any limb chain (upper, upper+1, upper+2): rotates the upper and lower
## segments so the end joint reaches target, bending towards pole (parent space), and
## turns the end bone to match hand_basis. Serves arms onto the weapon and legs onto feet.
func _solve_limb(upper: int, chest: Transform3D, target: Vector3, pole_local: Vector3, hand_basis: Basis) -> void:
	var fore := upper + 1
	var hand := upper + 2
	var a := _offsets[fore].length()
	var b := _offsets[hand].length()
	var shoulder := chest * _offsets[upper]
	var to := target - shoulder
	var d := clampf(to.length(), 0.02, a + b - 0.001)
	var dir := to.normalized() if to.length() > 0.001 else Vector3.DOWN
	var x := (a * a + d * d - b * b) / (2.0 * d)
	var h := sqrt(maxf(0.0, a * a - x * x))
	var cb := chest.basis.orthonormalized()
	var pole := cb * pole_local
	var pp := pole - dir * pole.dot(dir)
	if pp.length() < 0.001:
		pp = cb * Vector3.BACK
	pp = pp.normalized()
	var elbow := shoulder + dir * x + pp * h
	var hand_pos := shoulder + dir * d
	var u_local := (cb.inverse() * (elbow - shoulder)).normalized()
	var q_up := _arc(Vector3.DOWN, u_local)
	var up_basis := cb * Basis(q_up)
	var f_local := (up_basis.inverse() * (hand_pos - elbow)).normalized()
	var q_fore := _arc(Vector3.DOWN, f_local)
	var fore_basis := up_basis * Basis(q_fore)
	_q[upper] = q_up
	_q[fore] = q_fore
	_q[hand] = Quaternion((fore_basis.inverse() * hand_basis.orthonormalized()).orthonormalized())


## Shortest rotation from one direction to another, safe for opposite vectors.
static func _arc(from: Vector3, to: Vector3) -> Quaternion:
	if from.dot(to) < -0.999:
		return Quaternion(Vector3.RIGHT, PI)
	return Quaternion(from, to)


func _animate_dead(dt: float, map: BattleMap) -> void:
	if _settled and not wounded:
		return
	_clock += dt
	_dead_t = minf(1.0, _dead_t + dt * _fall_rate)
	# Thrown bodies fly a short ballistic arc, tumbling limply, then skid to a stop.
	_toss_vy -= 9.8 * dt
	_toss_y = maxf(0.0, _toss_y + _toss_vy * dt)
	if _toss_y <= 0.0 and _toss_vy < 0.0:
		_toss_vy = 0.0
	_toss *= exp(-(2.0 if _toss_y > 0.0 else 7.0) * dt)
	if carried_by == null:
		var np := position + _toss * dt
		if map.infantry_step_open(position, np):
			position = np
	position.y = map.height_at(position)
	# The yaw spin from the hit twists the body while it is still falling or flying.
	var falling := _dead_t < 1.0 or _toss_y > 0.0
	if falling and carried_by == null:
		facing += _spin * dt
		rotation.y = facing
	if _tumble_rate != 0.0:
		_tumble_phase += _tumble_rate * dt

	var dir := 1.0 if _face_down else -1.0
	if _dead_pose.is_empty():
		_make_dead_pose()
	var dead := _dead_pose.duplicate()
	if wounded:
		# Alive and hurting: a knee drawn up, a hand pressed to the wound, head rolling.
		var w := sin(_clock * 1.3 + _seed)
		dead[B.THIGH_R] = _qe(0.7 + 0.25 * w, 0.0, 0.15)
		dead[B.SHIN_R] = _qe(-1.3 - 0.2 * w, 0.0, 0.0)
		dead[B.UARM_R] = _qe(0.5, 0.0, 0.3)
		dead[B.FARM_R] = _qe(1.6 + 0.2 * w, 0.0, 0.0)
		dead[B.HEAD] = _qe(-0.1, 0.4 * sin(_clock * 0.7 + _seed), 0.0)
		if carried_by != null:
			# Hauled by the vest: arms trail up past the head.
			dead[B.UARM_L] = _qe(2.8, 0.0, -0.25)
			dead[B.UARM_R] = _qe(2.8, 0.0, 0.25)
			dead[B.FARM_L] = Quaternion.IDENTITY
			dead[B.FARM_R] = Quaternion.IDENTITY
	# The blast tumble rolls the whole body around a horizontal axis while airborne;
	# its weight fades out through the last half metre so the body settles flat.
	var tumble_w := clampf(_toss_y * 2.0, 0.0, 1.0)
	if tumble_w > 0.001:
		var tq := Quaternion(_tumble_axis, _tumble_phase)
		dead[B.ROOT] = Quaternion.IDENTITY.slerp(tq, tumble_w) * dead[B.ROOT]
	var wd := _pose_t(W_DEAD)
	var dead_root := Vector3(0.0, 0.2 + _toss_y, 0.9 * dir)
	var e := 1.0 - pow(1.0 - _dead_t, 2.0)
	for i in BONE_COUNT:
		_q[i] = _death_q[i].slerp(dead[i], e)
	_root_pos = _death_root.lerp(dead_root, e)
	_w_pos = _death_w.lerp(wd.origin, e)
	_apply()
	if _dead_t >= 1.0 and _toss_y <= 0.0 and _toss.length() < 0.05:
		_settled = true


func _apply() -> void:
	for i in BONE_COUNT:
		_skel.set_bone_pose_rotation(i, _q[i])
		_last_q[i] = _q[i]
	_skel.set_bone_pose_position(B.ROOT, _root_pos)
	_skel.set_bone_pose_position(B.WEAPON, _w_pos)
	_last_root = _root_pos
	_last_w = _w_pos
