import SwiftUI

@main
struct NeonSweepApp: App {
    init() {
        Diag.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

enum Module: String, CaseIterable, Identifiable {
    case dashboard, uninstaller, systemJunk, devJunk, photos, updates
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard:   return t("DASHBOARD")
        case .uninstaller: return t("UNINSTALLER")
        case .systemJunk:  return t("SYSTEM JUNK")
        case .devJunk:     return t("DEV JUNK")
        case .photos:      return t("PHOTOS")
        case .updates:     return t("UPDATES")
        }
    }
    var index: String {
        String(format: "%02d", (Module.allCases.firstIndex(of: self) ?? 0) + 1)
    }
}

struct RootView: View {
    @StateObject private var model = ScanModel()
    @StateObject private var uninstaller = UninstallerModel()
    @StateObject private var systemJunk = JunkModel(specs: SystemJunkSpecs.all)
    @StateObject private var devJunk = JunkModel(specs: DevJunkSpecs.all)
    @StateObject private var photos = PhotosModel()
    @StateObject private var updates = UpdatesModel()
    @ObservedObject private var tracker = FreedTracker.shared
    @ObservedObject private var lang = Lang.shared
    @State private var selected: Module = .dashboard
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(spacing: 0) {
                Group {
                    switch selected {
                    case .dashboard:
                        DashboardView(model: model)
                    case .uninstaller:
                        UninstallerView(model: uninstaller)
                    case .systemJunk:
                        JunkView(model: systemJunk)
                    case .devJunk:
                        JunkView(model: devJunk, prompt: "--dev")
                    case .photos:
                        PhotosView(model: photos)
                    case .updates:
                        UpdatesView(model: updates)
                    }
                }
                .frame(maxHeight: .infinity)
                TrashBar()
            }
        }
        .id(lang.code)   // cambiar de idioma reconstruye la interfaz
        .background(Theme.bg)
        .overlay(alignment: .center) { DropInspectorPanel() }
        .overlay {
            if dropTargeted {
                Rectangle().stroke(Theme.neon, lineWidth: 3)
                    .shadow(color: Theme.neon.opacity(0.7), radius: 10)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let url = await Self.loadURL(from: p) { urls.append(url) }
                }
                DropModel.shared.inspect(urls)
            }
            return true
        }
        .onAppear {
            model.scan()
            TrashModel.shared.refresh()
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NEONSWEEP")
                    .font(Theme.mono(18, .bold))
                    .foregroundStyle(Theme.neon)
                    .shadow(color: Theme.neon.opacity(0.5), radius: 6)
                Text("v0.2.0 // mac cleaner")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.grayDark)
            }
            .padding(.bottom, 24)

            ForEach(Module.allCases) { m in
                Button {
                    selected = m
                } label: {
                    HStack(spacing: 8) {
                        Text(selected == m ? ">" : " ")
                            .foregroundStyle(Theme.neon)
                        Text("[\(m.index)]")
                            .foregroundStyle(Theme.grayDark)
                        Text(m.label)
                            .foregroundStyle(selected == m ? Theme.neon : Theme.gray)
                    }
                    .font(Theme.mono(13, selected == m ? .bold : .regular))
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            freedCounter
            HStack {
                Text(t("// no telemetry\n// nothing deleted without asking"))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.grayDark)
                Spacer()
                Button { lang.toggle() } label: {
                    Text(lang.code == "es" ? "[ES|en]" : "[es|EN]")
                        .font(Theme.mono(10, .bold))
                        .foregroundStyle(Theme.neonDim)
                }
                .buttonStyle(.plain)
                .help("Español / English")
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 230, alignment: .leading)
        .background(Theme.bg)
    }

    private var freedCounter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("[ RECLAIMED ]"))
                .font(Theme.mono(10, .bold))
                .foregroundStyle(Theme.neonDim)
            counterRow(t("→ trash"), tracker.sessionTrashed, dim: true)
            counterRow(t("cleaned today"), tracker.sessionPurged)
            counterRow(t("cleaned total"), tracker.allTimePurged)
        }
        .padding(10)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
    }

    /// Fila del marcador. `dim: true` = aún recuperable (verde apagado);
    /// el resto es espacio liberado de verdad (neón).
    private func counterRow(_ label: String, _ bytes: Int64, dim: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.mono(10)).foregroundStyle(Theme.gray)
            Spacer()
            Text(formatBytes(bytes))
                .font(Theme.mono(11, .bold))
                .foregroundStyle(bytes == 0 ? Theme.grayDark : (dim ? Theme.neonDim : Theme.neon))
                .shadow(color: !dim && bytes > 0 ? Theme.neon.opacity(0.5) : .clear, radius: 5)
        }
    }
}
