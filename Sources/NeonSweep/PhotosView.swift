import SwiftUI
import Photos

struct PhotosView: View {
    @ObservedObject var model: PhotosModel
    private let maxGroupsShown = 60   // tope de render: evita desbordar SwiftUI

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeonScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    switch model.status {
                    case .notDetermined:
                        askAccess
                    case .denied, .restricted:
                        TerminalPanel(title: t("NO ACCESS")) {
                            Text(t("Grant Photos access in System Settings → Privacy → Photos"))
                                .font(Theme.body).foregroundStyle(Theme.amber)
                        }
                    default:
                        dupesSection
                        videosSection
                        rawSection
                    }
                }
                .padding(20)
            }
            footer
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("david@mac:~$").font(Theme.mono(14, .bold)).foregroundStyle(Theme.gray)
            Text("neonsweep --photos").font(Theme.mono(14, .bold)).foregroundStyle(Theme.neon)
            if model.scanning || model.optimizing {
                Text(model.progress).font(Theme.small).foregroundStyle(Theme.grayDark)
            } else {
                BlinkingCursor()
            }
            Spacer()
            Button { model.requestAndScan() } label: {
                Text(model.scanning ? t("[ ANALYZING… ]") : t("[ ANALYZE LIBRARY ]"))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning || model.optimizing ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(.plain)
            .disabled(model.scanning || model.optimizing)
        }
    }

    private var askAccess: some View {
        TerminalPanel(title: t("PHOTOS ACCESS")) {
            Text(t("NeonSweep needs to read your library to find duplicates and huge originals. Nothing is deleted without your confirmation; deletions go to \"Recently Deleted\" (recoverable for 30 days)."))
                .font(Theme.body).foregroundStyle(Theme.gray)
            Button { model.requestAndScan() } label: {
                Text(t("[ GRANT ACCESS & ANALYZE ]"))
                    .font(Theme.mono(13, .bold)).foregroundStyle(Theme.neon)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Duplicados / similares

    private var dupesSection: some View {
        TerminalPanel(title: String(format: t("DUPLICATES & SIMILAR — %d groups"), model.groups.count)) {
            if model.groups.isEmpty && !model.scanning {
                Text(t("no groups detected (or not analyzed yet)"))
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.groups.prefix(maxGroupsShown)) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            tierTag(g.tier)
                            Text(String(format: t("%d photos // %@"), g.members.count, formatBytes(g.totalSize)))
                                .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                            Spacer()
                            Button { model.selectAllButBest(g) } label: {
                                Text(t("[ ALL BUT BEST ]"))
                                    .font(Theme.mono(9, .bold)).foregroundStyle(Theme.neonDim)
                            }
                            .buttonStyle(.plain)
                            .help(t("Marks the whole group except the best — you can unmark any to keep more"))
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 6) {
                                ForEach(g.members) { m in
                                    thumbCell(m, isBest: m.id == g.bestID)
                                }
                            }
                        }
                        .frame(height: 118)
                    }
                }
            }
            if model.groups.count > maxGroupsShown {
                Text(String(format: t("… and %d more groups — clean these first and re-analyze"),
                            model.groups.count - maxGroupsShown))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            }
        }
    }

    private func tierTag(_ tier: DupeTier) -> some View {
        switch tier {
        case .exact:
            Text(t("DUPLICATES")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.neon)
        case .near:
            Text(t("NEAR-DUPLICATES")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
        case .similar:
            Text(t("SIMILAR")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.gray)
        }
    }

    private func thumbCell(_ m: PhotoAsset, isBest: Bool) -> some View {
        let isSel = model.selected.contains(m.id)
        return VStack(spacing: 2) {
            ZStack(alignment: .topLeading) {
                AssetThumb(asset: m.asset)
                    .frame(width: 92, height: 92)
                    .clipped()
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(
                        isSel ? Theme.neon : Theme.border, lineWidth: isSel ? 2 : 1))
                if isBest {
                    Text(t("BEST"))
                        .font(Theme.mono(8, .bold)).foregroundStyle(Theme.bg)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Theme.neon)
                }
            }
            Text(isBest ? t("kept") : (isSel ? t("[x] delete") : "[ ] " + formatBytes(m.fileSize)))
                .font(Theme.mono(9))
                .foregroundStyle(isBest ? Theme.neonDim : (isSel ? Theme.neon : Theme.grayDark))
        }
        .onTapGesture {
            guard !isBest else { return }   // la mejor no se puede marcar
            if isSel { model.selected.remove(m.id) } else { model.selected.insert(m.id) }
        }
        .help(isBest ? t("The best of the group is always kept") : "")
    }

    // MARK: Vídeos grandes → HEVC

    private var videosSection: some View {
        TerminalPanel(title: String(format: t("BIG VIDEOS (>100 MB) — %d"), model.bigVideos.count)) {
            if model.bigVideos.isEmpty {
                Text(t("none")).font(Theme.small).foregroundStyle(Theme.grayDark)
            } else {
                HStack {
                    Text(t("recompress to HEVC keeping resolution; the original stays 30 days in Recently Deleted"))
                        .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    Spacer()
                    optimizeButton(
                        label: t("[ RECOMPRESS SELECTED → HEVC ]"),
                        count: model.selectedVideos.count
                    ) { model.optimizeSelectedVideos() }
                }
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.bigVideos.prefix(30)) { m in
                        assetRow(m)
                    }
                }
            }
        }
    }

    // MARK: RAW → HEIC

    private var rawSection: some View {
        TerminalPanel(title: String(format: t("RAW PHOTOS — %d"), model.rawPhotos.count)) {
            if model.rawPhotos.isEmpty {
                Text(t("none")).font(Theme.small).foregroundStyle(Theme.grayDark)
            } else {
                HStack {
                    Text(t("convert to HEIC (~90% quality, huge savings); the original stays 30 days in Recently Deleted"))
                        .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    Spacer()
                    optimizeButton(
                        label: t("[ CONVERT SELECTED → HEIC ]"),
                        count: model.selectedRaws.count
                    ) { model.convertSelectedRaws() }
                }
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.rawPhotos.prefix(40)) { m in
                        assetRow(m)
                    }
                }
            }
        }
    }

    // MARK: Componentes comunes

    private func assetRow(_ m: PhotoAsset) -> some View {
        let isSel = model.selected.contains(m.id)
        return HStack(spacing: 8) {
            Button {
                if isSel { model.selected.remove(m.id) } else { model.selected.insert(m.id) }
            } label: {
                Text(isSel ? "[x]" : "[ ]")
                    .font(Theme.body)
                    .foregroundStyle(isSel ? Theme.neon : Theme.grayDark)
            }
            .buttonStyle(.plain)
            AssetThumb(asset: m.asset).frame(width: 44, height: 28).clipped()
            Text(m.asset.creationDate.map { Self.df.string(from: $0) } ?? "—")
                .font(Theme.small).foregroundStyle(Theme.gray)
            if m.asset.mediaType == .video {
                Text(Self.duration(m.asset.duration))
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
                VideoCodecTag(asset: m.asset)
            } else {
                Text("\(m.asset.pixelWidth)×\(m.asset.pixelHeight)")
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
            }
            Spacer()
            Text(formatBytes(m.fileSize))
                .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neon)
        }
    }

    private func optimizeButton(label: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(model.optimizing ? t("[ WORKING… ]") : "\(label) (\(count))")
                .font(Theme.mono(12, .bold))
                .foregroundStyle(count == 0 || model.optimizing ? Theme.grayDark : Theme.neon)
                .padding(.vertical, 5).padding(.horizontal, 8)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                    count == 0 || model.optimizing ? Theme.border : Theme.neon, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(count == 0 || model.optimizing)
    }

    private static let df: DateFormatter = {
        let d = DateFormatter(); d.dateFormat = "dd-MM-yyyy"; return d
    }()

    private static func duration(_ s: TimeInterval) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.optimizing {
                Text(model.progress)
                    .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neon)
                    .shadow(color: Theme.neon.opacity(0.5), radius: 4)
                BlinkingCursor()
            } else if let r = model.lastResult {
                Text(r).font(Theme.small)
                    .foregroundStyle(r.hasPrefix("OK") ? Theme.neon : Theme.amber)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(model.selectedCount) " + t("checked =") + " \(formatBytes(model.selectedSize))")
                .font(Theme.body).foregroundStyle(Theme.gray)
            Button { model.deleteSelected() } label: {
                Text(t("[ DELETE FROM PHOTOS ]"))
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(model.selectedCount == 0 || model.optimizing ? Theme.grayDark : Theme.neon)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        model.selectedCount == 0 || model.optimizing ? Theme.border : Theme.neon, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.selectedCount == 0 || model.optimizing)
            .help(t("macOS asks for confirmation; goes to \"Recently Deleted\" (30 days)"))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .top)
    }
}

/// Etiqueta de códec de un vídeo: los "HEVC ✓" ya no dan ahorro.
struct VideoCodecTag: View {
    let asset: PHAsset
    @State private var label: String?

    var body: some View {
        Text(label ?? "…")
            .font(Theme.mono(9, .bold))
            .foregroundStyle(label == "HEVC ✓" ? Theme.neonDim
                             : (label == nil ? Theme.grayDark : Theme.amber))
            .help(label == "HEVC ✓" ? t("Already HEVC — recompressing won't shrink it") : "")
            .task { label = await PhotosModel.codecLabel(for: asset) }
    }
}

/// Miniatura de un PHAsset vía PHImageManager (asíncrona, caché del sistema).
struct AssetThumb: View {
    let asset: PHAsset
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.panel)
                Text("…").font(Theme.small).foregroundStyle(Theme.grayDark)
            }
        }
        .onAppear {
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 120, height: 120),
                contentMode: .aspectFill, options: opts
            ) { img, _ in
                if let img { image = img }
            }
        }
    }
}
