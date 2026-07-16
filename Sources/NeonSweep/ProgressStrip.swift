import SwiftUI

/// Barra de progreso retro: determinada `[████░░░░] 42%` o indeterminada
/// (bloque que patrulla). Bien visible, en neón.
struct NeonProgressBar: View {
    var fraction: Double?   // nil = indeterminada
    var width = 26

    var body: some View {
        if let f = fraction {
            HStack(spacing: 8) {
                bar(String(repeating: "█", count: filled(f))
                    + String(repeating: "░", count: width - filled(f)))
                Text("\(Int((f * 100).rounded()))%")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.neon)
                    .shadow(color: Theme.neon.opacity(0.5), radius: 4)
                    .frame(minWidth: 40, alignment: .trailing)
            }
        } else {
            TimelineView(.animation(minimumInterval: 0.1)) { ctx in
                let tick = Int(ctx.date.timeIntervalSinceReferenceDate / 0.1)
                bar(marquee(tick))
            }
        }
    }

    private func filled(_ f: Double) -> Int {
        min(width, max(0, Int((f * Double(width)).rounded())))
    }

    private func marquee(_ tick: Int) -> String {
        let span = 5
        let range = width - span
        let cycle = tick % (range * 2)                 // rebota ida y vuelta
        let pos = cycle < range ? cycle : range * 2 - cycle
        return String(repeating: "░", count: pos)
            + String(repeating: "█", count: span)
            + String(repeating: "░", count: width - span - pos)
    }

    private func bar(_ s: String) -> some View {
        Text("[\(s)]")
            .font(Theme.mono(13, .bold))
            .foregroundStyle(Theme.neon)
            .shadow(color: Theme.neon.opacity(0.55), radius: 5)
            .lineLimit(1)
    }
}

/// Tira de progreso de módulo: barra + etiqueta de qué se está haciendo.
struct ProgressStrip: View {
    let label: String
    var fraction: Double?

    var body: some View {
        HStack(spacing: 12) {
            NeonProgressBar(fraction: fraction)
            Text(label)
                .font(Theme.small)
                .foregroundStyle(Theme.gray)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neonDim.opacity(0.6), lineWidth: 1))
    }
}
