import Foundation
import AppKit

// MARK: - Modelo

struct UnusedApp: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
    var size: Int64
    var lastUsed: Date?
    /// App auxiliar (manejador de URLs, agente sin icono en el Dock, extensión):
    /// nunca la abres tú, la invoca el sistema — así que "sin usar" no
    /// significa "prescindible".
    var isHelper = false

    var daysUnused: Int? {
        lastUsed.map { Int(Date().timeIntervalSince($0)) / 86_400 }
    }
    /// Puntuación de "candidata a borrar": pesa GB y meses sin abrir.
    var score: Double {
        let gb = Double(size) / 1_073_741_824
        let months = Double(daysUnused ?? 365) / 30
        return gb * min(months, 24)
    }
}

// MARK: - Motor

@MainActor
final class UnusedAppsModel: ObservableObject {
    @Published var apps: [UnusedApp] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var fraction: Double?
    @Published var scanned = false
    @Published var minDays = 90          // filtro: días sin abrir
    @Published var lastResult: String?

    /// Criterio de orden (persistido). Por defecto tamaño: es lo que se busca
    /// en un limpiador.
    @Published var sortBySize = UserDefaults.standard.object(forKey: "unused.sortBySize") as? Bool ?? true
    @Published var sortAsc = false

    /// Las auxiliares se ocultan por defecto: nunca se "usan" y borrarlas
    /// rompe funcionalidad sin liberar espacio.
    @Published var showHelpers = false

    var helperCount: Int { apps.filter(\.isHelper).count }

    var filtered: [UnusedApp] {
        let base = apps.filter {
            ($0.daysUnused ?? 9_999) >= minDays && (showHelpers || !$0.isHelper)
        }
        let out = sortBySize
            ? base.sorted { $0.size > $1.size }
            : base.sorted { ($0.daysUnused ?? 0) > ($1.daysUnused ?? 0) }
        return sortAsc ? out.reversed() : out
    }

    func setSort(bySize: Bool) {
        if sortBySize == bySize {
            sortAsc.toggle()
        } else {
            sortBySize = bySize
            sortAsc = false
            UserDefaults.standard.set(bySize, forKey: "unused.sortBySize")
        }
    }
    var reclaimable: Int64 { filtered.map(\.size).reduce(0, +) }

    func scan() {
        guard !scanning else { return }
        scanning = true
        apps = []
        Task {
            // Lista de apps (reutiliza el escáner del desinstalador)
            let installed = await Task.detached(priority: .userInitiated) {
                UninstallerModel.scanApps()
            }.value

            var out: [UnusedApp] = []
            for (i, app) in installed.enumerated() {
                progress = app.name
                fraction = Double(i) / Double(max(1, installed.count))
                let info = await Task.detached(priority: .userInitiated) {
                    (size: ScanModel.directorySize(URL(fileURLWithPath: app.path)),
                     used: Self.lastUsed(app.path),
                     helper: Self.isHelperApp(app.path))
                }.value
                out.append(UnusedApp(path: app.path, name: app.name, bundleID: app.bundleID,
                                     size: info.size, lastUsed: info.used,
                                     isHelper: info.helper))
            }
            apps = out
            progress = ""
            fraction = nil
            scanning = false
            scanned = true
            AppLog.log("UNUSED: \(out.count) apps analizadas")
            SoundFX.shared.play(.done)
        }
    }

    /// ¿Es una app auxiliar? Lo dice su Info.plist: agentes sin interfaz
    /// (LSUIElement/LSBackgroundOnly) o manejadores de esquemas de URL, que el
    /// sistema lanza por su cuenta y nunca registran "última apertura".
    nonisolated static func isHelperApp(_ path: String) -> Bool {
        guard let info = NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist") else {
            return false
        }
        if (info["LSUIElement"] as? Bool ?? false) || (info["LSUIElement"] as? String == "1") {
            return true
        }
        if info["LSBackgroundOnly"] as? Bool ?? false { return true }
        if let urls = info["CFBundleURLTypes"] as? [Any], !urls.isEmpty { return true }
        return false
    }

    /// Fecha de último uso según los metadatos de Spotlight. `kMDItemLastUsedDate`
    /// es lo que alimenta "Última apertura" en el Finder.
    nonisolated static func lastUsed(_ path: String) -> Date? {
        guard let item = NSMetadataItem(url: URL(fileURLWithPath: path)) else { return nil }
        if let d = item.value(forAttribute: "kMDItemLastUsedDate") as? Date { return d }
        // Sin registro de uso: la fecha de instalación sirve de suelo
        return item.value(forAttribute: "kMDItemDateAdded") as? Date
    }

    func reveal(_ app: UnusedApp) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
    }
}
