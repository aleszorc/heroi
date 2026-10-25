class_name InputController
extends Node
## Turns touches (and mouse and keys on desktop) into selection, orders and camera moves.
##
## Tap a friendly unit to select it. With a unit selected: tap ground to move, double-tap
## to move fast, tap a spotted enemy to fire. Hold a unit to open its command menu.
## Order buttons and menu entries arm a mode for the next tap. Defend and Ambush show a
## facing ring around the unit: drag or tap to set the direction it guards.

const TAP_SLOP := 14.0
## A hold that began on a friendly unit tolerates this much finger drift before it
## turns into a camera pan; menus survive shaky thumbs and trackpads.
const HOLD_SLOP := 30.0
const DOUBLE_TAP_TIME := 0.35
const LONG_PRESS := 0.45
const RING_RADIUS := 12.0
const MODE_COLORS := {"move": Color(0.5, 1.0, 0.5), "fast": Color(1.0, 0.9, 0.3), "sneak": Color(0.4, 0.9, 1.0)}
const GUARD_COLORS := {"defend": Color(0.45, 0.85, 1.0), "ambush": Color(0.85, 0.5, 1.0)}
const UNIT_MODES := ["move", "fast", "sneak", "fire", "smoke", "defend", "ambush"]

var battle: Battle
var cam: CameraRig
var hud: Hud
var selected: Unit = null
## Armed order for the next tap: "", move, fast, sneak, fire, smoke, defend, ambush,
## mortar, recon, fpv.
var mode := ""

var _touches := {}
var _start_pos := Vector2.ZERO
var _start_time := 0.0
## Seconds the current single press has been held, in frame time (pause-safe).
var _hold_time := 0.0
var _hold_on_unit := false
var _dragging := false
var _multi := false
var _long_done := false
var _pinch_dist := 0.0
var _last_tap_time := -10.0
var _last_tap_pos := Vector2.ZERO
## Facing being chosen for Defend / Ambush, previewed on the ring.
var _orient_dir := Vector3.ZERO
var _imesh := ImmediateMesh.new()


func _ready() -> void:
	var lines := MeshInstance3D.new()
	lines.mesh = _imesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lines.material_override = mat
	battle.add_child(lines)


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _orienting() -> bool:
	return mode == "defend" or mode == "ambush"


const MOUSE_ID := 900


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		if e.pressed:
			_press_begin(e.index, e.position)
		else:
			_press_end(e.index, e.position)
	elif event is InputEventScreenDrag:
		var e := event as InputEventScreenDrag
		_drag_update(e.index, e.position, e.relative)
	elif event is InputEventMouseButton:
		# The mouse is handled directly, so desktop behaves exactly like one finger.
		# On a phone every touch ALSO arrives as an emulated mouse event (the GUI
		# needs it); without this guard one finger counts as two pointers and every
		# tap becomes a pinch.
		var e := event as InputEventMouseButton
		if e.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			cam.zoom_by(0.9)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			cam.zoom_by(1.1)
		elif e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				_press_begin(MOUSE_ID, e.position)
			else:
				_press_end(MOUSE_ID, e.position)
	elif event is InputEventMouseMotion:
		var e := event as InputEventMouseMotion
		if e.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if _touches.has(MOUSE_ID):
			_drag_update(MOUSE_ID, e.position, e.relative)
	elif event is InputEventKey and event.pressed and not event.is_echo():
		match (event as InputEventKey).keycode:
			KEY_SPACE:
				hud.toggle_pause()
			KEY_Q:
				cam.rotate_step(-1)
			KEY_E:
				cam.rotate_step(1)
			KEY_ESCAPE:
				# Esc backs out one layer at a time; with nothing left to
				# cancel it offers to quit the battle (confirmed in the HUD).
				if hud.quit_confirm_open():
					hud.hide_quit_confirm()
				elif mode != "":
					hud.hide_menu()
					set_mode("")
				elif selected != null:
					hud.hide_menu()
					select(null)
				else:
					hud.hide_menu()
					hud.show_quit_confirm()


func _press_begin(idx: int, pos: Vector2) -> void:
	if _touches.is_empty() and hud.blocks(pos):
		return
	hud.hide_menu()
	_touches[idx] = pos
	if _touches.size() == 1:
		_start_pos = pos
		_start_time = _now()
		_hold_time = 0.0
		_dragging = false
		_multi = false
		_long_done = false
		_hold_on_unit = battle.phase == Battle.Phase.BATTLE \
				and battle.pick_unit(cam.screen_to_ground(pos), Game.UA, false) != null
		if _orienting():
			_preview_orient(pos)
	else:
		_multi = true
		_pinch_dist = _pinch_span()


func _press_end(idx: int, pos: Vector2) -> void:
	if not _touches.has(idx):
		return
	_touches.erase(idx)
	if _touches.is_empty() and not _multi and not _long_done:
		if _orienting():
			_preview_orient(pos)
			_apply_orient()
		elif not _dragging and pos.distance_to(_start_pos) < TAP_SLOP:
			_tap(pos)
	_pinch_dist = 0.0


