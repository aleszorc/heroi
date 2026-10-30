class_name CampaignScreen
extends CanvasLayer
## The between-battle screen (GDD §2b.4), one screen in the spirit of the start menu:
## the front ribbon, the next battle choice, the roster with replacements and
## veterancy, requisition purchases and the memorial. Drawn over the unit-less
## backdrop board built by main.gd.

const KIND_LABELS := {"assault": "ASSAULT", "meeting": "MEETING", "defend": "DEFEND", "town": "TOWN"}
const KIND_COLORS := {"assault": Color(1.0, 0.72, 0.4), "meeting": Color(0.7, 0.9, 0.55), "defend": Color(0.55, 0.75, 0.95), "town": Color(0.85, 0.7, 0.9)}

var state: Dictionary

var _root: Control
var _scroll: ScrollContainer
var _confirm_new := false
## The DISBAND button awaiting its second tap (two-tap confirm, no modal).
var _confirm_disband: Button = null
## Touch-drag scrolling, same mechanism as the start menu.
var _drag_id := -1
var _drag_accum := 0.0
var _dragging := false
var _mouse_down := false


func _ready() -> void:
	state = Game.campaign
	if state.is_empty():
		state = Campaign.load_state()
		if state.is_empty():
			state = Campaign.generate(randi() % 1000000)
		Game.campaign = state
	# A battle that was abandoned mid-way was never committed; it can be refought.
	state.erase("pending")
	Campaign.save_state(state)
	_rebuild()


func _rebuild() -> void:
	if _root != null:
		_root.queue_free()
	_confirm_new = false
	_confirm_disband = null
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = _make_theme()
	add_child(_root)
	var scrim := ColorRect.new()
	scrim.color = Color(0.03, 0.04, 0.03, 0.55)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(scrim)
	_build_header()
	_build_ribbon()
	_build_left()
	_build_roster()
	if state.get("won", false) or state.get("lost", false):
		_build_terminal()


# --- Header and ribbon ---

func _build_header() -> void:
	var col := VBoxContainer.new()
	col.offset_left = 36
	col.offset_top = 18
	col.add_theme_constant_override("separation", 2)
	_root.add_child(col)
	var title := Label.new()
	title.text = "OPERATION %s" % String(state["op_name"])
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	col.add_child(title)
	var sub := Label.new()
	sub.text = "Battle %d   ·   Requisition %d RP   ·   Fallen %d" % [
		Campaign.geti(state, "battle_n") + 1, Campaign.geti(state, "requisition"),
		(state["memorial"] as Array).size()]
	sub.add_theme_font_size_override("font_size", 17)
	sub.add_theme_color_override("font_color", Color(0.78, 0.78, 0.68))
	col.add_child(sub)


## The front as a strip of sector chips: held blue, the contested one red, the
## current objective yellow, the ground ahead unknown.
func _build_ribbon() -> void:
	var row := HBoxContainer.new()
	row.offset_left = 36
	row.offset_top = 92
	row.add_theme_constant_override("separation", 6)
	_root.add_child(row)
	var steps: Array = state["steps"]
	var taken := Campaign.geti(state, "taken")
	var defend := bool(state.get("next_defend", false))
	for i in steps.size():
		var st: Dictionary = steps[i]
		var chosen := maxi(Campaign.geti(st, "chosen", -1), 0)
		var chip := PanelContainer.new()
		var known: bool = i < taken or (i == taken and not state.get("won", false))
		var nm := String(((st["options"] as Array)[chosen] as Dictionary)["name"]) if known or i < taken else "?"
		var c := Color(0.5, 0.78, 1.0)
		if state.get("won", false):
			pass  # all held
		elif defend and i == taken - 1:
			c = Color(1.0, 0.42, 0.35)
		elif i == taken:
			c = Color(1.0, 0.86, 0.3)
			if Campaign.geti(st, "chosen", -1) < 0 and (st["options"] as Array).size() > 1:
				nm = "?"
		elif i > taken:
			c = Color(0.5, 0.5, 0.45)
			nm = "?"
		var l := Label.new()
		l.text = nm
		l.add_theme_font_size_override("font_size", 14)
		l.add_theme_color_override("font_color", c)
		chip.add_theme_stylebox_override("panel", _box(Color(0.07, 0.08, 0.06, 0.9), c * Color(1, 1, 1, 0.55)))
		chip.add_child(l)
		row.add_child(chip)
		if i < steps.size() - 1:
			var dash := Label.new()
			dash.text = "—"
			dash.add_theme_color_override("font_color", Color(0.45, 0.45, 0.4))
			row.add_child(dash)


