import Photos
import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import AppKit

// Flujo de optimización por lotes: convertir → verificar → borrar.
extension PhotosModel {
    // MARK: Optimización — vídeo → HEVC y RAW → HEIC
    // El original se conserva en "Eliminado recientemente" 30 días: red de seguridad.

    /// Lote de vídeos con perfil elegido; en MÁXIMA los HEVC también entran
    /// (reescalar a 1080p sí les ahorra).
    func optimizeSelectedVideos(profile: VideoProfile = .optimal) {
        optimize(videoTargets(for: profile), video: true, profile: profile)
    }

    /// Qué se convertiría de verdad con este perfil. Fuente única: el contador
    /// del botón usaba otro criterio y prometía más elementos de los que luego
    /// entraban.
    func videoTargets(for profile: VideoProfile) -> [PhotoAsset] {
        bigVideos.filter {
            guard optSelected.contains($0.id) else { return false }
            let willDownscale = min($0.asset.pixelWidth, $0.asset.pixelHeight) > 1080
            // Lo ya convertido por nosotros solo vuelve a entrar si MÁXIMO va
            // a reescalar de verdad; si no, sería recomprimir lo comprimido.
            if ConvertedRegistry.shared.contains($0.id) {
                return profile == .aggressive && willDownscale
            }
            guard codecByID[$0.id] == "HEVC ✓" else { return true }
            // Ya es HEVC: solo aporta algo si MÁXIMO va a bajar la resolución
            return profile == .aggressive && willDownscale
        }
    }
    func convertSelectedRaws()   { optimize(selectedRaws, video: false) }
    /// Conversión individual desde la ficha del vídeo, con perfil elegido.
    func optimizeVideo(_ pa: PhotoAsset, profile: VideoProfile) {
        optimize([pa], video: true, profile: profile)
    }

    /// Encola un lote. Si ya hay una conversión en marcha NO se descarta como
    /// antes: se apunta y se ejecuta al terminar la actual. El codificador es
    /// un recurso serie (medido: lanzar varias a la vez no acelera nada), así
    /// que la cola es exactamente la forma correcta de aceptar más trabajo.
    private func optimize(_ targets: [PhotoAsset], video: Bool, profile: VideoProfile = .optimal) {
        // Nada que ya esté en curso o esperando entra dos veces
        let busy = inFlightIDs.union(queued.flatMap { $0.targets.map(\.id) })
        let fresh = targets.filter { !busy.contains($0.id) }
        guard !fresh.isEmpty else { return }

        guard !optimizing else {
            queued.append(OptimizeJob(targets: fresh, video: video, profile: profile))
            AppLog.log("OPTIMIZE: \(fresh.count) en cola (\(queued.count) lotes esperando)")
            SoundFX.shared.play(.click)
            return
        }
        optimizing = true
        Task {
            // Se convierte TODA la cola antes de tocar Fotos: así el borrado
            // (que pide confirmación al sistema) sale una sola vez al final,
            // en vez de una por lote.
            var pending: [Ready] = []
            var noGain = 0, failed = 0
            var job: OptimizeJob? = OptimizeJob(targets: fresh, video: video, profile: profile)
            while let j = job {
                let r = await convertPhase(j)
                pending += r.ready
                noGain += r.noGain
                failed += r.failed
                // DETENER corta la cola entera, no solo el lote en curso; lo ya
                // convertido sí se confirma para no tirar ese trabajo.
                if stopRequested {
                    if !queued.isEmpty {
                        AppLog.log("  cola cancelada por el usuario: \(queued.count) lotes descartados")
                        queued.removeAll()
                    }
                    break
                }
                job = queued.isEmpty ? nil : queued.removeFirst()
            }
            await commitPhase(pending, noGain: noGain, failed: failed)
            optimizing = false
        }
    }

    /// Cancela un lote que aún no ha empezado.
    func dropQueued(_ id: UUID) { queued.removeAll { $0.id == id } }

