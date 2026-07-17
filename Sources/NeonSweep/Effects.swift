import SwiftUI
import AVFoundation

// MARK: - Sonidos retro sintetizados (ondas cuadradas, sin assets)

@MainActor
final class SoundFX: ObservableObject {
    static let shared = SoundFX()

    enum Effect { case boot, click, trash }

    @Published var muted: Bool {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private nonisolated static let sr: Double = 44_100

    private init() {
        muted = UserDefaults.standard.bool(forKey: "muted")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // arranque de terminal: arpegio ascendente
        buffers[.boot] = Self.buffer([
            Self.square(523, 0.07), Self.square(659, 0.07),
            Self.square(784, 0.07), Self.square(1046, 0.12),
        ].flatMap { $0 }, format: format)
        // clic: bip corto
        buffers[.click] = Self.buffer(Self.square(1800, 0.03, amp: 0.12), format: format)
        // borrado: barrido descendente (algo se va por el desagüe)
        buffers[.trash] = Self.buffer(Self.glide(from: 1000, to: 160, dur: 0.28), format: format)
        try? engine.start()
    }

    func play(_ e: Effect) {
        guard !muted, let buf = buffers[e] else { return }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    // MARK: síntesis

    nonisolated private static func square(_ freq: Double, _ dur: Double, amp: Float = 0.2) -> [Float] {
        let n = Int(sr * dur)
        return (0..<n).map { i in
            let t = Double(i) / sr
            let v: Float = sin(2 * .pi * freq * t) >= 0 ? amp : -amp
            let env = Float(exp(-3.0 * Double(i) / Double(n)))   // decaimiento
            return v * env
        }
    }

    nonisolated private static func glide(from f0: Double, to f1: Double, dur: Double) -> [Float] {
        let n = Int(sr * dur)
        var phase = 0.0
        return (0..<n).map { i in
            let p = Double(i) / Double(n)
            let f = f0 + (f1 - f0) * p
            phase += 2 * .pi * f / sr
            let v: Float = sin(phase) >= 0 ? 0.18 : -0.18
            return v * Float(1.0 - p * 0.6)
        }
    }

    nonisolated private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}

// MARK: - Estilo de botón: clic sonoro + feedback de pulsado

struct NeonClick: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { SoundFX.shared.play(.click) }
            }
    }
}

// MARK: - Barrido de arranque: la línea-cursor recorre la ventana

struct SweepOverlay: View {
    var onDone: () -> Void
    @State private var progress: CGFloat = 0
    @State private var opacity: Double = 1

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(
                    colors: [Theme.neon.opacity(0), Theme.neon.opacity(0.85), Theme.neon],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: 22)
                .shadow(color: Theme.neon.opacity(0.9), radius: 18)
                .shadow(color: Theme.neon.opacity(0.5), radius: 40)
                .offset(y: -30 + (geo.size.height + 60) * progress)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0)) { progress = 1 }
                    withAnimation(.linear(duration: 0.25).delay(0.95)) { opacity = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { onDone() }
                }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
