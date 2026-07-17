import SwiftUI

/// Paleta y tipografía retro-terminal: negro, grises y verde neón.
enum Theme {
    // Colores
    static let bg        = Color(red: 0.043, green: 0.051, blue: 0.043)   // #0B0D0B casi negro
    static let panel     = Color(red: 0.078, green: 0.094, blue: 0.078)   // #141814 panel gris-verde
    static let border    = Color(red: 0.16,  green: 0.22,  blue: 0.16)    // borde tenue
    static let neon      = Color(red: 0.224, green: 1.0,   blue: 0.078)   // #39FF14 verde neón
    static let neonDim   = Color(red: 0.15,  green: 0.55,  blue: 0.12)    // verde apagado
    static let gray      = Color(red: 0.62,  green: 0.65,  blue: 0.62)    // texto secundario
    static let grayDark  = Color(red: 0.35,  green: 0.38,  blue: 0.35)    // texto terciario
    static let amber     = Color(red: 1.0,   green: 0.72,  blue: 0.20)    // avisos (purgeable)

    // Tipografía: monospace estilo máquina de escribir (Menlo viene en todos los Macs)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Menlo", size: size).weight(weight)
    }

    static let title  = mono(22, .bold)
    static let body   = mono(13)
    static let small  = mono(11)
    static let big    = mono(34, .bold)
}

/// Panel con borde estilo terminal y título tipo [ SECCIÓN ].
/// Colapsable con clic en el título; el estado se recuerda entre sesiones
/// (clave estable vía `id`, o derivada del título si no se pasa).
struct TerminalPanel<Content: View>: View {
    let title: String
    var id: String?
    var collapsible = true
    @ViewBuilder var content: Content
    @State private var collapsed = false

    private var key: String { "panel.collapsed." + (id ?? title.filter(\.isLetter)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if collapsible {
                Button {
                    collapsed.toggle()
                    UserDefaults.standard.set(collapsed, forKey: key)
                } label: {
                    HStack(spacing: 6) {
                        Text(collapsed ? "[+]" : "[-]")
                            .font(Theme.mono(12, .bold))
                            .foregroundStyle(Theme.neonDim)
                        Text("[ \(title) ]")
                            .font(Theme.mono(12, .bold))
                            .foregroundStyle(Theme.neonDim)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NeonClick())
                .accessibilityLabel(title)
                .accessibilityValue(collapsed ? "colapsado" : "expandido")
            } else {
                Text("[ \(title) ]")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.neonDim)
            }
            if !collapsed || !collapsible {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
        .onAppear {
            if collapsible { collapsed = UserDefaults.standard.bool(forKey: key) }
        }
    }
}

/// Cursor de bloque parpadeante ▊
struct BlinkingCursor: View {
    @State private var on = true
    var body: some View {
        Text("▊")
            .font(Theme.mono(14))
            .foregroundStyle(Theme.neon)
            .opacity(on ? 1 : 0)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { _ in on.toggle() }
            }
    }
}

/// Barra de progreso ASCII: █████▒▒░░░
struct AsciiBar: View {
    let segments: [(fraction: Double, color: Color, char: String)]
    var width: Int = 48

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(rendered.enumerated()), id: \.offset) { _, seg in
                Text(seg.0).foregroundStyle(seg.1)
            }
        }
        .font(Theme.mono(14))
        .lineLimit(1)
    }

    private var rendered: [(String, Color)] {
        var out: [(String, Color)] = []
        var used = 0
        for seg in segments {
            let n = min(width - used, Int((seg.fraction * Double(width)).rounded()))
            if n > 0 { out.append((String(repeating: seg.char, count: n), seg.color)) }
            used += max(0, n)
        }
        if used < width {
            out.append((String(repeating: "░", count: width - used), Theme.grayDark))
        }
        return out
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}
