import AppKit
import Foundation

// MARK: - Modelos

struct JunkEntry: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let detail: String?   // ej. fecha de modificación
}

struct JunkCategory: Identifiable {
    let id: String
    let name: String
    let note: String              // aviso corto bajo el título
    var entries: [JunkEntry] = []
    var scanned = false
    var totalSize: Int64 { entries.map(\.size).reduce(0, +) }
}

/// Definición de una categoría: qué es y cómo escanearla.
struct JunkCategorySpec {
    let id: String
    let name: String
    let note: String
    let scan: @Sendable () -> [JunkEntry]
}

// MARK: - Motor genérico (lo usan [03] BASURA SISTEMA y [04] BASURA DEV)

@MainActor
final class JunkModel: ObservableObject {
    @Published var categories: [JunkCategory] = []
    @Published var checked: Set<UUID> = []
    @Published var expanded: Set<String> = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var fraction: Double?
    @Published var lastResult: String?

    private let specs: [JunkCategorySpec]

    init(specs: [JunkCategorySpec]) {
        self.specs = specs
    }

    var checkedSize: Int64 {
        allEntries.filter { checked.contains($0.id) }.map(\.size).reduce(0, +)
    }
    var checkedCount: Int {
        allEntries.filter { checked.contains($0.id) }.count
    }
    private var allEntries: [JunkEntry] { categories.flatMap(\.entries) }

    func scan() {
        guard !scanning else { return }
        scanning = true
        checked = []
        categories = specs.map { JunkCategory(id: $0.id, name: $0.name, note: $0.note) }

        Task {
            for (idx, spec) in specs.enumerated() {
                progress = spec.name
                let entries = await Task.detached(priority: .userInitiated) {
                    spec.scan()
                }.value
                categories[idx].entries = entries.sorted { $0.size > $1.size }
                categories[idx].scanned = true
                fraction = Double(idx + 1) / Double(specs.count)
            }
            progress = ""
            fraction = nil
            TrashModel.shared.refresh()
            scanning = false
        }
    }

    func toggleAll(in cat: JunkCategory) {
        let ids = cat.entries.map(\.id)
        if ids.allSatisfy({ checked.contains($0) }) {
            ids.forEach { checked.remove($0) }
        } else {
            ids.forEach { checked.insert($0) }
        }
    }

    func trashChecked() {
        let targets = allEntries.filter { checked.contains($0.id) }
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
            lastResult = failed == 0
                ? String(format: t("OK: %d items → Trash (%@)"), targets.count, formatBytes(freed))
                : String(format: t("WARN: %d items could not be moved (in use?)"), failed)
            scan()  // re-escanear para reflejar el estado real
        }
    }
}

// MARK: - Utilidades de escaneo compartidas

enum JunkFS {
    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Hijos directos de un directorio, con su tamaño en disco.
    nonisolated static func childDirs(_ base: String, minSize: Int64 = 1) -> [JunkEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        return names.compactMap { n in
            let p = "\(base)/\(n)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
            let size = isDir.boolValue
                ? ScanModel.directorySize(URL(fileURLWithPath: p))
                : ((try? fm.attributesOfItem(atPath: p))?[.size] as? Int64 ?? 0)
            guard size >= minSize else { return nil }
            return JunkEntry(name: n, path: p, size: size, detail: nil)
        }
    }

    /// Rutas sueltas etiquetadas (existentes y con contenido).
    nonisolated static func labeledPaths(_ list: [(String, String)]) -> [JunkEntry] {
        list.compactMap { label, path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let size = ScanModel.directorySize(URL(fileURLWithPath: path))
            guard size > 0 else { return nil }
            return JunkEntry(name: label, path: path, size: size, detail: nil)
        }
    }
}

// MARK: - Objetivos de [03] BASURA SISTEMA

enum SystemJunkSpecs {
    static let all: [JunkCategorySpec] = [
        JunkCategorySpec(
            id: "caches", name: "USER CACHES",
            note: "they regenerate on their own; open apps may recreate them instantly",
            scan: { JunkFS.childDirs("\(JunkFS.home)/Library/Caches") }),
        JunkCategorySpec(
            id: "logs", name: "LOGS",
            note: "old diagnostics; safe to delete",
            scan: { JunkFS.childDirs("\(JunkFS.home)/Library/Logs") }),
        JunkCategorySpec(
            id: "iosbackup", name: "iOS BACKUPS",
            note: "local iPhone/iPad backups — make sure you have an iCloud copy first",
            scan: { iosBackups() }),
        JunkCategorySpec(
            id: "installers", name: "INSTALLERS IN DOWNLOADS",
            // No se puede saber si un .dmg ya se instaló: la fecha es la pista
            // y el ISO que guardas a propósito también sale aquí.
            note: ".dmg / .pkg / .iso in Downloads — check the date; keep the ones you use as media",
            scan: { installers() }),
        JunkCategorySpec(
            id: "savedstate", name: "SAVED APP STATE",
            note: "saved windows of closed apps; regenerates",
            scan: { JunkFS.childDirs("\(JunkFS.home)/Library/Saved Application State") }),
    ]

    nonisolated private static func iosBackups() -> [JunkEntry] {
        let base = "\(JunkFS.home)/Library/Application Support/MobileSync/Backup"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        let df = DateFormatter()
        df.dateFormat = "dd-MM-yyyy"
        return names.compactMap { n in
            let p = "\(base)/\(n)"
            let size = ScanModel.directorySize(URL(fileURLWithPath: p))
            guard size > 0 else { return nil }
            var label = n
            var date: String?
            if let info = NSDictionary(contentsOfFile: "\(p)/Info.plist") {
                label = info["Display Name"] as? String ?? info["Device Name"] as? String ?? n
                if let d = info["Last Backup Date"] as? Date { date = df.string(from: d) }
            }
            return JunkEntry(name: label, path: p, size: size,
                             detail: date.map { String(format: t("last backup %@"), $0) })
        }
    }

    nonisolated private static func installers() -> [JunkEntry] {
        let base = "\(JunkFS.home)/Downloads"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        let df = DateFormatter()
        df.dateFormat = "dd-MM-yyyy"
        return names.compactMap { n in
            guard n.hasSuffix(".dmg") || n.hasSuffix(".pkg") || n.hasSuffix(".iso") else { return nil }
            let p = "\(base)/\(n)"
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let size = attrs[.size] as? Int64, size > 0 else { return nil }
            let mod = (attrs[.modificationDate] as? Date).map { df.string(from: $0) }
            return JunkEntry(name: n, path: p, size: size, detail: mod)
        }
    }
}
