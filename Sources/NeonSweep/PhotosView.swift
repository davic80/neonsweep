import SwiftUI
import Photos

enum MediaSort { case size, date, name }

struct PhotosView: View {
    @ObservedObject var model: PhotosModel
    @State private var preview: PreviewTarget?
    @State private var rawSort: MediaSort = .size
    @State private var videoSort: MediaSort = .size
    @State private var rawLimit = 50
    @State private var videoLimit = 50
    private let maxGroupsShown = 60   // tope de render: evita desbordar SwiftUI

    private func sorted(_ list: [PhotoAsset], by key: MediaSort) -> [PhotoAsset] {
        switch key {
        case .size: return list.sorted { $0.fileSize > $1.fileSize }
        case .date: return list.sorted {
            ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast)
        }
        case .name: return list.sorted {
            ($0.filename ?? "").localizedCaseInsensitiveCompare($1.filename ?? "") == .orderedAscending
        }
        }
    }

    private func sortPicker(_ sel: Binding<MediaSort>) -> some View {
        HStack(spacing: 6) {
            Text("sort:").font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            sortButton(t("[size]"), .size, sel)
            sortButton(t("[date]"), .date, sel)
            sortButton(t("[name]"), .name, sel)
        }
    }

    private func sortButton(_ label: String, _ key: MediaSort, _ sel: Binding<MediaSort>) -> some View {
        Button { sel.wrappedValue = key } label: {
            Text(label)
                .font(Theme.mono(10, sel.wrappedValue == key ? .bold : .regular))
                .foregroundStyle(sel.wrappedValue == key ? Theme.neon : Theme.grayDark)
        }
        .buttonStyle(.plain)
    }

    private func moreBar(total: Int, limit: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            Text(String(format: t("showing %d of %d"), min(limit.wrappedValue, total), total))
                .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            if total > limit.wrappedValue {
                Button { limit.wrappedValue += 200 } label: {
                    Text("[+200]").font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                }.buttonStyle(.plain)
                Button { limit.wrappedValue = total } label: {
                    Text(t("[ ALL ]")).font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeonScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if model.scanning {
                        ProgressStrip(label: model.progress, fraction: model.fraction)
                    }
                    if model.optimizing {
                        HStack(spacing: 8) {
                            if let w = model.workingAsset {
                                AssetThumb(asset: w)
                                    .frame(width: 40, height: 40).clipped()
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .stroke(Theme.neon, lineWidth: 1))
                            }
                            ProgressStrip(label: model.optProgress, fraction: model.optFraction)
                        }
                    }
                    if let d = model.cacheDate, !model.scanning {
                        Text(String(format: t("// saved results from %@ — re-analyze if the library changed"),
                                    Self.df.string(from: d)))
                            .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    }
                    switch model.status {
                    case .notDetermined:
                        askAccess
                    case .denied, .restricted:
                        TerminalPanel(title: t("NO ACCESS")) {
                            Text(t("Grant Photos access in System Settings → Privacy → Photos"))
                                .font(Theme.body).foregroundStyle(Theme.amber)
                        }
                    default:
                        rawSection
                        videosSection
                        dupesSection
                    }
                }
                .padding(20)
            }
            footer
        }
        .background(Theme.bg)
        .onAppear { model.refreshStatus() }
        .sheet(item: $preview) { AssetPreview(target: $0) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("david@mac:~$").font(Theme.mono(14, .bold)).foregroundStyle(Theme.gray)
            Text("neonsweep --photos").font(Theme.mono(14, .bold)).foregroundStyle(Theme.neon)
            if !model.scanning && !model.optimizing {
                BlinkingCursor()
            }
            Spacer()
            if model.hasResults && !model.scanning {
                Button { model.requestAndScan(fullRescan: true) } label: {
                    Text(t("[ RE-ANALYZE ALL ]"))
                        .font(Theme.mono(11))
                        .foregroundStyle(model.optimizing ? Theme.grayDark : Theme.neonDim)
                }
                .buttonStyle(.plain)
                .disabled(model.optimizing)
                .help(t("Full analysis from scratch (slow with big libraries)"))
            }
            Button { model.requestAndScan() } label: {
                Text(model.scanning ? t("[ ANALYZING… ]")
                     : (model.hasResults ? t("[ UPDATE ANALYSIS ]") : t("[ ANALYZE LIBRARY ]")))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning || model.optimizing ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(.plain)
            .disabled(model.scanning || model.optimizing)
            .help(model.hasResults ? t("Only processes what changed since the last analysis") : "")
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
            } else {
                HStack {
                    Text(t("nothing is pre-checked — you decide"))
                        .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    Spacer()
                    Button { model.selectAllExactDupes() } label: {
                        Text(t("[ MARK ALL EXACT DUPES ]"))
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neon)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(t("Marks every EXACT duplicate except the best of each group"))
                }
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
        .highPriorityGesture(TapGesture(count: 2).onEnded {
            preview = PreviewTarget(id: m.id, asset: m.asset)
        })
        .onTapGesture {
            guard !isBest else { return }   // la mejor no se puede marcar
            if isSel { model.selected.remove(m.id) } else { model.selected.insert(m.id) }
        }
        .help(isBest ? t("The best of the group is always kept — double-click to preview")
                     : t("Click to mark, double-click to preview"))
    }

    // MARK: Vídeos grandes → HEVC

    @State private var showHEVC = false

    private var optimizableVideos: [PhotoAsset] {
        model.bigVideos.filter { model.codecByID[$0.id] != "HEVC ✓" }
    }
    private var hevcVideos: [PhotoAsset] {
        model.bigVideos.filter { model.codecByID[$0.id] == "HEVC ✓" }
    }

    private var videosSection: some View {
        TerminalPanel(title: String(format: t("BIG VIDEOS (>100 MB) — %d optimizable"),
                                    optimizableVideos.count)) {
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
                if optimizableVideos.isEmpty {
                    Text(t("everything already in HEVC ✓"))
                        .font(Theme.body).foregroundStyle(Theme.neonDim)
                } else {
                    sortPicker($videoSort)
                }
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(sorted(optimizableVideos, by: videoSort).prefix(videoLimit)) { m in
                        assetRow(m)
                    }
                }
                if !optimizableVideos.isEmpty {
                    moreBar(total: optimizableVideos.count, limit: $videoLimit)
                }
                if !hevcVideos.isEmpty {
                    Button { showHEVC.toggle() } label: {
                        Text((showHEVC ? "[-] " : "[+] ") +
                             String(format: t("%d already HEVC — nothing to gain"), hevcVideos.count))
                            .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    }
                    .buttonStyle(.plain)
                    if showHEVC {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(sorted(hevcVideos, by: videoSort).prefix(videoLimit)) { m in
                                assetRow(m, optimizable: false)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: RAW → HEIC

    private var shownRaws: [PhotoAsset] {
        Array(sorted(model.rawPhotos, by: rawSort).prefix(rawLimit))
    }

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
                HStack {
                    sortPicker($rawSort)
                    Spacer()
                    Button { model.optSelected.formUnion(shownRaws.map(\.id)) } label: {
                        Text(t("[ MARK SHOWN ]"))
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                    }
                    .buttonStyle(.plain)
                    .help(t("Marks the visible rows for conversion — the limit below is your batch size"))
                }
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(shownRaws) { m in
                        assetRow(m)
                    }
                }
                moreBar(total: model.rawPhotos.count, limit: $rawLimit)
            }
        }
    }

    // MARK: Componentes comunes

    private func assetRow(_ m: PhotoAsset, optimizable: Bool = true) -> some View {
        let isOpt = model.optSelected.contains(m.id)
        return HStack(spacing: 8) {
            if optimizable {
                Button {
                    if isOpt { model.optSelected.remove(m.id) } else { model.optSelected.insert(m.id) }
                } label: {
                    Text(isOpt ? "[x]" : "[ ]")
                        .font(Theme.body)
                        .foregroundStyle(isOpt ? Theme.neon : Theme.grayDark)
                }
                .buttonStyle(.plain)
                .help(t("Mark to optimize"))
            } else {
                Text("[·]").font(Theme.body).foregroundStyle(Theme.grayDark)
                    .help(t("Already HEVC — recompressing won't shrink it"))
            }
            AssetThumb(asset: m.asset).frame(width: 44, height: 28).clipped()
                .onTapGesture { preview = PreviewTarget(id: m.id, asset: m.asset) }
                .help(t("Click to preview"))
            Text(m.filename ?? "—")
                .font(Theme.small).foregroundStyle(Theme.gray)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            Text(m.asset.creationDate.map { Self.df.string(from: $0) } ?? "—")
                .font(Theme.small).foregroundStyle(Theme.grayDark)
            if m.asset.mediaType == .video {
                Text(Self.duration(m.asset.duration))
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
                let codec = model.codecByID[m.id]
                Text(codec ?? "…")
                    .font(Theme.mono(9, .bold))
                    .foregroundStyle(codec == "HEVC ✓" ? Theme.neonDim
                                     : (codec == nil ? Theme.grayDark : Theme.amber))
                if model.dupeVideoIDs.contains(m.id) {
                    Text(t("DUPE?"))
                        .font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
                        .help(t("Same duration, resolution and size as another video — probably a duplicate"))
                    let isDel = model.selected.contains(m.id)
                    Button {
                        if isDel { model.selected.remove(m.id) } else { model.selected.insert(m.id) }
                    } label: {
                        Text(isDel ? t("[✗ delete]") : t("[ delete ]"))
                            .font(Theme.mono(9, .bold))
                            .foregroundStyle(isDel ? Theme.amber : Theme.grayDark)
                    }
                    .buttonStyle(.plain)
                    .help(t("Mark this duplicate video for deletion"))
                }
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
                Text(model.optProgress)
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
