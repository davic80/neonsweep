import Foundation
import AppKit

// MARK: - Modelo

/// Nodo del árbol de tamaños. `children` solo se llena al entrar en la carpeta
/// (escaneo bajo demanda), así navegar es instantáneo y no se re-escanea todo.
final class DiskNode: Identifiable, @unchecked Sendable {
    let id: String        // ruta
    let name: String
    let path: String
    let isDir: Bool
    var size: Int64
    var children: [DiskNode]?

    init(path: String, name: String, isDir: Bool, size: Int64) {
        self.id = path
        self.path = path
        self.name = name
        self.isDir = isDir
        self.size = size
    }
}

// MARK: - Motor

@MainActor
final class DiskMapModel: ObservableObject {
    @Published var stack: [DiskNode] = []      // migas: raíz → actual
    @Published var scanning = false
    @Published var progress = ""
    @Published var lastResult: String?
    @Published var checked: Set<String> = []

    var current: DiskNode? { stack.last }
    var checkedSize: Int64 {
        (current?.children ?? []).filter { checked.contains($0.id) }.map(\.size).reduce(0, +)
    }

    /// Carpetas de arranque: lo que de verdad ocupa en la carpeta de usuario.
    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser.path

    func start(at path: String? = nil) {
        guard !scanning else { return }
        let root = path ?? Self.home
        scanning = true
        checked = []
        progress = root.replacingOccurrences(of: Self.home, with: "~")
        Task {
            let node = await Task.detached(priority: .userInitiated) {
                Self.scanDir(root, depth: 0)
            }.value
            stack = [node]
            progress = ""
            scanning = false
            SoundFX.shared.play(.done)
        }
    }

    /// Entra en una carpeta: la escanea si aún no tiene hijos.
    func enter(_ node: DiskNode) {
        guard node.isDir else { return }
        if node.children != nil {
            stack.append(node)
            checked = []
            return
        }
        scanning = true
        progress = node.path.replacingOccurrences(of: Self.home, with: "~")
        Task {
            let full = await Task.detached(priority: .userInitiated) {
                Self.scanDir(node.path, depth: 0)
            }.value
            node.children = full.children
            node.size = full.size
            stack.append(node)
            checked = []
            progress = ""
            scanning = false
        }
    }

    func goBack() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        checked = []
    }

    func goTo(index: Int) {
        guard index < stack.count - 1 else { return }
        stack = Array(stack.prefix(index + 1))
        checked = []
    }

    /// Escaneo recursivo de un directorio: los hijos directos con su tamaño
    /// total. `depth` limita cuántos niveles se guardan en memoria (1 nivel;
    /// el resto se calcula pero se descarta hasta que se entre).
    nonisolated static func scanDir(_ path: String, depth: Int) -> DiskNode {
        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        let node = DiskNode(path: path, name: name, isDir: true, size: 0)
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return node }

        var children: [DiskNode] = []
        var total: Int64 = 0
        for entry in entries {
            autoreleasepool {
                let full = "\(path)/\(entry)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { return }
                // No seguir enlaces simbólicos (evita bucles y duplicar tamaños)
                if let attrs = try? fm.attributesOfItem(atPath: full),
                   attrs[.type] as? FileAttributeType == .typeSymbolicLink { return }

                let size: Int64
                if isDir.boolValue {
                    size = ScanModel.directorySize(URL(fileURLWithPath: full))
                } else {
                    size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? Int64) ?? 0
                }
                guard size > 0 else { return }
                children.append(DiskNode(path: full, name: entry, isDir: isDir.boolValue, size: size))
                total += size
            }
        }
        node.children = children.sorted { $0.size > $1.size }
        node.size = total
        return node
    }

    // MARK: Acciones

    func revealInFinder(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func trashChecked() {
        let targets = (current?.children ?? []).filter { checked.contains($0.id) }
        guard !targets.isEmpty else { return }
        Task {
            var freed: Int64 = 0
            var failed = 0
            for n in targets {
                do {
                    try await NSWorkspace.shared.recycle([URL(fileURLWithPath: n.path)])
                    freed += n.size
                } catch { failed += 1 }
            }
            FreedTracker.shared.addTrashed(freed)
            TrashModel.shared.refresh()
            if failed == 0, let cur = current {
                let gone = Set(targets.map(\.id))
                cur.children?.removeAll { gone.contains($0.id) }
                cur.size -= freed
            }
            checked = []
            lastResult = failed == 0
                ? String(format: t("OK: %d items → Trash (%@)"), targets.count, formatBytes(freed))
                : String(format: t("WARN: %d items could not be moved (in use?)"), failed)
        }
    }
}
