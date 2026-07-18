import Foundation

/// Registro de actividad simple: ~/Library/Logs/NeonSweep.log
/// Para diagnosticar optimizaciones sin depender del mensajito del footer.
enum AppLog {
    nonisolated static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NeonSweep.log").path

    /// Perfilado de rendimiento (fases por foto, resúmenes de lote).
    /// Se activa clicando la línea de versión del sidebar o con
    /// `defaults write com.davidcornejo.neonsweep debug.profile -bool true`.
    nonisolated(unsafe) static var profileEnabled =
        UserDefaults.standard.bool(forKey: "debug.profile")

    nonisolated static func setProfile(_ on: Bool) {
        profileEnabled = on
        UserDefaults.standard.set(on, forKey: "debug.profile")
        log("PROFILE \(on ? "activado" : "desactivado")")
    }

    private nonisolated static let df: DateFormatter = {
        let d = DateFormatter()
        d.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return d
    }()

    nonisolated static func log(_ s: String) {
        let line = "\(df.string(from: Date())) \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
