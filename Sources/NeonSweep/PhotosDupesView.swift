import SwiftUI
import Photos

// Sección de duplicados: filtros por nivel, slider de similitud y grupos.
extension PhotosView {
    var dupesSection: some View {
        TerminalPanel(title: String(format: t("DUPLICATES & SIMILAR — %d groups"), model.groups.count), id: "photos.dupes") {
            if model.groups.isEmpty && !model.scanning {
                Text(t("no groups detected (or not analyzed yet)"))
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
            } else {
                HStack(spacing: 6) {
                    Text(t("preset:")).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    presetChip(t("DUPLICATES"), PhotosModel.exactThreshold)
                    presetChip(t("NEAR-DUPLICATES"), PhotosModel.nearThreshold)
                    presetChip(t("SIMILAR"), PhotosModel.similarThreshold)
                    Spacer()
                    let bulkTier: DupeTier = model.similarity <= PhotosModel.exactThreshold ? .exact
                        : model.similarity <= PhotosModel.nearThreshold ? .near : .similar
                    Button { model.selectAll(tier: bulkTier) } label: {
                        Text(String(format: t("[ MARK ALL: %@ ]"), tierName(bulkTier)))
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neon)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
                    }
                    .buttonStyle(NeonClick())
                    .help(t("Marks every group of this tier except the best of each"))
                }
                similaritySlider
                HStack(spacing: 6) {
                    Text("sort:").font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    groupSortChip(t("[saving]"), .saving)
                    groupSortChip(t("[photos]"), .count)
                    groupSortChip(t("[date]"), .date)
                    thumbSizeControl
                    Spacer()
                    Text(String(format: t("potential saving here: %@"), formatBytes(visibleSaving)))
                        .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neon)
                        .shadow(color: Theme.neon.opacity(0.4), radius: 4)
                }
                Text(t("nothing is pre-checked — you decide // BEST = favourite > GPS > oldest real date > resolution > size; tap ☆ to choose another"))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                if model.protectedFavorites > 0 {
                    Text(String(format: t("// %d favourites left out of bulk marking — check them one by one if you really want them gone"),
                                model.protectedFavorites))
                        .font(Theme.mono(10)).foregroundStyle(Theme.neonDim)
                }
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(filteredGroups.prefix(maxGroupsShown)) { g in
                    groupRow(g)
                }
            }
            if filteredGroups.count > maxGroupsShown {
                Text(String(format: t("… and %d more groups — clean these first and re-analyze"),
                            filteredGroups.count - maxGroupsShown))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            }
        }
    }

    /// Slider de similitud: re-agrupa al instante (las distancias ya están
    /// calculadas, no hay que volver a analizar).
    /// Los presets mueven el slider al umbral de cada nivel: un solo control
    /// (el umbral) con tres atajos, en vez de dos filtros compitiendo.
    func presetChip(_ label: String, _ value: Float) -> some View {
        let active = abs(model.similarity - value) < 0.001
        return Button { model.setSimilarity(value) } label: {
            Text(label)
                .font(Theme.mono(10, active ? .bold : .regular))
                .foregroundStyle(active ? Theme.neon : Theme.grayDark)
                .padding(.vertical, 4).padding(.horizontal, 6)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                    active ? Theme.neon : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(NeonClick())
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(String(format: t("Sets the threshold to %.2f"), value))
    }

    private var similaritySlider: some View {
        HStack(spacing: 10) {
            Text(t("similarity:")).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            Text(t("strict")).font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
            Slider(value: Binding(
                get: { Double(model.similarity) },
                set: { model.setSimilarity(Float($0)) }
            ), in: 0.10...Double(PhotosModel.similarThreshold))
            .frame(maxWidth: 260)
            .tint(Theme.neon)
            .accessibilityLabel(t("similarity:"))
            .accessibilityValue(String(format: "%.2f", model.similarity))
            Text(t("loose")).font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
            Text(String(format: "%.2f", model.similarity))
                .font(Theme.mono(11, .bold)).foregroundStyle(Theme.neon)
                .frame(width: 40, alignment: .trailing)
            Spacer()
        }
    }

    private func groupRow(_ g: DupeGroup) -> some View {
        let markedInGroup = g.members.filter { model.selected.contains($0.id) }
        let bestMarked = model.selected.contains(g.bestID)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                tierTag(g.tier)
                Text(String(format: t("%d photos // %@"), g.members.count, formatBytes(g.totalSize)))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                Text("↓ " + formatBytes(g.potentialSaving))
                    .font(Theme.mono(11, .bold)).foregroundStyle(Theme.neon)
                    .help(t("Frees this much if you delete everything but the BEST"))
                Spacer()
                Button { model.selectAllButBest(g) } label: {
                    Text(t("[ ALL BUT BEST ]"))
                        .font(Theme.mono(9, .bold)).foregroundStyle(Theme.neonDim)
                }
                .buttonStyle(NeonClick())
                .help(t("Marks the whole group except the best — you can unmark any to keep more"))
                if !markedInGroup.isEmpty {
                    if bestMarked {
                        Text(t("★ marked!")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
                            .help(t("The BEST of this group is marked for deletion too"))
                    }
                    Button { model.delete(ids: Set(markedInGroup.map(\.id))) } label: {
                        Text(String(format: t("[ DELETE (%d) ]"), markedInGroup.count))
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.amber)
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.amber, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .disabled(model.optimizing)
                    .help(t("Deletes only this group's marked photos (system asks to confirm)"))
                }
                Button { model.deleteWholeGroup(g) } label: {
                    Text(t("[ DELETE WHOLE SET ]"))
                        .font(Theme.mono(9, .bold)).foregroundStyle(Theme.grayDark)
                }
                .buttonStyle(NeonClick())
                .disabled(model.optimizing)
                .help(t("Deletes ALL photos in this set, INCLUDING the best (system asks to confirm)"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(g.members) { m in
                        thumbCell(m, group: g)
                    }
                }
                .padding(.vertical, 2)
            }
            // miniatura + fila de estado (20) + fila de datos (~14) + aire
            .frame(height: CGFloat(model.thumbSide) + 44)
        }
    }

    /// Tamaño de miniatura: en un grupo de 12 fotos casi iguales, poder
    /// agrandarlas es la diferencia entre decidir y adivinar.
    var thumbSizeControl: some View {
        HStack(spacing: 4) {
            // fixedSize: en la fila de RAW no cabe y SwiftUI la partía en
            // tres líneas ("min / iat / uras:") antes que encoger a los vecinos
            Text(t("thumbs:")).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                .fixedSize()
                .padding(.leading, 10)
            Button { model.bumpThumb(-24) } label: {
                Text("[-]").font(Theme.mono(10, .bold))
                    .foregroundStyle(model.thumbSide <= 64 ? Theme.grayDark : Theme.neonDim)
                    .frame(minWidth: 26, minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            .disabled(model.thumbSide <= 64)
            .accessibilityLabel(t("thumbs:") + " −")
            Button { model.bumpThumb(24) } label: {
                Text("[+]").font(Theme.mono(10, .bold))
                    .foregroundStyle(model.thumbSide >= 220 ? Theme.grayDark : Theme.neonDim)
                    .frame(minWidth: 26, minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            .disabled(model.thumbSide >= 220)
            .accessibilityLabel(t("thumbs:") + " +")
            Text("\(Int(model.thumbSide))px")
                .font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
                .fixedSize()
                .frame(width: 38, alignment: .leading)
        }
    }

    func tierName(_ tier: DupeTier) -> String {
        switch tier {
        case .exact: return t("DUPLICATES")
        case .near: return t("NEAR-DUPLICATES")
        case .similar: return t("SIMILAR")
        }
    }

    func tierTag(_ tier: DupeTier) -> some View {
        switch tier {
        case .exact:
            Text(t("DUPLICATES")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.neon)
        case .near:
            Text(t("NEAR-DUPLICATES")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
        case .similar:
            Text(t("SIMILAR")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.gray)
        }
    }

    static let timeF: DateFormatter = {
        let d = DateFormatter(); d.dateFormat = "HH:mm:ss"; return d
    }()

    func thumbCell(_ m: PhotoAsset, group g: DupeGroup) -> some View {
        let isBest = m.id == g.bestID
        let isSel = model.selected.contains(m.id)
        let hasGPS = m.asset.location != nil
        let side = CGFloat(model.thumbSide)
        return VStack(spacing: 2) {
            ZStack(alignment: .topLeading) {
                AssetThumb(asset: m.asset, side: side)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(
                        isSel ? Theme.neon : Theme.border, lineWidth: isSel ? 2 : 1))
                if isBest {
                    Text(t("BEST"))
                        .font(Theme.mono(8, .bold)).foregroundStyle(Theme.bg)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Theme.neon)
                } else {
                    // ☆ arriba a la derecha: quedarse esta en lugar de la actual
                    HStack {
                        Spacer()
                        Button { model.setBest(g, to: m.id) } label: {
                            Text("☆").font(Theme.mono(11, .bold)).foregroundStyle(Theme.amber)
                                .padding(4).background(Theme.bg.opacity(0.7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(NeonClick())
                        .help(t("Keep this one instead (becomes the BEST)"))
                        .accessibilityLabel(t("Keep this one instead (becomes the BEST)"))
                    }
                }
            }
            .frame(width: side)
            Text(isSel ? t("[x] delete") : (isBest ? "★ " + t("kept") : "[ ] " + formatBytes(m.fileSize)))
                .font(Theme.mono(10, isSel ? .bold : .regular))
                .foregroundStyle(isSel ? Theme.amber : (isBest ? Theme.neonDim : Theme.grayDark))
                .lineLimit(1)
                .frame(width: side, height: 20)
                .contentShape(Rectangle())
            // datos para decidir: resolución · GPS · hora
            Text("\(m.asset.pixelWidth)×\(m.asset.pixelHeight)"
                 + (hasGPS ? " 📍" : "")
                 + (m.asset.creationDate.map { " " + Self.timeF.string(from: $0) } ?? ""))
                .font(Theme.mono(8))
                .foregroundStyle(hasGPS ? Theme.gray : Theme.grayDark)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side)
        }
        .frame(width: side)
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture(count: 2).onEnded {
            preview = PreviewTarget(id: m.id, asset: m.asset)
        })
        .onTapGesture {
            // La MEJOR también se puede marcar: a veces el set entero sobra
            if isSel { model.selected.remove(m.id) } else { model.selected.insert(m.id) }
        }
        .help(cellHelp(m, isBest: isBest, hasGPS: hasGPS))
        .accessibilityLabel(cellHelp(m, isBest: isBest, hasGPS: hasGPS))
        .accessibilityValue(isBest ? t("kept") : (isSel ? t("marked") : t("not marked")))
    }

    func cellHelp(_ m: PhotoAsset, isBest: Bool, hasGPS: Bool) -> String {
        var parts: [String] = []
        if let n = m.filename { parts.append(n) }
        if let d = m.asset.creationDate {
            parts.append(DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .medium))
        }
        parts.append("\(m.asset.pixelWidth)×\(m.asset.pixelHeight) · \(formatBytes(m.fileSize))")
        parts.append(hasGPS ? t("has GPS location") : t("no GPS location"))
        parts.append(isBest ? t("The best of the group is always kept — double-click to preview")
                            : t("Click to mark, double-click to preview"))
        return parts.joined(separator: "\n")
    }

    // MARK: Vídeos grandes → HEVC

    var optimizableVideos: [PhotoAsset] {
        model.bigVideos.filter { model.codecByID[$0.id] != "HEVC ✓" }
    }
    var hevcVideos: [PhotoAsset] {
        model.bigVideos.filter { model.codecByID[$0.id] == "HEVC ✓" }
    }

}
