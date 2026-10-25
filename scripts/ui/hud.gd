class_name Hud
extends CanvasLayer
## Touch HUD: clock and objectives, speed/rotate, unit roster, support buttons,
## prompts, the deployment (pre-battle) screen, the options overlay and the end
## screen. There is no order menu: units get only move and attack taps and handle
## their own tactics. There is no player-facing pause either; Game.paused is an
## internal mechanism (deployment, options overlay, end screen).

const PROMPTS := {
	"mortar": "Tap target for 82mm mortar (6 rounds)",
	"recon": "Tap area for the recon drone",
	"fpv": "Tap a spotted enemy for an FPV strike",
	"bomber": "Tap a spotted enemy for a heavy bomber run",
}

var battle: Battle
var ctl: InputController
var cam: CameraRig

var _root: Control
var _blockers: Array[Control] = []
var _clock: Label
var _vl_labels: Array[Label] = []
var _msgs: VBoxContainer
var _speed_btn: Button
## Roster cards: unit -> {btn, name, pips: Array[ColorRect], state: Label, strip}.
var _cards := {}
## Support buttons: mode -> {btn, stripe}.
var _support := {}
var _prompt: PanelContainer
var _prompt_label: Label
var _setup: Control
var _deploy_bar: PanelContainer
var _end: Control
var _end_title: Label
var _end_text: Label
var _selected_box: StyleBoxFlat
var _opts: Control
## Pause state to restore when the options overlay closes mid-battle.
var _opts_was_paused := false
var _tick := 0.0


func setup(b: Battle, c: InputController, camera: CameraRig) -> void:
	battle = b
	ctl = c
	cam = camera
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = _make_theme()
	add_child(_root)
	_build_top()
	_build_roster()
	_build_support()
	_build_prompt()
	_build_setup()
	_build_end()
	_build_options()
	battle.message.connect(msg)
	battle.ended.connect(_on_ended)
	_refresh()


# --- Layout helpers ---

func _place(c: Control, anchor: Vector2, offset: Vector2, grow_h: int, grow_v: int) -> void:
	c.anchor_left = anchor.x
	c.anchor_right = anchor.x
	c.anchor_top = anchor.y
	c.anchor_bottom = anchor.y
	c.offset_left = offset.x
	c.offset_right = offset.x
	c.offset_top = offset.y
	c.offset_bottom = offset.y
	c.grow_horizontal = grow_h
	c.grow_vertical = grow_v


func _button(text: String, cb: Callable, min_size := Vector2(100, 64), icon := "") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void:
		if battle != null and battle.sfx != null:
			battle.sfx.ui_tick()
		cb.call())
	if icon != "":
		b.icon = UiIcons.tex(icon)
	return b


## Beveled panel: flat dark olive face, hairline border and a soft drop shadow for depth.
func _box(bg: Color, border: Color, shadow := true) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 13
	sb.content_margin_right = 13
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	if shadow:
		sb.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
		sb.shadow_size = 4
		sb.shadow_offset = Vector2(0, 2)
	return sb


func _make_theme() -> Theme:
	var t := Theme.new()
	# Condensed system face for the stencil-ish military look; falls back gracefully.
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Avenir Next Condensed", "Arial Narrow", "Roboto Condensed", "sans-serif-condensed"])
	font.font_weight = 600
	t.default_font = font
	t.default_font_size = 18
	t.set_stylebox("normal", "Button", _box(Color(0.09, 0.1, 0.08, 0.94), Color(0.34, 0.37, 0.27)))
	t.set_stylebox("hover", "Button", _box(Color(0.14, 0.16, 0.11, 0.96), Color(0.55, 0.58, 0.42)))
	var pressed := _box(Color(0.24, 0.26, 0.15, 0.97), Color(0.95, 0.85, 0.35), false)
	pressed.set_border_width_all(2)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", _box(Color(0.07, 0.07, 0.06, 0.55), Color(0.2, 0.2, 0.18), false))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.93, 0.93, 0.85))
	t.set_color("font_hover_color", "Button", Color(1.0, 1.0, 0.95))
	t.set_color("font_pressed_color", "Button", Color(1.0, 0.9, 0.4))
	t.set_color("font_disabled_color", "Button", Color(0.45, 0.45, 0.4))
	t.set_color("icon_normal_color", "Button", Color(0.78, 0.8, 0.66))
	t.set_color("icon_hover_color", "Button", Color(0.95, 0.96, 0.85))
	t.set_color("icon_pressed_color", "Button", Color(1.0, 0.9, 0.4))
	t.set_color("icon_disabled_color", "Button", Color(0.38, 0.38, 0.34))
	t.set_constant("h_separation", "Button", 8)
	t.set_stylebox("panel", "PanelContainer", _box(Color(0.055, 0.065, 0.05, 0.9), Color(0.28, 0.31, 0.23)))
	t.set_color("font_color", "Label", Color(0.92, 0.92, 0.84))
	_selected_box = _box(Color(0.15, 0.16, 0.09, 0.97), Color(1.0, 0.88, 0.32), false)
	_selected_box.set_border_width_all(2)
	return t


