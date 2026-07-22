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

/// Booleano con candado, legible desde cualquier hilo (pausa de transcodificación).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Perfil de conversión de vídeo.
enum VideoProfile {
    case optimal      // HEVC, misma resolución, pérdida casi invisible
    case aggressive   // 1080p + compresión fuerte
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

/// Par de fotos parecidas con su distancia visual. Guardar las aristas (y no
/// solo los grupos) permite re-agrupar con otro umbral al instante, sin
/// recalcular las huellas de Vision.
struct DupeEdge: Codable {
    let a: String
    let b: String
    let d: Float
}

// MARK: - Motor

@MainActor
final class PhotosModel: ObservableObject {
    @Published var status: PHAuthorizationStatus = .notDetermined
    @Published var scanning = false
    @Published var optimizing = false
    @Published var progress = ""          // del análisis
    @Published var fraction: Double?      // del análisis
    @Published var optProgress = ""       // de la optimización (independiente)
    @Published var optFraction: Double?
    @Published var paused = false { didSet { pauseFlag.value = paused } }
    var stopRequested = false
    let pauseFlag = Flag()   // legible desde los hilos de transcodificación
    @Published var groups: [DupeGroup] = []
    @Published var bigVideos: [PhotoAsset] = []
    @Published var rawPhotos: [PhotoAsset] = []
    @Published var dupeVideoIDs: Set<String> = []   // vídeos con gemelo probable
    @Published var codecByID: [String: String] = [:]  // códec por vídeo ("HEVC ✓"…)
    @Published var selected: Set<String> = []      // marcadas para BORRAR
    @Published var optSelected: Set<String> = []   // marcadas para OPTIMIZAR
    @Published var workingAsset: PHAsset?          // elemento en curso (miniatura)
    @Published var lastResult: String?
    @Published var cacheDate: Date?   // los resultados vienen de análisis guardado

    // Umbrales de distancia entre huellas visuales de Vision
    private static let exactThreshold: Float = 0.25    // duplicadas
    private static let nearThreshold: Float = 0.55     // casi duplicadas
    /// Máxima distancia que se guarda como arista; el slider no puede pasar de
    /// aquí sin re-analizar.
    nonisolated static let similarThreshold: Float = 0.80

    /// Umbral activo del slider de similitud (persistido).
    @Published var similarity: Float = {
        let v = UserDefaults.standard.float(forKey: "photos.similarity")
        return v > 0 ? v : PhotosModel.similarThreshold
    }()

    /// Aristas del análisis y fotos implicadas: base para re-agrupar al vuelo.
    private var edges: [DupeEdge] = []
    private var edgeAssets: [String: PhotoAsset] = [:]
    private static let windowSize = 8           // comparar con los N vecinos temporales
    private nonisolated static let bigVideoMinBytes: Int64 = 100_000_000

    /// Trabajadores RAW en paralelo, adaptado a cualquier Apple Silicon:
    /// limita por núcleos (dejando 4 al sistema) y por RAM (~200 MB por RAW
    /// en vuelo → 1 trabajador por cada 2 GB sobre un suelo de 4). Ejemplos:
    /// M1 8GB→2 · M1 16GB→4 · M5 10c/16GB→6 · M3 Max 48GB→12 (tope).
    /// Experimental: `defaults write com.davidcornejo.neonsweep raw.workers N`
    /// fuerza N trabajadores (1-16) para afinar con el perfilado activado.
    nonisolated static var rawWorkers: Int {
        let override = UserDefaults.standard.integer(forKey: "raw.workers")
        if override > 0 { return min(16, override) }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return max(2, min(12, min(cores - 4, (ramGB - 4) / 2)))
    }

    /// CIContext compartido: crearlo es caro y es seguro entre hilos;
    /// reutilizarlo acelera los lotes y reduce el pico de memoria.
    nonisolated static let ciContext = CIContext()

    var selectedSize: Int64 {
        allAssets.filter { selected.contains($0.id) }.map(\.fileSize).reduce(0, +)
    }
    var selectedCount: Int { selected.count }
    // Solo son convertibles los que NO están ya en HEVC
    var selectedVideos: [PhotoAsset] {
        bigVideos.filter { optSelected.contains($0.id) && codecByID[$0.id] != "HEVC ✓" }
    }
    var selectedRaws: [PhotoAsset] { rawPhotos.filter { optSelected.contains($0.id) } }

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

    struct Cache: Codable {
        struct CAsset: Codable { let id: String; let size: Int64; let raw: Bool; let name: String? }
        struct CGroup: Codable { let members: [String]; let tier: Int; let best: String }
        let date: Date
        let assets: [CAsset]
        let groups: [CGroup]
        let videoIDs: [String]
        let rawIDs: [String]
        let dupeVideoIDs: [String]
        // Checkpoint: metadatos de TODAS las imágenes (evita releer 107k por
        // XPC) y hasta qué fecha llegó el análisis si quedó a medias.
        var imageMeta: [CAsset]?
        var analyzedUpTo: Double?
        var partial: Bool?
        /// Aristas de similitud: permiten mover el slider sin re-analizar.
        var edges: [DupeEdge]?
    }