    /// Un elemento ya convertido a fichero temporal, a la espera de commit.
    struct Ready {
        let pa: PhotoAsset
        let url: URL
        let newSize: Int64
        let video: Bool
    }

    /// FASE 1 de un lote: convertir a temporales. No toca la fototeca.
    private func convertPhase(_ job: OptimizeJob) async -> (ready: [Ready], noGain: Int, failed: Int) {
        let targets = job.targets
        let video = job.video
        let profile = job.profile
        inFlightIDs = Set(targets.map(\.id))
        paused = false
        stopRequested = false

        var noGain = 0, failed = 0
        let n = targets.count
        let batchStart = Date()
        AppLog.log("OPTIMIZE inicio: \(n) elementos, modo \(video ? "vídeo→HEVC" : "RAW→HEIC (\(Self.rawWorkers) trabajadores)")")

        // FASE 1: convertir todo a ficheros temporales (sin tocar Fotos).
        // Vídeos en serie (comparten el codificador hardware); RAWs con
        // 3 trabajadores en paralelo. Pausa/stop entre elementos.
        var ready: [Ready] = []
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
            ready.append(Ready(pa: pa, url: outURL, newSize: newSize, video: video))
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
                    await Self.exportVideo(
                        pa.asset, plan: plan, isPaused: { flag.value },
                        downloading: { frac in
                            Task { @MainActor in self.downloadFraction = frac }
                        }
                    ) { itemFrac in
                        Task { @MainActor in self.optFraction = (base + itemFrac) / Double(n) }
                    }
                }.value
                downloadFraction = nil
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

        optSelected.subtract(Set(targets.map(\.id)))
        inFlightIDs = []
        let wall = Date().timeIntervalSince(batchStart)
        if processed > 0, wall > 0 {
            AppLog.log(String(format: "PROFILE lote %@: %d elementos en %.0fs (%.1f/min) con %d trabajadores",
                              video ? "vídeo" : "RAW", processed, wall,
                              Double(processed) / wall * 60,
                              video ? 1 : Self.rawWorkers))
        }
        return (ready, noGain, failed)
    }

    /// FASE 2, UNA sola vez por cola: importar → verificar → borrar.
    ///
    /// Antes iba dentro de cada lote, así que encolar tres conversiones
    /// significaba tres confirmaciones de borrado del sistema. Ahora se
    /// convierte toda la cola y se confirma al final, de una vez.
    ///
    /// El borrado solo llega si los importados existen y declaran dimensiones
    /// válidas; si cancelas el diálogo conviven original y convertido, nunca te
    /// quedas sin ninguno.
    private func commitPhase(_ ready: [Ready], noGain: Int, failed failedIn: Int) async {
        var failed = failedIn
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
                            resOpts.originalFilename = base + (item.video ? ".mov" : ".heic")
                        }
                        let req = PHAssetCreationRequest.forAsset()
                        req.addResource(with: item.video ? .video : .photo,
                                        fileURL: item.url, options: resOpts)
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
                    // Apuntar lo convertido: única forma exacta de no volver a
                    // ofrecer comprimir algo que ya comprimimos. El orden de
                    // `created.ids` sigue al de `batch`: los placeholders se
                    // crean en ese mismo bucle.
                    for (i, item) in batch.enumerated() where i < created.ids.count {
                        ConvertedRegistry.shared.record(id: created.ids[i],
                                                        originalBytes: item.pa.fileSize,
                                                        newBytes: item.newSize)
                    }
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
        workingAsset = nil
        optProgress = ""
        optFraction = nil
        downloadFraction = nil
        SoundFX.shared.play(done > 0 || noGain > 0 ? .done : .error)
        AppLog.log("OPTIMIZE fin: \(done) ok, \(noGain) sin ganancia, \(failed) errores, ahorro \(formatBytes(savedTotal))")
        lastResult = String(format: t("%@: %d optimized, %d no gain, %d errors — %@ saved"),
                            failed == 0 ? "OK" : t("WARN"), done, noGain, failed, formatBytes(savedTotal))
    }
}