# --- Sections ---

func _build_top() -> void:
	var tl := PanelContainer.new()
	_root.add_child(tl)
	_place(tl, Vector2(0, 0), Vector2(12, 12), Control.GROW_DIRECTION_END, Control.GROW_DIRECTION_END)
	_blockers.append(tl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	tl.add_child(row)
	_clock = Label.new()
	_clock.add_theme_font_size_override("font_size", 26)
	_clock.custom_minimum_size.x = 90
	row.add_child(_clock)
	for vl in battle.vls:
		var l := Label.new()
		row.add_child(l)
		_vl_labels.append(l)

	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", 8)
	_root.add_child(tr)
	_place(tr, Vector2(1, 0), Vector2(-12, 12), Control.GROW_DIRECTION_BEGIN, Control.GROW_DIRECTION_END)
	_blockers.append(tr)
	tr.add_child(_button("", func() -> void: cam.rotate_step(-1), Vector2(58, 56), "rot_l"))
	tr.add_child(_button("", func() -> void: cam.rotate_step(1), Vector2(58, 56), "rot_r"))
	_speed_btn = _button("1×", _cycle_speed, Vector2(58, 56))
	tr.add_child(_speed_btn)
	tr.add_child(_button("", show_options, Vector2(58, 56), "menu"))

	_msgs = VBoxContainer.new()
	_msgs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_msgs.alignment = BoxContainer.ALIGNMENT_BEGIN
	_root.add_child(_msgs)
	_place(_msgs, Vector2(0.5, 0), Vector2(0, 86), Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_END)


func _build_roster() -> void:
	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.anchor_left = 0
	scroll.anchor_right = 1
	scroll.anchor_top = 1
	scroll.anchor_bottom = 1
	scroll.offset_left = 8
	scroll.offset_right = -8
	scroll.offset_top = -96
	scroll.offset_bottom = -6
	_root.add_child(scroll)
	_blockers.append(scroll)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	scroll.add_child(row)
	for u in battle.units:
		if u.side != Game.UA:
			continue
		var card := _button("", func() -> void:
			if u.is_targetable():
				ctl.select(u)
				cam.focus(u.position), Vector2(128, 84))
		row.add_child(card)
		var inner := VBoxContainer.new()
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.set_anchors_preset(Control.PRESET_FULL_RECT)
		inner.offset_left = 10
		inner.offset_right = -10
		inner.offset_top = 7
		inner.offset_bottom = -7
		inner.add_theme_constant_override("separation", 4)
		card.add_child(inner)
		var head := HBoxContainer.new()
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		head.add_theme_constant_override("separation", 6)
		inner.add_child(head)
		var icon := TextureRect.new()
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.texture = UiIcons.tex("veh" if u.is_vehicle else "inf")
		icon.custom_minimum_size = Vector2(18, 18)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.modulate = Color(0.78, 0.8, 0.66)
		head.add_child(icon)
		var nm := Label.new()
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		nm.text = u.display_name
		nm.add_theme_font_size_override("font_size", 15)
		head.add_child(nm)
		var pip_row := HBoxContainer.new()
		pip_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip_row.add_theme_constant_override("separation", 3)
		inner.add_child(pip_row)
		var pips: Array[ColorRect] = []
		for k in u.total_count():
			var pip := ColorRect.new()
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pip.custom_minimum_size = Vector2(10, 7)
			pip_row.add_child(pip)
			pips.append(pip)
		var st := Label.new()
		st.mouse_filter = Control.MOUSE_FILTER_IGNORE
		st.add_theme_font_size_override("font_size", 12)
		inner.add_child(st)
		var strip := ColorRect.new()
		strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		strip.anchor_top = 1.0
		strip.anchor_bottom = 1.0
		strip.anchor_right = 1.0
		strip.offset_top = -3.0
		strip.offset_left = 1.0
		strip.offset_right = -1.0
		card.add_child(strip)
		_cards[u] = {"btn": card, "name": nm, "pips": pips, "state": st, "strip": strip}


func _build_support() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_root.add_child(col)
	_place(col, Vector2(1, 0.5), Vector2(-12, -20), Control.GROW_DIRECTION_BEGIN, Control.GROW_DIRECTION_BOTH)
	_blockers.append(col)
	for mode: String in ["mortar", "recon", "fpv", "bomber"]:
		var btn := _button("", func() -> void: ctl.set_mode(mode), Vector2(128, 60), mode)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		col.add_child(btn)
		var stripe := ColorRect.new()
		stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stripe.anchor_bottom = 1.0
		stripe.offset_left = 1.0
		stripe.offset_right = 4.0
		stripe.offset_top = 1.0
		stripe.offset_bottom = -1.0
		btn.add_child(stripe)
		_support[mode] = {"btn": btn, "stripe": stripe}


func _build_prompt() -> void:
	_prompt = PanelContainer.new()
	_root.add_child(_prompt)
	_place(_prompt, Vector2(0.5, 1), Vector2(0, -200), Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_BEGIN)
	_blockers.append(_prompt)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_prompt.add_child(row)
	_prompt_label = Label.new()
	_prompt_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	row.add_child(_prompt_label)
	row.add_child(_button("CANCEL", func() -> void: ctl.set_mode(""), Vector2(116, 50), "cancel"))
	_prompt.visible = false


## The pre-battle flow is two screens: first a modal briefing (map input blocked)
## whose DEPLOY button hands over to placement, then a slim top bar with the
## placement hint and the START BATTLE button.
func _build_setup() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_setup = dim
	_root.add_child(_setup)
	_blockers.append(_setup)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_setup.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	var title := Label.new()
	title.text = String(battle.mission["title"])
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	col.add_child(title)
	var text := Label.new()
	text.text = String(battle.mission["briefing"])
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size.x = 600
	text.add_theme_font_size_override("font_size", 17)
	col.add_child(text)
	var info := Label.new()
	info.text = "mission %s  seed %d" % [Game.next_kind, int(battle.mission.get("seed", 0))]
	info.add_theme_color_override("font_color", Color(0.62, 0.62, 0.55))
	info.add_theme_font_size_override("font_size", 14)
	col.add_child(info)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 10)
	btns.alignment = BoxContainer.ALIGNMENT_END
	col.add_child(btns)
	btns.add_child(_button("MENU", _exit_to_menu, Vector2(130, 60), "menu"))
	var deploy := _button("DEPLOY", func() -> void:
		_setup.visible = false
		_deploy_bar.visible = true, Vector2(200, 60), "play")
	deploy.add_theme_stylebox_override("normal", _primary_box())
	btns.add_child(deploy)
	_build_deploy_bar()


