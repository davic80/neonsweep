import SwiftUI

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 0) {
            appList
            Rectangle().fill(Theme.border).frame(width: 1)
            detail
        }
        .background(Theme.bg)
        .onAppear { if model.apps.isEmpty { model.loadApps() } }
    }

    // MARK: Lista de apps

    private var appList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("grep:").font(Theme.small).foregroundStyle(Theme.grayDark)
                TextField(t("app name…"), text: $model.search)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.neon)
            }
            .padding(8)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))

            HStack(spacing: 6) {
                Text("sort:").font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                sortButton(t("[name]"), .name)
                sortButton(t("[size]"), .size)
                sortButton(t("[active]"), .running)
            }

            if model.loadingApps {
                Text(t("reading /Applications …"))
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
            }

            NeonScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.filteredApps) { app in
                        Button { model.inspect(app) } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: app.icon)
                                    .resizable().frame(width: 18, height: 18)
                                Text(app.name)
                                    .font(Theme.body)
                                    .foregroundStyle(
                                        model.selectedApp?.id == app.id ? Theme.neon : Theme.gray
                                    )
                                    .lineLimit(1)
                                Spacer()
                                if app.sized && app.totalSize > 0 {
                                    Text(formatBytes(app.totalSize))
                                        .font(Theme.mono(9))
                                        .foregroundStyle(app.totalSize > 2_000_000_000 ? Theme.neon : Theme.grayDark)
                                }
                                if app.hasLoginItem {
                                    Text("●").font(Theme.mono(8)).foregroundStyle(Theme.neonDim)
                                        .help(t("Starts at login (LaunchAgent)"))
                                }
                                if app.isRunning {
                                    Text("●").font(Theme.small).foregroundStyle(Theme.amber)
                                        .help(t("Running"))
                                }
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(
                                model.selectedApp?.id == app.id
                                    ? Theme.panel : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("\(model.filteredApps.count) " + t("apps // Apple (SIP) excluded"))
                .font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Text("●").foregroundStyle(Theme.amber)
                    Text(t("running")).foregroundStyle(Theme.gray)
                }
                HStack(spacing: 3) {
                    Text("●").foregroundStyle(Theme.neonDim)
                        .shadow(color: Theme.neonDim.opacity(0.8), radius: 3)
                    Text(t("starts at login")).foregroundStyle(Theme.gray)
                }
            }
            .font(Theme.mono(10))
            Text(t("size = app + its data in ~/Library"))
                .font(Theme.mono(10)).foregroundStyle(Theme.gray)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func sortButton(_ label: String, _ key: AppSortKey) -> some View {
        Button { model.sortKey = key } label: {
            Text(label)
                .font(Theme.mono(10, model.sortKey == key ? .bold : .regular))
                .foregroundStyle(model.sortKey == key ? Theme.neon : Theme.grayDark)
        }
        .buttonStyle(.plain)
    }

    // MARK: Detalle de restos

    @ViewBuilder
    private var detail: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: app.icon).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(Theme.mono(17, .bold)).foregroundStyle(Theme.neon)
                        Text(app.bundleID).font(Theme.small).foregroundStyle(Theme.grayDark)
                    }
                    Spacer()
                    if app.isRunning {
                        Text(t("[ RUNNING — quit it first ]"))
                            .font(Theme.small).foregroundStyle(Theme.amber)
                    }
                }

                if model.inspecting {
                    HStack(spacing: 8) {
                        Text(t("searching leftovers in ~/Library")).font(Theme.body).foregroundStyle(Theme.gray)
                        BlinkingCursor()
                    }
                } else {
                    leftoverList(app)
                }
                Spacer(minLength: 0)
                footer(app)
            }
            .padding(18)
        } else {
            VStack(spacing: 10) {
                Text("[02] " + t("UNINSTALLER")).font(Theme.title).foregroundStyle(Theme.neon)
                Text(t("pick an app to see everything it leaves on your disk"))
                    .font(Theme.body).foregroundStyle(Theme.gray)
                BlinkingCursor()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func leftoverList(_ app: InstalledApp) -> some View {
        NeonScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.leftovers) { f in
                    HStack(spacing: 8) {
                        Button {
                            if model.checked.contains(f.id) { model.checked.remove(f.id) }
                            else { model.checked.insert(f.id) }
                        } label: {
                            Text(model.checked.contains(f.id) ? "[x]" : "[ ]")
                                .font(Theme.body)
                                .foregroundStyle(model.checked.contains(f.id) ? Theme.neon : Theme.grayDark)
                        }
                        .buttonStyle(.plain)

                        Text(t(f.location))
                            .font(Theme.small).foregroundStyle(Theme.neonDim)
                            .frame(width: 130, alignment: .leading)
                        Text(f.path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(Theme.small).foregroundStyle(Theme.gray)
                            .lineLimit(1).truncationMode(.middle)
                            .help(f.path)
                        if f.kind == .name {
                            Text(t("name?")).font(Theme.mono(9)).foregroundStyle(Theme.amber)
                                .help(t("Matches by name only — review before checking"))
                        }
                        Spacer()
                        Text(formatBytes(f.size))
                            .font(Theme.small)
                            .foregroundStyle(f.size > 100_000_000 ? Theme.neon : Theme.gray)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func footer(_ app: InstalledApp) -> some View {
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
                    .foregroundStyle(model.checked.isEmpty || app.isRunning ? Theme.grayDark : Theme.neon)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        model.checked.isEmpty || app.isRunning ? Theme.border : Theme.neon, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.checked.isEmpty || app.isRunning)
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
    }
}
