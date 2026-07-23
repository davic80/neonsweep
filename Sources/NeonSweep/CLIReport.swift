import Foundation

/// Modo CLI de solo lectura: `NeonSweep --report [--json]`.
///
/// Deliberadamente NO borra nada. El valor de la app está en revisar antes de
/// actuar, y un limpiador que borra sin supervisión desde un cron es
/// exactamente la clase de herramienta que rompe Macs. Esto sirve para
/// vigilar (¿cuánto se puede recuperar hoy?) y para scripts de monitorización.
enum CLIReport {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--report") else { return }
        let json = args.contains("--json")

        let disk = ScanModel.diskSnapshot()
        var sections: [(String, Int64, String)] = []   // nombre, bytes, detalle

        // Basura de sistema y de desarrollo: se reutilizan las mismas specs
        for (label, specs) in [("system", SystemJunkSpecs.all), ("dev", DevJunkSpecs.all)] {
            for spec in specs {
                let entries = spec.scan()
                let total = entries.map(\.size).reduce(0, +)
                guard total > 0 else { continue }
                sections.append(("\(label).\(spec.id)", total, "\(entries.count) items"))
            }
        }

        // Snapshots locales de Time Machine (purgables a demanda)
        let snaps = PurgeModel.listSnapshots()
        if !snaps.isEmpty {
            sections.append(("timemachine.snapshots", 0, "\(snaps.count) snapshots"))
        }

        let reclaimable = sections.map(\.1).reduce(0, +)

        if json {
            var out: [String: Any] = [
                "disk": [
                    "total": disk.total, "free": disk.free,
                    "purgeable": disk.purgeable, "used": disk.used,
                ],
                "reclaimable": reclaimable,
            ]
            out["sections"] = sections.map { ["id": $0.0, "bytes": $0.1, "detail": $0.2] }
            if let data = try? JSONSerialization.data(withJSONObject: out,
                                                      options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                print(s)
            }
        } else {
            print("NeonSweep — report (read-only)\n")
            print(String(format: "  disk        %@ used · %@ free · %@ purgeable",
                         formatBytes(disk.used), formatBytes(disk.free),
                         formatBytes(disk.purgeable)))
            print(String(format: "  reclaimable %@\n", formatBytes(reclaimable)))
            for (id, bytes, detail) in sections.sorted(by: { $0.1 > $1.1 }) {
                print("  " + pad(id, 28) + " " + pad(formatBytes(bytes), 12, right: true) + "  " + detail)
            }
            print("\n  Nothing was deleted. Open the app to review and clean.")
        }
        exit(0)
    }

    /// Relleno con espacios en Swift puro: `%-28s` sobre `utf8String` apunta a
    /// una NSString temporal ya liberada.
    private static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, width - s.count))
        return right ? fill + s : s + fill
    }
}
