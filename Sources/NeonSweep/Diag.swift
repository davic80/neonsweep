import Photos
import AVFoundation
import CoreMedia
import Foundation

/// Modo diagnóstico por CLI: `NeonSweep --diag-videos 2023-12-09`
/// Imprime todos los vídeos de ese día con recursos, códec y bitrate, y sale.
/// Usa el permiso de Fotos de la propia app.
enum Diag {
    private static var log = ""
    private static func out(_ s: String) {
        print(s)
        log += s + "\n"
        try? log.write(toFile: "/tmp/neonsweep-diag.txt", atomically: true, encoding: .utf8)
    }

    static func runIfRequested() {
        runFindIfRequested()
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--diag-videos"), args.count > i + 1 else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let day = df.date(from: args[i + 1]) else {
            out("fecha inválida, usa yyyy-MM-dd"); exit(1)
        }
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
                status = st
                sem.signal()
            }
            sem.wait()
        }
        guard status == .authorized || status == .limited else {
            out("la app no tiene permiso de Fotos (estado \(status.rawValue))"); exit(1)
        }

        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@ AND mediaType = %d",
            start as NSDate, end as NSDate, PHAssetMediaType.video.rawValue)
        let fetch = PHAsset.fetchAssets(with: opts)
        out("vídeos del \(args[i + 1]): \(fetch.count)")

        fetch.enumerateObjects { a, _, _ in
            print("\n=== \(a.localIdentifier)")
            out("  creado: \(a.creationDate.map(String.init(describing:)) ?? "-") | " +
                  "duración \(Int(a.duration) / 60):\(String(format: "%02d", Int(a.duration) % 60)) | " +
                  "\(a.pixelWidth)×\(a.pixelHeight)")
            for r in PHAssetResource.assetResources(for: a) {
                let size = (r.value(forKey: "fileSize") as? Int64) ?? -1
                out(String(format: "  recurso: %@ | %@ | %.1f MB",
                             r.originalFilename, r.uniformTypeIdentifier, Double(size) / 1e6))
            }
            let vo = PHVideoRequestOptions()
            vo.isNetworkAccessAllowed = false
            vo.deliveryMode = .highQualityFormat
            let sem = DispatchSemaphore(value: 0)
            PHImageManager.default().requestAVAsset(forVideo: a, options: vo) { av, _, _ in
                defer { sem.signal() }
                guard let av, let track = av.tracks(withMediaType: .video).first else {
                    out("  (sin AVAsset local)"); return
                }
                if let desc = (track.formatDescriptions as? [CMFormatDescription])?.first {
                    let code = CMFormatDescriptionGetMediaSubType(desc)
                    let bytes: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                                          UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
                    let fourcc = String(bytes: bytes, encoding: .ascii) ?? "?"
                    out("  códec: \(fourcc) | bitrate: \(Int(track.estimatedDataRate / 1000)) kbps | " +
                          "fps: \(track.nominalFrameRate)")
                }
            }
            sem.wait()
        }
        exit(0)
    }

    /// `NeonSweep --diag-find NOMBRE1 NOMBRE2…` — busca assets por nombre de
    /// fichero original e imprime sus recursos (tipo, UTI, tamaño, ¿local?).
    private static func runFindIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--diag-find"), args.count > i + 1 else { return }
        var wanted = Set(args[(i + 1)...].map { $0.lowercased() })

        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
                status = st; sem.signal()
            }
            sem.wait()
        }
        guard status == .authorized || status == .limited else {
            out("la app no tiene permiso de Fotos (estado \(status.rawValue))"); exit(1)
        }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        let fetch = PHAsset.fetchAssets(with: opts)
        out("buscando \(wanted.joined(separator: ", ")) entre \(fetch.count) imágenes…")

        var checked = 0
        fetch.enumerateObjects { a, _, stop in
            autoreleasepool {
                checked += 1
                if checked % 5000 == 0 { out("  …\(checked) revisadas") }
                let resources = PHAssetResource.assetResources(for: a)
                let names = resources.map { $0.originalFilename.lowercased() }
                let hits = wanted.intersection(names)
                guard !hits.isEmpty else { return }
                wanted.subtract(hits)
                out("\n=== \(resources.first?.originalFilename ?? a.localIdentifier)")
                out("  creado: \(a.creationDate.map(String.init(describing:)) ?? "-") | \(a.pixelWidth)×\(a.pixelHeight)")
                for r in resources {
                    let size = (r.value(forKey: "fileSize") as? Int64) ?? -1
                    let local = (r.value(forKey: "locallyAvailable") as? Bool).map { $0 ? "local" : "SOLO iCLOUD" } ?? "¿local?"
                    out(String(format: "  recurso: %@ | %@ | tipo %d | %.1f MB | %@",
                               r.originalFilename, r.uniformTypeIdentifier, r.type.rawValue,
                               Double(size) / 1e6, local))
                }
                if wanted.isEmpty { stop.pointee = true }
            }
        }
        out("\nrevisadas \(checked) imágenes; sin encontrar: \(wanted.isEmpty ? "—" : wanted.joined(separator: ", "))")
        exit(0)
    }
}
