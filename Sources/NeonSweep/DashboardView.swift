import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: ScanModel
    @ObservedObject private var purge = PurgeModel.shared
    @State private var confirmingPurge = false

    var body: some View {
        NeonScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.scanning {
                    ProgressStrip(label: model.currentPath, fraction: model.fraction)
                }
                PermissionsPanel()
                diskPanel
                purgeablePanel
                HStack(alignment: .top, spacing: 14) {
                    icloudPanel
                    recoverablePanel
                }
                junkPanel
            }
            .padding(20)
        }
        .background(Theme.bg)
    }

    // MARK: Header estilo prompt

    private var header: some View {
        HStack(spacing: 6) {
            Text("david@mac:~$")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.gray)
            Text("neonsweep --scan")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.neon)
            if !model.scanning {
                BlinkingCursor()
            }
            Spacer()
            Button {
                model.scan()
            } label: {
                Text(model.scanning ? t("[ SCANNING… ]") : t("[ RESCAN ]"))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(NeonClick())
            .disabled(model.scanning)
        }
    }

    // MARK: Disco

    private var diskPanel: some View {
        TerminalPanel(title: "MACINTOSH HD") {
            let d = model.disk
            let total = Double(max(d.total, 1))
            AsciiBar(segments: [
                (Double(d.used) / total, Theme.neonDim, "█"),
                (Double(d.purgeable) / total, Theme.neon, "▒"),
            ], width: 56)
            HStack(spacing: 22) {
                legend("█", Theme.neonDim, t("USED"), d.used)
                legend("▒", Theme.neon, t("PURGEABLE"), d.purgeable)
                legend("░", Theme.grayDark, t("FREE"), d.free)
                Spacer()
                Text("TOTAL \(formatBytes(d.total))")
                    .font(Theme.small).foregroundStyle(Theme.gray)
            }
        }
    }

    // MARK: Purgable

    private var purgeablePanel: some View {
        TerminalPanel(title: String(format: t("PURGEABLE — %@"), formatBytes(model.disk.purgeable))) {
            Text(t("// space macOS frees on its own when needed: Time Machine local snapshots, evictable iCloud files and system caches. Only the snapshots can be purged on demand:"))
                .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            HStack {
                Text(String(format: t("Time Machine local snapshots: %d"), purge.snapshots.count))
                    .font(Theme.body)
                    .foregroundStyle(purge.snapshots.isEmpty ? Theme.grayDark : Theme.gray)
                if let last = purge.snapshots.last {
                    Text("// \(t("latest")) \(last)")
                        .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                }
                Spacer()
                if let r = purge.lastResult {
                    Text(r).font(Theme.small)
                        .foregroundStyle(r.hasPrefix("OK") ? Theme.neon : Theme.amber)
                }
                Button { confirmingPurge = true } label: {
                    Text(purge.working ? t("[ PURGING… ]") : t("[ DELETE SNAPSHOTS ]"))
                        .font(Theme.mono(11, .bold))
                        .foregroundStyle(purge.snapshots.isEmpty || purge.working ? Theme.grayDark : Theme.amber)
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                            purge.snapshots.isEmpty || purge.working ? Theme.border : Theme.amber, lineWidth: 1))
                }
                .buttonStyle(NeonClick())
                .disabled(purge.snapshots.isEmpty || purge.working)
                .confirmationDialog(
                    String(format: t("Delete %d local Time Machine snapshots?"), purge.snapshots.count),
                    isPresented: $confirmingPurge
                ) {
                    Button(t("Delete snapshots"), role: .destructive) {
                        purge.purgeSnapshots(scanModel: model)
                    }
                    Button(t("Cancel"), role: .cancel) {}
                } message: {
                    Text(t("They are temporary safety copies between Time Machine backups; the next backup recreates them. If you never use Time Machine there is nothing to lose."))
                }
            }
        }
        .onAppear { purge.list() }
    }

    private func legend(_ char: String, _ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Text(char).foregroundStyle(color)
            Text("\(label) \(formatBytes(bytes))").foregroundStyle(Theme.gray)
        }
        .font(Theme.small)
    }

    // MARK: iCloud

    private var icloudPanel: some View {
        TerminalPanel(title: "ICLOUD") {
            row(t("On this Mac"), model.icloud.localSize > 0 ? formatBytes(model.icloud.localSize) : "—")
            row(t("Free in the cloud"), model.icloud.quotaRemaining.map(formatBytes) ?? "…")
            Text(t("// local iCloud Drive files, evictable if you enable Optimize Mac Storage"))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.grayDark)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.gray)
            Spacer()
            Text(value).foregroundStyle(Theme.neon)
        }
        .font(Theme.body)
    }

    // MARK: Recuperable

    private var recoverablePanel: some View {
        TerminalPanel(title: t("RECLAIMABLE")) {
            Text(formatBytes(model.recoverable))
                .font(Theme.big)
                .foregroundStyle(Theme.neon)
                .shadow(color: Theme.neon.opacity(0.6), radius: 8)
            Text(model.scanning ? t("computing…") : t("space you could free"))
                .font(Theme.small)
                .foregroundStyle(Theme.gray)
        }
    }

    // MARK: Tabla de basura

    private var junkPanel: some View {
        TerminalPanel(title: t("DETECTED TARGETS")) {
            ForEach(model.items.filter { $0.exists || model.scanning }) { item in
                HStack(spacing: 0) {
                    Text(t(item.name))
                        .foregroundStyle(item.cleanable ? Theme.gray : Theme.grayDark)
                    Text(" ").foregroundStyle(Theme.grayDark)
                    // línea de puntos estilo índice retro
                    GeometryReader { geo in
                        Text(String(repeating: ".", count: max(3, Int(geo.size.width / 7))))
                            .foregroundStyle(Theme.grayDark.opacity(0.5))
                            .lineLimit(1)
                    }
                    .frame(height: 14)
                    Text(item.size > 0 ? formatBytes(item.size) : (model.scanning ? "…" : "0"))
                        .foregroundStyle(item.size > 5_000_000_000 ? Theme.neon : Theme.gray)
                        .frame(minWidth: 90, alignment: .trailing)
                }
                .font(Theme.body)
                .help(item.path)
            }
            if !model.scanning && model.items.allSatisfy({ !$0.exists }) {
                Text(t("press RESCAN to start"))
                    .font(Theme.body).foregroundStyle(Theme.grayDark)
            }
        }
    }
}