# --- Left column: the next battle, memorial, exit ---

func _build_left() -> void:
	var col := VBoxContainer.new()
	col.anchor_top = 0.0
	col.anchor_bottom = 1.0
	col.offset_left = 36
	col.offset_top = 148
	col.offset_bottom = -20
	col.offset_right = 476
	col.add_theme_constant_override("separation", 10)
	_root.add_child(col)
	if not (state.get("won", false) or state.get("lost", false)):
		var head := Label.new()
		var opts := Campaign.next_options(state)
		head.text = "NEXT BATTLE" if opts.size() < 2 else "NEXT BATTLE — CHOOSE A SECTOR"
		head.add_theme_font_size_override("font_size", 20)
		head.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
		col.add_child(head)
		var men := Campaign.deployable_men(state)
		for o: Dictionary in opts:
			col.add_child(_option_card(o, men))
		if men == 0:
			var warn := Label.new()
			warn.text = "No one is fit to fight. Buy replacements to continue."
			warn.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
			warn.add_theme_font_size_override("font_size", 15)
			col.add_child(warn)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(fill)
	var fallen: Array = state["memorial"]
	if not fallen.is_empty():
		col.add_child(_button("THE FALLEN  (%d)" % fallen.size(), _show_memorial, Vector2(280, 50)))
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	col.add_child(btns)
	btns.add_child(_button("MENU", _to_menu, Vector2(130, 50), "menu"))
	var new_op := _button("NEW OPERATION", func() -> void: _new_operation_pressed(), Vector2(210, 50), "fast")
	new_op.name = "NewOp"
	btns.add_child(new_op)


func _option_card(o: Dictionary, men: int) -> Control:
	var kind := String(o["kind"])
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(440, 86)
	card.add_theme_stylebox_override("panel", _box(Color(0.09, 0.1, 0.08, 0.94), Color(0.34, 0.37, 0.27)))
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 3)
	card.add_child(inner)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	inner.add_child(head)
	var nm := Label.new()
	nm.text = String(o["name"]).to_upper()
	nm.add_theme_font_size_override("font_size", 21)
	nm.add_theme_color_override("font_color", Color(0.95, 0.94, 0.85))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(nm)
	var kl := Label.new()
	kl.text = String(KIND_LABELS[kind])
	kl.add_theme_font_size_override("font_size", 14)
	kl.add_theme_color_override("font_color", KIND_COLORS[kind])
	head.add_child(kl)
	var blurb := Label.new()
	blurb.text = {
		"assault": "Enemy infantry is dug in here. Take the majority of the positions.",
		"meeting": "Nobody holds this ground yet. Win the race for it.",
		"defend": "The ground just taken. Break the counterattack.",
		"town": "A village on the line. Hold it street by street.",
	}[kind]
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.add_theme_font_size_override("font_size", 14)
	blurb.add_theme_color_override("font_color", Color(0.68, 0.68, 0.6))
	inner.add_child(blurb)
	var btn := _button("", func() -> void: _fight(o), Vector2.ZERO)
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		btn.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	btn.disabled = men == 0
	card.add_child(btn)
	return card


# --- Right column: roster and purchases ---

func _build_roster() -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -560
	panel.offset_right = -24
	panel.offset_top = 18
	panel.offset_bottom = -18
	_root.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	var head := HBoxContainer.new()
	col.add_child(head)
	var title := Label.new()
	title.text = "PLATOON"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var rp := Label.new()
	rp.text = "%d RP" % Campaign.geti(state, "requisition")
	rp.add_theme_font_size_override("font_size", 22)
	rp.add_theme_color_override("font_color", Color(0.8, 0.9, 0.6))
	head.add_child(rp)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_scroll)
	_scroll.get_v_scroll_bar().custom_minimum_size.x = 14
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	_scroll.add_child(list)
	for entry: Dictionary in state["roster"]:
		list.add_child(_unit_row(entry))
	list.add_child(_support_rows())
	list.add_child(_recruit_rows())