    nonisolated static func loadCacheFile() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private nonisolated static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeonSweep")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("photoscan.json")
    }

    private func saveCache(imageMeta: [Cache.CAsset]? = nil,
                           analyzedUpTo: Double? = nil,
                           partial: Bool = false) {
        var seen = Set<String>()
        var assets: [Cache.CAsset] = []
        // Guardar TODAS las fotos con aristas (no solo las agrupadas ahora):
        // al mover el slider pueden entrar en juego las demás
        for pa in Array(edgeAssets.values) + groups.flatMap(\.members) + bigVideos + rawPhotos
        where seen.insert(pa.id).inserted {
            assets.append(Cache.CAsset(id: pa.id, size: pa.fileSize, raw: pa.isRaw, name: pa.filename))
        }
        // Conservar checkpoint previo cuando el llamante no aporta uno nuevo
        let prev = (imageMeta == nil || analyzedUpTo == nil) ? Self.loadCacheFile() : nil
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
            dupeVideoIDs: Array(dupeVideoIDs),
            imageMeta: imageMeta ?? prev?.imageMeta,
            analyzedUpTo: analyzedUpTo ?? prev?.analyzedUpTo,
            partial: imageMeta == nil ? (prev?.partial ?? false) : partial,
            edges: edges)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: Self.cacheURL)
        }
        // Token del registro de cambios: ancla del próximo análisis incremental
        let token = PHPhotoLibrary.shared().currentChangeToken
        if let tokenData = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                             requiringSecureCoding: true) {
            try? tokenData.write(to: Self.tokenURL)
        }
    }

    private nonisolated static var tokenURL: URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("changetoken.bin")
    }

    nonisolated static func loadChangeToken() -> PHPersistentChangeToken? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self,
                                                       from: data)
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

        // Con aristas guardadas se reconstruyen los grupos con el umbral actual
        if let saved = cache.edges, !saved.isEmpty {
            edges = saved
            edgeAssets = [:]
            for id in Set(saved.flatMap { [$0.a, $0.b] }) {
                if let pa = rebuild(id) { edgeAssets[id] = pa }
            }
            rebuildGroups()
        } else {
            groups = cache.groups.compactMap { g in
                let members = g.members.compactMap(rebuild)
                guard members.count >= 2, members.contains(where: { $0.id == g.best }) else { return nil }
                let tier: DupeTier = g.tier == 0 ? .exact : g.tier == 1 ? .near : .similar
                return DupeGroup(members: members, tier: tier, bestID: g.best)
            }
        }
        bigVideos = cache.videoIDs.compactMap(rebuild)
        rawPhotos = cache.rawIDs.compactMap(rebuild)
        dupeVideoIDs = Set(cache.dupeVideoIDs).intersection(phByID.keys)
        cacheDate = cache.date
        loadVideoCodecs()
        AppLog.log("CACHE: restaurado análisis del \(cache.date) (\(groups.count) grupos, \(bigVideos.count) vídeos, \(rawPhotos.count) raws)")
    }

    /// Resuelve el códec de los vídeos grandes en segundo plano (progresivo).
    private func loadVideoCodecs() {
        let pending = bigVideos.filter { codecByID[$0.id] == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) {
            for v in pending {
                let label = await Self.codecLabel(for: v.asset)
                await MainActor.run { self.codecByID[v.id] = label }
            }
        }
    }

    var hasResults: Bool { !(groups.isEmpty && bigVideos.isEmpty && rawPhotos.isEmpty) }

    /// `fullRescan: false` → incremental si hay análisis previo y token válido.
    func requestAndScan(fullRescan: Bool = false) {
        Task {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else { return }
            if !fullRescan, hasResults, Self.loadCacheFile()?.partial != true,
               let token = Self.loadChangeToken() {
                await incrementalScan(since: token)
            } else {
                await fullScan(resume: !fullRescan)
            }
        }
    }

    /// Solo procesa lo insertado/borrado desde el último análisis (registro
    /// persistente de cambios de Fotos). Lo ya analizado permanece intacto.
    private func incrementalScan(since token: PHPersistentChangeToken) async {
        guard !scanning else { return }
        scanning = true
        progress = t("checking library changes…")
        fraction = nil
        do {
            let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
            var inserted: Set<String> = [], deleted: Set<String> = []
            for change in changes {
                guard let d = try? change.changeDetails(for: .asset) else { continue }
                inserted.formUnion(d.insertedLocalIdentifiers)
                inserted.formUnion(d.updatedLocalIdentifiers)
                deleted.formUnion(d.deletedLocalIdentifiers)
            }
            inserted.subtract(deleted)
            removeFromLists(deleted)
            codecByID = codecByID.filter { !deleted.contains($0.key) }

            var newCount = 0
            if !inserted.isEmpty {
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(inserted), options: opts)
                newCount = fetch.count
                progress = String(format: t("analyzing %d new items…"), newCount)
                let collected = await Self.collect(fetch) { done, total in
                    Task { @MainActor in self.fraction = Double(done) / Double(max(1, total)) * 0.5 }
                }
                let knownV = Set(bigVideos.map(\.id))
                bigVideos = (bigVideos + collected.videos.filter { !knownV.contains($0.id) })
                    .sorted { $0.fileSize > $1.fileSize }
                let knownR = Set(rawPhotos.map(\.id))
                rawPhotos = (rawPhotos + collected.raws.filter { !knownR.contains($0.id) })
                    .sorted { $0.fileSize > $1.fileSize }
                dupeVideoIDs = Self.findDupeVideos(bigVideos)
                loadVideoCodecs()
                // Agrupar solo lo nuevo entre sí (lotes de importación)
                let newGroups = await groupImages(collected.images, baseFraction: 0.5, span: 0.5)
                groups = (groups + newGroups).sorted { $0.totalSize > $1.totalSize }
            }
            pruneSelections()
            progress = ""
            fraction = nil
            scanning = false
            cacheDate = nil
            saveCache()
            lastResult = String(format: t("OK: incremental — %d new, %d removed"), newCount, deleted.count)
            AppLog.log("SCAN incremental: +\(newCount), -\(deleted.count)")
            SoundFX.shared.play(.done)
        } catch {
            AppLog.log("SCAN incremental: token inválido (\(error.localizedDescription)) → análisis completo")
            scanning = false
            await fullScan()
        }
    }

    private func fullScan(resume: Bool = true) async {
        guard !scanning else { return }
        scanning = true

        // Checkpoint previo: metadatos ya leídos y análisis a medias
        let checkpoint = resume ? Self.loadCacheFile() : nil
        let known = Dictionary(uniqueKeysWithValues:
            (checkpoint?.imageMeta ?? []).map { ($0.id, $0) })
        if !known.isEmpty {
            AppLog.log("SCAN: reutilizando metadatos de \(known.count) imágenes del checkpoint")
        }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: opts)

        progress = String(format: t("reading library (%d items)…"), fetch.count)
        let collected = await Self.collect(fetch, known: known) { done, total in
            Task { @MainActor in self.fraction = Double(done) / Double(max(1, total)) * 0.5 }
        }
        let images = collected.images
        let newVideos = collected.videos.sorted { $0.fileSize > $1.fileSize }
        let newRaws = collected.raws.sorted { $0.fileSize > $1.fileSize }
        // RAWs y vídeos disponibles en cuanto termina la lectura
        bigVideos = newVideos
        rawPhotos = newRaws
        dupeVideoIDs = Self.findDupeVideos(newVideos)
        loadVideoCodecs()

        let imgMeta = images.map {
            Cache.CAsset(id: $0.id, size: $0.fileSize, raw: $0.isRaw, name: $0.filename)
        }
        // ¿Análisis a medias? Sembrar los grupos ya hechos y saltar lo analizado
        var seed: [DupeGroup] = []
        var skipUntil: Double?
        if let c = checkpoint, c.partial == true, let upTo = c.analyzedUpTo {
            let byID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
            seed = c.groups.compactMap { g in
                let members = g.members.compactMap { byID[$0] }
                guard members.count >= 2, members.contains(where: { $0.id == g.best }) else { return nil }
                let tier: DupeTier = g.tier == 0 ? .exact : g.tier == 1 ? .near : .similar
                return DupeGroup(members: members, tier: tier, bestID: g.best)
            }
            skipUntil = upTo
            AppLog.log("SCAN: reanudando análisis desde \(Date(timeIntervalSince1970: upTo)) con \(seed.count) grupos previos")
        }

        let newGroups = await groupImages(images, baseFraction: 0.5, span: 0.5,
                                          seed: seed, skipUntil: skipUntil) { partialGroups, upTo in
            // Checkpoint: si la app muere a mitad, se reanuda desde aquí
            self.groups = partialGroups.sorted { $0.totalSize > $1.totalSize }
            self.saveCache(imageMeta: imgMeta,
                           analyzedUpTo: upTo.timeIntervalSince1970, partial: true)
        }

        groups = newGroups.sorted { $0.totalSize > $1.totalSize }
        pruneSelections()
        progress = ""
        fraction = nil
        scanning = false
        cacheDate = nil   // resultados frescos
        saveCache(imageMeta: imgMeta,
                  analyzedUpTo: images.last?.asset.creationDate?.timeIntervalSince1970,
                  partial: false)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "photos.lastFullScan")
        SoundFX.shared.play(.done)
    }

    /// Días desde el último análisis completo (nil si nunca se completó uno).
    var daysSinceFullScan: Int? {
        let ts = UserDefaults.standard.double(forKey: "photos.lastFullScan")
        guard ts > 0 else { return nil }
        return Int(Date().timeIntervalSince1970 - ts) / 86_400
    }

    /// Lee metadatos de un fetch (tamaños, RAW, nombre) fuera del hilo principal.
    nonisolated static func collect(
        _ fetch: PHFetchResult<PHAsset>,
        known: [String: Cache.CAsset] = [:],
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> (images: [PhotoAsset], videos: [PhotoAsset], raws: [PhotoAsset]) {
        await Task.detached(priority: .userInitiated) {
            var imgs: [PhotoAsset] = [], vids: [PhotoAsset] = [], raws: [PhotoAsset] = []
            var done = 0
            let total = fetch.count
            fetch.enumerateObjects { asset, _, _ in
                autoreleasepool {
                    done += 1
                    if done % 100 == 0 { onProgress(done, total) }
                    // Con checkpoint: los metadatos ya conocidos se reutilizan
                    // (evita una llamada XPC por foto — la fase pasa de minutos
                    // a segundos en relanzamientos)
                    let pa: PhotoAsset
                    if let k = known[asset.localIdentifier] {
                        pa = PhotoAsset(id: asset.localIdentifier, asset: asset,
                                        fileSize: k.size, isRaw: k.raw, filename: k.name)
                    } else {
                        let meta = Self.resourceMeta(of: asset)
                        pa = PhotoAsset(id: asset.localIdentifier, asset: asset,
                                        fileSize: meta.size, isRaw: meta.isRaw,
                                        filename: meta.filename)
                    }
                    switch asset.mediaType {
                    case .image:
                        if pa.isRaw { raws.append(pa) }
                        imgs.append(pa)
                    case .video:
                        if pa.fileSize >= Self.bigVideoMinBytes { vids.append(pa) }
                    default: break
                    }
                }
            }
            return (imgs, vids, raws)
        }.value
    }

    /// Las marcas solo pueden apuntar a assets que sigan en las listas.
    private func pruneSelections() {
        let valid = Set(allAssets.map(\.id))
        selected.formIntersection(valid)
        optSelected.formIntersection(valid)
    }

    /// Agrupación por huella visual con ventana temporal. baseFraction/span
    /// mapean el avance de esta fase sobre la barra de progreso.
    private func groupImages(_ images: [PhotoAsset],
                             baseFraction: Double, span: Double,
                             seed: [DupeGroup] = [], skipUntil: Double? = nil,
                             onCheckpoint: ((_ groups: [DupeGroup], _ upTo: Date) -> Void)? = nil) async -> [DupeGroup] {
        let total = images.count
        // Se conservan las aristas previas (checkpoint) y se añaden las nuevas
        var newEdges: [DupeEdge] = seed.isEmpty ? [] : edges
        var window: [(PhotoAsset, VNFeaturePrintObservation)] = []

        for (i, pa) in images.enumerated() {
            // Reanudación: saltar lo ya analizado en el checkpoint
            if let s = skipUntil,
               let d = pa.asset.creationDate, d.timeIntervalSince1970 <= s {
                continue
            }
            if i % 25 == 0 {
                progress = String(format: t("analyzing %d/%d…"), i, total)
                fraction = baseFraction + Double(i) / Double(max(1, total)) * span
                await Task.yield()
            }
            if i % 2500 == 0, i > 0, let cb = onCheckpoint, let d = pa.asset.creationDate {
                edges = newEdges
                rebuildGroups()
                cb(groups, d)
            }
            guard let print = await Task.detached(priority: .userInitiated, operation: {
                Self.featurePrint(for: pa.asset)
            }).value else { continue }

            // Comparar con los vecinos temporales: los duplicados y ráfagas
            // están siempre juntos en el tiempo
            for (prev, prevPrint) in window.suffix(Self.windowSize) {
                var d: Float = .greatestFiniteMagnitude
                try? print.computeDistance(&d, to: prevPrint)
                if d < Self.similarThreshold {
                    newEdges.append(DupeEdge(a: prev.id, b: pa.id, d: d))
                    edgeAssets[prev.id] = prev
                    edgeAssets[pa.id] = pa
                }
            }
            window.append((pa, print))
            if window.count > Self.windowSize * 2 { window.removeFirst() }
        }
        edges = newEdges
        rebuildGroups()
        return groups
    }

    /// Re-agrupa al instante con el umbral actual del slider (union-find sobre
    /// las aristas ya calculadas — sin recalcular huellas).
    func rebuildGroups() {
        let limit = similarity
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ x: String, _ y: String) {
            parent[x] = parent[x] ?? x
            parent[y] = parent[y] ?? y
            let rx = find(x), ry = find(y)
            if rx != ry { parent[rx] = ry }
        }

        var worst: [String: Float] = [:]   // peor distancia dentro del grupo
        for e in edges where e.d <= limit { union(e.a, e.b) }
        for e in edges where e.d <= limit {
            let root = find(e.a)
            worst[root] = max(worst[root] ?? 0, e.d)
        }

        var buckets: [String: [PhotoAsset]] = [:]
        for id in Set(edges.filter { $0.d <= limit }.flatMap { [$0.a, $0.b] }) {
            guard let pa = edgeAssets[id] else { continue }
            buckets[find(id), default: []].append(pa)
        }

        // Conservar las MEJOR elegidas a mano por el usuario
        let manualBest = Set(groups.map(\.bestID))
        groups = buckets.compactMap { root, members in
            guard members.count >= 2 else { return nil }
            let w = worst[root] ?? 0
            let tier: DupeTier = w < Self.exactThreshold ? .exact
                : w < Self.nearThreshold ? .near : .similar
            let best = members.first { manualBest.contains($0.id) }
                ?? members.max { Self.bestScore($0) < Self.bestScore($1) }!
            return DupeGroup(members: members.sorted {
                ($0.asset.creationDate ?? .distantPast) < ($1.asset.creationDate ?? .distantPast)
            }, tier: tier, bestID: best.id)
        }
        .sorted { $0.totalSize > $1.totalSize }
        pruneSelections()
    }

    /// Cambia el umbral del slider y re-agrupa (persistido).
    func setSimilarity(_ v: Float) {
        similarity = v
        UserDefaults.standard.set(v, forKey: "photos.similarity")
        rebuildGroups()
    }

    /// Criterio de "mejor": conserva GPS > la más antigua (con fecha real)
    /// > más resolución > más peso. Las copias re-guardadas pierden GPS y
    /// tienen fecha posterior; una fecha ~epoch (1-1-1970, timestamp 0 o
    /// anterior) es corrupta y nunca gana el criterio de antigüedad.
    nonisolated static func bestScore(_ p: PhotoAsset) -> (Int, Double, Int, Int64) {
        let t = p.asset.creationDate?.timeIntervalSince1970
        // válida si existe y no está pegada al epoch (dos días de margen)
        let dateScore: Double = (t != nil && t! > 172_800) ? -t! : -.greatestFiniteMagnitude
        return (p.asset.location != nil ? 1 : 0,
                dateScore,                                   // más antigua = mayor
                p.asset.pixelWidth * p.asset.pixelHeight,
                p.fileSize)
    }

    /// El usuario elige otra "mejor" para el grupo; la anterior pasa a ser marcable.
    func setBest(_ g: DupeGroup, to id: String) {
        guard let idx = groups.firstIndex(where: { $0.id == g.id }),
              groups[idx].members.contains(where: { $0.id == id }) else { return }
        groups[idx].bestID = id
        selected.remove(id)   // la nueva mejor no puede estar marcada
        saveCache()
    }

    /// Marca todo el grupo menos la mejor (la mejor nunca es borrable).
    func selectAllButBest(_ g: DupeGroup) {
        for m in g.members where m.id != g.bestID { selected.insert(m.id) }
    }

    /// Marca de golpe todas las DUPLICADAS exactas (menos las mejores).
    func selectAllExactDupes() {
        for g in groups where g.tier == .exact { selectAllButBest(g) }
    }

    // MARK: Borrado (va a "Eliminado recientemente", 30 días recuperable)

    func deleteSelected() { delete(ids: selected) }

    /// Borra un subconjunto concreto (p. ej. las marcadas de un solo grupo).
    func delete(ids requested: Set<String>) {
        // La MEJOR también puede borrarse si el usuario la marca a propósito
        performDelete(ids: requested.intersection(selected))
    }

    /// Borra TODO el grupo, incluida la MEJOR — decisión explícita del usuario
    /// (a veces el set completo es basura). Confirmación del sistema mediante.
    func deleteWholeGroup(_ g: DupeGroup) {
        performDelete(ids: Set(g.members.map(\.id)))
    }

    /// Marca todos los grupos de un nivel (menos la mejor de cada uno).
    func selectAll(tier: DupeTier) {
        for g in groups where g.tier == tier { selectAllButBest(g) }
    }

    private func performDelete(ids: Set<String>) {
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

    /// Lote de vídeos con perfil elegido; en MÁXIMA los HEVC también entran
    /// (reescalar a 1080p sí les ahorra).
    func optimizeSelectedVideos(profile: VideoProfile = .optimal) {
        let targets = bigVideos.filter {
            optSelected.contains($0.id)
                && (profile == .aggressive || codecByID[$0.id] != "HEVC ✓")
        }
        optimize(targets, video: true, profile: profile)
    }
    func convertSelectedRaws()   { optimize(selectedRaws, video: false) }
    /// Conversión individual desde la ficha del vídeo, con perfil elegido.
    func optimizeVideo(_ pa: PhotoAsset, profile: VideoProfile) {
        optimize([pa], video: true, profile: profile)
    }

    private func optimize(_ targets: [PhotoAsset], video: Bool, profile: VideoProfile = .optimal) {
        guard !optimizing, !targets.isEmpty else { return }
        optimizing = true
        paused = false
        stopRequested = false
        Task {
            var noGain = 0, failed = 0
            let n = targets.count
            let batchStart = Date()
            AppLog.log("OPTIMIZE inicio: \(n) elementos, modo \(video ? "vídeo→HEVC" : "RAW→HEIC (\(Self.rawWorkers) trabajadores)")")

            // FASE 1: convertir todo a ficheros temporales (sin tocar Fotos).
            // Vídeos en serie (comparten el codificador hardware); RAWs con
            // 3 trabajadores en paralelo. Pausa/stop entre elementos.
            var ready: [(pa: PhotoAsset, url: URL, newSize: Int64)] = []
            var processed = 0

            @MainActor func handleResult(_ pa: PhotoAsset, _ outURL: URL?) {
                processed += 1
                optProgress = String(format: video ? t("recompressing %d/%d…") : t("converting %d/%d…"),
                                     processed, n)
                if !video { optFraction = Double(processed) / Double(n) }
                guard let outURL,
                      let newSize = (try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? Int64,
                      newSize > 0 else {
                    AppLog.log("  \(pa.filename ?? pa.id): conversión falló o se omitió (ver líneas previas)")
                    failed += 1
                    return
                }
                // Solo merece la pena si encoge DE VERDAD (mínimo 15%)
                guard newSize < pa.fileSize * 85 / 100 else {
                    AppLog.log("  \(pa.filename ?? pa.id): sin ganancia (\(pa.fileSize / 1_000_000) MB → \(newSize / 1_000_000) MB), se conserva el original")
                    try? FileManager.default.removeItem(at: outURL)
                    noGain += 1
                    return
                }
                AppLog.log("  \(pa.filename ?? pa.id): convertido \(pa.fileSize / 1_000_000) MB → \(newSize / 1_000_000) MB")
                ready.append((pa, outURL, newSize))
            }

            if video {
                for (i, pa) in targets.enumerated() {
                    while paused { try? await Task.sleep(for: .seconds(0.3)) }
                    if stopRequested { AppLog.log("  detenido por el usuario en \(i)/\(n)"); break }
                    optProgress = String(format: t("recompressing %d/%d…"), i + 1, n)
                    optFraction = Double(i) / Double(n)
                    workingAsset = pa.asset
                    let base = Double(i)
                    // En perfil óptimo, un HEVC no da ahorro; en agresivo sí (reescala)
                    if profile == .optimal, await Self.codecLabel(for: pa.asset) == "HEVC ✓" {
                        AppLog.log("  \(pa.filename ?? pa.id): ya es HEVC, sin ganancia posible")
                        noGain += 1
                        processed += 1
                        continue
                    }
                    let plan = TranscodePlan.make(for: pa, profile: profile)
                    let flag = pauseFlag
                    let outURL = await Task.detached(priority: .userInitiated) {
                        await Self.exportVideo(pa.asset, plan: plan, isPaused: { flag.value }) { itemFrac in
                            Task { @MainActor in self.optFraction = (base + itemFrac) / Double(n) }
                        }
                    }.value
                    handleResult(pa, outURL)
                }
            } else {
                // RAWs: hasta 3 a la vez (CPU/GPU-bound, escala bien)
                await withTaskGroup(of: (PhotoAsset, URL?).self) { group in
                    var it = targets.makeIterator()
                    @MainActor func addNext() {
                        guard !stopRequested, let pa = it.next() else { return }
                        group.addTask { (pa, Self.rawToHEIC(pa.asset)) }
                    }
                    for _ in 0..<Self.rawWorkers { addNext() }
                    for await (pa, outURL) in group {
                        workingAsset = pa.asset
                        handleResult(pa, outURL)
                        while paused { try? await Task.sleep(for: .seconds(0.3)) }
                        addNext()
                    }
                }
                if stopRequested { AppLog.log("  detenido por el usuario en \(processed)/\(n)") }
            }

            // FASE 2: importar → verificar → borrar. El borrado (con su única
            // confirmación del sistema) solo llega si los importados existen
            // e informan dimensiones válidas. Si cancelas el diálogo, conviven
            // original y convertido: nunca te quedas sin ninguno.
            var done = 0
            var savedTotal: Int64 = 0
            var committedIDs: Set<String> = []
            if !ready.isEmpty {
                optProgress = String(format: t("importing %d into Photos…"), ready.count)
                optFraction = nil
                let batch = ready

                // 2a) importar (esto no pide confirmación)
                final class Box: @unchecked Sendable { var ids: [String] = [] }
                let created = Box()
                var importOK = false
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        for item in batch {
                            let origName = PHAssetResource.assetResources(for: item.pa.asset).first {
                                $0.type == .video || $0.type == .photo
                            }?.originalFilename
                            let resOpts = PHAssetResourceCreationOptions()
                            if let origName {
                                let base = (origName as NSString).deletingPathExtension
                                resOpts.originalFilename = base + (video ? ".mov" : ".heic")
                            }
                            let req = PHAssetCreationRequest.forAsset()
                            req.addResource(with: video ? .video : .photo, fileURL: item.url, options: resOpts)
                            req.creationDate = item.pa.asset.creationDate
                            req.location = item.pa.asset.location
                            if let ph = req.placeholderForCreatedAsset {
                                created.ids.append(ph.localIdentifier)
                            }
                        }
                    }
                    importOK = true
                } catch {
                    AppLog.log("  importación fallida (originales intactos): \(error.localizedDescription)")
                    failed += batch.count
                }

                // 2b) verificar los recién importados
                if importOK {
                    let check = PHAsset.fetchAssets(withLocalIdentifiers: created.ids, options: nil)
                    var healthy = 0
                    check.enumerateObjects { a, _, _ in
                        if a.pixelWidth > 0, a.pixelHeight > 0 { healthy += 1 }
                    }
                    if healthy != batch.count {
                        AppLog.log("  verificación: \(healthy)/\(batch.count) íntegros — NO se borra ningún original")
                        lastResult = t("WARN: import verification failed — originals untouched (both copies kept)")
                        failed += batch.count
                        importOK = false
                    } else {
                        AppLog.log("  verificados \(healthy)/\(batch.count) importados")
                    }
                }

                // 2c) borrar originales, ya con red de seguridad doble
                if importOK {
                    do {
                        let originals = batch.map(\.pa.asset)
                        try await PHPhotoLibrary.shared().performChanges {
                            PHAssetChangeRequest.deleteAssets(originals as NSArray)
                        }
                        done = batch.count
                        savedTotal = batch.map { $0.pa.fileSize - $0.newSize }.reduce(0, +)
                        committedIDs = Set(batch.map(\.pa.id))
                        AppLog.log("  originales borrados tras verificación: \(done)")
                    } catch {
                        AppLog.log("  borrado cancelado/fallido: conviven original y convertido: \(error.localizedDescription)")
                        lastResult = t("WARN: deletion cancelled — converted files imported, originals kept (duplicates!)")
                        failed += batch.count
                    }
                }
                for item in ready { try? FileManager.default.removeItem(at: item.url) }
            }

            FreedTracker.shared.addTrashed(savedTotal)
            removeFromLists(committedIDs)
            optSelected.subtract(Set(targets.map(\.id)))
            workingAsset = nil
            optProgress = ""
            optFraction = nil
            optimizing = false
            SoundFX.shared.play(done > 0 || noGain > 0 ? .done : .error)
            let wall = Date().timeIntervalSince(batchStart)
            if processed > 0, wall > 0 {
                AppLog.log(String(format: "PROFILE lote %@: %d elementos en %.0fs (%.1f/min) con %d trabajadores",
                                  video ? "vídeo" : "RAW", processed, wall,
                                  Double(processed) / wall * 60,
                                  video ? 1 : Self.rawWorkers))
            }
            AppLog.log("OPTIMIZE fin: \(done) ok, \(noGain) sin ganancia, \(failed) errores, ahorro \(formatBytes(savedTotal))")
            lastResult = String(format: t("%@: %d optimized, %d no gain, %d errors — %@ saved (log: ~/Library/Logs/NeonSweep.log)"),
                                failed == 0 ? "OK" : t("WARN"), done, noGain, failed, formatBytes(savedTotal))
        }
    }

    // MARK: Transcodificación de vídeo con control de bitrate

    /// Plan de conversión: dimensiones, bitrate objetivo y estimación de tamaño.
    struct TranscodePlan {
        let width: Int
        let height: Int
        let bitrate: Int          // bits/s de vídeo
        let estBytes: Int64       // estimación del resultado

        /// Calcula el plan desde los metadatos del asset (sin abrir el fichero).
        nonisolated static func make(for pa: PhotoAsset, profile: VideoProfile) -> TranscodePlan {
            let seconds = max(1.0, pa.asset.duration)
            let srcBps = Double(pa.fileSize) * 8.0 / seconds
            var w = pa.asset.pixelWidth, h = pa.asset.pixelHeight
            // Factores ajustables (tuning avanzado):
            // defaults write com.davidcornejo.neonsweep video.optimal.pct 45
            // defaults write com.davidcornejo.neonsweep video.max.pct 12
            let optPct = { let v = UserDefaults.standard.integer(forKey: "video.optimal.pct")
                           return v > 0 ? Double(v) / 100 : 0.45 }()
            let maxPct = { let v = UserDefaults.standard.integer(forKey: "video.max.pct")
                           return v > 0 ? Double(v) / 100 : 0.12 }()
            var target: Double
            switch profile {
            case .optimal:
                // misma resolución, ~45% del bitrate original (HEVC rinde eso
                // frente a H.264 con pérdida casi invisible)
                target = min(max(srcBps * optPct, 6_000_000), 40_000_000)
            case .aggressive:
                // reescala a 1080p y comprime fuerte
                let maxDim = Double(max(w, h))
                if maxDim > 1920 {
                    let f = 1920.0 / maxDim
                    w = Int(Double(w) * f) & ~1   // dimensiones pares
                    h = Int(Double(h) * f) & ~1
                }
                target = min(max(srcBps * maxPct, 4_000_000), 10_000_000)
            }
            target = min(target, srcBps * 0.85)   // nunca apuntar por encima del original
            let est = Int64((target + 192_000) / 8.0 * seconds)   // + audio
            return TranscodePlan(width: w, height: h, bitrate: Int(target), estBytes: est)
        }
    }

    /// Descarga el AVAsset y lo transcodifica a HEVC según el plan.
    nonisolated static func exportVideo(_ asset: PHAsset, plan: TranscodePlan,
                                        isPaused: @escaping @Sendable () -> Bool = { false },
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
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("neonsweep-\(UUID().uuidString).mov")
        let ok = await transcode(avAsset, to: out, plan: plan, isPaused: isPaused, progress: progress)
        if !ok { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    /// AVAssetReader → AVAssetWriter: HEVC con bitrate controlado, escala vía
    /// composición de vídeo (respeta la orientación) y audio en passthrough.
    nonisolated static func transcode(_ avAsset: AVAsset, to out: URL, plan: TranscodePlan,
                                      isPaused: @escaping @Sendable () -> Bool = { false },
                                      progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        do {
            guard let vTrack = try await avAsset.loadTracks(withMediaType: .video).first else { return false }
            let duration = try await avAsset.load(.duration).seconds
            let fps = try await vTrack.load(.nominalFrameRate)

            let reader = try AVAssetReader(asset: avAsset)
            let writer = try AVAssetWriter(outputURL: out, fileType: .mov)

            let comp = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: avAsset)
            comp.renderSize = CGSize(width: plan.width, height: plan.height)
            let vOut = AVAssetReaderVideoCompositionOutput(
                videoTracks: [vTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            vOut.videoComposition = comp
            guard reader.canAdd(vOut) else { return false }
            reader.add(vOut)

            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: plan.bitrate,
                    AVVideoExpectedSourceFrameRateKey: Int(max(24, fps.rounded())),
                ] as [String: Any],
            ])
            vIn.expectsMediaDataInRealTime = false
            writer.add(vIn)

            var aOut: AVAssetReaderTrackOutput?
            var aIn: AVAssetWriterInput?
            if let aTrack = try await avAsset.loadTracks(withMediaType: .audio).first {
                let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
                if reader.canAdd(o) {
                    reader.add(o)
                    aOut = o
                    let desc = try await aTrack.load(.formatDescriptions).first
                    let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                               sourceFormatHint: desc)
                    i.expectsMediaDataInRealTime = false
                    writer.add(i)
                    aIn = i
                }
            }

            guard reader.startReading(), writer.startWriting() else {
                AppLog.log("TRANSCODE: no arranca (reader \(reader.error?.localizedDescription ?? "-"))")
                return false
            }
            writer.startSession(atSourceTime: .zero)

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                group.enter()
                vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "ns.video")) {
                    while vIn.isReadyForMoreMediaData {
                        while isPaused() { Thread.sleep(forTimeInterval: 0.15) }
                        if let sb = vOut.copyNextSampleBuffer() {
                            if duration > 0 {
                                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                                progress(min(1, t / duration))
                            }
                            vIn.append(sb)
                        } else {
                            vIn.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
                if let aIn, let aOut {
                    group.enter()
                    aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "ns.audio")) {
                        while aIn.isReadyForMoreMediaData {
                            if let sb = aOut.copyNextSampleBuffer() {
                                aIn.append(sb)
                            } else {
                                aIn.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    }
                }
                group.notify(queue: .global()) { cont.resume() }
            }
            await writer.finishWriting()
            if writer.status != .completed {
                AppLog.log("TRANSCODE: fallo escribiendo (\(writer.error?.localizedDescription ?? "-"))")
                return false
            }
            progress(1)
            return true
        } catch {
            AppLog.log("TRANSCODE: \(error.localizedDescription)")
            return false
        }
    }

    /// Convierte un RAW a HEIC (CIRAWFilter + CIContext, pipeline oficial de Apple).
    /// Pide explícitamente el recurso RAW (clave en assets RAW+JPEG o en iCloud).
    nonisolated static func rawToHEIC(_ asset: PHAsset) -> URL? {
        let tStart = Date()
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
        let tDown = Date()

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
        guard let cg = ciContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else {
            AppLog.log("RAW \(name): no se pudo renderizar la imagen")
            return nil
        }
        let tDecode = Date()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("neonsweep-\(UUID().uuidString).heic")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            AppLog.log("RAW \(name): no se pudo crear el destino HEIC")
            return nil
        }
        // Conservar EXIF/TIFF/GPS/IPTC: ImageIO no sabe leer el ARW directo,
        // pero el CIImage del CIRAWFilter trae los metadatos en .properties
        // Calidad elegida por el usuario (85/90/95; por defecto 0.9)
        let q = UserDefaults.standard.double(forKey: "heic.quality")
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: q > 0 ? q : 0.9]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = image.properties[key as String] { props[key] = v }
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            AppLog.log("RAW \(name): CGImageDestinationFinalize falló")
            return nil
        }
        if AppLog.profileEnabled {
            let now = Date()
            AppLog.log(String(format: "PROFILE %@ bajada=%.1fs decode=%.1fs encode=%.1fs total=%.1fs",
                              name,
                              tDown.timeIntervalSince(tStart),
                              tDecode.timeIntervalSince(tDown),
                              now.timeIntervalSince(tDecode),
                              now.timeIntervalSince(tStart)))
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
