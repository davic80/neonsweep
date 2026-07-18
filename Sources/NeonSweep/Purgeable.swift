import Foundation

/// Desglose y purga de lo purgable que SÍ es accionable con APIs oficiales:
/// los snapshots locales de Time Machine (`tmutil`). El resto (iCloud
/// evictable, cachés del sistema) lo gestiona macOS automáticamente.
@MainActor
final class PurgeModel: ObservableObject {
    static let shared = PurgeModel()

    @Published var snapshots: [String] = []   // "2026-07-17-101010"
    @Published var working = false
    @Published var lastResult: String?

    private init() {}

    func list() {
        Task {
            let names = await Task.detached(priority: .utility) { Self.listSnapshots() }.value
            snapshots = names
        }
    }

    /// Borra todos los snapshots locales y apunta lo liberado de verdad.
    func purgeSnapshots(scanModel: ScanModel) {
        guard !working, !snapshots.isEmpty else { return }
        working = true
        let before = scanModel.disk.purgeable
        Task {
            var failedSnaps: [String] = []
            for snap in snapshots {
                let (status, out) = await Task.detached(priority: .utility) {
                    UpdatesModel.run("/usr/bin/tmutil", ["deletelocalsnapshots", snap])
                }.value
                if status != 0 {
                    failedSnaps.append(snap)
                    AppLog.log("PURGE snapshot \(snap): fallo (\(out.trimmingCharacters(in: .whitespacesAndNewlines)))")
                } else {
                    AppLog.log("PURGE snapshot \(snap): borrado")
                }
            }
            // Reintento con privilegios de administrador (una sola autorización)
            var failed = failedSnaps.count
            if !failedSnaps.isEmpty {
                let cmd = failedSnaps.map { "tmutil deletelocalsnapshots \($0)" }
                    .joined(separator: "; ")
                if let err = AdminOps.run(cmd) {
                    AppLog.log("PURGE admin: \(err)")
                } else {
                    AppLog.log("PURGE admin: \(failedSnaps.count) snapshots borrados con privilegios")
                    failed = 0
                }
            }
            // Medir cuánto espacio purgable se liberó realmente
            try? await Task.sleep(for: .seconds(2))
            let after = ScanModel.diskSnapshot()
            let freed = max(0, before - after.purgeable)
            FreedTracker.shared.addPurged(freed)
            scanModel.disk = after
            list()
            working = false
            lastResult = failed == 0
                ? String(format: t("OK: snapshots deleted — %@ truly freed"), formatBytes(freed))
                : String(format: t("WARN: %d snapshots could not be deleted (admin required?)"), failed)
        }
    }

    /// "com.apple.TimeMachine.2026-07-17-101010.local" → "2026-07-17-101010"
    nonisolated static func listSnapshots() -> [String] {
        let (status, out) = UpdatesModel.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard status == 0 else { return [] }
        return out.split(separator: "\n").compactMap { line in
            // "com.apple.TimeMachine.2026-07-14-014238.local (dataless)" → fecha
            guard let token = line.split(separator: " ").first,
                  token.hasPrefix("com.apple.TimeMachine.") else { return nil }
            return token.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                .replacingOccurrences(of: ".local", with: "")
        }
    }
}
