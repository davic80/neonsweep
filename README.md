# 🧹 NeonSweep

> A retro neon-terminal Mac cleaner. Free, open source, no telemetry, nothing deleted without asking.

**NeonSweep** is a native macOS app (Swift + SwiftUI, official Apple APIs only) inspired by CleanMyMac and Gemini 2, with a black / grey / neon-green terminal aesthetic. English & Spanish.

*Limpiador de Mac nativo con estética retro-terminal neón. Gratis, open source, sin telemetría, y nada se borra sin confirmar. Interfaz en español e inglés.*

## Modules / Módulos

| # | Module | What it does |
|---|--------|--------------|
| 01 | **DASHBOARD** | Disk usage incl. **purgeable** space Finder hides, iCloud quota (`brctl`), reclaimable-space targets |
| 02 | **UNINSTALLER** | Pick an app, see every leftover it dropped in `~/Library` (bundle-ID matching, 12 locations), move it all to Trash. Also finds **orphaned leftovers** from apps you deleted long ago (reverse vendor-prefix matching) and system-level (`/Library`) leftovers, deletable via a single admin authorization |
| 03 | **SYSTEM JUNK** | User caches, logs, iOS backups (with device name & date), old installers, saved app state |
| 04 | **DEV JUNK** | Xcode DerivedData & DeviceSupport, simulators, Docker/Colima/OrbStack, 15 package-manager caches, `node_modules`/venvs of projects untouched for 15–365 days (you pick) |
| 05 | **PHOTOS** | Duplicate & similar groups (Vision feature prints, 3 tiers, user-pickable BEST), plus the killer feature: **RAW → HEIC** (parallel, ~92% savings, EXIF intact) and **video → HEVC** with optimal/max profiles. Incremental analysis with resume checkpoints; import → verify → delete safety flow |
| 06 | **UPDATES** | Pending Homebrew formulae/casks and App Store updates (via `mas`), upgradeable per package or all at once |
| 07 | **ICLOUD DUPES** | Exact file duplicates in iCloud Drive via streaming SHA-256 (size pre-grouping, not-downloaded files skipped) — keeps the shortest path per group |

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

Dev loop: `swift build && swift run`. Tests: `swift test`. Open a specific module directly (handy for demos): `swift run NeonSweep -- --module photos`.

### Command line

There is a report mode, and only a report mode:

```sh
/Applications/NeonSweep.app/Contents/MacOS/NeonSweep --report          # human readable
/Applications/NeonSweep.app/Contents/MacOS/NeonSweep --report --json   # for scripts
```

It prints disk usage and reclaimable space per category, then exits. **It never deletes anything.** There is no `--clean` flag and there won't be one: every module here is built around looking at the list before agreeing to it, and a cleaner that empties folders unattended from a cron job is exactly the kind of tool that breaks Macs. Use `--report` to watch, open the app to act.

`--bench-video <file> [seconds]` measures the video transcoder against a loose file — never the photo library, where converting deletes the original. It reports decode-only cost, speed-priority encoding and N concurrent jobs, and is how the "parallel does not help" claim below was established.

### Homebrew

```sh
brew tap davic80/neonsweep
brew install --cask neonsweep
```

## Permissions / Permisos

macOS will ask as features are used: folder access (TCC), Automation → Finder (empty Trash), Photos library (module 05). For full leftover coverage, grant **Full Disk Access** in System Settings.

## License

[MIT](LICENSE) — © 2026 David Cornejo