func _drag_update(idx: int, pos: Vector2, relative: Vector2) -> void:
	if not _touches.has(idx):
		return
	_touches[idx] = pos
	if _touches.size() >= 2:
		var span := _pinch_span()
		if _pinch_dist > 0.0 and span > 0.0:
			cam.zoom_by(_pinch_dist / span)
		_pinch_dist = span
		cam.pan(relative * 0.5)
	elif _orienting() and not _multi:
		# One finger swings the facing around the ring instead of panning.
		_preview_orient(pos)
	else:
		var slop := HOLD_SLOP if _hold_on_unit and not _long_done else TAP_SLOP
		if not _dragging and pos.distance_to(_start_pos) > slop:
			_dragging = true
		if _dragging and not _multi and not _long_done:
			cam.pan(relative)


func _pinch_span() -> float:
	var pts := _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1] as Vector2)


func _is_double(sp: Vector2) -> bool:
	return _now() - _last_tap_time < DOUBLE_TAP_TIME and sp.distance_to(_last_tap_pos) < 40.0


func _remember_tap(sp: Vector2) -> void:
	_last_tap_time = _now()
	_last_tap_pos = sp


## A finger held on a friendly unit opens its command menu.
func _check_long_press(delta: float) -> void:
	if _touches.size() != 1 or _dragging or _multi or _long_done or _orienting():
		return
	_hold_time += delta
	if _hold_time < LONG_PRESS:
		return
	_long_done = true
	if battle.phase != Battle.Phase.BATTLE:
		return
	var p := cam.screen_to_ground(_start_pos)
	var u := battle.pick_unit(p, Game.UA, false)
	if u == null and selected != null and selected.distance_to_point(p) < 8.0:
		u = selected
	if u == null:
		return
	select(u)
	hud.show_menu(u, _start_pos)


func _tap(sp: Vector2) -> void:
	if battle.phase == Battle.Phase.ENDED:
		return
	var p := cam.screen_to_ground(sp)
	if mode != "":
		_apply_mode(p)
		return
	var friend := battle.pick_unit(p, Game.UA, false)
	if friend != null:
		if friend == selected and _is_double(sp):
			cam.focus(friend.position)
		select(friend)
		_remember_tap(sp)
		return
	if selected == null:
		return
	if battle.phase == Battle.Phase.SETUP:
		_deploy(p)
		return
	var foe := battle.pick_unit(p, Game.RU, true)
	if foe != null:
		_fire_at(foe)
		return
	_move(p, Unit.Order.FAST if _is_double(sp) else Unit.Order.MOVE)
	_remember_tap(sp)


func _deploy(p: Vector3) -> void:
	if not battle.in_deploy_zone(p) or not battle.map.is_passable(p, selected.is_vehicle):
		hud.msg("Outside the deployment zone", Color(1.0, 0.7, 0.4))
		return
	selected.teleport(p)
	battle.fx.order_marker(p, Color(0.5, 0.8, 1.0))


func _move(p: Vector3, order: int) -> void:
	if selected.order_move(p, order):
		var key: String = ["", "move", "fast", "sneak"][mini(order, 3)]
		battle.fx.order_marker(p, MODE_COLORS.get(key, Color.WHITE))
	elif selected.state >= Unit.State.PINNED:
		hud.msg("%s is %s and won't move" % [selected.display_name, selected.status_text().to_lower()], Color(1.0, 0.6, 0.4))
	elif selected.is_vehicle and (selected as VehicleUnit).immobile:
		hud.msg("%s is immobilized" % selected.display_name, Color(1.0, 0.6, 0.4))
	else:
		hud.msg("Can't get there", Color(1.0, 0.7, 0.4))


func _fire_at(foe: Unit) -> void:
	selected.order_fire(foe)
	battle.fx.order_marker(foe.position, Color(1.0, 0.35, 0.3))


func _apply_mode(p: Vector3) -> void:
	var m := mode
	set_mode("")
	if m in UNIT_MODES and (selected == null or not selected.is_targetable()):
		return
	match m:
		"move":
			_move(p, Unit.Order.MOVE)
		"fast":
			_move(p, Unit.Order.FAST)
		"sneak":
			_move(p, Unit.Order.SNEAK)
		"fire":
			var foe := battle.pick_unit(p, Game.RU, true)
			if foe != null:
				_fire_at(foe)
			else:
				selected.order_area_fire(p)
				battle.fx.order_marker(p, Color(1.0, 0.55, 0.2))
		"smoke":
			if selected.throw_smoke(p):
				battle.fx.order_marker(p, Color(0.9, 0.9, 0.9))
			else:
				hud.msg("Too far: smoke reaches %d m" % int(InfantryUnit.SMOKE_RANGE), Color(1.0, 0.7, 0.4))
		"mortar":
			if battle.support.call_mortar(p):
				battle.fx.order_marker(p, Color(1.0, 0.5, 0.2))
		"recon":
			if battle.support.launch_recon(p):
				battle.fx.order_marker(p, Color(0.5, 0.8, 1.0))
		"fpv":
			var foe := battle.pick_unit(p, Game.RU, true)
			if foe == null:
				hud.msg("FPV needs a spotted enemy", Color(1.0, 0.7, 0.4))
			elif battle.support.launch_fpv(foe):
				battle.fx.order_marker(foe.position, Color(1.0, 0.35, 0.3))


