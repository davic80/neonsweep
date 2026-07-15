# 🧹 NeonSweep

> A retro neon-terminal Mac cleaner. Free, open source, no telemetry, nothing deleted without asking.

**NeonSweep** is a native macOS app (Swift + SwiftUI, official Apple APIs only) inspired by CleanMyMac and Gemini 2, with a black / grey / neon-green terminal aesthetic. English & Spanish.

*Limpiador de Mac nativo con estética retro-terminal neón. Gratis, open source, sin telemetría, y nada se borra sin confirmar. Interfaz en español e inglés.*

## Modules / Módulos

| # | Module | What it does |
|---|--------|--------------|
| 01 | **DASHBOARD** | Disk usage incl. **purgeable** space Finder hides, iCloud quota (`brctl`), reclaimable-space targets |
| 02 | **UNINSTALLER** | Pick an app, see every leftover it dropped in `~/Library` (bundle-ID matching, 12 locations), move it all to Trash |
| 03 | **SYSTEM JUNK** | User caches, logs, iOS backups (with device name & date), old installers, saved app state |
| 04 | **DEV JUNK** | Xcode DerivedData & DeviceSupport, simulators, Docker/Colima/OrbStack, 11 package-manager caches, forgotten `node_modules` |
| 05 | **PHOTOS** | Duplicate & similar photo groups (Vision feature prints), plus the killer feature: **recompress huge videos → HEVC** and **convert RAW → HEIC** with the original kept 30 days in Recently Deleted |

## Safety model / Modelo de seguridad

- Nothing is preselected aggressively; **you** check what goes.
- Everything goes to the **macOS Trash** (restorable from Finder) or to Photos' **Recently Deleted** (30 days).
- Emptying the Trash is the only irreversible action — amber-coloured, double-confirmed, done via Finder (Apple Events).
- Reclaimed-space counters distinguish *"→ trash"* (recoverable) from *"cleaned"* (truly freed).
- Official Apple APIs only: FileManager, NSWorkspace, PhotoKit, Vision, AVFoundation, Core Image.

## Build

Requires macOS 15+ and Swift 6 (Command Line Tools are enough — no Xcode needed):

```sh
./build-app.sh          # → build/NeonSweep.app
open build/NeonSweep.app
```

Dev loop: `swift build && swift run`.

## Permissions / Permisos

macOS will ask as features are used: folder access (TCC), Automation → Finder (empty Trash), Photos library (module 05). For full leftover coverage, grant **Full Disk Access** in System Settings.

## License

[MIT](LICENSE) — © 2026 David Cornejo
