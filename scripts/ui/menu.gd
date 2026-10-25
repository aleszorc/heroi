class_name MainMenu
extends CanvasLayer
## Start menu: the wordmark, the curated scenario list and a random-battle entry,
## drawn over a unit-less backdrop map built by main.gd. Picking an entry stores
## the choice in the Game autoload and reloads the scene into deployment.

const KINDS := ["assault", "defend", "meeting"]
const KIND_LABELS := {"treeline": "DEFEND", "defend": "DEFEND", "assault": "ASSAULT", "meeting": "MEETING"}
const DRAG_THRESHOLD := 10.0

var _scroll: ScrollContainer
var _drag_id := -1
var _drag_accum := 0.0
var _dragging := false
var _mouse_down := false


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = _make_theme()
	add_child(root)
	# Scrim so the menu text reads over the backdrop map.
	var scrim := ColorRect.new()
	scrim.color = Color(0.03, 0.04, 0.03, 0.45)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(scrim)
	_build_left(root)
	_build_scenarios(root)
	_build_dedication(root)


# --- Layout ---

## Left column: wordmark, random battle and quit.
func _build_left(root: Control) -> void:
	var col := VBoxContainer.new()
	col.anchor_top = 0.5
	col.anchor_bottom = 0.5
	col.offset_left = 48
	col.offset_top = -190
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	col.add_theme_constant_override("separation", 10)
	root.add_child(col)
	# Godot's default font covers Cyrillic (incl. Ї); the condensed theme face may not.
	var mark := Label.new()
	mark.text = "ГЕРОЇ"
	mark.add_theme_font_override("font", ThemeDB.fallback_font)
	mark.add_theme_font_size_override("font_size", 84)
	mark.add_theme_color_override("font_color", Color(0.95, 0.93, 0.8))
	mark.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	mark.add_theme_constant_override("outline_size", 10)
	col.add_child(mark)
	var sub := Label.new()
	sub.text = "H E R O I"
	sub.add_theme_font_size_override("font_size", 20)
	sub.add_theme_color_override("font_color", Color(0.62, 0.66, 0.55))
	# Tuck the latinisation up against the wordmark (the big font carries tall metrics).
	var tuck := Control.new()
	tuck.custom_minimum_size.y = 24
	tuck.add_child(sub)
	sub.position.y = -18
	col.add_child(tuck)
	col.add_child(_spacer(26))
	var camp := _button("CAMPAIGN" if Campaign.load_state().is_empty() else "CONTINUE CAMPAIGN", _campaign, Vector2(300, 66), "play")
	col.add_child(camp)
	var camp_hint := Label.new()
	camp_hint.text = "One operation, one platoon. Losses,\nveterans and supplies carry over."
	camp_hint.add_theme_font_size_override("font_size", 14)
	camp_hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.53))
	col.add_child(camp_hint)
	col.add_child(_spacer(12))
	var random := _button("RANDOM BATTLE", _random_battle, Vector2(300, 66), "fast")
	col.add_child(random)
	var hint := Label.new()
	hint.text = "Random map and mission. The kind and\nseed show on the deployment screen."
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.53))
	col.add_child(hint)
	col.add_child(_spacer(18))
	var quit := _button("QUIT", func() -> void: get_tree().quit(), Vector2(300, 54), "cancel")
	col.add_child(quit)


## Right column: the curated scenario list, scrollable on small screens.
func _build_scenarios(root: Control) -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -560
	panel.offset_right = -24
	panel.offset_top = 24
	panel.offset_bottom = -24
	root.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	var head := Label.new()
	head.text = "SCENARIOS"
	head.add_theme_font_size_override("font_size", 22)
	head.add_theme_color_override("font_color", Color(1.0, 0.86, 0.3))
	col.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	_scroll = scroll
	scroll.get_v_scroll_bar().custom_minimum_size.x = 14
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)
	for s: Dictionary in Scenarios.ALL:
		list.add_child(_scenario_card(s))


