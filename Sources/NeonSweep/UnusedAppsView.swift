import SwiftUI

struct UnusedAppsView: View {
    @ObservedObject var model: UnusedAppsModel
    var onUninstall: (String) -> Void      // pasa el bundle ID al desinstalador

    private static let df: DateFormatter = {
        let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .none; return d
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeonScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if model.scanning {
                        ProgressStrip(label: model.progress, fraction: model.fraction)
                    }
                    summary
                    listPanel
                }
                .padding(20)
            }
        }
        .background(Theme.bg)
        .onAppear { if !model.scanned && !model.scanning { model.scan() } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("david@mac:~$").font(Theme.mono(14, .bold)).foregroundStyle(Theme.gray)
            Text("neonsweep --unused").font(Theme.mono(14, .bold)).foregroundStyle(Theme.neon)
            if !model.scanning { BlinkingCursor() }
            Spacer()
            Button { model.scan() } label: {
                Text(model.scanning ? t("[ SCANNING… ]") : t("[ RESCAN ]"))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(NeonClick())
            .disabled(model.scanning)
        }
    }

    private var summary: some View {
        TerminalPanel(title: t("APPS YOU DON'T USE"), id: "unused.summary") {
            Text(t("// last-opened date comes from Spotlight (same as Finder's \"Last opened\"). Sorted by how much you'd gain: size × time unused."))
                .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            HStack(spacing: 6) {
                Text("sort:").font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                sortChip(t("[size]"), bySize: true)
                sortChip(t("[unused time]"), bySize: false)
                Spacer()
            }
            HStack(spacing: 12) {
                Text(t("unused for at least:")).font(Theme.body).foregroundStyle(Theme.gray)
                ForEach([7, 30, 90, 180, 365], id: \.self) { d in
                    Button { model.minDays = d } label: {
                        Text(thresholdLabel(d))
                            .font(Theme.mono(10, model.minDays == d ? .bold : .regular))
                            .foregroundStyle(model.minDays == d ? Theme.neon : Theme.grayDark)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .accessibilityAddTraits(model.minDays == d ? .isSelected : [])
                }
                Spacer()
                if model.helperCount > 0 {
                    Button { model.showHelpers.toggle() } label: {
                        Text(String(format: model.showHelpers
                                    ? t("[ hide %d helpers ]") : t("[ show %d helpers ]"),
                                    model.helperCount))
                            .font(Theme.mono(10, model.showHelpers ? .bold : .regular))
                            .foregroundStyle(model.showHelpers ? Theme.neon : Theme.grayDark)
                            .frame(minHeight: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .help(t("URL handlers and background agents: the system launches them, so they never register a last-opened date"))
                }
                if model.scanned {
                    Text(String(format: t("%d apps · %@ reclaimable"),
                                model.filtered.count, formatBytes(model.reclaimable)))
                        .font(Theme.mono(13, .bold)).foregroundStyle(Theme.neon)
                        .shadow(color: Theme.neon.opacity(0.5), radius: 5)
                }
            }
        }
    }

    private func thresholdLabel(_ days: Int) -> String {
        switch days {
        case 7:   return t("[1 week]")
        case 365: return t("[1 year]")
        default:  return String(format: t("[%d months]"), days / 30)
        }
    }

    private func sortChip(_ label: String, bySize: Bool) -> some View {
        let active = model.sortBySize == bySize
        return Button { model.setSort(bySize: bySize) } label: {
            Text(label + (active ? (model.sortAsc ? " ↑" : " ↓") : ""))
                .font(Theme.mono(10, active ? .bold : .regular))
                .foregroundStyle(active ? Theme.neon : Theme.grayDark)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(NeonClick())
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityValue(active ? (model.sortAsc ? t("ascending") : t("descending")) : "")
    }

    private var listPanel: some View {
        TerminalPanel(title: String(format: t("CANDIDATES — %d"), model.filtered.count), id: "unused.list") {
            if model.filtered.isEmpty && model.scanned && !model.scanning {
                Text(t("nothing unused at this threshold ✓"))
                    .font(Theme.body).foregroundStyle(Theme.neonDim)
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(model.filtered) { app in
                    row(app)
                }
            }
        }
    }

    private func row(_ app: UnusedApp) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).font(Theme.body).foregroundStyle(Theme.gray).lineLimit(1)
                    if app.isHelper {
                        Text(t("helper")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.amber)
                            .help(t("Auxiliary app: launched by the system, not by you — \"unused\" does not mean removable"))
                    }
                }
                Text(app.lastUsed.map { Self.df.string(from: $0) } ?? t("never opened"))
                    .font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
            }
            Spacer()
            if let d = app.daysUnused {
                Text(d >= 365
                     ? String(format: t("%d years"), d / 365)
                     : String(format: t("%d months"), max(1, d / 30)))
                    .font(Theme.mono(11, .bold))
                    .foregroundStyle(d > 180 ? Theme.amber : Theme.grayDark)
                    .frame(width: 80, alignment: .trailing)
            }
            Text(formatBytes(app.size))
                .font(Theme.mono(12, .bold))
                .foregroundStyle(app.size > 1_000_000_000 ? Theme.neon : Theme.gray)
                .frame(width: 80, alignment: .trailing)
            Button { model.reveal(app) } label: {
                Text(t("[ FINDER ]")).font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
                    .frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            Button { onUninstall(app.bundleID) } label: {
                Text(t("[ UNINSTALL ]"))
                    .font(Theme.mono(10, .bold)).foregroundStyle(Theme.neon)
                    .padding(.vertical, 4).padding(.horizontal, 7)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            .help(t("Opens it in the uninstaller with all its leftovers"))
        }
    }
}
