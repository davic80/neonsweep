import AppKit
import Foundation

/// Contabilidad del espacio recuperado.
/// - `sessionTrashed`: enviado a la Papelera en esta sesión (aún recuperable).
/// - `sessionPurged`:  liberado de verdad en esta sesión (vaciados de papelera
///                     o borrados que no pasan por ella). No recuperable.
/// - `allTimePurged`:  histórico de liberado real, persistido.
@MainActor
final class FreedTracker: ObservableObject {
    static let shared = FreedTracker()

    @Published private(set) var sessionTrashed: Int64 = 0
    @Published private(set) var sessionPurged: Int64 = 0
    @Published private(set) var allTimePurged: Int64

    private static let key = "allTimePurgedBytes"

    private init() {
        allTimePurged = Int64(UserDefaults.standard.integer(forKey: Self.key))
    }

    /// Algo se movió a la Papelera (recuperable).
    func addTrashed(_ bytes: Int64) {
        guard bytes > 0 else { return }
        sessionTrashed += bytes
    }

    /// Algo se liberó definitivamente (no pasa o ya salió de la Papelera).
    func addPurged(_ bytes: Int64) {
        guard bytes > 0 else { return }
        sessionPurged += bytes
        allTimePurged += bytes
        UserDefaults.standard.set(Int(allTimePurged), forKey: Self.key)
    }

    /// La Papelera se vació: lo que estaba "en papelera" pasa a "limpiado".
    func trashEmptied(measuredTrashSize: Int64) {
        // Contamos lo mayor entre lo que medimos en ~/.Trash y lo que esta
        // sesión envió (por si TCC nos impidió medir la Papelera real).
        addPurged(max(measuredTrashSize, sessionTrashed))
        sessionTrashed = 0
    }
}

/// Estado global de la Papelera, visible desde todos los módulos.
@MainActor
final class TrashModel: ObservableObject {
    static let shared = TrashModel()
    @Published private(set) var size: Int64 = 0
    @Published var emptying = false
    @Published var lastResult: String?

    private init() {}

    func refresh() {
        Task {
            size = await Task.detached(priority: .utility) { TrashOps.size() }.value
        }
    }

    /// Vacía la Papelera vía Finder y pasa lo liberado a "limpiado".
    func empty() {
        guard !emptying else { return }
        emptying = true
        Task {
            let before = await Task.detached(priority: .userInitiated) { TrashOps.size() }.value
            if let err = TrashOps.empty() {
                lastResult = String(format: t("WARN: could not empty (%@)"), err)
                emptying = false
                return
            }
            // Finder tarda; esperamos hasta que quede vacía (máx 30 s)
            var after = before
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                after = await Task.detached(priority: .utility) { TrashOps.size() }.value
                if after == 0 { break }
            }
            let freed = max(0, before - after)
            FreedTracker.shared.trashEmptied(measuredTrashSize: freed)
            size = after
            emptying = false
            lastResult = String(format: t("OK: Trash emptied — %@ truly freed"), formatBytes(freed))
        }
    }
}

/// Operaciones sobre la Papelera del usuario (APIs oficiales).
enum TrashOps {
    nonisolated static var trashPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.Trash"
    }

    /// Tamaño actual de la Papelera. Puede devolver 0 si TCC bloquea la lectura.
    nonisolated static func size() -> Int64 {
        ScanModel.directorySize(URL(fileURLWithPath: trashPath))
    }

    /// Abre la Papelera en Finder para revisarla.
    @MainActor static func reveal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: trashPath))
    }

    /// Vacía la Papelera pidiéndoselo a Finder (Apple Events; macOS pedirá
    /// permiso de Automatización la primera vez). Devuelve error o nil.
    @MainActor static func empty() -> String? {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        if let err, let msg = err[NSAppleScript.errorMessage] as? String {
            return msg
        }
        return nil
    }
}
