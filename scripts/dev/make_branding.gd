extends SceneTree
## Generates the app branding PNGs (app icon + boot splash) into assets/branding/.
## Headless-safe: letterforms are drawn as flat axis-aligned rects straight into an
## Image (no viewport, no font), matching the game's flat-shaded geometric art.
## Run: godot --headless --path . --script scripts/dev/make_branding.gd

const OUT_DIR := "res://assets/branding"

## Palette — sober military tones, UA yellow only as the small accent on Ї's dots.
const OLIVE_BG := Color("39402e")       # icon field
const SPLASH_BG := Color("14180f")      # splash background (mirrored in boot_splash/bg_color)
const SAND := Color("e3d9b0")           # primary wordmark / glyph colour
const ACCENT := Color("f2c94c")         # UA yellow, Ї dots only
const MUTED := Color("8a8f7a")          # secondary latin wordmark

## Blocky stencil letterforms on a 7-unit cap height; each rect is [x, y, w, h]
## in grid units from the letter's cap-top-left. Ї's dots are drawn separately
## so they can take the accent colour.
const LETTERS := {
	"Г": [[0, 0, 1.2, 7], [0, 0, 5, 1.2]],
	"Е": [[0, 0, 1.2, 7], [0, 0, 5, 1.2], [0, 2.9, 4, 1.2], [0, 5.8, 5, 1.2]],
	"Р": [[0, 0, 1.2, 7], [0, 0, 5, 1.2], [3.8, 0, 1.2, 4.4], [0, 3.2, 5, 1.2]],
	"О": [[0, 0, 1.2, 7], [3.8, 0, 1.2, 7], [0, 0, 5, 1.2], [0, 5.8, 5, 1.2]],
	"Ї": [[0, 0, 4, 1.2], [1.4, 0, 1.2, 7], [0, 5.8, 4, 1.2]],
	"H": [[0, 0, 1.2, 7], [3.8, 0, 1.2, 7], [0, 2.9, 5, 1.2]],
	"E": [[0, 0, 1.2, 7], [0, 0, 5, 1.2], [0, 2.9, 4, 1.2], [0, 5.8, 5, 1.2]],
	"O": [[0, 0, 1.2, 7], [3.8, 0, 1.2, 7], [0, 0, 5, 1.2], [0, 5.8, 5, 1.2]],
	"R": [[0, 0, 1.2, 7], [0, 0, 5, 1.2], [3.8, 0, 1.2, 4.4], [0, 3.2, 5, 1.2],
		[2.6, 4.4, 1.2, 1.4], [3.8, 5.2, 1.2, 1.8]],
	"I": [[0, 0, 4, 1.2], [1.4, 0, 1.2, 7], [0, 5.8, 4, 1.2]],
}
const WIDTHS := {
	"Г": 5.0, "Е": 5.0, "Р": 5.0, "О": 5.0, "Ї": 4.0,
	"H": 5.0, "E": 5.0, "R": 5.0, "O": 5.0, "I": 4.0,
}
const DOTS := [[0.3, -1.9, 1.1, 1.1], [2.6, -1.9, 1.1, 1.1]]  # Ї diaeresis, above cap line
const GAP := 1.5  # inter-letter gap in grid units


func _init() -> void:
	DirAccess.open("res://").make_dir_recursive(OUT_DIR.trim_prefix("res://"))
	_make_icon()
	_make_splash()
	_verify()
	quit()


## Flat olive field with a large sand Ї, UA-yellow dots. Glyph kept inside the
## centre ~60% so Android's round/squircle masks never clip it.
func _make_icon() -> void:
	var img := Image.create(1024, 1024, false, Image.FORMAT_RGBA8)
	img.fill(OLIVE_BG)
	var u := 61.0
	var w := WIDTHS["Ї"] * u
	var h := 8.9 * u  # 7 cap + 1.9 dots
	var x := (1024.0 - w) / 2.0
	var y := (1024.0 - h) / 2.0 + 1.9 * u
	_draw_letter(img, "Ї", x, y, u, SAND)
	for d in DOTS:
		_fill(img, x, y, u, d, ACCENT)
	img.save_png(OUT_DIR + "/icon.png")


## 1920x1080 dark splash: ГЕРОЇ large in sand, thin rule, HEROI small in muted grey.
func _make_splash() -> void:
	var img := Image.create(1920, 1080, false, Image.FORMAT_RGBA8)
	img.fill(SPLASH_BG)
	var u := 38.0
	var word := "ГЕРОЇ"
	var x := (1920.0 - _word_width(word, u)) / 2.0
	var y := 360.0
	_draw_word(img, word, x, y, u, SAND, ACCENT)
	var rule_w := 260
	img.fill_rect(Rect2i(int((1920 - rule_w) / 2.0), int(y + 7.0 * u + 52.0), rule_w, 4), MUTED)
	var u2 := 13.0
	var sub := "HEROI"
	var x2 := (1920.0 - _word_width(sub, u2)) / 2.0
	_draw_word(img, sub, x2, y + 7.0 * u + 92.0, u2, MUTED, MUTED)
	img.save_png(OUT_DIR + "/splash.png")


func _word_width(word: String, u: float) -> float:
	var w := 0.0
	for i in word.length():
		w += WIDTHS[word[i]] * u
		if i < word.length() - 1:
			w += GAP * u
	return w


func _draw_word(img: Image, word: String, x: float, y: float, u: float, col: Color, accent: Color) -> void:
	for i in word.length():
		var ch := word[i]
		_draw_letter(img, ch, x, y, u, col)
		if ch == "Ї":
			for d in DOTS:
				_fill(img, x, y, u, d, accent)
		x += (WIDTHS[ch] + GAP) * u


func _draw_letter(img: Image, ch: String, x: float, y: float, u: float, col: Color) -> void:
	for r in LETTERS[ch]:
		_fill(img, x, y, u, r, col)


## Rect in grid units -> pixel rect, edges rounded from absolute positions so
## adjoining bars never leave seams.
func _fill(img: Image, x: float, y: float, u: float, r: Array, col: Color) -> void:
	var x0 := roundi(x + r[0] * u)
	var y0 := roundi(y + r[1] * u)
	var x1 := roundi(x + (r[0] + r[2]) * u)
	var y1 := roundi(y + (r[1] + r[3]) * u)
	img.fill_rect(Rect2i(x0, y0, x1 - x0, y1 - y0), col)


## Reload the saved PNGs and sample pixels to prove they are non-blank.
func _verify() -> void:
	for name: String in ["icon.png", "splash.png"]:
		var path := OUT_DIR + "/" + name
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img == null:
			push_error("branding: failed to reload " + path)
			continue
		var c := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
		var corner := img.get_pixel(4, 4)
		print("branding: %s %dx%d centre=%s corner=%s" % [name, img.get_width(), img.get_height(), c, corner])
