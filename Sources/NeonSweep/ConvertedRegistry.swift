import Foundation

/// Registro permanente de lo que ha convertido NeonSweep.
///
/// Nace de un caso real: un vídeo ya recomprimido de ~500 MB a 231 MB volvía a
/// aparecer ofreciendo otro −53%. Adivinarlo por el códec no sirve, porque
/// leerlo obliga a abrir el fichero y el 83% de esta biblioteca vive solo en
/// iCloud (`codecLabel` devuelve "?" sin descargarlo). Y la densidad de bitrate
/// tampoco basta: ese vídeo salió a 0,25 bits/píxel, que no es "apretado".
///
/// Lo único exacto es acordarse. Al importar una conversión se apunta el id del
/// asset nuevo, y con eso la app sabe con certeza —sin abrir nada, sin red— que
/// ese vídeo ya pasó por aquí.
@MainActor
final class ConvertedRegistry: ObservableObject {
    static let shared = ConvertedRegistry()

    struct Entry: Codable {
        let date: Date
        let originalBytes: Int64
        let newBytes: Int64
        var saved: Int64 { max(0, originalBytes - newBytes) }
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeonSweep")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("converted.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func contains(_ id: String) -> Bool { entries[id] != nil }
    func entry(_ id: String) -> Entry? { entries[id] }

    /// Apunta un asset recién creado por una conversión nuestra.
    func record(id: String, originalBytes: Int64, newBytes: Int64) {
        entries[id] = Entry(date: Date(), originalBytes: originalBytes, newBytes: newBytes)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.url)
    }
}
