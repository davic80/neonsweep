import SwiftUI

@main
struct NeonSweepApp: App {
    init() {
        CLIReport.runIfRequested()
        BenchTranscode.runIfRequested()
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
    case dashboard, diskMap, uninstaller, unusedApps, systemJunk, devJunk, photos, updates, fileDupes
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard:   return t("DASHBOARD")
        case .diskMap:     return t("DISK MAP")
        case .unusedApps:  return t("UNUSED APPS")
        case .uninstaller: return t("UNINSTALLER")
        case .systemJunk:  return t("SYSTEM JUNK")
        case .devJunk:     return t("DEV JUNK")
        case .photos:      return t("PHOTOS")
        case .updates:     return t("UPDATES")
        case .fileDupes:   return t("FILE DUPES")
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
    @StateObject private var icloudDupes = ICloudDupesModel()
    @StateObject private var diskMap = DiskMapModel()
    @StateObject private var unusedApps = UnusedAppsModel()
    @ObservedObject private var tracker = FreedTracker.shared
    @ObservedObject private var lang = Lang.shared
    @ObservedObject private var sfx = SoundFX.shared
    @ObservedObject private var ui = UIScale.shared
    // `--module photos` abre directamente ese módulo (útil para capturas/demos)
    @State private var selected: Module = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--module"), args.count > i + 1,
           let m = Module(rawValue: args[i + 1]) {
            return m
        }
        return .dashboard
    }()
    @State private var dropTargeted = false
    @State private var sweeping = true   // barrido de arranque
    @State private var dbg = AppLog.profileEnabled

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
                    case .fileDupes:
                        ICloudDupesView(model: icloudDupes)
                    case .diskMap:
                        DiskMapView(model: diskMap)
                    case .unusedApps:
                        UnusedAppsView(model: unusedApps) { bundleID in
                            // Salta al desinstalador con esa app ya inspeccionada
                            // (carga la lista antes si aún está vacía)
                            uninstaller.inspect(bundleID: bundleID)
                            selected = .uninstaller
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                TrashBar()
            }
        }
        .id("\(lang.code)-\(ui.factor)")   // idioma o escala reconstruyen la interfaz
        .background(Theme.bg)
        .overlay { if sweeping { SweepOverlay { sweeping = false } } }
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
            SoundFX.shared.play(.boot)
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
        VStack(alignment: .center, spacing: 4) {
            VStack(alignment: .center, spacing: 2) {
                Text("NEONSWEEP")
                    .font(Theme.mono(18, .bold))
                    .foregroundStyle(Theme.neon)
                    .shadow(color: Theme.neon.opacity(0.5), radius: 6)
                Button {
                    AppLog.setProfile(!AppLog.profileEnabled)
                    dbg = AppLog.profileEnabled
                } label: {
                    Text("v0.7.0 // mac cleaner" + (dbg ? " [dbg]" : ""))
                        .font(Theme.mono(10))
                        .foregroundStyle(dbg ? Theme.amber : Theme.grayDark)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NeonClick())
                .help(t("Toggle performance profiling (writes to ~/Library/Logs/NeonSweep.log)"))
            }
            .padding(.bottom, 24)

            // El bloque de módulos va centrado como conjunto, pero por dentro
            // alineado a la izquierda: así los [01]…[09] forman columna en vez
            // de bailar según lo largo que sea cada nombre.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Module.allCases.enumerated()), id: \.element) { idx, m in
                    Button {
                        selected = m
                    } label: {
                        // Sin columna de cursor: el activo se distingue por
                        // color y negrita, y [01] recuerda su ⌘n.
                        HStack(spacing: 6) {
                            Text("[\(m.index)]")
                                .foregroundStyle(selected == m ? Theme.neonDim : Theme.grayDark)
                            Text(m.label)
                                .foregroundStyle(selected == m ? Theme.neon : Theme.gray)
                            Spacer(minLength: 0)
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .font(Theme.mono(13, selected == m ? .bold : .regular))
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                    .help("⌘\(idx + 1)")
                    .accessibilityAddTraits(selected == m ? .isSelected : [])
                }
            }
            // ⌘R: re-escanea/actualiza el módulo activo
            Button("") { rescanCurrent() }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
            Spacer()
            freedCounter
            // Cada ajuste en su fila: con texto grande no se empujan entre sí
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(t("text")).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    Spacer(minLength: 0)
                    Button { ui.bump(-0.1) } label: {
                        Text("[A-]").font(Theme.mono(11, .bold)).foregroundStyle(Theme.neonDim)
                            .frame(minWidth: 34, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .accessibilityLabel(t("Text size") + " −")
                    Button { ui.bump(0.1) } label: {
                        Text("[A+]").font(Theme.mono(11, .bold)).foregroundStyle(Theme.neonDim)
                            .frame(minWidth: 34, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .accessibilityLabel(t("Text size") + " +")
                }
                HStack(spacing: 8) {
                    Text(t("sound")).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    Spacer(minLength: 0)
                    Button { sfx.muted.toggle() } label: {
                        Text(sfx.muted ? "[ off ]" : "[ on ]")
                            .font(Theme.mono(11, .bold))
                            .foregroundStyle(sfx.muted ? Theme.grayDark : Theme.neonDim)
                            .frame(minWidth: 52, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .accessibilityLabel(t("Sound on/off"))
                    .accessibilityValue(sfx.muted ? "off" : "on")
                }
                HStack(spacing: 8) {
                    Text(t("lang")).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                    Spacer(minLength: 0)
                    Button { lang.toggle() } label: {
                        Text(lang.code == "es" ? "[ES|en]" : "[es|EN]")
                            .font(Theme.mono(11, .bold))
                            .foregroundStyle(Theme.neonDim)
                            .frame(minWidth: 52, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NeonClick())
                    .help("Español / English")
                }
                Text(t("// no telemetry\n// nothing deleted without asking"))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.grayDark)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 8).padding(.vertical, 18)
        // Se ajusta al elemento más largo (p. ej. "ACTUALIZACIONES") sin pasarse:
        // los atajos ⌘n viven en el tooltip, no en la fila, para no ensancharlo.
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 120 * Theme.scaleFactor,
               maxWidth: 210 * Theme.scaleFactor, alignment: .center)
        .background(Theme.bg)
    }

    private func rescanCurrent() {
        switch selected {
        case .dashboard:   model.scan()
        case .uninstaller: uninstaller.loadApps()
        case .systemJunk:  systemJunk.scan()
        case .devJunk:     devJunk.scan()
        case .photos:      photos.requestAndScan()
        case .updates:     updates.scan()
        case .fileDupes:   icloudDupes.scan()
        case .diskMap:     diskMap.start()
        case .unusedApps:  unusedApps.scan()
        }
    }

    private var freedCounter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("[ RECLAIMED ]"))
                .font(Theme.mono(10, .bold))
                .foregroundStyle(Theme.neonDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            counterRow(t("→ trash"), tracker.sessionTrashed, dim: true)
            counterRow(t("cleaned today"), tracker.todayPurged)
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
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 6)
            Text(formatBytes(bytes))
                .font(Theme.mono(11, .bold))
                .lineLimit(1)
                .foregroundStyle(bytes == 0 ? Theme.grayDark : (dim ? Theme.neonDim : Theme.neon))
                .shadow(color: !dim && bytes > 0 ? Theme.neon.opacity(0.5) : .clear, radius: 5)
        }
    }
}
