import AppKit
import Foundation

// MARK: - Modelos

struct InstalledApp: Identifiable, Hashable {
    let id: String        // ruta del bundle
    let name: String
    let bundleID: String
    let path: String
    var appSize: Int64 = -1     // -1 = calculando
    var dataSize: Int64 = -1    // estimación rápida de datos en ~/Library
    var hasLoginItem = false    // tiene LaunchAgent → arranca al iniciar sesión
    var isApple: Bool { bundleID.hasPrefix("com.apple.") }

    var totalSize: Int64 { max(0, appSize) + max(0, dataSize) }
    var sized: Bool { appSize >= 0 && dataSize >= 0 }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

enum AppSortKey { case name, size, running }

/// Resto huérfano: carpeta/fichero con pinta de bundle ID cuya app ya no existe.
struct OrphanEntry: Identifiable {
    var id: String { path }
    let path: String
    let location: String
    let bundleID: String
    let size: Int64
}

enum MatchKind { case appBundle, bundleID, name }

struct LeftoverFile: Identifiable {
    let id = UUID()
    let path: String
    let location: String   // ej. "Application Support"
    let kind: MatchKind
    var size: Int64 = 0
}

// MARK: - Motor

@MainActor
final class UninstallerModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var search = ""
    @Published var sortKey: AppSortKey = .name
    @Published var selectedApp: InstalledApp?
    @Published var leftovers: [LeftoverFile] = []
    @Published var checked: Set<UUID> = []
    @Published var inspecting = false
    @Published var loadingApps = false
    @Published var lastResult: String?
    @Published var orphans: [OrphanEntry] = []
    @Published var orphanChecked: Set<String> = []
    @Published var orphanScanning = false
    @Published var showingOrphans = false

