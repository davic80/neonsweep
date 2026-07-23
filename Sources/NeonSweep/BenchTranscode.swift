import Foundation
import AVFoundation

/// Banco de pruebas del transcodificador: `NeonSweep --bench-video <fichero> [segundos]`.
///
/// Existe para no medir a ojo. Trabaja sobre un fichero suelto —nunca sobre la
/// fototeca, donde convertir borra el original— y ejecuta el mismo trozo de
/// vídeo por los dos caminos: el antiguo, que renderizaba cada fotograma por
/// `AVVideoComposition`, y el actual, que lee la pista directa. Imprime tiempos
/// y factor sobre tiempo real.
enum BenchTranscode {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--bench-video"), args.count > i + 1 else { return }
        let path = args[i + 1]
        let seconds = args.count > i + 2 ? Double(args[i + 2]) ?? 60 : 60

        let sem = DispatchSemaphore(value: 0)
        Task {
            await run(path: path, seconds: seconds)
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    private static func run(path: String, seconds: Double) async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            print("no existe: \(path)"); return
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let total = try? await asset.load(.duration).seconds else {
            print("no se pudo leer la pista de vídeo"); return
        }
        let span = min(seconds, total)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        print("banco: \(url.lastPathComponent)")
        print(String(format: "  %.0f×%.0f · %.0fs de %.0fs · %@",
                     size.width, size.height, span, total, formatBytes(bytes)))

        // Mismo bitrate objetivo en ambos: se compara la ruta, no la calidad
        let plan = PhotosModel.TranscodePlan(width: Int(size.width), height: Int(size.height),
                                             bitrate: 4_000_000, estBytes: 0, scale: 1)

        // 0) solo decodificar: separa el coste del decodificador del total
        var t0 = Date()
        let frames = await decodeOnly(asset, limit: span)
        report("solo decodificar", Date().timeIntervalSince(t0), span, 1)
        print("     (\(frames) fotogramas)")

        // 1) ¿cuesta algo el compositor? (era la sospecha)
        let out0 = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-\(UUID().uuidString).mov")
        t0 = Date()
        _ = await viaComposition(asset, to: out0, plan: plan, limit: span)
        report("compositor (antes)", Date().timeIntervalSince(t0), span, 1)
        try? FileManager.default.removeItem(at: out0)

        // 2) la ruta actual, y con N en paralelo: si escala, el límite no es
        //    el codificador sino que decodificar y codificar van en serie
        // 2b) ¿y pidiendo al codificador que priorice velocidad sobre calidad?
        t0 = Date()
        let outFast = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-\(UUID().uuidString).mov")
        _ = await PhotosModel.transcode(asset, to: outFast, plan: plan,
                                        timeLimit: span, fastEncode: true, progress: { _ in })
        let fastBytes = (try? FileManager.default.attributesOfItem(atPath: outFast.path)[.size] as? Int64) ?? 0
        try? FileManager.default.removeItem(at: outFast)
        report("prioriza velocidad", Date().timeIntervalSince(t0), span, 1)
        print("     (" + formatBytes(fastBytes) + ")")

        for workers in [1, 2, 3, 4] {
            t0 = Date()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask {
                        let o = FileManager.default.temporaryDirectory
                            .appendingPathComponent("bench-\(UUID().uuidString).mov")
                        _ = await PhotosModel.transcode(asset, to: o, plan: plan,
                                                        timeLimit: span, progress: { _ in })
                        try? FileManager.default.removeItem(at: o)
                    }
                }
            }
            report("pista directa ×\(workers)", Date().timeIntervalSince(t0), span, workers)
        }
    }

    private static func report(_ label: String, _ dt: Double, _ span: Double, _ n: Int) {
        let pad = String(repeating: " ", count: max(0, 24 - label.count))
        print("  " + label + pad
              + String(format: "%6.1fs  →  %5.1f× tiempo real agregado", dt, span * Double(n) / dt))
    }

    /// Lee y descarta todos los fotogramas: cuánto cuesta solo decodificar.
    private static func decodeOnly(_ avAsset: AVAsset, limit: Double) async -> Int {
        guard let vTrack = try? await avAsset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: avAsset) else { return 0 }
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: limit, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(
            track: vTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return 0 }
        reader.add(out)
        guard reader.startReading() else { return 0 }
        var n = 0
        while out.copyNextSampleBuffer() != nil { n += 1 }
        return n
    }

    /// La implementación anterior, conservada solo aquí para poder compararla.
    private static func viaComposition(_ avAsset: AVAsset, to out: URL,
                                       plan: PhotosModel.TranscodePlan, limit: Double) async -> Bool {
        do {
            guard let vTrack = try await avAsset.loadTracks(withMediaType: .video).first else { return false }
            let fps = try await vTrack.load(.nominalFrameRate)
            let reader = try AVAssetReader(asset: avAsset)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 600))
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

            guard reader.startReading(), writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "bench.video")) {
                    while vIn.isReadyForMoreMediaData {
                        if let sb = vOut.copyNextSampleBuffer() {
                            vIn.append(sb)
                        } else {
                            vIn.markAsFinished()
                            cont.resume()
                            return
                        }
                    }
                }
            }
            await writer.finishWriting()
            return writer.status == .completed
        } catch {
            return false
        }
    }
}