func _unit_row(entry: Dictionary) -> Control:
	var row := PanelContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_stylebox_override("panel", _box(Color(0.08, 0.09, 0.07, 0.9), Color(0.3, 0.33, 0.25)))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	row.add_child(h)
	var nm := Label.new()
	nm.text = String(entry["name"])
	nm.custom_minimum_size.x = 104
	nm.add_theme_font_size_override("font_size", 17)
	h.add_child(nm)
	var vet := Label.new()
	var lvl := Campaign.vet_level(Campaign.geti(entry, "vet"))
	vet.text = String(Defs.VET_NAMES[lvl])
	vet.custom_minimum_size.x = 88
	vet.add_theme_font_size_override("font_size", 13)
	vet.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3) if lvl == 2 else Color(0.7, 0.85, 0.55))
	h.add_child(vet)
	if entry.get("vehicle", false):
		var ok := Label.new()
		ok.text = "READY"
		ok.add_theme_font_size_override("font_size", 13)
		ok.add_theme_color_override("font_color", Color(0.7, 0.85, 0.55))
		h.add_child(ok)
	else:
		# Men as pips: fit (light), wounded out (yellow), empty template slot (dark).
		var men: Array = entry["men"]
		var template: Array = (Defs.UNITS[String(entry["id"])] as Dictionary)["men"]
		var pips := HBoxContainer.new()
		pips.add_theme_constant_override("separation", 3)
		pips.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(pips)
		for man: Dictionary in men:
			var pip := ColorRect.new()
			pip.custom_minimum_size = Vector2(11, 14)
			pip.color = Color(0.8, 0.84, 0.68) if Campaign.geti(man, "out") <= 0 else Color(0.9, 0.7, 0.25)
			pip.tooltip_text = "%s — %s" % [String(man["name"]), "ready" if Campaign.geti(man, "out") <= 0 else "wounded, out %d" % Campaign.geti(man, "out")]
			pips.add_child(pip)
		for k in maxi(0, template.size() - men.size()):
			var pip := ColorRect.new()
			pip.custom_minimum_size = Vector2(11, 14)
			pip.color = Color(0.22, 0.22, 0.19)
			pips.add_child(pip)
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(fill)
	if not entry.get("vehicle", false) and Campaign.missing_weapon(entry) != "":
		var cost := Campaign.geti(Defs.CAMPAIGN, "cost_man")
		var buy := _button("+MAN %dRP" % cost, func() -> void:
			if Campaign.buy_man(state, entry):
				_rebuild(), Vector2(96, 40))
		buy.add_theme_font_size_override("font_size", 14)
		buy.disabled = Campaign.geti(state, "requisition") < cost
		h.add_child(buy)
	if Campaign.can_disband(state):
		var dis: Button = _button("DISBAND", Callable(), Vector2(0, 40))
		dis.pressed.connect(func() -> void: _disband_pressed(entry, dis))
		dis.add_theme_font_size_override("font_size", 13)
		dis.tooltip_text = "Release the unit; refunds %d RP" % Campaign.disband_refund(String(entry["id"]))
		h.add_child(dis)
	return row


## First tap arms the button (SURE? +nRP) for a few seconds, second tap disbands.
func _disband_pressed(entry: Dictionary, btn: Button) -> void:
	if _dragging:
		return
	if _confirm_disband == btn:
		if Campaign.disband_unit(state, entry):
			_rebuild()
		return
	_cancel_disband()
	_confirm_disband = btn
	btn.text = "SURE? +%dRP" % Campaign.disband_refund(String(entry["id"]))
	btn.add_theme_color_override("font_color", Color(1.0, 0.6, 0.4))
	get_tree().create_timer(3.0).timeout.connect(func() -> void:
		if _confirm_disband == btn:
			_cancel_disband())


func _cancel_disband() -> void:
	if _confirm_disband != null and is_instance_valid(_confirm_disband):
		_confirm_disband.text = "DISBAND"
		_confirm_disband.remove_theme_color_override("font_color")
	_confirm_disband = null


