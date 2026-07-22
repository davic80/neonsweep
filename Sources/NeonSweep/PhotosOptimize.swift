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

}
