import Foundation
import AppKit

// MARK: - Modelos

enum UpdateKind { case formula, cask, appStore }

struct UpdateItem: Identifiable {
    var id: String { "\(kind)-\(name)" }
    let name: String
    let installed: String
    let latest: String
    let kind: UpdateKind
    let masID: String?      // solo App Store
}

// MARK: - Motor

@MainActor
final class UpdatesModel: ObservableObject {
    @Published var brewFound = false
    @Published var masFound = false
    @Published var items: [UpdateItem] = []
    @Published var scanning = false
    @Published var working = false
    @Published var progress = ""
    @Published var lastResult: String?
    @Published var scanned = false

    var brewItems: [UpdateItem] { items.filter { $0.kind != .appStore } }
    var masItems: [UpdateItem] { items.filter { $0.kind == .appStore } }

    // MARK: Detección y escaneo

    func scan() {
        guard !scanning, !working else { return }
        scanning = true
        items = []
        lastResult = nil
        Task {
            let brew = Self.find("brew")
            let mas = Self.find("mas")
            brewFound = brew != nil
            masFound = mas != nil

            var found: [UpdateItem] = []
            if let brew {
                progress = "brew update…"
                _ = await Task.detached(priority: .utility) { Self.run(brew, ["update", "--quiet"]) }.value
                progress = "brew outdated…"
                let (_, out) = await Task.detached(priority: .utility) {
                    Self.run(brew, ["outdated", "--json=v2"])
                }.value
                found += Self.parseBrew(out)
                items = found.sorted { $0.name < $1.name }
            }
            if let mas {
                progress = "mas outdated…"
                let (_, out) = await Task.detached(priority: .utility) { Self.run(mas, ["outdated"]) }.value
                found += Self.parseMas(out)
                items = found.sorted { $0.name < $1.name }
            }
            progress = ""
            scanning = false
            scanned = true
        }
    }

    // MARK: Actualizar

    func upgrade(_ item: UpdateItem) { upgradeSequence([item]) }
    func upgradeAll() { upgradeSequence(items) }

    private func upgradeSequence(_ targets: [UpdateItem]) {
        guard !working, !targets.isEmpty else { return }
        working = true
        Task {
            var ok = 0, failed = 0
            for item in targets {
                progress = String(format: t("upgrading %@…"), item.name)
                let status: Int32 = await Task.detached(priority: .utility) {
                    switch item.kind {
                    case .formula:
                        guard let brew = Self.find("brew") else { return -1 }
                        return Self.run(brew, ["upgrade", item.name]).0
                    case .cask:
                        guard let brew = Self.find("brew") else { return -1 }
                        return Self.run(brew, ["upgrade", "--cask", item.name]).0
                    case .appStore:
                        guard let mas = Self.find("mas"), let id = item.masID else { return -1 }
                        return Self.run(mas, ["upgrade", id]).0
                    }
                }.value
                if status == 0 {
                    ok += 1
                    items.removeAll { $0.id == item.id }
                } else {
                    failed += 1
                }
            }
            progress = ""
            working = false
            lastResult = failed == 0
                ? String(format: t("OK: %d updated"), ok)
                : String(format: t("WARN: %d updated, %d failed (see Terminal for details)"), ok, failed)
        }
    }

    func openAppStore() {
        if let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Helpers

    nonisolated static func find(_ tool: String) -> String? {
        ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private struct BrewOutdated: Codable {
        struct Entry: Codable {
            let name: String
            let installed_versions: [String]
            let current_version: String
        }
        let formulae: [Entry]
        let casks: [Entry]
    }

    nonisolated static func parseBrew(_ json: String) -> [UpdateItem] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(BrewOutdated.self, from: data) else { return [] }
        return parsed.formulae.map {
            UpdateItem(name: $0.name, installed: $0.installed_versions.last ?? "?",
                       latest: $0.current_version, kind: .formula, masID: nil)
        } + parsed.casks.map {
            UpdateItem(name: $0.name, installed: $0.installed_versions.last ?? "?",
                       latest: $0.current_version, kind: .cask, masID: nil)
        }
    }

    /// Formato de `mas outdated`: "446107677  Magnet (2.4.5 -> 2.14.0)"
    nonisolated static func parseMas(_ out: String) -> [UpdateItem] {
        out.split(separator: "\n").compactMap { line in
            let pattern = #"^(\d+)\s+(.+?)\s+\(([^)]+)\s*->\s*([^)]+)\)\s*$"#
            guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
            let m = String(line[r])
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)),
                  match.numberOfRanges == 5,
                  let idR = Range(match.range(at: 1), in: m),
                  let nameR = Range(match.range(at: 2), in: m),
                  let fromR = Range(match.range(at: 3), in: m),
                  let toR = Range(match.range(at: 4), in: m) else { return nil }
            return UpdateItem(name: String(m[nameR]), installed: String(m[fromR]),
                              latest: String(m[toR]), kind: .appStore, masID: String(m[idR]))
        }
    }
}
