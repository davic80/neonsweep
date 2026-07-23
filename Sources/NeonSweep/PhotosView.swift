import SwiftUI
import Photos

enum MediaSort { case size, date, name }
enum PhotoTab: String { case all, raw, videos, dupes }
enum GroupSort: String { case saving, count, date }

struct PhotosView: View {
    @ObservedObject var model: PhotosModel
    @State var preview: PreviewTarget?
    @State var videoOptions: PreviewTarget?
    @State var rawSort: MediaSort = .size
    @State var rawAsc = false
    @State var videoSort: MediaSort = .size
    @State var videoAsc = false
    @State var dupeFilter: DupeTier?   // nil = todos los niveles
    @AppStorage("photos.tab") private var tabRaw = PhotoTab.all.rawValue
    @AppStorage("photos.videoProfile") private var videoProfileRaw = "optimal"

    var batchProfile: VideoProfile { videoProfileRaw == "max" ? .aggressive : .optimal }
    var batchVideoCount: Int {
        model.bigVideos.filter {
            model.optSelected.contains($0.id)
                && (batchProfile == .aggressive || model.codecByID[$0.id] != "HEVC ✓")
        }.count
    }
    @AppStorage("photos.rawLimit") var rawLimit = 50
    @AppStorage("photos.videoLimit") var videoLimit = 50

    private var tab: PhotoTab { PhotoTab(rawValue: tabRaw) ?? .all }
    @State private var lastAnchor: [String: String] = [:]   // lista → último id clicado