func _build_deploy_bar() -> void:
	_deploy_bar = PanelContainer.new()
	_root.add_child(_deploy_bar)
	_place(_deploy_bar, Vector2(0.5, 0), Vector2(0, 84), Control.GROW_DIRECTION_BOTH, Control.GROW_DIRECTION_END)
	_blockers.append(_deploy_bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	_deploy_bar.add_child(row)
	var hint := Label.new()
	hint.text = "Deploy: tap a unit, then tap inside the blue zone."
	hint.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	hint.add_theme_font_size_override("font_size", 17)
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(hint)
	var start := _button("START BATTLE", func() -> void:
		battle.start_battle()
		_deploy_bar.visible = false
		on_selection(ctl.selected), Vector2(220, 60), "play")
	start.add_theme_stylebox_override("normal", _primary_box())
	row.add_child(start)
	_deploy_bar.visible = false


func _primary_box() -> StyleBoxFlat:
	var primary := _box(Color(0.22, 0.23, 0.12, 0.97), Color(1.0, 0.88, 0.32))
	primary.set_border_width_all(2)
	return primary


func _build_end() -> void:
	_end = ColorRect.new()
	(_end as ColorRect).color = Color(0.0, 0.0, 0.0, 0.55)
	_end.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_end)
	_blockers.append(_end)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_end.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)
	_end_title = Label.new()
	_end_title.add_theme_font_size_override("font_size", 44)
	_end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_end_title)
	_end_text = Label.new()
	_end_text.custom_minimum_size.x = 460
	_end_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_end_text)
	# The kind/seed stays readable here so a good random map can be found again.
	var info := Label.new()
	info.text = "mission %s  seed %d" % [Game.next_kind, int(battle.mission.get("seed", 0))]
	info.add_theme_color_override("font_color", Color(0.62, 0.62, 0.55))
	info.add_theme_font_size_override("font_size", 14)
	col.add_child(info)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 10)
	btns.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(btns)
	# PLAY AGAIN replays the exact same map; NEW BATTLE rerolls the same kind.
	btns.add_child(_button("PLAY AGAIN", func() -> void: _restart(Game.next_kind, int(battle.mission.get("seed", 0))), Vector2(190, 60), "rot_l"))
	btns.add_child(_button("NEW BATTLE", func() -> void: _restart(Game.next_kind, -1), Vector2(190, 60), "fast"))
	btns.add_child(_button("MENU", _exit_to_menu, Vector2(140, 60), "menu"))
	_end.visible = false


