import Foundation

// MARK: - Modelos

struct DiskSnapshot {
    var total: Int64 = 0
    var free: Int64 = 0            // libre real (sin contar purgeable)
    var freeImportant: Int64 = 0   // libre si el sistema purga lo purgable
    var purgeable: Int64 { max(0, freeImportant - free) }
    var used: Int64 { max(0, total - freeImportant) }
}

struct ICloudSnapshot {
    var localSize: Int64 = 0          // lo que iCloud Drive ocupa en el disco local
    var quotaRemaining: Int64? = nil  // espacio libre en iCloud (via brctl)
}

struct JunkItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var size: Int64 = 0
    var exists: Bool = false
    let cleanable: Bool  // true = candidato a liberar; false = solo informativo
}

// MARK: - Escáner

@MainActor
final class ScanModel: ObservableObject {
    @Published var disk = DiskSnapshot()
    @Published var icloud = ICloudSnapshot()
    @Published var items: [JunkItem] = []
    @Published var scanning = false
    @Published var currentPath = ""

    var recoverable: Int64 {
        items.filter(\.cleanable).map(\.size).reduce(0, +)
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Objetivos del escaneo: (clave de nombre en inglés, ruta, limpiable)
    private static let targets: [(String, String, Bool)] = [
        ("User caches",            "\(home)/Library/Caches", true),
        ("Logs",                   "\(home)/Library/Logs", true),
        ("Trash",                  "\(home)/.Trash", true),
        ("iOS backups",            "\(home)/Library/Application Support/MobileSync/Backup", true),
        ("Xcode DerivedData",      "\(home)/Library/Developer/Xcode/DerivedData", true),
        ("iOS Simulators",         "\(home)/Library/Developer/CoreSimulator", true),
        ("Docker",                 "\(home)/Library/Containers/com.docker.docker/Data", true),
        ("npm cache",              "\(home)/.npm", true),
        ("cargo cache",            "\(home)/.cargo/registry", true),
        ("gradle cache",           "\(home)/.gradle/caches", true),
        ("Installers (.dmg/.pkg)", "\(home)/Downloads", true),   // solo suma dmg/pkg
        ("iCloud Drive (local)",   "\(home)/Library/Mobile Documents", false),
    ]

    func scan() {
        guard !scanning else { return }
        scanning = true
        items = Self.targets.map { JunkItem(name: $0.0, path: $0.1, cleanable: $0.2) }

        // Otras nubes sincronizadas (Google Drive, Dropbox, OneDrive…):
        // File Provider las monta en ~/Library/CloudStorage. Solo informativo:
        // lo que ocupan EN LOCAL (la limpieza dentro de la nube es cosa suya).
        let cloudBase = "\(Self.home)/Library/CloudStorage"
        if let provs = try? FileManager.default.contentsOfDirectory(atPath: cloudBase) {
            for p in provs.sorted() where !p.hasPrefix(".") {
                items.append(JunkItem(name: Self.prettyCloudName(p),
                                      path: "\(cloudBase)/\(p)", cleanable: false))
            }
        }

        Task {
            // Disco: instantáneo
            self.disk = Self.diskSnapshot()

            // iCloud quota en paralelo
            Task.detached(priority: .utility) {
                let quota = Self.icloudQuota()
                await MainActor.run { self.icloud.quotaRemaining = quota }
            }

            // Tamaños de carpetas, secuencial para poder mostrar progreso
            for idx in self.items.indices {
                let item = self.items[idx]
                self.currentPath = item.path.replacingOccurrences(of: Self.home, with: "~")
                let isDownloads = item.name.hasPrefix("Installers")
                let result = await Task.detached(priority: .userInitiated) { () -> (Int64, Bool) in
                    let fm = FileManager.default
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { return (0, false) }
                    let size = isDownloads
                        ? Self.installersSize(inDownloads: item.path)
                        : Self.directorySize(URL(fileURLWithPath: item.path))
                    return (size, true)
                }.value
                self.items[idx].size = result.0
                self.items[idx].exists = result.1
                if item.name.hasPrefix("iCloud Drive") {
                    self.icloud.localSize = result.0
                }
            }

            self.currentPath = ""
            self.scanning = false
        }
    }

    /// "GoogleDrive-david@gmail.com" → "Google Drive (david@gmail.com, local)"
    nonisolated static func prettyCloudName(_ raw: String) -> String {
        guard let dash = raw.firstIndex(of: "-") else { return "\(raw) (local)" }
        let provider = String(raw[..<dash])
            .replacingOccurrences(of: "GoogleDrive", with: "Google Drive")
            .replacingOccurrences(of: "OneDrive", with: "OneDrive")
        let account = String(raw[raw.index(after: dash)...])
        return "\(provider) (\(account), local)"
    }

    // MARK: Helpers (nonisolated, corren fuera del MainActor)

    nonisolated static func diskSnapshot() -> DiskSnapshot {
        var s = DiskSnapshot()
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            s.total = Int64(v.volumeTotalCapacity ?? 0)
            s.free = Int64(v.volumeAvailableCapacity ?? 0)
            s.freeImportant = v.volumeAvailableCapacityForImportantUsage ?? s.free
        }
        return s
    }

    /// Tamaño en disco de un directorio (bytes asignados). Ignora errores de permisos.
    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            guard let v = try? f.resourceValues(forKeys: keys),
                  v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated static func installersSize(inDownloads path: String) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return 0 }
        var total: Int64 = 0
        for n in names where n.hasSuffix(".dmg") || n.hasSuffix(".pkg") || n.hasSuffix(".iso") {
            let p = "\(path)/\(n)"
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let size = attrs[.size] as? Int64 { total += size }
        }
        return total
    }

    /// Espacio libre en iCloud vía `brctl quota` (ej: "1.8 TB of quota remaining").
    nonisolated static func icloudQuota() -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        p.arguments = ["quota"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        // Formatos vistos: "123456789 bytes of quota remaining" o "1.82 TB of quota remaining"
        if let bytes = out.split(separator: " ").first.flatMap({ Int64($0) }) {
            return bytes
        }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6)]
        for (u, mult) in units {
            if let r = out.range(of: #"([\d.,]+)\s*"# + u, options: .regularExpression) {
                let numStr = out[r].replacingOccurrences(of: u, with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: ".")
                if let n = Double(numStr) { return Int64(n * mult) }
            }
        }
        return nil
    }
}