func _support_rows() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	var head := Label.new()
	head.text = "SUPPORT STOCK — campaign ammunition"
	head.add_theme_font_size_override("font_size", 15)
	head.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	col.add_child(head)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	for kind: String in ["mortar", "fpv", "bomber"]:
		var cost := Campaign.geti(Defs.CAMPAIGN["cost_support"], kind)
		var have := Campaign.geti(state["support"], kind)
		var b := _button("%s %d  +1 (%dRP)" % [kind.to_upper(), have, cost], func() -> void:
			if Campaign.buy_support(state, kind):
				_rebuild(), Vector2(150, 44))
		b.add_theme_font_size_override("font_size", 14)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = Campaign.geti(state, "requisition") < cost
		row.add_child(b)
	return col


func _recruit_rows() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	var head := Label.new()
	head.text = "REINFORCEMENTS — green units"
	head.add_theme_font_size_override("font_size", 15)
	head.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	col.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 8)
	col.add_child(grid)
	for id: String in Defs.CAMPAIGN["cost_unit"]:
		var cost := Campaign.geti(Defs.CAMPAIGN["cost_unit"], id)
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 2)
		grid.add_child(cell)
		var b := _button("%s  %dRP" % [String((Defs.UNITS[id] as Dictionary)["name"]).to_upper(), cost], func() -> void:
			if Campaign.buy_unit(state, id):
				_rebuild(), Vector2(166, 44))
		b.add_theme_font_size_override("font_size", 14)
		b.disabled = Campaign.geti(state, "requisition") < cost
		cell.add_child(b)
		var hint := Label.new()
		hint.text = _role_hint(id)
		hint.add_theme_font_size_override("font_size", 12)
		hint.add_theme_color_override("font_color", Color(0.62, 0.62, 0.55))
		cell.add_child(hint)
	var note := Label.new()
	note.text = "Disbanding a unit refunds half its price; replacements bought into it are not refunded."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.45))
	col.add_child(note)
	return col


## One line under each recruit button: strength and what the unit is for.
func _role_hint(id: String) -> String:
	var def: Dictionary = Defs.UNITS[id]
	if def.get("vehicle", false):
		return "IFV · autocannon, TOW"
	var n: int = (def["men"] as Array).size()
	var role: String = {
		"ua_rifle": "assault, RPG",
		"ua_mg": "suppression",
		"ua_atgm": "anti-armour",
		"ua_sniper": "spotting, long range",
		"ua_drone": "recon from above",
	}.get(id, "infantry")
	return "%d men · %s" % [n, role]


# --- Overlays ---

func _show_memorial() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	var title := Label.new()
	title.text = "THE FALLEN"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.95, 0.94, 0.85))
	col.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for m: Dictionary in state["memorial"]:
		var l := Label.new()
		l.text = "%s   —   %s, %s" % [String(m["name"]), String(m["unit"]), String(m["battle"])]
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color", Color(0.8, 0.8, 0.72))
		list.add_child(l)
	var close := _button("CLOSE", func() -> void: dim.queue_free(), Vector2(160, 50), "cancel")
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(close)


## Operation over: the result, the cost, and the way to a fresh start.
func _build_terminal() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)
	var won: bool = state.get("won", false)
	var title := Label.new()
	title.text = "OPERATION COMPLETE" if won else "OPERATION FAILED"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0) if won else Color(1.0, 0.4, 0.3))
	col.add_child(title)
	var text := Label.new()
	var fallen: Array = state["memorial"]
	text.text = ("Operation %s is over: the objective is taken after %d battles." if won
			else "Operation %s ends after %d battles: the platoon can no longer fight.") % [
			String(state["op_name"]).capitalize(), Campaign.geti(state, "battle_n")]
	text.text += "\n%d men did not come home." % fallen.size() if not fallen.is_empty() else "\nEvery man came home."
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size.x = 480
	col.add_child(text)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 10)
	btns.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(btns)
	if not fallen.is_empty():
		btns.add_child(_button("THE FALLEN", _show_memorial, Vector2(170, 56)))
	btns.add_child(_button("NEW OPERATION", _new_operation, Vector2(210, 56), "fast"))
	btns.add_child(_button("MENU", _to_menu, Vector2(130, 56), "menu"))


# --- Actions ---

func _fight(o: Dictionary) -> void:
	if _dragging:
		return
	Campaign.launch(state, o)
	Game.next_kind = String(o["kind"])
	Game.next_seed = int(o["seed"])
	Game.scenario = {}
	Game.show_campaign = false
	Game.show_menu = false
	get_tree().reload_current_scene()


