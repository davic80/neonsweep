import SwiftUI
import Photos
import AVKit

/// Envoltorio identificable para .sheet(item:)
struct PreviewTarget: Identifiable {
    let id: String
    let asset: PHAsset
}

/// Previsualización grande de un asset: imagen a resolución alta o vídeo
/// reproducible (AVPlayer). Todo APIs oficiales; puede tirar de iCloud.
struct AssetPreview: View {
    let target: PreviewTarget
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.bg
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(nsImage: image)
                        .resizable().scaledToFit()
                } else {
                    VStack(spacing: 10) {
                        Text(loading ? t("loading preview…") : t("could not load (iCloud?)"))
                            .font(Theme.body)
                            .foregroundStyle(loading ? Theme.gray : Theme.amber)
                        if loading { BlinkingCursor() }
                    }
                }
            }
            HStack {
                Text(dimsLine).font(Theme.small).foregroundStyle(Theme.grayDark)
                Spacer()
                Button { dismiss() } label: {
                    Text(t("[ CLOSE ]"))
                        .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neon)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc cierra
            }
            .padding(10)
            .background(Theme.panel)
        }
        .frame(minWidth: 860, minHeight: 600)
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
    }

    private var dimsLine: String {
        let a = target.asset
        return "\(a.pixelWidth)×\(a.pixelHeight)" +
            (a.creationDate.map { " · " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "")
    }

    private func load() {
        let asset = target.asset
        if asset.mediaType == .video {
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: opts) { item, _ in
                Task { @MainActor in
                    loading = false
                    if let item {
                        let p = AVPlayer(playerItem: item)
                        player = p
                        p.play()
                    }
                }
            }
        } else {
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .opportunistic   // rápida primero, nítida después
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 2400, height: 2400),
                contentMode: .aspectFit, options: opts
            ) { img, info in
                Task { @MainActor in
                    if let img { image = img }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) != true { loading = false }
                }
            }
        }
    }
}
