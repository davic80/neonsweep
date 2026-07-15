import AppKit
import Foundation

// MARK: - Modelos

struct InstalledApp: Identifiable, Hashable {
    let id: String        // ruta del bundle
    let name: String
    let bundleID: String
    let path: String
    var size: Int64 = 0

    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
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
    @Published var selectedApp: InstalledApp?
    @Published var leftovers: [LeftoverFile] = []
    @Published var checked: Set<UUID> = []
    @Published var inspecting = false
    @Published var loadingApps = false
    @Published var lastResult: String?

    var filteredApps: [InstalledApp] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
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
        }
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
                // Las apps de Apple no se pueden desinstalar (SIP) — fuera de la lista
                if bid.hasPrefix("com.apple.") { continue }
                let name = (n as NSString).deletingPathExtension
                result.append(InstalledApp(id: path, name: name, bundleID: bid, path: path))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Buscar restos de una app

    func inspect(_ app: InstalledApp) {
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
