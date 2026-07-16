import Photos
import Vision
import AVFoundation
import CoreImage
import CoreMedia
import UniformTypeIdentifiers
import AppKit

// MARK: - Modelos

struct PhotoAsset: Identifiable {
    let id: String            // localIdentifier
    let asset: PHAsset
    var fileSize: Int64
    var isRaw: Bool = false
}

/// Nivel de parecido dentro de un grupo (según la peor distancia interna).
enum DupeTier {
    case exact      // duplicadas (~100%)
    case near       // casi duplicadas (~90%)
    case similar    // misma escena / ráfaga
}

struct DupeGroup: Identifiable {
    let id = UUID()
    var members: [PhotoAsset]
    var tier: DupeTier
    var bestID: String        // el que conviene conservar (mayor resolución/tamaño)
    var totalSize: Int64 { members.map(\.fileSize).reduce(0, +) }
}

// MARK: - Motor

@MainActor
final class PhotosModel: ObservableObject {
    @Published var status: PHAuthorizationStatus = .notDetermined
    @Published var scanning = false
    @Published var optimizing = false
    @Published var progress = ""
    @Published var fraction: Double?
    @Published var groups: [DupeGroup] = []
    @Published var bigVideos: [PhotoAsset] = []
    @Published var rawPhotos: [PhotoAsset] = []
    @Published var selected: Set<String> = []
    @Published var lastResult: String?

    // Umbrales de distancia entre huellas visuales de Vision
    private static let exactThreshold: Float = 0.25    // duplicadas
    private static let nearThreshold: Float = 0.55     // casi duplicadas
    private static let similarThreshold: Float = 0.80  // similares (une el grupo)
    private static let windowSize = 8           // comparar con los N vecinos temporales
    private nonisolated static let bigVideoMinBytes: Int64 = 100_000_000

    var selectedSize: Int64 {
        allAssets.filter { selected.contains($0.id) }.map(\.fileSize).reduce(0, +)
    }
    var selectedCount: Int { selected.count }
    var selectedVideos: [PhotoAsset] { bigVideos.filter { selected.contains($0.id) } }
    var selectedRaws: [PhotoAsset] { rawPhotos.filter { selected.contains($0.id) } }

    private var allAssets: [PhotoAsset] {
        groups.flatMap(\.members) + bigVideos + rawPhotos
    }

    // MARK: Acceso y escaneo

    /// Lee el estado actual del permiso (p. ej. concedido desde el dashboard).
    func refreshStatus() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAndScan() {
        Task {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else { return }
            await scan()
        }
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        groups = []; bigVideos = []; rawPhotos = []; selected = []

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: opts)

        progress = String(format: t("reading library (%d items)…"), fetch.count)
        let fetchCount = fetch.count
        let collected: ([PhotoAsset], [PhotoAsset], [PhotoAsset]) = await Task.detached(priority: .userInitiated) {
            var imgs: [PhotoAsset] = [], vids: [PhotoAsset] = [], raws: [PhotoAsset] = []
            var done = 0
            fetch.enumerateObjects { asset, _, _ in
                done += 1
                if done % 100 == 0 {
                    let f = Double(done) / Double(max(1, fetchCount)) * 0.5
                    Task { @MainActor in self.fraction = f }
                }
                let meta = Self.resourceMeta(of: asset)
                let pa = PhotoAsset(id: asset.localIdentifier, asset: asset,
                                    fileSize: meta.size, isRaw: meta.isRaw)
                switch asset.mediaType {
                case .image:
                    if meta.isRaw { raws.append(pa) }
                    imgs.append(pa)
                case .video:
                    if pa.fileSize >= Self.bigVideoMinBytes { vids.append(pa) }
                default: break
                }
            }
            return (imgs, vids, raws)
        }.value
        let images = collected.0
        bigVideos = collected.1.sorted { $0.fileSize > $1.fileSize }
        rawPhotos = collected.2.sorted { $0.fileSize > $1.fileSize }

        // Huellas visuales + agrupación por ventana temporal
        let total = images.count
        var result: [DupeGroup] = []
        var window: [(PhotoAsset, VNFeaturePrintObservation)] = []
        var current: [(PhotoAsset, VNFeaturePrintObservation)] = []
        var currentWorst: Float = 0   // peor distancia interna del grupo

        func closeGroup() {
            if current.count >= 2 {
                let members = current.map(\.0)
                let best = members.max {
                    let a = $0.asset.pixelWidth * $0.asset.pixelHeight
                    let b = $1.asset.pixelWidth * $1.asset.pixelHeight
                    return a == b ? $0.fileSize < $1.fileSize : a < b
                }!
                let tier: DupeTier = currentWorst < Self.exactThreshold ? .exact
                    : currentWorst < Self.nearThreshold ? .near : .similar
                result.append(DupeGroup(members: members, tier: tier, bestID: best.id))
            }
            current = []; currentWorst = 0
        }

