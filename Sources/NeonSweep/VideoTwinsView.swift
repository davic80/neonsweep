import SwiftUI
import Photos

/// Comparación de vídeos gemelos, lado a lado.
///
/// Un vídeo "gemelo" se detecta por duración, resolución y peso — no por
/// contenido, porque los vídeos no tienen huella visual de Vision. Es una
/// sospecha, no una certeza: dos tomas seguidas del mismo trípode pueden
/// coincidir en los tres. Por eso aquí no se marca nada solo y se enseña todo
/// lo que permite distinguirlas antes de borrar.
extension PhotosView {

    @ViewBuilder
    func twinComparison(_ g: VideoTwinGroup) -> some View {
        let side = CGFloat(model.thumbSide)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(t("// same duration, resolution and size (±2%) — NeonSweep cannot see inside a video, so check them yourself"))
                    .font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
                Spacer()
                Text("↓ " + formatBytes(g.reclaimable))
                    .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neon)
                    .help(t("Frees this much if you keep only the ★ copy"))
                Button { model.markTwinsButKeeper(g) } label: {
                    Text(t("[ ALL BUT ★ ]"))
                        .font(Theme.mono(9, .bold)).foregroundStyle(Theme.neonDim)
                        .frame(minHeight: 22).contentShape(Rectangle())
                }
                .buttonStyle(NeonClick())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(g.members) { m in
                        twinCard(m, group: g, side: side)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: side + 92)
        }
        .padding(10)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
        .padding(.leading, 36)
        .padding(.bottom, 4)
    }

    private func twinCard(_ m: PhotoAsset, group g: VideoTwinGroup, side: CGFloat) -> some View {
        let isKeep = m.id == g.keepID
        let isSel = model.selected.contains(m.id)
        let hasGPS = m.asset.location != nil
        return VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                AssetThumb(asset: m.asset, side: side)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(
                        isSel ? Theme.amber : (isKeep ? Theme.neon : Theme.border),
                        lineWidth: isSel || isKeep ? 2 : 1))
                    .onTapGesture { preview = PreviewTarget(id: m.id, asset: m.asset) }
                if isKeep {
                    Text(t("KEEP"))
                        .font(Theme.mono(8, .bold)).foregroundStyle(Theme.bg)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Theme.neon)
                } else {
                    HStack {
                        Spacer()
                        Button { model.setTwinKeeper(g.id, to: m.id) } label: {
                            Text("☆").font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
                                .padding(4).background(Theme.bg.opacity(0.7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(NeonClick())
                        .help(t("Keep this copy instead"))
                    }
                    .frame(width: side)
                }
            }
            // Los datos que de verdad distinguen dos copias del mismo vídeo
            twinLine(m.filename ?? "—", Theme.gray, bold: true)
            twinLine(m.asset.creationDate.map {
                DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium)
            } ?? t("no date"), Theme.grayDark)
            twinLine(formatBytes(m.fileSize) + " · " + Self.duration(m.asset.duration), Theme.neonDim)
            twinLine("\(m.asset.pixelWidth)×\(m.asset.pixelHeight)"
                     + " · " + (model.codecByID[m.id] ?? "…")
                     + (hasGPS ? " 📍" : ""), Theme.grayDark)

            if isKeep {
                Text("★ " + t("kept"))
                    .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                    .frame(width: side, alignment: .leading)
            } else {
                Button {
                    // Rechazado = intentabas marcar la última copia sin marcar
                    blockedTwin = model.toggleTwin(m.id) ? nil : m.id
                } label: {
                    Text(isSel ? t("[x] delete") : t("[ ] keep"))
                        .font(Theme.mono(10, isSel ? .bold : .regular))
                        .foregroundStyle(isSel ? Theme.amber : Theme.grayDark)
                        .frame(width: side, height: 20, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NeonClick())
                .accessibilityLabel(m.filename ?? "")
                .accessibilityValue(isSel ? t("marked") : t("not marked"))
            }
            if blockedTwin == m.id {
                Text(t("// that's the last unmarked copy"))
                    .font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
                    .frame(width: side, alignment: .leading)
            }
        }
        .frame(width: side)
    }

    private func twinLine(_ s: String, _ color: Color, bold: Bool = false) -> some View {
        Text(s)
            .font(Theme.mono(9, bold ? .bold : .regular))
            .foregroundStyle(color)
            .lineLimit(1).truncationMode(.middle)
            .frame(width: CGFloat(model.thumbSide), alignment: .leading)
            .help(s)
    }
}
