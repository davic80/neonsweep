import SwiftUI

/// ScrollView con barra propia estilo retro-neón: oculta la del sistema y
/// dibuja un knob segmentado (bloques) con glow sobre un carril oscuro.
struct NeonScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var geo: ScrollGeometry?

    var body: some View {
        ScrollView {
            content
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in
            geo = new
        }
        .overlay(alignment: .topTrailing) { scrollbar }
    }

    @ViewBuilder
    private var scrollbar: some View {
        if let g = geo, g.contentSize.height > g.containerSize.height + 1 {
            let vh = g.containerSize.height
            let ch = g.contentSize.height
            let knobH = max(36, vh * vh / ch)
            let maxOff = max(1, ch - vh)
            let off = min(max(0, g.contentOffset.y), maxOff)
            let y = (vh - knobH) * (off / maxOff)

            ZStack(alignment: .top) {
                // carril
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border, lineWidth: 1))
                    .frame(width: 7)
                // knob de bloques ▮▮▮
                VStack(spacing: 2) {
                    ForEach(0..<max(2, Int(knobH / 8)), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.neon)
                            .frame(width: 5, height: 6)
                    }
                }
                .frame(height: knobH)
                .clipped()
                .shadow(color: Theme.neon.opacity(0.6), radius: 4)
                .offset(y: y)
            }
            .frame(width: 7)
            .padding(.trailing, 3)
            .padding(.vertical, 2)
            .allowsHitTesting(false)
        }
    }
}