        for (i, pa) in images.enumerated() {
            if i % 25 == 0 {
                progress = String(format: t("analyzing %d/%d…"), i, total)
                fraction = 0.5 + Double(i) / Double(max(1, total)) * 0.5
                await Task.yield()
            }
            guard let print = await Task.detached(priority: .userInitiated, operation: {
                Self.featurePrint(for: pa.asset)
            }).value else { continue }

            var joined = false
            if let (_, lastPrint) = current.last {
                var d: Float = .greatestFiniteMagnitude
                try? print.computeDistance(&d, to: lastPrint)
                if d < Self.similarThreshold {
                    current.append((pa, print))
                    currentWorst = max(currentWorst, d)
                    joined = true
                }
            }
            if !joined {
                closeGroup()
                for (prev, prevPrint) in window.suffix(Self.windowSize).reversed() {
                    var d: Float = .greatestFiniteMagnitude
                    try? print.computeDistance(&d, to: prevPrint)
                    if d < Self.similarThreshold {
                        current = [(prev, prevPrint), (pa, print)]
                        currentWorst = d
                        break
                    }
                }
            }
            window.append((pa, print))
            if window.count > Self.windowSize * 2 { window.removeFirst() }
        }
        closeGroup()

        // Los grupos más gordos primero (la vista además los renderiza con tope)
        groups = result.sorted { $0.totalSize > $1.totalSize }
        // Preselección: solo duplicadas exactas, todo menos la mejor
        for g in groups where g.tier == .exact {
            for m in g.members where m.id != g.bestID { selected.insert(m.id) }
        }
        progress = ""
        fraction = nil
        scanning = false
    }

    /// Marca todo el grupo menos la mejor (la mejor nunca es borrable).
    func selectAllButBest(_ g: DupeGroup) {
        for m in g.members where m.id != g.bestID { selected.insert(m.id) }
    }

    // MARK: Borrado (va a "Eliminado recientemente", 30 días recuperable)

    func deleteSelected() {
        // Red de seguridad: la "mejor" de cada grupo jamás entra en el borrado
        let bests = Set(groups.map(\.bestID))
        let ids = selected.subtracting(bests)
        guard !ids.isEmpty else { return }
        let targets = allAssets.filter { ids.contains($0.id) }
        let bytes = targets.map(\.fileSize).reduce(0, +)
        let phAssets = targets.map(\.asset)
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(phAssets as NSArray)
                }
                FreedTracker.shared.addTrashed(bytes)
                lastResult = String(format: t("OK: %d photos → Recently Deleted (%@)"),
                                    targets.count, formatBytes(bytes))
                removeFromLists(ids)
            } catch {
                lastResult = String(format: t("WARN: %@"), error.localizedDescription)
            }
        }
    }

    private func removeFromLists(_ gone: Set<String>) {
        groups = groups.compactMap { g in
            var g2 = g
            g2.members.removeAll { gone.contains($0.id) }
            return g2.members.count >= 2 ? g2 : nil
        }
        bigVideos.removeAll { gone.contains($0.id) }
        rawPhotos.removeAll { gone.contains($0.id) }
        selected.subtract(gone)
    }

    // MARK: Optimización — vídeo → HEVC y RAW → HEIC
    // El original se conserva en "Eliminado recientemente" 30 días: red de seguridad.

    func optimizeSelectedVideos() { optimize(selectedVideos, video: true) }
    func convertSelectedRaws()   { optimize(selectedRaws, video: false) }

    private func optimize(_ targets: [PhotoAsset], video: Bool) {
        guard !optimizing, !targets.isEmpty else { return }
        optimizing = true
        Task {
            var savedTotal: Int64 = 0
            var done = 0, failed = 0
            let n = targets.count
            for (i, pa) in targets.enumerated() {
                progress = String(format: video ? t("recompressing %d/%d…") : t("converting %d/%d…"),
                                  i + 1, n)
                fraction = Double(i) / Double(n)
                let base = Double(i)
                let outURL = await Task.detached(priority: .userInitiated) {
                    video
                        ? await Self.exportHEVC(pa.asset) { itemFrac in
                            Task { @MainActor in self.fraction = (base + itemFrac) / Double(n) }
                          }
                        : Self.rawToHEIC(pa.asset)
                }.value
                guard let outURL,
                      let newSize = (try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? Int64,
                      newSize > 0 else { failed += 1; continue }

                // Solo merece la pena si encoge DE VERDAD (mínimo 15%)
                guard newSize < pa.fileSize * 85 / 100 else {
                    try? FileManager.default.removeItem(at: outURL)
                    failed += 1
                    continue
                }
                do {
                    let original = pa.asset
                    // Conservar el nombre original (con la extensión nueva)
                    let origName = PHAssetResource.assetResources(for: original).first {
                        $0.type == .video || $0.type == .photo
                    }?.originalFilename
                    let resOpts = PHAssetResourceCreationOptions()
                    if let origName {
                        let base = (origName as NSString).deletingPathExtension
                        resOpts.originalFilename = base + (video ? ".mov" : ".heic")
                    }
                    try await PHPhotoLibrary.shared().performChanges {
                        let req = PHAssetCreationRequest.forAsset()
                        req.addResource(with: video ? .video : .photo, fileURL: outURL, options: resOpts)
                        req.creationDate = original.creationDate
                        req.location = original.location
                        PHAssetChangeRequest.deleteAssets([original] as NSArray)
                    }
                    savedTotal += pa.fileSize - newSize
                    done += 1
                } catch {
                    failed += 1
                }
                try? FileManager.default.removeItem(at: outURL)
            }
            FreedTracker.shared.addTrashed(savedTotal)
            let ids = Set(targets.map(\.id))
            removeFromLists(ids)
            progress = ""
            fraction = nil
            optimizing = false
            lastResult = String(format: t("OK: %d optimized, %d skipped — %@ saved (original in Recently Deleted)"),
                                done, failed, formatBytes(savedTotal))
        }
    }

    /// Reexporta un vídeo a HEVC manteniendo resolución (AVAssetExportSession).
    /// `progress` recibe la fracción real de exportación (0…1).
    nonisolated static func exportHEVC(_ asset: PHAsset,
                                       progress: @escaping @Sendable (Double) -> Void) async -> URL? {
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true    // el original puede estar solo en iCloud
        opts.deliveryMode = .highQualityFormat
        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, _ in
                cont.resume(returning: av)
            }
        }
        guard let avAsset else { return nil }

        // Si ya es HEVC, recomprimir no aporta nada: fuera.
        if let track = try? await avAsset.loadTracks(withMediaType: .video).first,
           let desc = try? await track.load(.formatDescriptions).first,
           CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_HEVC {
            return nil
        }

        guard let session = AVAssetExportSession(asset: avAsset,
                                                 presetName: AVAssetExportPresetHEVCHighestQuality)
        else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("neonsweep-\(UUID().uuidString).mov")
        do {
            let export = Task { try await session.export(to: out, as: .mov) }
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
            try await export.value
            progress(1)
            return out
        } catch {
            return nil
        }
    }

    /// Convierte un RAW a HEIC (CIRAWFilter + CIContext, pipeline oficial de Apple).
    nonisolated static func rawToHEIC(_ asset: PHAsset) -> URL? {
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.isNetworkAccessAllowed = true
        opts.version = .original
        var rawData: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, _ in
            rawData = data
        }
        guard let rawData,
              let filter = CIRAWFilter(imageData: rawData, identifierHint: nil),
              let image = filter.outputImage
        else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("neonsweep-\(UUID().uuidString).heic")
        let ctx = CIContext()
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        do {
            try ctx.writeHEIFRepresentation(
                of: image, to: out, format: .RGBA8,
                colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!,
                options: [quality: 0.9])
            return out
        } catch {
            return nil
        }
    }

    // MARK: Helpers

    /// Tamaño y tipo del recurso original del asset.
    nonisolated static func resourceMeta(of asset: PHAsset) -> (size: Int64, isRaw: Bool) {
        let res = PHAssetResource.assetResources(for: asset)
        let primary = res.first {
            $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        } ?? res.first
        let size = (primary?.value(forKey: "fileSize") as? Int64) ?? 0
        let isRaw = res.contains {
            ($0.type == .photo || $0.type == .alternatePhoto || $0.type == .fullSizePhoto)
                && (UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false)
        }
        return (size, isRaw)
    }

    /// Códec del vídeo ("HEVC ✓", "H.264", "ProRes"…) para mostrar en la fila.
    nonisolated static func codecLabel(for asset: PHAsset) async -> String {
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = false
        opts.deliveryMode = .fastFormat
        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, _ in
                cont.resume(returning: av)
            }
        }
        guard let avAsset,
              let track = try? await avAsset.loadTracks(withMediaType: .video).first,
              let desc = try? await track.load(.formatDescriptions).first
        else { return "?" }
        switch CMFormatDescriptionGetMediaSubType(desc) {
        case kCMVideoCodecType_HEVC:  return "HEVC ✓"
        case kCMVideoCodecType_H264:  return "H.264"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444,
             kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT:
            return "ProRes"
        default: return "otro"
        }
    }

    /// Huella visual de Vision sobre una miniatura local (sin descargar de iCloud).
    nonisolated static func featurePrint(for asset: PHAsset) -> VNFeaturePrintObservation? {
        let opts = PHImageRequestOptions()
        opts.isSynchronous = true
        opts.deliveryMode = .fastFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false   // no tirar de red: solo miniaturas locales
        var cg: CGImage?
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: 224, height: 224),
            contentMode: .aspectFill, options: opts
        ) { img, _ in
            cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let cg else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
}
