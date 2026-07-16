import Foundation

// MARK: - Objetivos de [04] BASURA DEV

enum DevJunkSpecs {
    static let all: [JunkCategorySpec] = [
        JunkCategorySpec(
            id: "deriveddata", name: "XCODE DERIVEDDATA",
            note: "intermediate builds per project; Xcode regenerates them when building",
            scan: { JunkFS.childDirs("\(JunkFS.home)/Library/Developer/Xcode/DerivedData") }),
        JunkCategorySpec(
            id: "devicesupport", name: "XCODE DEVICE SUPPORT",
            note: "symbols for every iOS version you plugged in; only your current iPhone's is needed",
            scan: { JunkFS.childDirs("\(JunkFS.home)/Library/Developer/Xcode/iOS DeviceSupport") }),
        JunkCategorySpec(
            id: "simulators", name: "iOS SIMULATORS",
            note: "simulated devices and their data; recreating one from Xcode is free",
            scan: { simulators() }),
        JunkCategorySpec(
            id: "containers", name: "DOCKER / VMs",
            note: "WARNING: this deletes ALL your local images and containers — prefer `docker system prune` to trim",
            scan: { JunkFS.labeledPaths([
                ("Docker Desktop (data)", "\(JunkFS.home)/Library/Containers/com.docker.docker/Data"),
                ("Colima", "\(JunkFS.home)/.colima"),
                ("OrbStack (data)", "\(JunkFS.home)/.orbstack"),
            ]) }),
        JunkCategorySpec(
            id: "pkgcaches", name: "PACKAGE MANAGER CACHES",
            note: "npm/pip/brew/etc. will re-download if needed",
            scan: { JunkFS.labeledPaths([
                ("npm", "\(JunkFS.home)/.npm"),
                ("yarn", "\(JunkFS.home)/Library/Caches/Yarn"),
                ("pnpm", "\(JunkFS.home)/Library/pnpm/store"),
                ("pip", "\(JunkFS.home)/Library/Caches/pip"),
                ("poetry", "\(JunkFS.home)/Library/Caches/pypoetry"),
                ("uv", "\(JunkFS.home)/.cache/uv"),
                ("uv (Caches)", "\(JunkFS.home)/Library/Caches/uv"),
                ("pipenv", "\(JunkFS.home)/Library/Caches/pipenv"),
                ("Homebrew", "\(JunkFS.home)/Library/Caches/Homebrew"),
                ("cargo (registry)", "\(JunkFS.home)/.cargo/registry"),
                ("gradle", "\(JunkFS.home)/.gradle/caches"),
                ("CocoaPods", "\(JunkFS.home)/Library/Caches/CocoaPods"),
                ("Go modules", "\(JunkFS.home)/go/pkg/mod"),
                ("SwiftPM", "\(JunkFS.home)/Library/Caches/org.swift.swiftpm"),
                ("Maven", "\(JunkFS.home)/.m2/repository"),
            ]) }),
        JunkCategorySpec(
            id: "nodemodules", name: "FORGOTTEN NODE_MODULES",
            note: "project dependencies; `npm install` recreates them — check the project date",
            scan: { forgottenDirs(named: ["node_modules"], hidden: false) }),
        JunkCategorySpec(
            id: "venvs", name: "FORGOTTEN VENVS",
            note: "Python virtualenvs; `uv sync` / `poetry install` recreates them — check the project date",
            scan: { forgottenDirs(named: [".venv", "venv"], hidden: true) }),
    ]

    // MARK: Simuladores con nombre legible

    nonisolated private static func simulators() -> [JunkEntry] {
        let base = "\(JunkFS.home)/Library/Developer/CoreSimulator/Devices"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        return names.compactMap { n in
            let p = "\(base)/\(n)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
            let size = ScanModel.directorySize(URL(fileURLWithPath: p))
            guard size > 0 else { return nil }
            var label = n
            var runtime: String?
            if let plist = NSDictionary(contentsOfFile: "\(p)/device.plist") {
                label = plist["name"] as? String ?? n
                if let r = plist["runtime"] as? String {
                    runtime = r.components(separatedBy: ".").last?
                        .replacingOccurrences(of: "-", with: " ")
                }
            }
            return JunkEntry(name: label, path: p, size: size, detail: runtime)
        }
    }

    // MARK: directorios de dependencias en proyectos sin tocar

    /// Busca directorios con los nombres dados bajo las carpetas de proyectos.
    /// `hidden: true` permite encontrar nombres que empiezan por punto (.venv).
    nonisolated private static func forgottenDirs(named targets: [String], hidden: Bool) -> [JunkEntry] {
        let fm = FileManager.default
        let df = DateFormatter()
        df.dateFormat = "dd-MM-yyyy"
        // No entramos en carpetas del sistema/medios ni ocultas
        let skipRoots: Set<String> = [
            "Library", "Applications", "Pictures", "Movies", "Music",
            "Public", "Desktop",
        ]
        var results: [JunkEntry] = []

        func walk(_ dir: String, depth: Int) {
            guard depth <= 4, results.count < 100 else { return }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names {
                let isTarget = targets.contains(n)
                if n.hasPrefix("."), !(hidden && isTarget) { continue }
                let p = "\(dir)/\(n)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                if isTarget {
                    let size = ScanModel.directorySize(URL(fileURLWithPath: p))
                    guard size > 20_000_000 else { continue }   // ignorar los diminutos
                    let projectName = (dir as NSString).lastPathComponent
                    let mod = (try? fm.attributesOfItem(atPath: dir))?[.modificationDate] as? Date
                    results.append(JunkEntry(
                        name: "\(projectName)/\(n)", path: p, size: size,
                        detail: mod.map { String(format: t("project modified %@"), df.string(from: $0)) }))
                } else if n != "node_modules" {   // no descender a dependencias
                    walk(p, depth: depth + 1)
                }
            }
        }

        for n in (try? fm.contentsOfDirectory(atPath: JunkFS.home)) ?? [] {
            guard !n.hasPrefix("."), !skipRoots.contains(n) else { continue }
            let p = "\(JunkFS.home)/\(n)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            walk(p, depth: 1)
        }
        return results
    }
}
