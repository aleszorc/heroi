class_name InputController
extends Node
## Turns touches (and mouse and keys on desktop) into selection, orders and camera moves.
##
## Two orders only: with a unit selected, tap ground to move, tap a spotted enemy to
## attack. Pace, facing, cover, smoke and holding fire are the unit's own decisions.
## The HUD's support buttons arm a mode (mortar, recon, fpv, bomber) for the next tap.

const TAP_SLOP := 14.0
const DOUBLE_TAP_TIME := 0.35
const MOVE_COLOR := Color(0.5, 1.0, 0.5)
const FIRE_COLOR := Color(1.0, 0.35, 0.3)

var battle: Battle
var cam: CameraRig
var hud: Hud
var selected: Unit = null
## Armed support mode for the next tap: "", mortar, recon, fpv, bomber.
var mode := ""

var _touches := {}
var _start_pos := Vector2.ZERO
var _dragging := false
var _multi := false
var _pinch_dist := 0.0
var _last_tap_time := -10.0
var _last_tap_pos := Vector2.ZERO
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
					set_mode("")
				elif selected != null:
					select(null)
				else:
					hud.show_quit_confirm()


func _press_begin(idx: int, pos: Vector2) -> void:
	if _touches.is_empty() and hud.blocks(pos):
		return
	_touches[idx] = pos
	if _touches.size() == 1:
		_start_pos = pos
		_dragging = false
		_multi = false
	else:
		_multi = true
		_pinch_dist = _pinch_span()


func _press_end(idx: int, pos: Vector2) -> void:
	if not _touches.has(idx):
		return
	_touches.erase(idx)
	if _touches.is_empty() and not _multi and not _dragging \
			and pos.distance_to(_start_pos) < TAP_SLOP:
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
	else:
		if not _dragging and pos.distance_to(_start_pos) > TAP_SLOP:
			_dragging = true
		if _dragging and not _multi:
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


func _tap(sp: Vector2) -> void:
	if battle.phase == Battle.Phase.ENDED:
		return
	var p := cam.screen_to_ground(sp)
	if mode != "":
		_apply_support(p)
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
		selected.order_fire(foe)
		battle.fx.order_marker(foe.position, FIRE_COLOR)
		return
	if selected.order_move(p):
		battle.fx.order_marker(p, MOVE_COLOR)
	_remember_tap(sp)


func _deploy(p: Vector3) -> void:
	if not battle.in_deploy_zone(p) or not battle.map.is_passable(p, selected.is_vehicle):
		return
	selected.teleport(p)
	battle.fx.order_marker(p, Color(0.5, 0.8, 1.0))


func _apply_support(p: Vector3) -> void:
	var m := mode
	set_mode("")
	match m:
		"mortar":
			if battle.support.call_mortar(p):
				battle.fx.order_marker(p, Color(1.0, 0.5, 0.2))
		"recon":
			if battle.support.launch_recon(p):
				battle.fx.order_marker(p, Color(0.5, 0.8, 1.0))
		"fpv":
			var foe := battle.pick_unit(p, Game.RU, true)
			if foe != null and battle.support.launch_fpv(foe):
				battle.fx.order_marker(foe.position, FIRE_COLOR)
		"bomber":
			var foe := battle.pick_unit(p, Game.RU, true)
			if foe != null and battle.support.launch_bomber(foe):
				battle.fx.order_marker(foe.position, FIRE_COLOR)


func set_mode(m: String) -> void:
	mode = m
	hud.show_prompt(m)


func select(u: Unit) -> void:
	if selected != null:
		selected.selected = false
	selected = u
	if u != null:
		u.selected = true
	hud.on_selection(u)


func _process(_delta: float) -> void:
	_imesh.clear_surfaces()
	if selected == null:
		return
	if not selected.is_targetable():
		select(null)
		return
	var up := Vector3.UP * 0.4
	var c := selected.position + up
	if not selected.arrived and selected.path_i < selected.path.size():
		var pts := PackedVector3Array([c])
		for i in range(selected.path_i, selected.path.size()):
			var q := selected.path[i]
			q.y = battle.map.height_at(q)
			pts.append(q + up)
		_ribbon(pts, 0.4, MOVE_COLOR)
	if selected.fire_target != null and selected.fire_target.is_targetable():
		_ribbon(PackedVector3Array([c, selected.fire_target.position + up]), 0.4, FIRE_COLOR)


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


