import Photos
import Vision
import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Modelos

struct PhotoAsset: Identifiable {
    let id: String            // localIdentifier
    let asset: PHAsset
    var fileSize: Int64
    var isRaw: Bool = false
    var filename: String?
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
    @Published var dupeVideoIDs: Set<String> = []   // vídeos con gemelo probable
    @Published var selected: Set<String> = []
    @Published var lastResult: String?
    @Published var cacheDate: Date?   // los resultados vienen de análisis guardado

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
        // Si hay análisis guardado y aún no se cargó nada, restaurarlo
        if (status == .authorized || status == .limited),
           groups.isEmpty, bigVideos.isEmpty, rawPhotos.isEmpty, !scanning {
            loadCache()
        }
    }

    // MARK: Caché del análisis (reabrir la app no obliga a re-analizar)

    private struct Cache: Codable {
        struct CAsset: Codable { let id: String; let size: Int64; let raw: Bool; let name: String? }
        struct CGroup: Codable { let members: [String]; let tier: Int; let best: String }
        let date: Date
        let assets: [CAsset]
        let groups: [CGroup]
        let videoIDs: [String]
        let rawIDs: [String]
        let dupeVideoIDs: [String]
    }

    private nonisolated static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeonSweep")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("photoscan.json")
    }

    private func saveCache() {
        var seen = Set<String>()
        var assets: [Cache.CAsset] = []
        for pa in groups.flatMap(\.members) + bigVideos + rawPhotos where seen.insert(pa.id).inserted {
            assets.append(Cache.CAsset(id: pa.id, size: pa.fileSize, raw: pa.isRaw, name: pa.filename))
        }
        let cache = Cache(
            date: Date(),
            assets: assets,
            groups: groups.map { g in
                Cache.CGroup(members: g.members.map(\.id),
                             tier: g.tier == .exact ? 0 : g.tier == .near ? 1 : 2,
                             best: g.bestID)
            },
            videoIDs: bigVideos.map(\.id),
            rawIDs: rawPhotos.map(\.id),
            dupeVideoIDs: Array(dupeVideoIDs))
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: Self.cacheURL)
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              !cache.assets.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: cache.assets.map { ($0.id, $0) })
        // Recuperar los PHAsset que sigan existiendo
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: cache.assets.map(\.id), options: nil)
        var phByID: [String: PHAsset] = [:]
        fetch.enumerateObjects { a, _, _ in phByID[a.localIdentifier] = a }

        func rebuild(_ id: String) -> PhotoAsset? {
            guard let ph = phByID[id], let c = byID[id] else { return nil }
            return PhotoAsset(id: id, asset: ph, fileSize: c.size, isRaw: c.raw, filename: c.name)
        }

        groups = cache.groups.compactMap { g in
            let members = g.members.compactMap(rebuild)
            guard members.count >= 2, members.contains(where: { $0.id == g.best }) else { return nil }
            let tier: DupeTier = g.tier == 0 ? .exact : g.tier == 1 ? .near : .similar
            return DupeGroup(members: members, tier: tier, bestID: g.best)
        }
        bigVideos = cache.videoIDs.compactMap(rebuild)
        rawPhotos = cache.rawIDs.compactMap(rebuild)
        dupeVideoIDs = Set(cache.dupeVideoIDs).intersection(phByID.keys)
        cacheDate = cache.date
        AppLog.log("CACHE: restaurado análisis del \(cache.date) (\(groups.count) grupos, \(bigVideos.count) vídeos, \(rawPhotos.count) raws)")
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
                                    fileSize: meta.size, isRaw: meta.isRaw,
                                    filename: meta.filename)
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
        dupeVideoIDs = Self.findDupeVideos(bigVideos)

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
        cacheDate = nil   // resultados frescos
        saveCache()
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
            var done = 0, noGain = 0, failed = 0
            let n = targets.count
            AppLog.log("OPTIMIZE inicio: \(n) elementos, modo \(video ? "vídeo→HEVC" : "RAW→HEIC")")
            for (i, pa) in targets.enumerated() {
                progress = String(format: video ? t("recompressing %d/%d…") : t("converting %d/%d…"),
                                  i + 1, n)
                fraction = Double(i) / Double(n)
                let base = Double(i)

                // Los HEVC no dan ahorro: cuenta como "sin ganancia", no error
                if video, await Self.codecLabel(for: pa.asset) == "HEVC ✓" {
                    AppLog.log("  \(pa.filename ?? pa.id): ya es HEVC, sin ganancia posible")
                    noGain += 1
                    continue
                }
                let outURL = await Task.detached(priority: .userInitiated) {
                    video
                        ? await Self.exportHEVC(pa.asset) { itemFrac in
                            Task { @MainActor in self.fraction = (base + itemFrac) / Double(n) }
                          }
                        : Self.rawToHEIC(pa.asset)
                }.value
                guard let outURL,
                      let newSize = (try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? Int64,
                      newSize > 0 else {
                    AppLog.log("  \(pa.filename ?? pa.id): conversión falló o se omitió (ver líneas previas)")
                    failed += 1
                    continue
                }

                // Solo merece la pena si encoge DE VERDAD (mínimo 15%)
                guard newSize < pa.fileSize * 85 / 100 else {
                    AppLog.log("  \(pa.filename ?? pa.id): sin ganancia (\(pa.fileSize / 1_000_000) MB → \(newSize / 1_000_000) MB), se conserva el original")
                    try? FileManager.default.removeItem(at: outURL)
                    noGain += 1
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
                    AppLog.log("  \(pa.filename ?? pa.id): OK \(pa.fileSize / 1_000_000) MB → \(newSize / 1_000_000) MB")
                } catch {
                    AppLog.log("  \(pa.filename ?? pa.id): error al importar/borrar en Fotos: \(error.localizedDescription)")
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
            AppLog.log("OPTIMIZE fin: \(done) ok, \(noGain) sin ganancia, \(failed) errores, ahorro \(formatBytes(savedTotal))")
            lastResult = String(format: t("%@: %d optimized, %d no gain, %d errors — %@ saved (log: ~/Library/Logs/NeonSweep.log)"),
                                failed == 0 ? "OK" : t("WARN"), done, noGain, failed, formatBytes(savedTotal))
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
            AppLog.log("VIDEO \(asset.localIdentifier): ya es HEVC, omitido")
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
    /// Pide explícitamente el recurso RAW (clave en assets RAW+JPEG o en iCloud).
    nonisolated static func rawToHEIC(_ asset: PHAsset) -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let name = resources.first?.originalFilename ?? asset.localIdentifier
        guard let rawRes = resources.first(where: {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false
        }) else {
            AppLog.log("RAW \(name): sin recurso RAW entre \(resources.map(\.uniformTypeIdentifier))")
            return nil
        }

        var data = Data()
        var reqError: Error?
        let reqOpts = PHAssetResourceRequestOptions()
        reqOpts.isNetworkAccessAllowed = true   // puede estar solo en iCloud
        let sem = DispatchSemaphore(value: 0)
        PHAssetResourceManager.default().requestData(for: rawRes, options: reqOpts) { chunk in
            data.append(chunk)
        } completionHandler: { err in
            reqError = err
            sem.signal()
        }
        sem.wait()
        if let reqError {
            AppLog.log("RAW \(name): error descargando datos: \(reqError.localizedDescription)")
            return nil
        }
        AppLog.log("RAW \(name): \(data.count / 1_000_000) MB de \(rawRes.uniformTypeIdentifier)")

        // El identifierHint es OBLIGATORIO: sin él, el decodificador RAW no
        // identifica la cámara y devuelve una imagen vacía (extent infinito).
        guard let filter = CIRAWFilter(imageData: data, identifierHint: rawRes.uniformTypeIdentifier),
              let image = filter.outputImage,
              !image.extent.isInfinite, !image.extent.isEmpty else {
            AppLog.log("RAW \(name): CIRAWFilter no pudo decodificar (\(rawRes.uniformTypeIdentifier))")
            return nil
        }

        // Render a CGImage y escritura HEIC vía ImageIO (el escritor HEIF de
        // CIContext falla con RAWs grandes: "CINonLocalizedDescriptionKey error 1")
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(image, from: image.extent, format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else {
            AppLog.log("RAW \(name): no se pudo renderizar la imagen")
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("neonsweep-\(UUID().uuidString).heic")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            AppLog.log("RAW \(name): no se pudo crear el destino HEIC")
            return nil
        }
        // Conservar EXIF/TIFF/GPS/IPTC: ImageIO no sabe leer el ARW directo,
        // pero el CIImage del CIRAWFilter trae los metadatos en .properties
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = image.properties[key as String] { props[key] = v }
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            AppLog.log("RAW \(name): CGImageDestinationFinalize falló")
            return nil
        }
        return out
    }

    // MARK: Helpers

    /// Tamaño, tipo y nombre del recurso original del asset.
    nonisolated static func resourceMeta(of asset: PHAsset) -> (size: Int64, isRaw: Bool, filename: String?) {
        let res = PHAssetResource.assetResources(for: asset)
        let primary = res.first {
            $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        } ?? res.first
        let size = (primary?.value(forKey: "fileSize") as? Int64) ?? 0
        let isRaw = res.contains {
            ($0.type == .photo || $0.type == .alternatePhoto || $0.type == .fullSizePhoto)
                && (UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false)
        }
        return (size, isRaw, primary?.originalFilename)
    }

    /// Vídeos con gemelo probable: misma duración (±0,5 s), misma resolución
    /// y tamaño idéntico al 2%. No usa Vision (los vídeos no tienen featureprint).
    nonisolated static func findDupeVideos(_ videos: [PhotoAsset]) -> Set<String> {
        var out: Set<String> = []
        for i in videos.indices {
            for j in (i + 1)..<videos.count {
                let a = videos[i], b = videos[j]
                guard abs(a.asset.duration - b.asset.duration) < 0.5,
                      a.asset.pixelWidth == b.asset.pixelWidth,
                      a.asset.pixelHeight == b.asset.pixelHeight,
                      abs(a.fileSize - b.fileSize) < max(a.fileSize, b.fileSize) / 50
                else { continue }
                out.insert(a.id)
                out.insert(b.id)
            }
        }
        return out
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