## Reloads the scene into `kind`; a negative seed rolls a fresh map.
func _restart(kind: String, mission_seed: int) -> void:
	Game.next_kind = kind
	Game.next_seed = mission_seed
	get_tree().reload_current_scene()


## Reloads the scene into the start menu.
func _exit_to_menu() -> void:
	Game.show_menu = true
	get_tree().reload_current_scene()


## Options overlay (the only menu in battle): resume, restart the same scenario,
## exit to the start menu, quit the app. Opening it pauses the simulation
## internally; closing restores the pause state it found.
func _build_options() -> void:
	_opts = ColorRect.new()
	(_opts as ColorRect).color = Color(0.0, 0.0, 0.0, 0.55)
	_opts.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_opts)
	_blockers.append(_opts)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_opts.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)
	var title := Label.new()
	title.text = String(battle.mission["title"])
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	col.add_child(_button("RESUME", hide_options, Vector2(280, 60), "play"))
	# Restart keeps the exact kind+seed, so the same map and waves come back.
	col.add_child(_button("RESTART", func() -> void: _restart(Game.next_kind, int(battle.mission.get("seed", 0))), Vector2(280, 60), "rot_l"))
	col.add_child(_button("EXIT TO MENU", _exit_to_menu, Vector2(280, 60), "menu"))
	col.add_child(_button("QUIT GAME", func() -> void: get_tree().quit(), Vector2(280, 60), "cancel"))
	_opts.visible = false


func show_options() -> void:
	if _opts.visible:
		return
	ctl.set_mode("")
	_opts_was_paused = Game.paused
	Game.paused = true
	_opts.visible = true
	_refresh()


func hide_options() -> void:
	if not _opts.visible:
		return
	_opts.visible = false
	Game.paused = _opts_was_paused
	_refresh()


func options_open() -> bool:
	return _opts != null and _opts.visible


# --- Public API ---

## True when a screen point is over HUD, so the tap should not reach the map.
func blocks(pos: Vector2) -> bool:
	for c in _blockers:
		if c.is_visible_in_tree() and c.get_global_rect().has_point(pos):
			return true
	return false


func msg(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_font_size_override("font_size", 20)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_msgs.add_child(l)
	while _msgs.get_child_count() > 4:
		var old := _msgs.get_child(0)
		_msgs.remove_child(old)
		old.queue_free()
	var tw := l.create_tween()
	tw.tween_interval(4.5)
	tw.tween_property(l, "modulate:a", 0.0, 0.8)
	tw.tween_callback(l.queue_free)


func _cycle_speed() -> void:
	Game.speed = 2.0 if Game.speed < 2.0 else 1.0
	_refresh()


func show_prompt(mode: String) -> void:
	_prompt.visible = mode != ""
	_prompt_label.text = PROMPTS.get(mode, "")


func on_selection(_u: Unit) -> void:
	_refresh()


func _on_ended(victory: bool, title: String, summary: String) -> void:
	ctl.set_mode("")
	_end_title.text = title
	_end_title.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0) if victory else Color(1.0, 0.4, 0.3))
	_end_text.text = summary
	_end.visible = true


