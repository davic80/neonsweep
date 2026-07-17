import SwiftUI

struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeonScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if model.scanning || model.working {
                        ProgressStrip(label: model.progress, fraction: nil)
                    }
                    brewPanel
                    appStorePanel
                }
                .padding(20)
            }
            footer
        }
        .background(Theme.bg)
        .onAppear { if !model.scanned && !model.scanning { model.scan() } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("david@mac:~$").font(Theme.mono(14, .bold)).foregroundStyle(Theme.gray)
            Text("neonsweep --updates").font(Theme.mono(14, .bold)).foregroundStyle(Theme.neon)
            if !model.scanning && !model.working { BlinkingCursor() }
            Spacer()
            Button { model.scan() } label: {
                Text(model.scanning ? t("[ CHECKING… ]") : t("[ CHECK AGAIN ]"))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning || model.working ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(NeonClick())
            .disabled(model.scanning || model.working)
        }
    }

    // MARK: Homebrew

    private var brewPanel: some View {
        TerminalPanel(title: String(format: t("HOMEBREW — %d updates"), model.brewItems.count)) {
            if !model.brewFound {
                Text(t("brew not found on this Mac"))
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
            } else if model.brewItems.isEmpty && model.scanned && !model.scanning {
                Text(t("everything up to date ✓"))
                    .font(Theme.body).foregroundStyle(Theme.neonDim)
            } else {
                ForEach(model.brewItems) { item in
                    updateRow(item, tag: item.kind == .cask ? "cask" : "formula")
                }
            }
        }
    }

    // MARK: App Store

    private var appStorePanel: some View {
        TerminalPanel(title: String(format: t("APP STORE — %d updates"), model.masItems.count)) {
            if !model.masFound {
                HStack {
                    Text(t("install `mas` (brew install mas) to list App Store updates here"))
                        .font(Theme.small).foregroundStyle(Theme.grayDark)
                    Spacer()
                    Button { model.openAppStore() } label: {
                        Text(t("[ OPEN APP STORE ]"))
                            .font(Theme.mono(11, .bold)).foregroundStyle(Theme.neonDim)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(NeonClick())
                }
            } else if model.masItems.isEmpty && model.scanned && !model.scanning {
                Text(t("everything up to date ✓"))
                    .font(Theme.body).foregroundStyle(Theme.neonDim)
            } else {
                ForEach(model.masItems) { item in
                    updateRow(item, tag: "app store")
                }
            }
        }
    }

    private func updateRow(_ item: UpdateItem, tag: String) -> some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(Theme.body).foregroundStyle(Theme.gray)
                .lineLimit(1)
            Text(tag).font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
            Spacer()
            Text(item.installed)
                .font(Theme.small).foregroundStyle(Theme.grayDark)
            Text("→").font(Theme.small).foregroundStyle(Theme.neonDim)
            Text(item.latest)
                .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neon)
            Button { model.upgrade(item) } label: {
                Text(t("[ UPGRADE ]"))
                    .font(Theme.mono(10, .bold))
                    .foregroundStyle(model.working ? Theme.grayDark : Theme.neon)
                    .padding(.vertical, 2).padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        model.working ? Theme.border : Theme.neon, lineWidth: 1))
            }
            .buttonStyle(NeonClick())
            .disabled(model.working)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let r = model.lastResult {
                Text(r).font(Theme.small)
                    .foregroundStyle(r.hasPrefix("OK") ? Theme.neon : Theme.amber)
            }
            Spacer()
            Button { model.upgradeAll() } label: {
                Text(String(format: t("[ UPGRADE ALL (%d) ]"), model.items.count))
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(model.items.isEmpty || model.working ? Theme.grayDark : Theme.neon)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        model.items.isEmpty || model.working ? Theme.border : Theme.neon, lineWidth: 1))
            }
            .buttonStyle(NeonClick())
            .disabled(model.items.isEmpty || model.working)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .top)
    }
}
