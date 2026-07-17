import SwiftUI
import Photos
import AppKit

/// Estado de los permisos que la app necesita; pedirlos todos desde el
/// dashboard evita que cada módulo interrumpa con diálogos a mitad de faena.
@MainActor
final class PermissionsModel: ObservableObject {
    static let shared = PermissionsModel()

    @Published var fullDisk = false
    @Published var photos: PHAuthorizationStatus = .notDetermined
    @Published var automation: Bool?   // nil = aún no probado

    private init() {}

    func refresh() {
        photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        Task {
            fullDisk = await Task.detached(priority: .utility) { Self.checkFullDisk() }.value
        }
    }

    /// Heurística FDA: ~/Library/Safari está protegido por TCC; si se puede
    /// listar, tenemos Acceso Total al Disco.
    nonisolated static func checkFullDisk() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Safari"
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    func openFullDiskSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestPhotos() {
        Task { photos = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
    }

    /// Dispara el diálogo de Automatización con un Apple Event inocuo a Finder.
    func requestAutomation() {
        var err: NSDictionary?
        let script = NSAppleScript(source: "tell application \"Finder\" to get name")
        script?.executeAndReturnError(&err)
        automation = (err == nil)
    }
}

struct PermissionsPanel: View {
    @ObservedObject var model = PermissionsModel.shared
    @State private var expanded = false   // con todo concedido, arranca plegado

    private var allGood: Bool {
        model.fullDisk && model.photos == .authorized && model.automation == true
    }

    var body: some View {
        if allGood && !expanded {
            Button { expanded = true } label: {
                HStack(spacing: 6) {
                    Text("[+]").font(Theme.mono(12, .bold)).foregroundStyle(Theme.neonDim)
                    Text("[ " + t("PERMISSIONS") + " ✓ ]")
                        .font(Theme.mono(12, .bold)).foregroundStyle(Theme.neonDim)
                    Text(t("all granted")).font(Theme.mono(10)).foregroundStyle(Theme.gray)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            .padding(.vertical, 10).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
            .onAppear { model.refresh() }
        } else {
            fullPanel
        }
    }

    private var fullPanel: some View {
        TerminalPanel(title: t("PERMISSIONS"), id: "permissions") {
            Text(t("// grant everything once here and the modules won't nag you later"))
                .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            row(t("Full Disk Access"), t("finds ~98% of app leftovers and measures the Trash"),
                ok: model.fullDisk, action: t("[ OPEN SETTINGS ]")) {
                model.openFullDiskSettings()
            }
            row(t("Automation → Finder"), t("needed to empty the Trash"),
                ok: model.automation == true, action: t("[ REQUEST ]")) {
                model.requestAutomation()
            }
            row(t("Photos library"), t("needed by the PHOTOS module"),
                ok: model.photos == .authorized, action: t("[ REQUEST ]")) {
                model.requestPhotos()
            }
        }
        .onAppear { model.refresh() }
    }

    private func row(_ name: String, _ why: String, ok: Bool,
                     action: String, _ tap: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text("●").font(Theme.small)
                .foregroundStyle(ok ? Theme.neon : Theme.amber)
                .shadow(color: ok ? Theme.neon.opacity(0.6) : .clear, radius: 4)
            Text(name).font(Theme.body).foregroundStyle(Theme.gray)
            Text("// " + why).font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                .lineLimit(1)
            Spacer()
            if !ok {
                Button(action: tap) {
                    Text(action)
                        .font(Theme.mono(11, .bold)).foregroundStyle(Theme.neon)
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.neon, lineWidth: 1))
                }
                .buttonStyle(NeonClick())
            } else {
                Text("OK").font(Theme.mono(11, .bold)).foregroundStyle(Theme.neonDim)
            }
        }
    }
}