func _preview_orient(sp: Vector2) -> void:
	if selected == null:
		return
	var p := cam.screen_to_ground(sp)
	var d := Vector3(p.x - selected.position.x, 0.0, p.z - selected.position.z)
	if d.length() > 0.5:
		_orient_dir = d.normalized()


func _apply_orient() -> void:
	var m := mode
	set_mode("")
	if selected == null or not selected.is_targetable() or _orient_dir == Vector3.ZERO:
		return
	selected.order_defend(_orient_dir, m == "ambush")
	battle.fx.order_marker(selected.position + _orient_dir * RING_RADIUS, GUARD_COLORS[m])
	# The order is complete once the facing is set; drop the selection so the
	# next tap pans or picks a new unit instead of re-ordering this one.
	select(null)


func set_mode(m: String) -> void:
	mode = m
	if _orienting() and selected != null:
		_orient_dir = selected.guard_dir if selected.guard_dir != Vector3.ZERO else selected.forward()
	hud.show_prompt(m)


func select(u: Unit) -> void:
	if selected != null:
		selected.selected = false
	selected = u
	if u != null:
		u.selected = true
	if mode in UNIT_MODES:
		set_mode("")
	hud.on_selection(u)


func _process(_delta: float) -> void:
	_check_long_press(_delta)
	_imesh.clear_surfaces()
	if selected == null:
		return
	if not selected.is_targetable():
		select(null)
		return
	var up := Vector3.UP * 0.4
	var c := selected.position + up
	if _orienting():
		_draw_ring(c, RING_RADIUS, GUARD_COLORS[mode])
		_draw_arc(c, _orient_dir, RING_RADIUS, GUARD_COLORS[mode])
		return
	if selected.is_guarding() and selected.arrived:
		var key := "ambush" if selected.order == Unit.Order.AMBUSH else "defend"
		_draw_arc(c, selected.guard_dir, RING_RADIUS, GUARD_COLORS[key])
	if not selected.arrived and selected.path_i < selected.path.size():
		var key: String = ["", "move", "fast", "sneak", "", ""][selected.order]
		var pts := PackedVector3Array([c])
		for i in range(selected.path_i, selected.path.size()):
			var q := selected.path[i]
			q.y = battle.map.height_at(q)
			pts.append(q + up)
		_ribbon(pts, 0.4, MODE_COLORS.get(key, Color.WHITE))
	var aim := Vector3.INF
	var color := Color(1.0, 0.35, 0.3)
	if selected.fire_target != null and selected.fire_target.is_targetable():
		aim = selected.fire_target.position
	elif selected.area_fire:
		aim = selected.fire_point
		color = Color(1.0, 0.6, 0.2)
	if aim != Vector3.INF:
		_ribbon(PackedVector3Array([c, aim + up]), 0.4, color)


## Flat band on the ground through the points, wide enough to read on a phone.
func _ribbon(pts: PackedVector3Array, width: float, color: Color) -> void:
	if pts.size() < 2:
		return
	_imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_imesh.surface_set_color(color)
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var d := Vector3(b.x - a.x, 0.0, b.z - a.z).normalized()
		var n := Vector3(-d.z, 0.0, d.x) * width * 0.5
		_imesh.surface_add_vertex(a - n)
		_imesh.surface_add_vertex(a + n)
		_imesh.surface_add_vertex(b + n)
		_imesh.surface_add_vertex(a - n)
		_imesh.surface_add_vertex(b + n)
		_imesh.surface_add_vertex(b - n)
	_imesh.surface_end()


func _draw_ring(c: Vector3, r: float, color: Color) -> void:
	var pts := PackedVector3Array()
	for k in 49:
		var a := k * TAU / 48.0
		pts.append(c + Vector3(cos(a), 0.0, sin(a)) * r)
	_ribbon(pts, 0.5, Color(color, 0.55))


## Fire arc: two edges and the outer curve.
func _draw_arc(c: Vector3, dir: Vector3, r: float, color: Color) -> void:
	if dir == Vector3.ZERO:
		return
	var yaw := atan2(dir.x, dir.z)
	var pts := PackedVector3Array([c])
	for k in 13:
		var a := yaw - Unit.GUARD_ARC + k * Unit.GUARD_ARC * 2.0 / 12.0
		pts.append(c + Vector3(sin(a), 0.0, cos(a)) * r * 1.6)
	pts.append(c)
	_ribbon(pts, 0.6, color)
	# Translucent fill so the guarded sector reads at a glance.
	_imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_imesh.surface_set_color(Color(color, 0.18))
	for k in 12:
		_imesh.surface_add_vertex(c)
		_imesh.surface_add_vertex(pts[k + 1])
		_imesh.surface_add_vertex(pts[k + 2])
	_imesh.surface_end()