    var filteredApps: [InstalledApp] {
        var list = apps
        if !search.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        switch sortKey {
        case .name:
            return list
        case .size:
            return list.sorted { $0.totalSize > $1.totalSize }
        case .running:
            return list.sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning }
                if $0.hasLoginItem != $1.hasLoginItem { return $0.hasLoginItem }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    var checkedSize: Int64 {
        leftovers.filter { checked.contains($0.id) }.map(\.size).reduce(0, +)
    }

    private nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Dónde dejan restos las apps (nivel usuario, sin root).
    private nonisolated static let locations: [(String, String)] = [
        ("Application Support", "\(home)/Library/Application Support"),
        ("Caches",              "\(home)/Library/Caches"),
        ("Preferences",         "\(home)/Library/Preferences"),
        ("Containers",          "\(home)/Library/Containers"),
        ("Group Containers",    "\(home)/Library/Group Containers"),
        ("Saved State",         "\(home)/Library/Saved Application State"),
        ("Logs",                "\(home)/Library/Logs"),
        ("WebKit",              "\(home)/Library/WebKit"),
        ("HTTPStorages",        "\(home)/Library/HTTPStorages"),
        ("LaunchAgents",        "\(home)/Library/LaunchAgents"),
        ("Application Scripts", "\(home)/Library/Application Scripts"),
        ("Cookies",             "\(home)/Library/Cookies"),
    ]

    // MARK: Listar apps instaladas

    func loadApps() {
        guard !loadingApps else { return }
        loadingApps = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.scanApps() }.value
            self.apps = found
            self.loadingApps = false
            self.computeSizes()
        }
    }

    /// Tamaños (bundle + datos) y LaunchAgents, en segundo plano y progresivo.
    private func computeSizes() {
        let snapshot = apps
        Task.detached(priority: .utility) {
            let agents = Self.launchAgentNames()
            for app in snapshot {
                let appSize = ScanModel.directorySize(URL(fileURLWithPath: app.path))
                let dataSize = Self.quickDataSize(bundleID: app.bundleID)
                let login = agents.contains { $0.contains(app.bundleID.lowercased()) }
                await MainActor.run {
                    if let idx = self.apps.firstIndex(where: { $0.id == app.id }) {
                        self.apps[idx].appSize = appSize
                        self.apps[idx].dataSize = dataSize
                        self.apps[idx].hasLoginItem = login
                    }
                }
            }
        }
    }

    /// Estimación rápida de datos: solo rutas exactas por bundle ID (sin listar).
    nonisolated static func quickDataSize(bundleID bid: String) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for p in ["\(home)/Library/Application Support/\(bid)",
                  "\(home)/Library/Caches/\(bid)",
                  "\(home)/Library/Containers/\(bid)"] {
            if fm.fileExists(atPath: p) {
                total += ScanModel.directorySize(URL(fileURLWithPath: p))
            }
        }
        let plist = "\(home)/Library/Preferences/\(bid).plist"
        total += (try? fm.attributesOfItem(atPath: plist))?[.size] as? Int64 ?? 0
        return total
    }

    nonisolated static func launchAgentNames() -> [String] {
        var names: [String] = []
        for dir in ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            names += ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { $0.lowercased() }
        }
        return names
    }

    nonisolated static func scanApps() -> [InstalledApp] {
        let fm = FileManager.default
        var result: [InstalledApp] = []
        for dir in ["/Applications", "\(home)/Applications"] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                let path = "\(dir)/\(n)"
                guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
                      let bid = bundle.bundleIdentifier else { continue }
                // Las de /System/Applications no se listan (SIP); en /Applications
                // las de Apple (iWork, iMovie, GarageBand…) SÍ son desinstalables.
                // Safari es la excepción: protegida aunque viva en /Applications.
                if bid == "com.apple.Safari" { continue }
                let name = (n as NSString).deletingPathExtension
                result.append(InstalledApp(id: path, name: name, bundleID: bid, path: path))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Buscar restos de una app

    func inspect(_ app: InstalledApp) {
        showingOrphans = false
        selectedApp = app
        inspecting = true
        leftovers = []
        checked = []
        lastResult = nil
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.findLeftovers(for: app)
            }.value
            self.leftovers = found
            // Preselección conservadora: el bundle y los matches por bundle ID.
            // Los matches solo por nombre quedan sin marcar (riesgo de falso positivo).
            self.checked = Set(found.filter { $0.kind != .name }.map(\.id))
            self.inspecting = false
        }
    }

    nonisolated static func findLeftovers(for app: InstalledApp) -> [LeftoverFile] {
        let fm = FileManager.default
        var out: [LeftoverFile] = [
            LeftoverFile(path: app.path, location: "Application", kind: .appBundle,
                         size: ScanModel.directorySize(URL(fileURLWithPath: app.path)))
        ]
        let bid = app.bundleID.lowercased()
        let name = app.name.lowercased()
        let nameUsable = name.count >= 4   // nombres cortos generan demasiados falsos positivos

        for (locName, locPath) in locations {
            guard let entries = try? fm.contentsOfDirectory(atPath: locPath) else { continue }
            for entry in entries {
                let e = entry.lowercased()
                var kind: MatchKind?
                if e.contains(bid) {
                    kind = .bundleID
                } else if nameUsable && e.contains(name) {
                    kind = .name
                }
                guard let k = kind else { continue }
                let full = "\(locPath)/\(entry)"
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                let size = isDir.boolValue
                    ? ScanModel.directorySize(URL(fileURLWithPath: full))
                    : ((try? fm.attributesOfItem(atPath: full))?[.size] as? Int64 ?? 0)
                out.append(LeftoverFile(path: full, location: locName, kind: k, size: size))
            }
        }
        return out
    }

    // MARK: Huérfanos — restos de apps que ya no están instaladas

    /// Escaneo inverso: entradas con formato de bundle ID en ~/Library cuyo
    /// fabricante (dos primeros componentes) no corresponde a ninguna app
    /// instalada. Conservador: solo nombres reverse-DNS, nunca com.apple.*.
    func scanOrphans() {
        guard !orphanScanning else { return }
        orphanScanning = true
        showingOrphans = true
        orphans = []
        orphanChecked = []
        let installedPrefixes = Set(apps.map { Self.vendorPrefix($0.bundleID) })
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.findOrphans(installedPrefixes: installedPrefixes)
            }.value
            self.orphans = found.sorted { $0.size > $1.size }
            self.orphanScanning = false
        }
    }

    /// "group.com.spotify.client" → "com.spotify"
    nonisolated static func vendorPrefix(_ bid: String) -> String {
        var parts = bid.lowercased().split(separator: ".")
        if parts.first == "group" { parts.removeFirst() }
        return parts.prefix(2).joined(separator: ".")
    }

    nonisolated static func findOrphans(installedPrefixes: Set<String>) -> [OrphanEntry] {
        let fm = FileManager.default
        var out: [OrphanEntry] = []
        for (locName, locPath) in locations {
            guard let entries = try? fm.contentsOfDirectory(atPath: locPath) else { continue }
            for entry in entries {
                // Preferences guarda ficheros com.x.y.plist; el resto, carpetas
                var candidate = entry
                if candidate.hasSuffix(".plist") {
                    candidate = String(candidate.dropLast(6))
                }
                let lower = candidate.lowercased()
                // Solo formato reverse-DNS claro (mínimo tld.vendor.app)
                let parts = lower.split(separator: ".")
                guard parts.count >= 3, parts[0].count <= 6,
                      parts[0].allSatisfy(\.isLetter) else { continue }
                // Jamás señalar cosas de Apple
                guard !lower.hasPrefix("com.apple."),
                      !lower.hasPrefix("group.com.apple") else { continue }
                // Si el fabricante sigue instalado (cualquier app suya), no es huérfano
                guard !installedPrefixes.contains(Self.vendorPrefix(lower)) else { continue }
                let full = "\(locPath)/\(entry)"
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                let size = isDir.boolValue
                    ? ScanModel.directorySize(URL(fileURLWithPath: full))
                    : ((try? fm.attributesOfItem(atPath: full))?[.size] as? Int64 ?? 0)
                guard size > 0 else { continue }
                out.append(OrphanEntry(path: full, location: locName,
                                       bundleID: candidate, size: size))
            }
        }
        return out
    }

    func trashCheckedOrphans() {
        let targets = orphans.filter { orphanChecked.contains($0.id) }
        guard !targets.isEmpty else { return }
        Task {
            var freed: Int64 = 0
            var failed = 0
            for t in targets {
                do {
                    try await NSWorkspace.shared.recycle([URL(fileURLWithPath: t.path)])
                    freed += t.size
                } catch {
                    failed += 1
                }
            }
            FreedTracker.shared.addTrashed(freed)
            TrashModel.shared.refresh()
            orphans.removeAll { orphanChecked.contains($0.id) && failed == 0 }
            lastResult = failed == 0
                ? String(format: t("OK: %d items → Trash (%@)"), targets.count, formatBytes(freed))
                : String(format: t("WARN: %d items could not be moved (in use?)"), failed)
            if failed > 0 { scanOrphans() }
            orphanChecked = []
        }
    }

    // MARK: Enviar a la Papelera (deshacible desde Finder)

    func trashChecked() {
        let targets = leftovers.filter { checked.contains($0.id) }
        guard !targets.isEmpty else { return }
        Task {
            var failures: [String] = []
            var freed: Int64 = 0
            for t in targets {
                do {
                    try await NSWorkspace.shared.recycle([URL(fileURLWithPath: t.path)])
                    freed += t.size
                } catch {
                    failures.append((t.path as NSString).lastPathComponent)
                }
            }
            FreedTracker.shared.addTrashed(freed)
            TrashModel.shared.refresh()
            if failures.isEmpty {
                self.lastResult = String(format: t("OK: %d items → Trash (%@)"), targets.count, formatBytes(freed))
            } else {
                self.lastResult = String(format: t("WARN: could not move: %@"), failures.joined(separator: ", "))
            }
            // Refrescar estado
            if let app = self.selectedApp {
                let stillExists = FileManager.default.fileExists(atPath: app.path)
                if !stillExists {
                    self.apps.removeAll { $0.id == app.id }
                    self.leftovers = []
                    self.selectedApp = nil
                } else {
                    self.inspect(app)
                }
            }
        }
    }
}
