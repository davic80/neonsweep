import SwiftUI

struct ICloudDupesView: View {
    @ObservedObject var model: ICloudDupesModel
    @State private var confirming = false
    @State private var shownLimit = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeonScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if model.scanning {
                        ProgressStrip(label: model.progress, fraction: model.fraction)
                    }
                    summaryPanel
                    groupsPanel
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
            Text("neonsweep --icloud-dupes").font(Theme.mono(14, .bold)).foregroundStyle(Theme.neon)
            if !model.scanning { BlinkingCursor() }
            Spacer()
            Button { model.scan() } label: {
                Text(model.scanning ? t("[ SCANNING… ]") : t("[ SCAN ICLOUD DRIVE ]"))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(NeonClick())
            .disabled(model.scanning)
        }
    }

    private var summaryPanel: some View {
        TerminalPanel(title: t("EXACT FILE DUPLICATES IN ICLOUD DRIVE"), id: "icloud.summary") {
            Text(t("// SHA-256 over downloaded files ≥1 MB; deleting frees space here AND in the cloud after sync. Not-downloaded files are skipped (hashing them would download everything)."))
                .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            HStack(spacing: 20) {
                if model.scanned {
                    Text(String(format: t("%d duplicate groups"), model.groups.count))
                        .font(Theme.body).foregroundStyle(Theme.gray)
                    Text(String(format: t("wasted: %@"), formatBytes(model.wastedTotal)))
                        .font(Theme.mono(15, .bold)).foregroundStyle(Theme.neon)
                        .shadow(color: Theme.neon.opacity(0.5), radius: 5)
                    if model.skippedNotDownloaded > 0 {
                        Text(String(format: t("%d not downloaded, skipped"), model.skippedNotDownloaded))
                            .font(Theme.small).foregroundStyle(Theme.grayDark)
                    }
                } else {
                    Text(t("press SCAN to start")).font(Theme.body).foregroundStyle(Theme.grayDark)
                }
                Spacer()
                if !model.groups.isEmpty {
                    Button { model.markAllButKeep() } label: {
                        Text(t("[ MARK ALL BUT KEPT ]"))
                            .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neon)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
                    }
                    .buttonStyle(NeonClick())
                }
            }
        }
    }

    private var groupsPanel: some View {
        TerminalPanel(title: String(format: t("GROUPS — %d"), model.groups.count), id: "icloud.groups") {
            if model.groups.isEmpty && model.scanned {
                Text(t("no duplicates — clean as a whistle"))
                    .font(Theme.body).foregroundStyle(Theme.neonDim)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.groups.prefix(shownLimit)) { g in
                    groupRow(g)
                }
            }
            if model.groups.count > shownLimit {
                Button { shownLimit += 200 } label: {
                    Text(String(format: t("showing %d of %d"), shownLimit, model.groups.count) + " [+200]")
                        .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neonDim)
                }
                .buttonStyle(NeonClick())
            }
        }
    }

    private func groupRow(_ g: FileDupeGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(g.files.count)× \(formatBytes(g.size))")
                    .font(Theme.mono(11, .bold)).foregroundStyle(Theme.neon)
                Text(String(format: t("wasted: %@"), formatBytes(g.wasted)))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                Spacer()
            }
            ForEach(g.files, id: \.self) { f in
                fileRow(f, group: g)
            }
        }
        .padding(.bottom, 4)
    }

    private func fileRow(_ f: String, group g: FileDupeGroup) -> some View {
        let isKeep = f == g.keep
        let isSel = model.checked.contains(f)
        let display = f.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Mobile Documents/", with: "")
        return HStack(spacing: 8) {
            if isKeep {
                Text("★").font(Theme.body).foregroundStyle(Theme.neonDim)
                    .frame(minWidth: 28)
                    .help(t("kept"))
            } else {
                Button {
                    if isSel { model.checked.remove(f) } else { model.checked.insert(f) }
                } label: {
                    Text(isSel ? "[x]" : "[ ]")
                        .font(Theme.body)
                        .foregroundStyle(isSel ? Theme.neon : Theme.grayDark)
                        .frame(minWidth: 28, minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NeonClick())
                .accessibilityLabel(display)
                .accessibilityValue(isSel ? t("marked") : t("not marked"))
            }
            Text(display)
                .font(Theme.small)
                .foregroundStyle(isKeep ? Theme.neonDim : Theme.gray)
                .lineLimit(1).truncationMode(.middle)
                .help(f)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if let r = model.lastResult {
                Text(r).font(Theme.small)
                    .foregroundStyle(r.hasPrefix("OK") ? Theme.neon : Theme.amber)
            }
            Spacer()
            Text("\(model.checked.count) " + t("checked =") + " \(formatBytes(model.checkedSize))")
                .font(Theme.body).foregroundStyle(Theme.gray)
            Button { confirming = true } label: {
                Text(t("[ MOVE TO TRASH ]"))
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(model.checked.isEmpty ? Theme.grayDark : Theme.neon)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        model.checked.isEmpty ? Theme.border : Theme.neon, lineWidth: 1))
            }
            .buttonStyle(NeonClick())
            .disabled(model.checked.isEmpty)
            .confirmationDialog(
                String(format: t("Move %d items (%@) to the Trash?"),
                       model.checked.count, formatBytes(model.checkedSize)),
                isPresented: $confirming
            ) {
                Button(t("Move to Trash"), role: .destructive) { model.trashChecked() }
                Button(t("Cancel"), role: .cancel) {}
            } message: {
                Text(t("Everything goes to the macOS Trash: you can restore it from Finder."))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .top)
    }
}