## A card sizes itself to its text (PanelContainer drives the height); a transparent
## full-rect button on top handles the tap and the hover/pressed feedback.
func _scenario_card(s: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size.y = 76.0
	card.add_theme_stylebox_override("panel", _box(Color(0.09, 0.1, 0.08, 0.94), Color(0.34, 0.37, 0.27)))
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 3)
	card.add_child(inner)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	inner.add_child(head)
	var nm := Label.new()
	nm.text = String(s["name"]).to_upper()
	nm.add_theme_font_size_override("font_size", 21)
	nm.add_theme_color_override("font_color", Color(0.95, 0.94, 0.85))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(nm)
	var kind := Label.new()
	kind.text = String(KIND_LABELS.get(s["kind"], "BATTLE"))
	kind.add_theme_font_size_override("font_size", 14)
	kind.add_theme_color_override("font_color", Color(0.55, 0.75, 0.95) if s["kind"] in ["defend", "treeline"] else (Color(1.0, 0.72, 0.4) if s["kind"] == "assault" else Color(0.7, 0.9, 0.55)))
	head.add_child(kind)
	var brief := Label.new()
	brief.text = String(s["briefing"])
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	brief.add_theme_font_size_override("font_size", 14)
	brief.add_theme_color_override("font_color", Color(0.68, 0.68, 0.6))
	inner.add_child(brief)
	var btn := _button("", func() -> void: _start(String(s["kind"]), int(s["seed"]), s), Vector2.ZERO)
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		btn.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	card.add_child(btn)
	return card


## Bottom-left footer: a small Ukrainian flag and the dedication line.
func _build_dedication(root: Control) -> void:
	var row := HBoxContainer.new()
	row.anchor_top = 1.0
	row.anchor_bottom = 1.0
	row.offset_left = 48
	row.offset_top = -46
	row.offset_bottom = -20
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	root.add_child(row)
	var flag := VBoxContainer.new()
	flag.add_theme_constant_override("separation", 0)
	flag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var blue := ColorRect.new()
	blue.color = Color(0.0, 0.34, 0.72)
	blue.custom_minimum_size = Vector2(30, 10)
	flag.add_child(blue)
	var yellow := ColorRect.new()
	yellow.color = Color(1.0, 0.84, 0.0)
	yellow.custom_minimum_size = Vector2(30, 10)
	flag.add_child(yellow)
	row.add_child(flag)
	var txt := Label.new()
	txt.text = "Dedicated to the Ukrainian heroes."
	txt.add_theme_font_size_override("font_size", 15)
	txt.add_theme_color_override("font_color", Color(0.78, 0.78, 0.68))
	txt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	txt.add_theme_constant_override("outline_size", 4)
	txt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(txt)


# --- Touch-drag scrolling ---
# The cards are buttons, so they swallow touch events before the ScrollContainer
# sees them; dragging is handled here instead. A tap that moved past the threshold
# scrolls the list and does not launch its card.

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
	if not _dragging and absf(_drag_accum) > DRAG_THRESHOLD:
		_dragging = true
	if _dragging:
		_scroll.scroll_vertical -= int(dy)


# --- Actions ---

func _start(kind: String, mission_seed: int, scen: Dictionary) -> void:
	if _dragging:
		return
	Game.next_kind = kind
	Game.next_seed = mission_seed
	Game.scenario = scen
	Game.show_menu = false
	get_tree().reload_current_scene()


func _random_battle() -> void:
	_start(KINDS[randi() % KINDS.size()], -1, {})


func _campaign() -> void:
	if _dragging:
		return
	Game.show_menu = false
	Game.show_campaign = true
	get_tree().reload_current_scene()


# --- Styling (matches the HUD look) ---

func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = h
	return c


func _button(text: String, cb: Callable, min_size: Vector2, icon := "") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
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
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.93, 0.93, 0.85))
	t.set_color("font_hover_color", "Button", Color(1.0, 1.0, 0.95))
	t.set_color("font_pressed_color", "Button", Color(1.0, 0.9, 0.4))
	t.set_color("icon_normal_color", "Button", Color(0.78, 0.8, 0.66))
	t.set_color("icon_hover_color", "Button", Color(0.95, 0.96, 0.85))
	t.set_color("icon_pressed_color", "Button", Color(1.0, 0.9, 0.4))
	t.set_constant("h_separation", "Button", 8)
	t.set_stylebox("panel", "PanelContainer", _box(Color(0.055, 0.065, 0.05, 0.82), Color(0.28, 0.31, 0.23)))
	t.set_color("font_color", "Label", Color(0.92, 0.92, 0.84))
	return t
