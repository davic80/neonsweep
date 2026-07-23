import Foundation

/// Cola de conversiones. Pedir otra conversión mientras hay una en marcha ya
/// no se descarta en silencio: se apunta y arranca al terminar la anterior.
///
/// No se lanzan varias a la vez a propósito. Medido con `--bench-video` en este
/// Mac (M5, 4K): 1 vídeo 24,9 s · 2 → 49,8 s · 3 → 74,7 s · 4 → 99,6 s. Escala
/// exactamente lineal, así que el rendimiento agregado no sube ni un 1%.
/// `ffmpeg` da lo mismo (9,6 s uno, 38,3 s cuatro): no es cosa de esta app, es
/// que codificar lo hace un bloque dedicado del chip, no los núcleos de CPU, y
/// ese bloque atiende de uno en uno. Repartir el trabajo solo repartiría la
/// espera.
struct OptimizeJob: Identifiable {
    let id = UUID()
    let targets: [PhotoAsset]
    let video: Bool
    let profile: VideoProfile
    var label: String {
        targets.count == 1 ? (targets[0].filename ?? "1")
                           : String(format: t("%d items"), targets.count)
    }
    var bytes: Int64 { targets.map(\.fileSize).reduce(0, +) }
}
