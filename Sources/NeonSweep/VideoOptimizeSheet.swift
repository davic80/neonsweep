import SwiftUI
import Photos

/// Ficha de conversión de un vídeo concreto: dos perfiles con ahorro estimado.
struct VideoOptimizeSheet: View {
    @ObservedObject var model: PhotosModel
    let target: PreviewTarget
    @Environment(\.dismiss) private var dismiss

    private var pa: PhotoAsset? {
        model.bigVideos.first { $0.id == target.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let pa {
                header(pa)
                profileCard(pa, profile: .optimal,
                            title: t("OPTIMAL — HEVC, same resolution"),
                            detail: t("nearly invisible quality loss; ideal to keep as archive"),
                            disabled: model.codecByID[pa.id] == "HEVC ✓",
                            disabledNote: t("Already HEVC — recompressing won't shrink it"))
                profileCard(pa, profile: .aggressive,
                            title: t("MAX — 1080p + strong compression"),
                            detail: t("downscales 4K to 1080p; fine for casual viewing and sharing"),
                            disabled: false, disabledNote: "")
                Text(t("The original stays 30 days in Recently Deleted; only replaced if it truly shrinks ≥15%."))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            } else {
                Text(t("video no longer in the list")).font(Theme.body).foregroundStyle(Theme.amber)
            }
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text(t("[ CLOSE ]"))
                        .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neonDim)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(NeonClick())
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .background(Theme.bg)
    }

    private func header(_ pa: PhotoAsset) -> some View {
        let mins = Int(pa.asset.duration) / 60
        let secs = Int(pa.asset.duration) % 60
        let codec = model.codecByID[pa.id] ?? "…"
        let info = "\(pa.asset.pixelWidth)×\(pa.asset.pixelHeight) · "
            + String(format: "%d:%02d", mins, secs) + " · "
            + formatBytes(pa.fileSize) + " · " + codec
        return HStack(spacing: 10) {
            AssetThumb(asset: pa.asset).frame(width: 72, height: 46).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(pa.filename ?? "—")
                    .font(Theme.mono(14, .bold)).foregroundStyle(Theme.neon)
                    .lineLimit(1).truncationMode(.middle)
                Text(info)
                    .font(Theme.small).foregroundStyle(Theme.gray)
            }
            Spacer()
        }
    }

    private func profileCard(_ pa: PhotoAsset, profile: VideoProfile,
                             title: String, detail: String,
                             disabled: Bool, disabledNote: String) -> some View {
        let plan = PhotosModel.TranscodePlan.make(for: pa, profile: profile)
        let saving = max(0, pa.fileSize - plan.estBytes)
        let pct = pa.fileSize > 0 ? Int(Double(saving) / Double(pa.fileSize) * 100) : 0
        return TerminalPanel(title: title) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    Text("\(plan.width)×\(plan.height) · ~\(plan.bitrate / 1_000_000) Mbps")
                        .font(Theme.small).foregroundStyle(Theme.gray)
                    if disabled {
                        Text(disabledNote).font(Theme.small).foregroundStyle(Theme.amber)
                    } else {
                        Text(String(format: t("estimated: ~%@ (−%d%%)"),
                                    formatBytes(plan.estBytes), pct))
                            .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neon)
                            .shadow(color: Theme.neon.opacity(0.4), radius: 4)
                    }
                }
                Spacer()
                Button {
                    model.optimizeVideo(pa, profile: profile)
                    dismiss()
                } label: {
                    Text(t("[ CONVERT ]"))
                        .font(Theme.mono(12, .bold))
                        .foregroundStyle(disabled || model.optimizing ? Theme.grayDark : Theme.neon)
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                            disabled || model.optimizing ? Theme.border : Theme.neon, lineWidth: 1))
                }
                .buttonStyle(NeonClick())
                .disabled(disabled || model.optimizing)
            }
        }
    }
}
