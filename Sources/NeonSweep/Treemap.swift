import SwiftUI

/// Treemap por el algoritmo "squarified" (Bruls et al.): reparte el área en
/// rectángulos proporcionales al tamaño, buscando proporciones cercanas al
/// cuadrado para que sean fáciles de comparar y de clicar.
enum Treemap {
    struct Tile: Identifiable {
        let id: String
        let node: DiskNode
        let rect: CGRect
    }

    static func layout(_ nodes: [DiskNode], in rect: CGRect) -> [Tile] {
        let items = nodes.filter { $0.size > 0 }
        let total = items.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0, !items.isEmpty, rect.width > 1, rect.height > 1 else { return [] }

        var tiles: [Tile] = []
        var remaining = rect
        var pending = items[...]
        let scale = (rect.width * rect.height) / total   // área por byte

        while !pending.isEmpty {
            let shortSide = min(remaining.width, remaining.height)
            guard shortSide > 0 else { break }

            // Acumular mientras mejore la peor proporción de la fila
            var row: [DiskNode] = []
            var rowArea = 0.0
            var bestRatio = Double.greatestFiniteMagnitude
            while let next = pending.first {
                let area = Double(next.size) * scale
                let candidateArea = rowArea + area
                let ratio = worstRatio(row: row.map { Double($0.size) * scale } + [area],
                                       total: candidateArea, side: shortSide)
                if row.isEmpty || ratio <= bestRatio {
                    row.append(next)
                    rowArea = candidateArea
                    bestRatio = ratio
                    pending = pending.dropFirst()
                } else {
                    break
                }
            }

            // Colocar la fila en el lado corto
            let horizontal = remaining.width >= remaining.height
            let thickness = rowArea / shortSide
            var offset = 0.0
            for node in row {
                let area = Double(node.size) * scale
                let length = area / max(thickness, 0.0001)
                let r: CGRect = horizontal
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset,
                             width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY,
                             width: length, height: thickness)
                tiles.append(Tile(id: node.path, node: node, rect: r.insetBy(dx: 1, dy: 1)))
                offset += length
            }
            remaining = horizontal
                ? CGRect(x: remaining.minX + thickness, y: remaining.minY,
                         width: max(0, remaining.width - thickness), height: remaining.height)
                : CGRect(x: remaining.minX, y: remaining.minY + thickness,
                         width: remaining.width, height: max(0, remaining.height - thickness))
            if remaining.width < 1 || remaining.height < 1 { break }
        }
        return tiles
    }

    /// Peor relación de aspecto de una fila: guía del algoritmo squarified.
    private static func worstRatio(row: [Double], total: Double, side: Double) -> Double {
        guard let mn = row.min(), let mx = row.max(), total > 0, mn > 0 else {
            return .greatestFiniteMagnitude
        }
        let s2 = side * side
        let t2 = total * total
        return max(s2 * mx / t2, t2 / (s2 * mn))
    }
}

/// Vista del treemap: cada rectángulo es una carpeta/fichero; clic entra,
/// el brillo indica el peso relativo.
struct TreemapView: View {
    let nodes: [DiskNode]
    let checked: Set<String>
    var onTap: (DiskNode) -> Void
    var onToggle: (DiskNode) -> Void
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            let tiles = Treemap.layout(Array(nodes.prefix(80)),
                                       in: CGRect(origin: .zero, size: geo.size))
            let maxSize = nodes.first?.size ?? 1
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    tileView(tile, maxSize: maxSize)
                }
            }
        }
        .background(Theme.bg)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
    }

    private func tileView(_ tile: Treemap.Tile, maxSize: Int64) -> some View {
        let weight = Double(tile.node.size) / Double(max(maxSize, 1))
        let isChecked = checked.contains(tile.node.path)
        let isHover = hovered == tile.node.path
        // Del verde apagado al neón según el peso relativo
        let fill = Theme.neon.opacity(0.10 + weight * 0.55)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isChecked ? Theme.amber.opacity(0.55) : fill)
                .overlay(Rectangle().stroke(
                    isHover ? Theme.neon : Theme.bg,
                    lineWidth: isHover ? 2 : 1))
                .shadow(color: isHover ? Theme.neon.opacity(0.6) : .clear, radius: 6)
            if tile.rect.width > 54 && tile.rect.height > 26 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.node.name)
                        .font(Theme.mono(9, .bold))
                        .foregroundStyle(Theme.bg)
                        .lineLimit(1)
                    if tile.rect.height > 40 {
                        Text(formatBytes(tile.node.size))
                            .font(Theme.mono(8))
                            .foregroundStyle(Theme.bg.opacity(0.75))
                    }
                }
                .padding(4)
            }
        }
        .frame(width: max(1, tile.rect.width), height: max(1, tile.rect.height))
        .offset(x: tile.rect.minX, y: tile.rect.minY)
        .onHover { hovered = $0 ? tile.node.path : nil }
        .onTapGesture { onTap(tile.node) }
        .highPriorityGesture(TapGesture().modifiers(.command).onEnded { onToggle(tile.node) })
        .help("\(tile.node.name) — \(formatBytes(tile.node.size))\n"
              + t("Click to go inside · ⌘-click to mark"))
        .accessibilityLabel("\(tile.node.name), \(formatBytes(tile.node.size))")
    }
}