# --- Per-frame refresh ---

func _process(delta: float) -> void:
	_tick -= delta
	if _tick <= 0.0:
		_tick = 0.2
		_refresh()


func _refresh() -> void:
	if battle.phase == Battle.Phase.SETUP:
		_clock.text = "DEPLOY"
	else:
		_setup.visible = false
		_deploy_bar.visible = false
		_clock.text = Battle.clock_text(battle.time_limit - battle.time)
	for i in battle.vls.size():
		var vl := battle.vls[i]
		var l := _vl_labels[i]
		l.text = "■ %s%s" % [vl.loc_name, " !" if vl.contested else ""]
		var c := Color(0.7, 0.7, 0.7)
		if vl.owner_side == Game.UA:
			c = Color(0.5, 0.78, 1.0)
		elif vl.owner_side == Game.RU:
			c = Color(1.0, 0.42, 0.35)
		l.add_theme_color_override("font_color", c)
	_speed_btn.text = "%d×" % int(Game.speed)
	var live := battle.phase == Battle.Phase.BATTLE
	var s := battle.support
	var team_ok := s.drone_team() != null
	var recon_wait := int(ceil(s.recon_ready_at - battle.time))
	var ready := Color(0.55, 0.75, 0.35)
	var wait := Color(0.9, 0.7, 0.25)
	var out := Color(0.3, 0.3, 0.27)
	_support_state("mortar", "MORTAR  %d" % s.mortar_left, not live or s.mortar_left <= 0,
			ready if s.mortar_left > 0 else out)
	_support_state("recon", "RECON  %s" % ("" if team_ok and recon_wait <= 0 else ("%ds" % recon_wait if team_ok else "—")),
			not live or not s.can_recon(), (ready if recon_wait <= 0 else wait) if team_ok else out)
	_support_state("fpv", "FPV  %d" % s.fpv_left if team_ok else "FPV  —",
			not live or not s.can_fpv(), (ready if s.fpv_left > 0 else out) if team_ok else out)
	_support_state("bomber", "BOMBER  %d" % s.bomber_left if team_ok else "BOMBER  —",
			not live or not s.can_bomber(), (ready if s.bomber_left > 0 else out) if team_ok else out)
	for u: Unit in _cards.keys():
		var card: Dictionary = _cards[u]
		var btn: Button = card["btn"]
		var alive := u.alive_count()
		var state_c: Color = Unit.STATE_COLORS[u.state]
		for k in (card["pips"] as Array).size():
			(card["pips"][k] as ColorRect).color = Color(0.8, 0.84, 0.68) if k < alive else Color(0.22, 0.22, 0.19)
		var st: Label = card["state"]
		st.text = u.status_text() if u.state != Unit.State.OK else ""
		st.add_theme_color_override("font_color", state_c)
		(card["strip"] as ColorRect).color = state_c if u.state != Unit.State.OK else Color(0.35, 0.45, 0.6)
		(card["name"] as Label).add_theme_color_override("font_color",
				Color(1.0, 0.85, 0.25) if u == ctl.selected else Color(0.93, 0.93, 0.85))
		btn.disabled = not u.is_targetable()
		if u == ctl.selected:
			btn.add_theme_stylebox_override("normal", _selected_box)
			btn.add_theme_stylebox_override("hover", _selected_box)
		else:
			btn.remove_theme_stylebox_override("normal")
			btn.remove_theme_stylebox_override("hover")


func _support_state(mode: String, text: String, disabled: bool, stripe: Color) -> void:
	var w: Dictionary = _support[mode]
	(w["btn"] as Button).text = text
	(w["btn"] as Button).disabled = disabled
	(w["stripe"] as ColorRect).color = stripe if not disabled or stripe == Color(0.3, 0.3, 0.27) else Color(0.9, 0.7, 0.25)
