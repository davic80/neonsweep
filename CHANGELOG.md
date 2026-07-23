# Changelog

All notable changes to NeonSweep. Format based on [Keep a Changelog](https://keepachangelog.com); versions follow [SemVer](https://semver.org).

## [Unreleased]

### Added
- **Read-only CLI report**: `NeonSweep --report [--json]` prints disk usage and reclaimable space per category and exits. It never deletes anything — deliberately, so it's safe in a cron job or a status bar script. Cleaning stays interactive.
- Duplicate photos: a counter of **favourites excluded from bulk marking**.
- Unused apps: a counter of apps **with no usage data**, which are no longer judged.

### Fixed — false-positive audit
- **Hard links and symlinks counted as duplicates** in file dupes: several names for the same inode reported wasted space that deleting would never recover. One representative per inode now, symlinks skipped, and sizes read as allocated-on-disk. Added a note that APFS clones share storage, so real freed space can be lower than estimated.
- **Favourite photos could be proposed for deletion**: `isFavorite` is now the top criterion for BEST, and favourites are excluded from *mark all* even when they aren't the best of their group.
- **Apps with no Spotlight record were reported as abandoned** (`9999 days unused`). Absence of data is not evidence of disuse — with indexing disabled every app would have been flagged. They're now counted separately and never listed.
- **"Forgotten" node_modules / venvs included live projects**: an active project's `.venv` was listed as junk. They now require the project to be untouched for 60+ days, measured on the project's own files rather than the dependency folder.
- Installers in Downloads no longer claim to be "already installed" — that can't be known. The date is shown and the note says to keep ISOs you use as media.

## [0.5.0] — 2026-07-22

### Added
- **Persistent local code signing** (`scripts/setup-signing.sh`): creates a self-signed *NeonSweep Dev* identity in the keychain and `build-app.sh` uses it when present. The signature stays stable across rebuilds, so macOS stops re-asking for Full Disk Access / Photos permissions (and demanding restarts) after every compile. Ad-hoc signing remains the fallback.
- **Similarity slider** in duplicates: analysis now stores similarity *edges* (photo pairs + distance) instead of fixed groups, so moving the slider (0.10 strict → 0.80 loose) re-groups instantly via union-find with no re-analysis. Persisted and cached.
- **Sort duplicate groups by potential saving** (everything but the BEST), with per-group `↓ size` and an aggregate for the active filter; sort chips for saving / photo count / date.
- **The BEST photo can be deleted**: it's markable like any other member (with an amber `★ marked!` warning) for sets that are entirely junk.

### Changed
- Sidebar settings split into three labelled rows (text / sound / language) and the sidebar width now scales with the text size, so nothing wraps or gets clipped at larger sizes.
- Bigger hit areas on duplicate cells and per-group delete buttons.

### Fixed
- **Uninstaller left services running** (found via a real CleanMyMac uninstall): processes of the same app family are now terminated and their launchd services booted out *before* anything is deleted — previously the root helper survived, recreated its preference/storage files and kept notifying. System bootout is folded into the same admin authorization as the deletion.
- `/Library/PrivilegedHelperTools` (where root helpers live), `/Library/Logs`, `/Library/Extensions` and `/Library/Internet Plug-Ins` added to system scan paths; `~/Library/Preferences/ByHost` and `Autosave Information` to user paths.
- **Family matching**: `com.macpaw.CleanMyMac5` → `com.macpaw.cleanmymac` now also finds leftovers from older versions and helper suffixes, without touching other apps from the same vendor; folder names are normalized so `CleanMyMac_5` matches too.
- **Orphan scan compared vendors instead of apps**: an installed app (The Unarchiver) shielded every leftover from the same vendor (CleanMyMac). It now compares app families.

## [0.4.0] — 2026-07-18

### Added
- **[07] ICLOUD DUPES module**: exact file deduplication in iCloud Drive via streaming SHA-256 (size pre-grouping so only real candidates get hashed); not-downloaded placeholders are skipped and counted separately; shortest path kept per group; deletion frees space locally and in the cloud after sync.
- **Orphaned leftovers scan** in the uninstaller: reverse bundle-ID matching finds `~/Library` entries whose vendor prefix (e.g. `com.acme`) has no currently installed app — conservative by design, never flags `com.apple.*`, nothing preselected.
- **System-level leftovers** (`/Library`): uninstaller now also scans Application Support/Caches/Preferences/LaunchAgents/LaunchDaemons at the system level, tagged `(admin)`, never preselected; deletion goes through a single admin-authorization prompt (`do shell script … with administrator privileges`) since there's no system Trash. Time Machine snapshot deletion also retries via admin privileges when `tmutil` alone is denied.
- **Selectable batch video profile** (optimal / max 1080p) for the big-videos batch button; MAX makes already-HEVC videos checkable too, since downscaling still saves space.
- **Configurable HEIC quality** (85/90/95, persisted) and advanced video bitrate tuning knobs (`video.optimal.pct` / `video.max.pct` via `defaults write`).
- **Stale full-scan reminder**: an amber note appears when the last *full* photo analysis is more than 30 days old, since incremental scans never cross-match new photos against old ones.
- **Keyboard navigation** in the Photos RAW/video lists: arrow keys move a highlighted row, space toggles it, return opens the preview, shift+arrow extends the mark — on top of existing shift-click ranges.
- **`--module <name>` CLI flag** opens NeonSweep directly on a given module (dashboard/uninstaller/systemJunk/devJunk/photos/updates/icloudDupes) — useful for demos and screenshots.
- **Unit test suite** (swift-testing): brew/mas output parsers, orphan vendor-prefix matching, admin shell-quoting, file-dupe-group keep logic, streaming SHA-256, video-twin size threshold. Caught and fixed a real bug: a greedy regex in `parseMas` left a trailing space in the installed-version string. CI runs the suite on every push.

## [0.3.0] — 2026-07-18

### Added
- **[06] UPDATES module**: Homebrew formulae/casks (`brew outdated --json`) and App Store (via `mas` when installed) with per-package and upgrade-all actions.
- **Incremental photo analysis** via Photos' persistent change history: *Update analysis* only processes what changed; results stay visible and selectable while any scan runs. **Checkpoints** every 2500 images: killed mid-scan, the app resumes where it stopped and reuses cached metadata (read phase drops from minutes to seconds).
- **Bitrate-controlled video transcoder** (AVAssetReader/Writer): OPTIMAL (same resolution, ~45% source bitrate) and MAX (1080p, 4-10 Mbps) profiles; click a video's filename for a per-video sheet with estimated savings. Audio passthrough, orientation preserved, real per-frame progress.
- **Three-step optimization commit**: import → verify (dimensions of every new asset) → delete originals with a single system confirmation. Worst case is duplicates, never data loss.
- **Parallel RAW conversion** scaled to any Apple Silicon (cores + RAM aware, 2-12 workers; measured 291 RAWs/min on an M5). Pause/resume mid-batch and stop-and-import controls. `raw.workers` override + performance profiling flag ([dbg] on the version line) with per-phase timings.
- **Duplicate tiers** (exact / near / similar) with filter chips, per-group delete, whole-set delete (including best), bulk mark per tier, and a user-selectable BEST (☆) chosen by GPS > oldest real date (epoch-corrupt dates excluded) > resolution > size, with per-thumb metadata visible.
- **Preview** (click thumbnails / double-click dupe cells): high-res image or playable video, Esc to close.
- **Video twin detection** (same duration/resolution/size) flagged DUPE? with an explicit delete toggle.
- **Retro effects**: startup cursor-bar sweep, synthesized square-wave sounds (boot arpeggio, clicks, deletion glide, completion chime, error buzz) with a persisted mute toggle.
- **Purgeable panel** on the dashboard: lists and deletes Time Machine local snapshots, measuring truly-freed space.
- **Permissions panel** (Full Disk / Automation / Photos) with live status, auto-collapsed to one line when all granted.
- **Drop inspector**: drag any photo/video onto the window for codec/dimensions and estimated optimization savings.
- **UX/accessibility round**: collapsible panels with per-panel memory, Photos ALL/RAW/VIDEOS/DUPES tabs, two-way pagination with remembered limits, Shift-click range selection, sort by size/date/name, ⌘1-⌘6 module shortcuts + ⌘R rescan, VoiceOver labels on all ASCII controls, WCAG-friendly contrast, persisted [A-]/[A+] text scale, 28pt hit targets.
- Activity log at `~/Library/Logs/NeonSweep.log`; diagnostic CLI modes (`--diag-videos`, `--diag-find`, `--diag-export-raw`).

### Fixed
- RAW decode required `identifierHint` (silent infinite-extent failure) and CIContext's HEIF writer fails on large RAWs — replaced with ImageIO writer; EXIF/TIFF/GPS/IPTC preserved from the RAW decoder. Verified: 37 MB ARW → 3 MB HEIC, metadata intact.
- Video preview crash: AVKit framework was not linked by SPM auto-linking.
- Converted assets keep their original filename; HEVC sources are excluded from optimal recompression and only counted as "no gain".
- "Cleaned today" persists per calendar day instead of per session.
- Delete and optimize selections are independent (marked dupes no longer leaked into conversion batches); nothing is pre-checked.
- Uninstaller lists removable Apple apps (iWork, iMovie…) and sorts by name/size/running with login-item indicators.

## [Unreleased]

### Added
- **Permissions panel** on the dashboard: grant Full Disk Access, Automation → Finder and Photos once, with live status dots, instead of being interrupted module by module.
- **Cloud overview**: synced cloud drives from `~/Library/CloudStorage` (Google Drive, Dropbox, OneDrive…) listed on the dashboard with their local footprint.
- **Drag & drop inspector**: drop any photo/video onto the app to see codec, dimensions, duration and estimated savings if optimized (H.264 ~45%, ProRes ~85%, RAW→HEIC ~75%…).
- Dev junk: poetry / uv / pipenv caches and **forgotten Python venvs** (`.venv`, `venv`) with project dates.

### Changed
- New app icon: `clean_` in glowing terminal type (replaces the ASCII broom).
- Photos: optimize buttons moved to the top of each section; live progress (`recompressing 2/5…`) shown in the footer while working.

## [0.2.0] — 2026-07-15

### Added
- **Photos optimization**: recompress big videos to HEVC (AVAssetExportSession, resolution kept) and convert RAW photos to HEIC (CIRAWFilter + Core Image, ~90% quality). Originals stay 30 days in Recently Deleted.
- **Bilingual UI** (English/Spanish) with in-app `[es|EN]` toggle; follows system language by default.
- **Retro neon app icon**: ASCII broom drawn in Menlo with neon glow and CRT scanlines, generated by `scripts/make-icon.swift`.
- Global **Trash bar** visible in every module: size, review in Finder, empty (via Finder Apple Events, double-confirmed).
- Three-level reclaimed counters: *→ trash* (recoverable), *cleaned today*, *cleaned total* (persisted).
- Custom neon scrollbar (segmented glowing knob) replacing the system one.
- GitHub Actions: SwiftLint + build on every push; DMG attached to releases on tags.

### Changed
- Photos module now focuses on duplicates + optimization; screenshots section removed (Photos app already covers it).
- Duplicate groups sorted by size, rendered lazily with a 60-group cap.
- Accounting is honest: only space that truly left the disk counts as *cleaned*; deletions that skip the Trash count directly as cleaned.

### Fixed
- Crash (SIGABRT in AttributeGraph) after photo analysis finished: thousands of result views were materialized at once; now lists are lazy and capped.

## [0.1.0] — 2026-07-15

### Added
- Initial release with retro neon-terminal UI (black / grey / #39FF14, Menlo).
- **[01] Dashboard**: disk bar with used/purgeable/free (ASCII blocks), iCloud panel (`brctl quota`), reclaimable targets table.
- **[02] Uninstaller**: app list from `/Applications`, leftover search by bundle ID + name across 12 `~/Library` locations, conservative preselection, everything to Trash via `NSWorkspace.recycle`.
- **[03] System junk**: user caches, logs, iOS backups (device name + last backup date), installers in Downloads, saved app state.
- **[04] Dev junk**: DerivedData, DeviceSupport, simulators (readable names), Docker/Colima/OrbStack, package-manager caches, forgotten `node_modules` with project dates.
- **[05] Photos (part 1)**: duplicate/similar detection with Vision feature prints over local thumbnails, temporal-window grouping, BEST pick per group, big-videos list; deletion to Recently Deleted via PhotoKit.
