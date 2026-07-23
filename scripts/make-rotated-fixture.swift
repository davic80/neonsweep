// Genera un vídeo con rotación como METADATO (matriz de display), que es como
// graba el iPhone: píxeles apaisados + transform de 90°. ffmpeg no escribe esa
// matriz de forma fiable, y sin un fichero así no se puede comprobar que el
// transcodificador conserva la orientación.
//   swift scripts/make-rotated-fixture.swift <entrada> <salida>
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count > 2 else { print("uso: <entrada> <salida>"); exit(1) }
let src = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)

let sem = DispatchSemaphore(value: 0)
Task {
    guard let track = try? await src.loadTracks(withMediaType: .video).first,
          let size = try? await track.load(.naturalSize) else { exit(1) }
    let reader = try! AVAssetReader(asset: src)
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600))
    let rOut = AVAssetReaderTrackOutput(track: track, outputSettings:
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    reader.add(rOut)
    let writer = try! AVAssetWriter(outputURL: out, fileType: .mov)
    let wIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
    ])
    wIn.expectsMediaDataInRealTime = false
    wIn.transform = CGAffineTransform(rotationAngle: .pi / 2)   // 90°, como el iPhone
    writer.add(wIn)
    reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        wIn.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture")) {
            while wIn.isReadyForMoreMediaData {
                if let sb = rOut.copyNextSampleBuffer() { wIn.append(sb) }
                else { wIn.markAsFinished(); c.resume(); return }
            }
        }
    }
    await writer.finishWriting()
    print(writer.status == .completed ? "ok: \(out.path)" : "falló")
    sem.signal()
}
sem.wait()
