# Heroi (ГЕРОЇ)

Mobile isometric real-time tactics set in the Russo-Ukrainian war. Godot 4.7.

- Design: [docs/GDD.md](docs/GDD.md)
- Play on desktop: `godot --path .` (mouse = touch, wheel zoom, WASD pan, Q/E rotate, Esc options)
- Open in the editor: `godot -e --path .`
- Headless full-battle test: `godot --headless --path . --fixed-fps 30 --quit-after 6000 -- autostart fast log`

## Install on Android

Build the debug APK (one command):

```sh
godot --headless --path . --export-debug "Android" build/heroi.apk
```

Then install it on the phone, either way:

- **USB (adb):** enable USB debugging on the phone, connect it, run `adb install build/heroi.apk`.
- **No cable:** AirDrop/copy `build/heroi.apk` to the phone and open it there (allow installs from unknown sources when prompted).

Notes: the APK is a debug build signed with the standard debug keystore (`~/.android/debug.keystore`), arm64 only. iOS is not covered — it needs Xcode and an Apple developer account.