    /// Clic normal alterna; Shift+clic aplica al rango desde el último clic,
    /// en el orden mostrado en pantalla.
    func toggleRow(_ m: PhotoAsset, in list: [PhotoAsset], key: String) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift,
           let anchorID = lastAnchor[key],
           let a = list.firstIndex(where: { $0.id == anchorID }),
           let b = list.firstIndex(where: { $0.id == m.id }) {
            let marking = !model.optSelected.contains(m.id)
            for item in list[min(a, b)...max(a, b)] {
                if marking { model.optSelected.insert(item.id) }
                else { model.optSelected.remove(item.id) }
            }
        } else if model.optSelected.contains(m.id) {
            model.optSelected.remove(m.id)
        } else {
            model.optSelected.insert(m.id)
        }
        lastAnchor[key] = m.id
    }
    let maxGroupsShown = 60   // tope de render: evita desbordar SwiftUI

    /// `asc` invierte el criterio natural de cada columna (tamaño y fecha
    /// empiezan de mayor a menor; el nombre, alfabético).
    func sorted(_ list: [PhotoAsset], by key: MediaSort, asc: Bool) -> [PhotoAsset] {
        let out: [PhotoAsset]
        switch key {
        case .size: out = list.sorted { $0.fileSize > $1.fileSize }
        case .date: out = list.sorted {
            ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast)
        }
        case .name: out = list.sorted {
            ($0.filename ?? "").localizedCaseInsensitiveCompare($1.filename ?? "") == .orderedAscending
        }
        }
        return asc ? out.reversed() : out
    }

    func sortPicker(_ sel: Binding<MediaSort>, _ asc: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text("sort:").font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            sortButton(t("[size]"), .size, sel, asc)
            sortButton(t("[date]"), .date, sel, asc)
            sortButton(t("[name]"), .name, sel, asc)
            // El mismo ajuste que en duplicados: aquí también hay que mirar la
            // miniatura para decidir, y 44 px no daban para nada.
            thumbSizeControl
        }
        // Los controles no se encogen: en la fila de RAW competían con el texto
        // de ayuda y SwiftUI recortaba "[tamaño]" a "o]".
        .fixedSize()
    }

    /// Clic en otra columna: la activa con su orden natural.
    /// Clic en la activa: invierte la dirección.
    private func sortButton(_ label: String, _ key: MediaSort,
                            _ sel: Binding<MediaSort>, _ asc: Binding<Bool>) -> some View {
        let active = sel.wrappedValue == key
        return Button {
            if active { asc.wrappedValue.toggle() } else { sel.wrappedValue = key; asc.wrappedValue = false }
        } label: {
            Text(label + (active ? (asc.wrappedValue ? " ↑" : " ↓") : ""))
                .font(Theme.mono(10, active ? .bold : .regular))
                .foregroundStyle(active ? Theme.neon : Theme.grayDark)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(NeonClick())
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityValue(active ? (asc.wrappedValue ? t("ascending") : t("descending")) : "")
    }

    func moreBar(total: Int, limit: Binding<Int>, base: Int = 50) -> some View {
        HStack(spacing: 10) {
            Text(String(format: t("showing %d of %d"), min(limit.wrappedValue, total), total))
                .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            if total > limit.wrappedValue {
                Button { limit.wrappedValue += 200 } label: {
                    Text("[+200]").font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                }.buttonStyle(NeonClick())
                Button { limit.wrappedValue = total } label: {
                    Text(t("[ ALL ]")).font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                }.buttonStyle(NeonClick())
            }
            if limit.wrappedValue > base {
                Button { limit.wrappedValue = base } label: {
                    Text(t("[ less ]")).font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                }.buttonStyle(NeonClick())
            }
            Spacer()
        }
    }

    // MARK: Pestañas del módulo

    private var tabsRow: some View {
        HStack(spacing: 6) {
            tabChip(t("ALL"), .all)
            tabChip("RAW (\(model.rawPhotos.count))", .raw)
            tabChip(t("VIDEOS") + " (\(optimizableVideos.count))", .videos)
            tabChip(t("DUPES") + " (\(model.groups.count))", .dupes)
            Spacer()
        }
    }

    private func tabChip(_ label: String, _ value: PhotoTab) -> some View {
        Button { tabRaw = value.rawValue } label: {
            Text(label)
                .font(Theme.mono(11, tab == value ? .bold : .regular))
                .foregroundStyle(tab == value ? Theme.neon : Theme.grayDark)
                .padding(.vertical, 4).padding(.horizontal, 8)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                    tab == value ? Theme.neon : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(NeonClick())
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    var rawTitle: String {
        var s = String(format: t("RAW PHOTOS — %d"), model.rawPhotos.count)
        let n = model.selectedRaws.count
        if n > 0 { s += " · \(n) ✓" }
        return s
    }

    var videosTitle: String {
        var s = String(format: t("BIG VIDEOS (>100 MB) — %d optimizable"), optimizableVideos.count)
        let n = model.selectedVideos.count
        if n > 0 { s += " · \(n) ✓" }
        return s
    }

    @State var showHEVC = false
    @State var navCursor: String?   // fila bajo el cursor de teclado
    @State var expandedTwinRow: String?   // fila con la comparación abierta
    @State var blockedTwin: String?       // aviso: era la última copia sin marcar

    /// Lista sobre la que actúa el teclado según la pestaña visible.
    private func keyboardList() -> [PhotoAsset] {
        switch tab {
        case .videos: return Array(sorted(optimizableVideos, by: videoSort, asc: videoAsc).prefix(videoLimit))
        default:      return shownRaws
        }
    }

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let list = keyboardList()
        guard !list.isEmpty else { return .ignored }
        switch press.key {
        case .downArrow, .upArrow:
            let delta = press.key == .downArrow ? 1 : -1
            let idx = navCursor.flatMap { c in list.firstIndex { $0.id == c } }
                ?? (delta == 1 ? -1 : list.count)
            let m = list[min(max(idx + delta, 0), list.count - 1)]
            navCursor = m.id
            if press.modifiers.contains(.shift) { model.optSelected.insert(m.id) }
            withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(m.id, anchor: .center) }
            return .handled
        case .space:
            guard let c = navCursor, let m = list.first(where: { $0.id == c }) else { return .ignored }
            if model.optSelected.contains(m.id) { model.optSelected.remove(m.id) }
            else { model.optSelected.insert(m.id) }
            return .handled
        case .return:
            guard let c = navCursor, let m = list.first(where: { $0.id == c }) else { return .ignored }
            preview = PreviewTarget(id: m.id, asset: m.asset)
            return .handled
        default:
            return .ignored
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            bodyContent(proxy: proxy)
        }
    }

    private func bodyContent(proxy: ScrollViewProxy) -> some View {
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
                                AssetThumb(asset: w, side: 40)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .stroke(Theme.neon, lineWidth: 1))
                            }
                            ProgressStrip(label: model.paused ? t("PAUSED — " ) + model.optProgress
                                                              : model.optProgress,
                                          fraction: model.optFraction)
                            Button { model.paused.toggle() } label: {
                                Text(model.paused ? t("[ RESUME ]") : t("[ PAUSE ]"))
                                    .font(Theme.mono(11, .bold)).foregroundStyle(Theme.neon)
                                    .padding(.vertical, 4).padding(.horizontal, 6)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
                            }
                            .buttonStyle(NeonClick())
                            Button { model.stopRequested = true; model.paused = false } label: {
                                Text(t("[ STOP ]"))
                                    .font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
                                    .padding(.vertical, 4).padding(.horizontal, 6)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.amber, lineWidth: 1))
                            }
                            .buttonStyle(NeonClick())
                            .help(t("Finishes the current item and imports what's already converted"))
                        }
                    }
                    if let d = model.cacheDate, !model.scanning {
                        Text(String(format: t("// saved results from %@ — re-analyze if the library changed"),
                                    Self.df.string(from: d)))
                            .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    }
                    if let days = model.daysSinceFullScan, days > 30, !model.scanning {
                        Text(String(format: t("// last FULL analysis %d days ago — RE-ANALYZE ALL also matches new photos against old ones"), days))
                            .font(Theme.mono(10)).foregroundStyle(Theme.amber)
                    }
                    switch model.status {
                    case .notDetermined:
                        askAccess
                    case .denied, .restricted:
                        TerminalPanel(title: t("NO ACCESS"), collapsible: false) {
                            Text(t("Grant Photos access in System Settings → Privacy → Photos"))
                                .font(Theme.body).foregroundStyle(Theme.amber)
                        }
                    default:
                        tabsRow
                        if tab == .all || tab == .raw { rawSection }
                        if tab == .all || tab == .videos { videosSection }
                        if tab == .all || tab == .dupes { dupesSection }
                    }
                }
                .padding(20)
            }
            footer
        }
        .background(Theme.bg)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handleKey($0, proxy: proxy) }
        .onAppear { model.refreshStatus() }
        .sheet(item: $preview) { AssetPreview(target: $0) }
        .sheet(item: $videoOptions) { VideoOptimizeSheet(model: model, target: $0) }
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
                .buttonStyle(NeonClick())
                .disabled(model.optimizing)
                .help(t("Full analysis from scratch (slow with big libraries)"))
            }
            Button { model.requestAndScan() } label: {
                Text(model.scanning ? t("[ ANALYZING… ]")
                     : (model.hasResults ? t("[ UPDATE ANALYSIS ]") : t("[ ANALYZE LIBRARY ]")))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning || model.optimizing ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(NeonClick())
            .disabled(model.scanning || model.optimizing)
            .help(model.hasResults ? t("Only processes what changed since the last analysis") : "")
        }
    }

    private var askAccess: some View {
        TerminalPanel(title: t("PHOTOS ACCESS"), collapsible: false) {
            Text(t("NeonSweep needs to read your library to find duplicates and huge originals. Nothing is deleted without your confirmation; deletions go to \"Recently Deleted\" (recoverable for 30 days)."))
                .font(Theme.body).foregroundStyle(Theme.gray)
            Button { model.requestAndScan() } label: {
                Text(t("[ GRANT ACCESS & ANALYZE ]"))
                    .font(Theme.mono(13, .bold)).foregroundStyle(Theme.neon)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
            }
            .buttonStyle(NeonClick())
        }
    }

    // MARK: Duplicados / similares

    @AppStorage("photos.groupSort") private var groupSortRaw = GroupSort.saving.rawValue
    @AppStorage("photos.groupSortAsc") private var groupSortAsc = false
    private var groupSort: GroupSort { GroupSort(rawValue: groupSortRaw) ?? .saving }

    var filteredGroups: [DupeGroup] {
        let base = model.groups
        let out: [DupeGroup]
        switch groupSort {
        case .saving: out = base.sorted { $0.potentialSaving > $1.potentialSaving }
        case .count:  out = base.sorted { $0.members.count > $1.members.count }
        case .date:   out = base.sorted {
            ($0.members.first?.asset.creationDate ?? .distantPast)
                > ($1.members.first?.asset.creationDate ?? .distantPast)
        }
        }
        return groupSortAsc ? out.reversed() : out
    }

    var visibleSaving: Int64 {
        filteredGroups.map(\.potentialSaving).reduce(0, +)
    }

    func groupSortChip(_ label: String, _ value: GroupSort) -> some View {
        let active = groupSort == value
        return Button {
            if active { groupSortAsc.toggle() } else { groupSortRaw = value.rawValue; groupSortAsc = false }
        } label: {
            Text(label + (active ? (groupSortAsc ? " ↑" : " ↓") : ""))
                .font(Theme.mono(10, active ? .bold : .regular))
                .foregroundStyle(active ? Theme.neon : Theme.grayDark)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(NeonClick())
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityValue(active ? (groupSortAsc ? t("ascending") : t("descending")) : "")
    }

    func tierCount(_ tier: DupeTier) -> Int {
        model.groups.filter { $0.tier == tier }.count
    }

    func tierChip(_ label: String, _ tier: DupeTier?, count: Int) -> some View {
        Button { dupeFilter = tier } label: {
            Text("\(label) (\(count))")
                .font(Theme.mono(10, dupeFilter == tier ? .bold : .regular))
                .foregroundStyle(dupeFilter == tier ? Theme.neon : Theme.grayDark)
                .padding(.vertical, 4).padding(.horizontal, 6)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                    dupeFilter == tier ? Theme.neon : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(NeonClick())
        .accessibilityAddTraits(dupeFilter == tier ? .isSelected : [])
    }

    private var videosSection: some View {
        TerminalPanel(title: videosTitle, id: "photos.videos") {
            if model.bigVideos.isEmpty {
                Text(t("none")).font(Theme.small).foregroundStyle(Theme.grayDark)
            } else {
                HStack {
                    Text(t("recompress to HEVC keeping resolution; the original stays 30 days in Recently Deleted"))
                        .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    Spacer()
                    Text(t("batch profile:")).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    profileChip(t("[optimal]"), "optimal")
                    profileChip(t("[max 1080p]"), "max")
                    optimizeButton(
                        label: t("[ RECOMPRESS SELECTED → HEVC ]"),
                        count: batchVideoCount
                    ) { model.optimizeSelectedVideos(profile: batchProfile) }
                }
                Text(t("// HEVC ✓ = no gain · DUPE? = probable twin, compare before deleting · click the name for conversion profiles"))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                if !model.videoTwins.isEmpty {
                    HStack(spacing: 8) {
                        Text(String(format: t("%d twin groups"), model.videoTwins.count))
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.amber)
                        Text("↓ " + formatBytes(model.twinReclaimable))
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neon)
                        Text(t("// same capture date, duration, resolution and size — always compare first"))
                            .font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
                        Spacer()
                    }
                }
                if optimizableVideos.isEmpty {
                    Text(t("everything already in HEVC ✓"))
                        .font(Theme.body).foregroundStyle(Theme.neonDim)
                } else {
                    sortPicker($videoSort, $videoAsc)
                }
                let shownVideos = Array(sorted(optimizableVideos, by: videoSort, asc: videoAsc).prefix(videoLimit))
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(shownVideos) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            assetRow(m, in: shownVideos, key: "video")
                            if expandedTwinRow == m.id, let g = model.twinGroup(for: m.id) {
                                twinComparison(g)
                            }
                        }
                            .id(m.id)
                            .background(navCursor == m.id ? Theme.bg : .clear)
                            .overlay(alignment: .leading) {
                                if navCursor == m.id {
                                    Rectangle().fill(Theme.neon).frame(width: 2)
                                }
                            }
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
                    .buttonStyle(NeonClick())
                    if showHEVC {
                        let hevcShown = Array(sorted(hevcVideos, by: videoSort, asc: videoAsc).prefix(videoLimit))
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(hevcShown) { m in
                                // Con perfil MÁXIMA los HEVC sí son optimizables (reescala)
                                assetRow(m, in: hevcShown, key: "hevc",
                                         optimizable: batchProfile == .aggressive)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: RAW → HEIC

    var shownRaws: [PhotoAsset] {
        Array(sorted(model.rawPhotos, by: rawSort, asc: rawAsc).prefix(rawLimit))
    }

    private var rawSection: some View {
        TerminalPanel(title: rawTitle, id: "photos.raw") {
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
                    sortPicker($rawSort, $rawAsc)
                    // La pista es lo primero que sobra si no cabe todo
                    Text(t("// Shift-click = range · ↑↓ move · space mark · ↵ preview"))
                        .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                        .lineLimit(1).truncationMode(.tail)
                        .layoutPriority(-1)
                    Spacer()
                    Text(t("HEIC quality:")).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    qualityChip("85", 0.85)
                    qualityChip("90", 0.90)
                    qualityChip("95", 0.95)
                    Button { model.optSelected.formUnion(shownRaws.map(\.id)) } label: {
                        Text(t("[ MARK SHOWN ]"))
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                    }
                    .buttonStyle(NeonClick())
                    .help(t("Marks the visible rows for conversion — the limit below is your batch size"))
                }
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(shownRaws) { m in
                        assetRow(m, in: shownRaws, key: "raw")
                            .id(m.id)
                            .background(navCursor == m.id ? Theme.bg : .clear)
                            .overlay(alignment: .leading) {
                                if navCursor == m.id {
                                    Rectangle().fill(Theme.neon).frame(width: 2)
                                }
                            }
                    }
                }
                moreBar(total: model.rawPhotos.count, limit: $rawLimit)
            }
        }
    }

    // MARK: Componentes comunes

    func assetRow(_ m: PhotoAsset, in list: [PhotoAsset] = [], key: String = "",
                          optimizable: Bool = true) -> some View {
        let isOpt = model.optSelected.contains(m.id)
        return HStack(spacing: 8) {
            if optimizable {
                Button {
                    toggleRow(m, in: list, key: key)
                } label: {
                    Text(isOpt ? "[x]" : "[ ]")
                        .font(Theme.body)
                        .foregroundStyle(isOpt ? Theme.neon : Theme.grayDark)
                        .frame(minWidth: 28, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NeonClick())
                .help(t("Mark to optimize (Shift-click = range from last click)"))
                .accessibilityLabel((m.filename ?? "") + " — " + t("Mark to optimize (Shift-click = range from last click)"))
                .accessibilityValue(isOpt ? t("marked") : t("not marked"))
            } else {
                Text("[·]").font(Theme.body).foregroundStyle(Theme.grayDark)
                    .help(t("Already HEVC — recompressing won't shrink it"))
            }
            AssetThumb(asset: m.asset,
                       width: model.rowThumbWidth, height: model.rowThumbHeight)
                .onTapGesture { preview = PreviewTarget(id: m.id, asset: m.asset) }
                .help(t("Click to preview"))
            if m.asset.mediaType == .video {
                // clic en el nombre = ficha con perfiles de conversión
                Button { videoOptions = PreviewTarget(id: m.id, asset: m.asset) } label: {
                    Text(m.filename ?? "—")
                        .font(Theme.small).foregroundStyle(Theme.neon)
                        .underline()
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(NeonClick())
                .frame(maxWidth: 180, alignment: .leading)
                .help(t("Click for conversion options (optimal / max compression)"))
            } else {
                Text(m.filename ?? "—")
                    .font(Theme.small).foregroundStyle(Theme.gray)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
            }
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
                // Ya no se borra desde aquí: sin ver la otra copia, marcar "borrar"
                // es a ciegas. El botón abre la comparación lado a lado.
                if let g = model.twinGroup(for: m.id) {
                    Text(t("DUPE?"))
                        .font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
                        .help(t("Same duration, resolution and size as another video — probably a duplicate"))
                    let open = expandedTwinRow == m.id
                    Button {
                        expandedTwinRow = open ? nil : m.id
                    } label: {
                        Text(open ? t("[ hide ]")
                                  : String(format: t("[ compare %d ]"), g.members.count))
                            .font(Theme.mono(9, .bold))
                            .foregroundStyle(open ? Theme.neon : Theme.amber)
                            .frame(minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .help(t("Show the other copies side by side before deciding"))
                    if model.selected.contains(m.id) {
                        Text(t("[✗ marked]"))
                            .font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
                    }
                }
            } else {
                if m.isRaw, let ext = m.filename.map({ ($0 as NSString).pathExtension.uppercased() }),
                   !ext.isEmpty {
                    Text(ext)
                        .font(Theme.mono(9, .bold)).foregroundStyle(Theme.neonDim)
                        .help(t("RAW format detected"))
                }
                Text("\(m.asset.pixelWidth)×\(m.asset.pixelHeight)")
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
            }
            Spacer()
            Text(formatBytes(m.fileSize))
                .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neon)
        }
    }

    @AppStorage("heic.quality") private var heicQuality = 0.9

    func qualityChip(_ label: String, _ value: Double) -> some View {
        Button { heicQuality = value } label: {
            Text("[\(label)]")
                .font(Theme.mono(10, abs(heicQuality - value) < 0.001 ? .bold : .regular))
                .foregroundStyle(abs(heicQuality - value) < 0.001 ? Theme.neon : Theme.grayDark)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(NeonClick())
        .accessibilityLabel(t("HEIC quality:") + " \(label)")
        .accessibilityAddTraits(abs(heicQuality - value) < 0.001 ? .isSelected : [])
    }

    func profileChip(_ label: String, _ value: String) -> some View {
        Button { videoProfileRaw = value } label: {
            Text(label)
                .font(Theme.mono(10, videoProfileRaw == value ? .bold : .regular))
                .foregroundStyle(videoProfileRaw == value ? Theme.neon : Theme.grayDark)
                .padding(.vertical, 3).padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(NeonClick())
        .accessibilityAddTraits(videoProfileRaw == value ? .isSelected : [])
    }

    func optimizeButton(label: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(model.optimizing ? t("[ WORKING… ]") : "\(label) (\(count))")
                .font(Theme.mono(12, .bold))
                .foregroundStyle(count == 0 || model.optimizing ? Theme.grayDark : Theme.neon)
                .padding(.vertical, 5).padding(.horizontal, 8)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                    count == 0 || model.optimizing ? Theme.border : Theme.neon, lineWidth: 1))
        }
        .buttonStyle(NeonClick())
        .disabled(count == 0 || model.optimizing)
    }

    static let df: DateFormatter = {
        let d = DateFormatter(); d.dateFormat = "dd-MM-yyyy"; return d
    }()

    static func duration(_ s: TimeInterval) -> String {
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
            .buttonStyle(NeonClick())
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
    var width: CGFloat = 92
    var height: CGFloat?          // nil = cuadrada
    @State private var image: NSImage?

    /// Azúcar para el caso cuadrado, que es el habitual.
    init(asset: PHAsset, side: CGFloat = 92) {
        self.asset = asset
        self.width = side
        self.height = nil
    }

    init(asset: PHAsset, width: CGFloat, height: CGFloat) {
        self.asset = asset
        self.width = width
        self.height = height
    }

    private var h: CGFloat { height ?? width }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.panel)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text("…").font(Theme.small).foregroundStyle(Theme.grayDark)
            }
        }
        // El recorte y la forma de pulsación van AQUÍ, no en quien la usa: una
        // foto vertical con scaledToFill se sale del marco por arriba y por
        // abajo, y `.clipped()` recorta el dibujo pero NO el área sensible al
        // clic. Sin esto, pulsar una miniatura activaba la de la fila de al
        // lado. Por lo mismo, el alto se pide aquí: enmarcar por fuera con un
        // alto menor encoge el dibujo pero deja el área de clic desbordada.
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(RoundedRectangle(cornerRadius: 3))
        .onAppear { load() }
        // Al cambiar el tamaño se vuelve a pedir con más resolución
        .onChange(of: width) { _, _ in load() }
    }

    private func load() {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false
        let scale: CGFloat = 2   // margen para pantallas Retina
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: width * scale, height: h * scale),
            contentMode: .aspectFill, options: opts
        ) { img, _ in
            if let img { image = img }
        }
    }
}