## Mid-run NEW OPERATION asks for a second tap; it throws the whole run away.
func _new_operation_pressed() -> void:
	if state.get("won", false) or state.get("lost", false) or _confirm_new:
		_new_operation()
		return
	_confirm_new = true
	var b := _root.find_child("NewOp", true, false)
	if b is Button:
		(b as Button).text = "SURE? TAP AGAIN"


func _new_operation() -> void:
	Campaign.delete_save()
	state = Campaign.generate(randi() % 1000000)
	Game.campaign = state
	Campaign.save_state(state)
	_rebuild()


func _to_menu() -> void:
	Game.show_campaign = false
	Game.show_menu = true
	get_tree().reload_current_scene()


# --- Touch-drag scrolling (same pattern as the start menu) ---

func _input(event: InputEvent) -> void:
	if _scroll == null:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed and _drag_id == -1:
			if _scroll.get_global_rect().has_point(t.position):
				_begin_drag(t.index)
			else:
				_dragging = false
		elif not t.pressed and t.index == _drag_id:
			_drag_id = -1
	elif event is InputEventScreenDrag and (event as InputEventScreenDrag).index == _drag_id:
		_apply_drag((event as InputEventScreenDrag).relative.y)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _scroll.get_global_rect().has_point(mb.position):
					_begin_drag(-2)
					_mouse_down = true
				else:
					_dragging = false
			else:
				_mouse_down = false
				_drag_id = -1
	elif event is InputEventMouseMotion and _mouse_down:
		_apply_drag((event as InputEventMouseMotion).relative.y)


func _begin_drag(id: int) -> void:
	_drag_id = id
	_drag_accum = 0.0
	_dragging = false


func _apply_drag(dy: float) -> void:
	_drag_accum += dy
	if not _dragging and absf(_drag_accum) > 10.0:
		_dragging = true
	if _dragging:
		_scroll.scroll_vertical -= int(dy)


# --- Styling (matches the start menu look) ---

func _button(text: String, cb: Callable, min_size: Vector2, icon := "") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	if cb.is_valid():
		# A touch that scrolled the list must not also fire the button it ended on.
		b.pressed.connect(func() -> void:
			if not _dragging:
				cb.call())
	if icon != "":
		b.icon = UiIcons.tex(icon)
	return b


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 13
	sb.content_margin_right = 13
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	sb.shadow_size = 4
	sb.shadow_offset = Vector2(0, 2)
	return sb


func _make_theme() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Avenir Next Condensed", "Arial Narrow", "Roboto Condensed", "sans-serif-condensed"])
	font.font_weight = 600
	t.default_font = font
	t.default_font_size = 18
	t.set_stylebox("normal", "Button", _box(Color(0.09, 0.1, 0.08, 0.94), Color(0.34, 0.37, 0.27)))
	t.set_stylebox("hover", "Button", _box(Color(0.14, 0.16, 0.11, 0.96), Color(0.55, 0.58, 0.42)))
	var pressed := _box(Color(0.24, 0.26, 0.15, 0.97), Color(0.95, 0.85, 0.35))
	pressed.set_border_width_all(2)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", _box(Color(0.07, 0.07, 0.06, 0.55), Color(0.2, 0.2, 0.18)))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.93, 0.93, 0.85))
	t.set_color("font_hover_color", "Button", Color(1.0, 1.0, 0.95))
	t.set_color("font_pressed_color", "Button", Color(1.0, 0.9, 0.4))
	t.set_color("font_disabled_color", "Button", Color(0.45, 0.45, 0.4))
	t.set_color("icon_normal_color", "Button", Color(0.78, 0.8, 0.66))
	t.set_color("icon_hover_color", "Button", Color(0.95, 0.96, 0.85))
	t.set_color("icon_pressed_color", "Button", Color(1.0, 0.9, 0.4))
	t.set_constant("h_separation", "Button", 8)
	t.set_stylebox("panel", "PanelContainer", _box(Color(0.055, 0.065, 0.05, 0.82), Color(0.28, 0.31, 0.23)))
	t.set_color("font_color", "Label", Color(0.92, 0.92, 0.84))
	return t
