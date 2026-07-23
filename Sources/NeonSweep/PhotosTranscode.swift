import Photos
import AVFoundation
import VideoToolbox
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import AppKit

// Transcodificación de vídeo y conversión RAW→HEIC.
extension PhotosModel {
    // MARK: Transcodificación de vídeo con control de bitrate

    /// Plan de conversión: dimensiones, bitrate objetivo y estimación de tamaño.
    struct TranscodePlan {
        let width: Int
        let height: Int
        let bitrate: Int          // bits/s de vídeo
        let estBytes: Int64       // estimación del resultado
        /// Reducción respecto al original (1 = misma resolución). Se aplica
        /// sobre el tamaño natural de la pista, que puede venir girado.
        var scale: Double = 1

        /// Techo de 1080p para el perfil MÁXIMA, medido sobre el **lado corto**:
        /// "1080p" son 1080 líneas, no 1920 píxeles de ancho. Limitar el lado
        /// largo dejaría un panorámico de 3840×1080 en 1920×540, por debajo de
        /// 1080p. Devuelve las dimensiones ya pares (las exige el codificador).
        ///
        /// Nunca amplía: si el original está por debajo de 1080p se devuelve tal
        /// cual y solo se recorta el bitrate. El perfil ÓPTIMA ni pasa por aquí.
        nonisolated static func cappedTo1080p(width: Int, height: Int) -> (Int, Int, Double) {
            let shortSide = Double(min(width, height))
            guard shortSide > 1080 else { return (width, height, 1) }
            let scale = 1080.0 / shortSide
            return (max(2, Int(Double(width) * scale) & ~1),
                    max(2, Int(Double(height) * scale) & ~1),
                    scale)
        }

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
            var scale = 1.0
            switch profile {
            case .optimal:
                // misma resolución, ~45% del bitrate original (HEVC rinde eso
                // frente a H.264 con pérdida casi invisible)
                target = min(max(srcBps * optPct, 6_000_000), 40_000_000)
            case .aggressive:
                // Techo de 1080p y compresión fuerte. NUNCA sube resolución:
                // si el original ya está por debajo, se queda como está y solo
                // baja el bitrate.
                (w, h, scale) = Self.cappedTo1080p(width: w, height: h)
                target = min(max(srcBps * maxPct, 4_000_000), 10_000_000)
            }
            target = min(target, srcBps * 0.85)   // nunca apuntar por encima del original
            let est = Int64((target + 192_000) / 8.0 * seconds)   // + audio
            return TranscodePlan(width: w, height: h, bitrate: Int(target),
                                 estBytes: est, scale: scale)
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
        let ok = await transcode(avAsset, to: out, plan: plan, isPaused: isPaused,
                                 progress: progress)
        if !ok { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    /// Prioriza velocidad en el codificador. Medido en este Mac (M5, 4K, mismo
    /// bitrate): 24,9 s → 14,2 s, y el fichero sale igual de grande (26,8 vs
    /// 26,9 MB) con SSIM 0,996164 → 0,996051. Un 0,011% de diferencia por 1,75×
    /// de velocidad; en las muestras es indistinguible. Se puede desactivar:
    /// defaults write com.davidcornejo.neonsweep video.fastEncode -bool NO
    nonisolated static var fastEncodeDefault: Bool {
        UserDefaults.standard.object(forKey: "video.fastEncode") as? Bool ?? true
    }

    /// AVAssetReader → AVAssetWriter: HEVC con bitrate controlado y audio en
    /// passthrough.
    ///
    /// Lee la pista DIRECTAMENTE, sin `AVVideoComposition`. El compositor
    /// renderizaba cada fotograma por Core Image aunque no hubiera nada que
    /// reescalar, y era el cuello de botella: la parte de codificación va por
    /// hardware, pero ese render intermedio va por el camino largo. La
    /// orientación no se pierde porque se copia `preferredTransform` al
    /// escritor: es lo que hace el propio iPhone (los vídeos verticales son
    /// píxeles apaisados + metadato de rotación), y si hay que reducir, escala
    /// el codificador, que también es hardware.
    nonisolated static func transcode(_ avAsset: AVAsset, to out: URL, plan: TranscodePlan,
                                      isPaused: @escaping @Sendable () -> Bool = { false },
                                      timeLimit: Double? = nil,   // solo para --bench-video
                                      fastEncode: Bool = fastEncodeDefault,
                                      progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        do {
            guard let vTrack = try await avAsset.loadTracks(withMediaType: .video).first else { return false }
            let duration = try await avAsset.load(.duration).seconds
            let fps = try await vTrack.load(.nominalFrameRate)
            let natural = try await vTrack.load(.naturalSize)
            let transform = try await vTrack.load(.preferredTransform)

            // Dimensiones EN PÍXELES de la pista (no las de pantalla, que ya
            // llevan la rotación aplicada); pares, que el codificador lo exige.
            let encW = max(2, Int(natural.width * plan.scale) & ~1)
            let encH = max(2, Int(natural.height * plan.scale) & ~1)

            let reader = try AVAssetReader(asset: avAsset)
            if let timeLimit {
                reader.timeRange = CMTimeRange(start: .zero,
                                               duration: CMTime(seconds: timeLimit, preferredTimescale: 600))
            }
            let writer = try AVAssetWriter(outputURL: out, fileType: .mov)

            let vOut = AVAssetReaderTrackOutput(
                track: vTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            vOut.alwaysCopiesSampleData = false   // sin copia extra por fotograma
            guard reader.canAdd(vOut) else { return false }
            reader.add(vOut)

            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: encW,
                AVVideoHeightKey: encH,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: {
                    var p: [String: Any] = [
                        AVVideoAverageBitRateKey: plan.bitrate,
                        AVVideoExpectedSourceFrameRateKey: Int(max(24, fps.rounded())),
                    ]
                    if fastEncode {
                        p[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
                    }
                    return p
                }(),
            ])
            vIn.expectsMediaDataInRealTime = false
            vIn.transform = transform     // conserva la orientación de reproducción
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
            PhotosModel.isRawResource($0.uniformTypeIdentifier, filename: $0.originalFilename)
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

}
