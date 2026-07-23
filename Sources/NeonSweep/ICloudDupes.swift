import Foundation
import CryptoKit
import AppKit
import SwiftUI

// MARK: - Modelos

struct FileDupeGroup: Identifiable {
    let id: String        // hash del contenido
    let size: Int64
    var files: [String]
    /// Se conserva la ruta más corta (la copia "principal")
    var keep: String { files.min { ($0.count, $0) < ($1.count, $1) } ?? files[0] }
    var wasted: Int64 { Int64(max(0, files.count - 1)) * size }
}

// MARK: - Motor

/// Ámbito del escaneo de duplicados.
enum DupeScope: String, CaseIterable {
    case icloud, home, downloads, documents, custom

    var label: String {
        switch self {
        case .icloud:    return t("iCloud Drive")
        case .home:      return t("Home folder")
        case .downloads: return t("Downloads")
        case .documents: return t("Documents")
        case .custom:    return t("Choose…")
        }
    }

    var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .icloud:    return home + "/Library/Mobile Documents"
        case .home:      return home
        case .downloads: return home + "/Downloads"
        case .documents: return home + "/Documents"
        case .custom:    return nil
        }
    }
}

@MainActor
final class ICloudDupesModel: ObservableObject {
    @Published var groups: [FileDupeGroup] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var fraction: Double?
    @Published var checked: Set<String> = []   // rutas marcadas para borrar
    @Published var skippedNotDownloaded = 0
    @Published var scanned = false
    @Published var lastResult: String?

    /// Ámbito activo y ruta escaneada (persistidos).
    @Published var scope: DupeScope = {
        DupeScope(rawValue: UserDefaults.standard.string(forKey: "dupes.scope") ?? "") ?? .icloud
    }()
    @Published var customPath: String? = UserDefaults.standard.string(forKey: "dupes.customPath")

    var rootPath: String { scope.path ?? customPath ?? DupeScope.icloud.path! }

    private nonisolated static let minSize: Int64 = 1_000_000   // ignorar < 1 MB

    /// Carpetas que nunca se recorren: paquetes de apps, librerías gestionadas
    /// y cachés donde "duplicado" es normal y borrar rompería cosas.
    private nonisolated static let skipNames: Set<String> = [
        "Library", "node_modules", ".git", ".Trash", "Applications",
        "Photos Library.photoslibrary", ".build", "DerivedData", "Caches",
    ]

    func setScope(_ s: DupeScope, custom: String? = nil) {
        scope = s
        if let custom {
            customPath = custom
            UserDefaults.standard.set(custom, forKey: "dupes.customPath")
        }
        UserDefaults.standard.set(s.rawValue, forKey: "dupes.scope")
        groups = []
        scanned = false
        checked = []
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = t("Choose…")
        if panel.runModal() == .OK, let url = panel.url {
            setScope(.custom, custom: url.path)
        }
    }

    var wastedTotal: Int64 { groups.map(\.wasted).reduce(0, +) }
    var checkedSize: Int64 {
        groups.reduce(0) { acc, g in
            acc + Int64(g.files.filter { checked.contains($0) }.count) * g.size
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        groups = []; checked = []; skippedNotDownloaded = 0

        Task {
            // FASE 1: inventario de ficheros locales (los .icloud sin descargar
            // se saltan — hashearlos forzaría descargarlos todos)
            let root = rootPath
            progress = String(format: t("listing %@…"), (root as NSString).lastPathComponent)
            fraction = nil
            let inventory = await Task.detached(priority: .userInitiated) {
                Self.listFiles(root: root)
            }.value
            skippedNotDownloaded = inventory.skipped

            // FASE 2: solo puede haber duplicado donde coincide el tamaño
            let bySize = Dictionary(grouping: inventory.files, by: \.size)
                .filter { $0.value.count > 1 }
            let toHash = bySize.values.flatMap { $0 }
            let totalBytes = toHash.map(\.size).reduce(0, +)
            AppLog.log("DUPES [\(root)]: \(inventory.files.count) ficheros, \(toHash.count) candidatos (\(formatBytes(totalBytes)) a hashear), \(inventory.skipped) sin descargar")

            var hashed: [String: [(path: String, size: Int64)]] = [:]
            var doneBytes: Int64 = 0
            for f in toHash {
                progress = String(format: t("hashing %@…"), (f.path as NSString).lastPathComponent)
                fraction = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : nil
                let h = await Task.detached(priority: .userInitiated) {
                    Self.sha256(of: f.path)
                }.value
                doneBytes += f.size
                guard let h else { continue }
                hashed[h, default: []].append(f)
            }

            groups = hashed.compactMap { hash, files in
                guard files.count > 1 else { return nil }
                return FileDupeGroup(id: hash, size: files[0].size,
                                     files: files.map(\.path).sorted())
            }
            .sorted { $0.wasted > $1.wasted }

            progress = ""
            fraction = nil
            scanning = false
            scanned = true
            AppLog.log("DUPES: \(groups.count) grupos duplicados, \(formatBytes(wastedTotal)) desperdiciados")
            SoundFX.shared.play(.done)
        }
    }

    nonisolated static func listFiles(root: String) -> (files: [(path: String, size: Int64)], skipped: Int) {
        let fm = FileManager.default
        var files: [(String, Int64)] = []
        var skipped = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        let scanningHome = root == FileManager.default.homeDirectoryForCurrentUser.path
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                     includingPropertiesForKeys: Array(keys),
                                     options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in true }) else {
            return ([], 0)
        }
        for case let url as URL in en {
            autoreleasepool {
                // Saltar carpetas donde duplicar es normal (o peligroso tocar)
                if skipNames.contains(url.lastPathComponent) {
                    en.skipDescendants()
                    return
                }
                // Paquetes (.app, .photoslibrary, .fcpbundle…): son una unidad
                if scanningHome, url.pathExtension.count >= 3,
                   ["app", "bundle", "framework", "photoslibrary", "fcpbundle", "logicx"]
                    .contains(url.pathExtension) {
                    en.skipDescendants()
                    return
                }
                // ".fichero.ext.icloud" = placeholder sin descargar
                if url.pathExtension == "icloud" { skipped += 1; return }
                guard let v = try? url.resourceValues(forKeys: keys),
                      v.isRegularFile == true,
                      let size = v.totalFileAllocatedSize, Int64(size) >= minSize else { return }
                files.append((url.path, Int64(size)))
            }
        }
        return (files, skipped)
    }

    /// SHA-256 completo en streaming (sin cargar el fichero entero en memoria).
    nonisolated static func sha256(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 4_000_000), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Acciones

    func markAllButKeep() {
        for g in groups {
            for f in g.files where f != g.keep { checked.insert(f) }
        }
    }

    func trashChecked() {
        let paths = checked
        guard !paths.isEmpty else { return }
        Task {
            var freed: Int64 = 0
            var failed = 0
            for g in groups {
                for f in g.files where paths.contains(f) {
                    do {
                        try await NSWorkspace.shared.recycle([URL(fileURLWithPath: f)])
                        freed += g.size
                    } catch {
                        failed += 1
                    }
                }
            }
            FreedTracker.shared.addTrashed(freed)
            TrashModel.shared.refresh()
            groups = groups.compactMap { g in
                var g2 = g
                g2.files.removeAll { paths.contains($0) && failed == 0 }
                return g2.files.count > 1 ? g2 : nil
            }
            checked = []
            lastResult = failed == 0
                ? String(format: t("OK: %d items → Trash (%@)"), paths.count, formatBytes(freed))
                : String(format: t("WARN: %d items could not be moved (in use?)"), failed)
        }
    }
}
