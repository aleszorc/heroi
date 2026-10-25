class_name UiIcons
extends RefCounted
## Procedural UI icons: small white SVG glyphs rasterized at startup and tinted by the
## button theme, so the HUD needs no image assets.

## SVGs are authored at 24 px and rendered at 2x for crisp phone DPI.
const SCALE := 2.0

const _HEAD := '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">'

const ICONS := {
	"move": '<path d="M5 19 L17 7 M17 7 H10.5 M17 7 V13.5"/>',
	"fast": '<path d="M5 5 l7 7 -7 7 M13 5 l7 7 -7 7"/>',
	"sneak": '<circle cx="17.5" cy="9" r="2.2" fill="#fff" stroke="none"/><path d="M3 17.5 Q9 11 14.5 12.5 L18 13.5 M8 15 L5 20 M13 13 L13.5 19"/>',
	"fire": '<circle cx="12" cy="12" r="6"/><path d="M12 2.5 V6 M12 18 V21.5 M2.5 12 H6 M18 12 H21.5"/><circle cx="12" cy="12" r="1.5" fill="#fff" stroke="none"/>',
	"smoke": '<path d="M7 17 a3.5 3.5 0 0 1 -0.5 -6.9 a5 5 0 0 1 9.6 -1.1 a4 4 0 0 1 1.4 7.8 z" fill="#fff" stroke="none"/>',
	"defend": '<path d="M12 3 L19 5.8 V11.5 C19 16.5 12 20.5 12 20.5 C12 20.5 5 16.5 5 11.5 V5.8 Z"/>',
	"ambush": '<path d="M2.5 12 Q12 4.5 21.5 12 Q12 19.5 2.5 12 Z"/><circle cx="12" cy="12" r="2.6" fill="#fff" stroke="none"/>',
	"stop": '<rect x="7" y="7" width="10" height="10" fill="#fff" stroke="none"/>',
	"mortar": '<path d="M7 20 L15 5.5" stroke-width="3.8"/><path d="M12 11.5 L17.5 20"/><path d="M3.5 21 H13.5"/>',
	"recon": '<path d="M7 7 L17 17 M17 7 L7 17"/><circle cx="5.5" cy="5.5" r="3"/><circle cx="18.5" cy="5.5" r="3"/><circle cx="5.5" cy="18.5" r="3"/><circle cx="18.5" cy="18.5" r="3"/><rect x="10" y="10" width="4" height="4" fill="#fff" stroke="none"/>',
	"fpv": '<path d="M4.5 8.5 H19.5"/><path d="M6.5 8.5 V5.5 M17.5 8.5 V5.5"/><path d="M3.5 5.5 H9.5 M14.5 5.5 H20.5"/><rect x="10.2" y="6.7" width="3.6" height="3.6" fill="#fff" stroke="none"/><path d="M12 11.5 L9.6 13.4 12 19.8 14.4 13.4 Z" fill="#fff" stroke="none"/>',
	"pause": '<rect x="7.5" y="6" width="3.2" height="12" fill="#fff" stroke="none"/><rect x="13.3" y="6" width="3.2" height="12" fill="#fff" stroke="none"/>',
	"play": '<path d="M8.5 5.5 L18.5 12 L8.5 18.5 Z" fill="#fff" stroke="none"/>',
	"rot_l": '<path d="M6.5 7 A7.5 7.5 0 1 0 12 4.5"/><path d="M12 1.5 L9 4.7 L12.4 7.5"/>',
	"rot_r": '<path d="M17.5 7 A7.5 7.5 0 1 1 12 4.5"/><path d="M12 1.5 L15 4.7 L11.6 7.5"/>',
	"inf": '<circle cx="12" cy="5.5" r="2.4" fill="#fff" stroke="none"/><path d="M12 8.5 V14 M12 10.5 L7.5 12.5 M12 10.5 L16.5 12.5 M12 14 L9 20 M12 14 L15 20"/>',
	"veh": '<path d="M4 14.5 H20 L18 18.5 H6 Z" fill="#fff" stroke="none"/><rect x="9" y="9.5" width="6.5" height="4" fill="#fff" stroke="none"/><path d="M15.5 11 H22"/>',
	"cancel": '<path d="M6.5 6.5 L17.5 17.5 M17.5 6.5 L6.5 17.5"/>',
}

static var _cache := {}


static func tex(icon_name: String) -> Texture2D:
	if _cache.has(icon_name):
		return _cache[icon_name]
	var img := Image.new()
	var svg: String = _HEAD + String(ICONS.get(icon_name, ICONS["stop"])) + "</svg>"
	var t: Texture2D
	if img.load_svg_from_string(svg, SCALE) == OK:
		t = ImageTexture.create_from_image(img)
	else:
		t = PlaceholderTexture2D.new()
	_cache[icon_name] = t
	return t
