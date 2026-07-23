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
    @Published var minMonths = 3          // filtro: meses sin abrir
    @Published var lastResult: String?

    var filtered: [UnusedApp] {
        apps.filter { ($0.daysUnused ?? 9_999) >= minMonths * 30 }
            .sorted { $0.score > $1.score }
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
                     used: Self.lastUsed(app.path))
                }.value
                out.append(UnusedApp(path: app.path, name: app.name, bundleID: app.bundleID,
                                     size: info.size, lastUsed: info.used))
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
