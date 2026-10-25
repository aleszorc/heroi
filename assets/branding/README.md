# Branding assets

`icon.png` (1024×1024 app icon) and `splash.png` (1920×1080 boot splash) are
**generated** — do not edit them by hand. Regenerate with:

```sh
godot --headless --path . --script scripts/dev/make_branding.gd
```

Design lives in `scripts/dev/make_branding.gd`: flat vertex-colour palette,
blocky stencil letterforms drawn as rects (headless-safe, no font dependency).
