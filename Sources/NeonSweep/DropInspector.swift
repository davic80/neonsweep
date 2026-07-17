import SwiftUI
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

// MARK: - Modelo

struct MediaInfo: Identifiable {
    let id = UUID()
    let name: String
    let kindLine: String     // "vídeo H.264 · 3840×2160 · 2:41" / "imagen RAW · 6000×4000"
    let size: Int64
    let savingPercent: Int   // 0 = ya eficiente
    var savingBytes: Int64 { Int64(Double(size) * Double(savingPercent) / 100.0) }
}

@MainActor
final class DropModel: ObservableObject {
    static let shared = DropModel()
    @Published var items: [MediaInfo] = []
    @Published var visible = false
    @Published var working = false

    private init() {}

    func inspect(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        visible = true
        working = true
        Task {
            var out: [MediaInfo] = []
            for url in urls {
                if let info = await Self.info(for: url) { out.append(info) }
            }
            items = out
            working = false
        }
    }

    func close() { visible = false; items = [] }

    // MARK: Análisis

    nonisolated static func info(for url: URL) async -> MediaInfo? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        let name = url.lastPathComponent
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }

        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return await videoInfo(url: url, name: name, size: size)
        }
        if type.conforms(to: .image) {
            return imageInfo(url: url, name: name, size: size, type: type)
        }
        return nil
    }

    nonisolated private static func videoInfo(url: URL, name: String, size: Int64) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let dims = (try? await track.load(.naturalSize)) ?? .zero
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let descs = (try? await track.load(.formatDescriptions)) ?? []
        let codecCode = descs.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let codec = fourCC(codecCode)

        let (label, saving): (String, Int)
        switch codec {
        case "hvc1", "hev1": (label, saving) = ("HEVC", 5)
        case "avc1":         (label, saving) = ("H.264", 45)
        case "ap4h", "apch", "apcn", "apcs": (label, saving) = ("ProRes", 85)
        case "jpeg", "mjpa": (label, saving) = ("MJPEG", 70)
        default:             (label, saving) = (codec.uppercased(), 40)
        }
        let dur = String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
        return MediaInfo(
            name: name,
            kindLine: "\(t("video")) \(label) · \(Int(dims.width))×\(Int(dims.height)) · \(dur)",
            size: size, savingPercent: saving)
    }

    nonisolated private static func imageInfo(url: URL, name: String, size: Int64, type: UTType) -> MediaInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0

        let (label, saving): (String, Int)
        if type.conforms(to: .rawImage)     { (label, saving) = ("RAW", 75) }
        else if type.conforms(to: .heic)    { (label, saving) = ("HEIC", 0) }
        else if type.conforms(to: .jpeg)    { (label, saving) = ("JPEG", 35) }
        else if type.conforms(to: .png)     { (label, saving) = ("PNG", 50) }
        else if type.conforms(to: .tiff)    { (label, saving) = ("TIFF", 80) }
        else { (label, saving) = (type.preferredFilenameExtension?.uppercased() ?? "?", 25) }

        return MediaInfo(
            name: name,
            kindLine: "\(t("image")) \(label) · \(w)×\(h)",
            size: size, savingPercent: saving)
    }

    nonisolated private static func fourCC(_ code: FourCharCode) -> String {
        let chars: [Character] = (0..<4).compactMap {
            let byte = UInt8((code >> (8 * (3 - $0))) & 0xFF)
            return byte >= 32 && byte < 127 ? Character(UnicodeScalar(byte)) : nil
        }
        return String(chars)
    }
}

// MARK: - Vista flotante

struct DropInspectorPanel: View {
    @ObservedObject var model = DropModel.shared

    private var totalSaving: Int64 { model.items.map(\.savingBytes).reduce(0, +) }

    var body: some View {
        if model.visible {
            VStack(alignment: .leading, spacing: 0) {
                TerminalPanel(title: t("INSPECTOR")) {
                    if model.working {
                        HStack(spacing: 8) {
                            Text(t("inspecting…")).font(Theme.body).foregroundStyle(Theme.gray)
                            BlinkingCursor()
                        }
                    } else if model.items.isEmpty {
                        Text(t("no photos or videos recognized"))
                            .font(Theme.body).foregroundStyle(Theme.amber)
                    } else {
                        ForEach(model.items) { i in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.name).font(Theme.mono(12, .bold)).foregroundStyle(Theme.gray)
                                    .lineLimit(1).truncationMode(.middle)
                                HStack {
                                    Text(i.kindLine).font(Theme.small).foregroundStyle(Theme.grayDark)
                                    Spacer()
                                    Text(formatBytes(i.size)).font(Theme.small).foregroundStyle(Theme.gray)
                                }
                                Text(i.savingPercent > 0
                                     ? String(format: t("possible saving: ~%@ (%d%%)"),
                                              formatBytes(i.savingBytes), i.savingPercent)
                                     : t("already efficient — nothing to gain"))
                                    .font(Theme.mono(11, .bold))
                                    .foregroundStyle(i.savingPercent > 0 ? Theme.neon : Theme.neonDim)
                                    .shadow(color: i.savingPercent > 0 ? Theme.neon.opacity(0.4) : .clear, radius: 4)
                            }
                            .padding(.bottom, 6)
                        }
                        if model.items.count > 1 {
                            Text(String(format: t("TOTAL possible saving: ~%@"), formatBytes(totalSaving)))
                                .font(Theme.mono(13, .bold)).foregroundStyle(Theme.neon)
                        }
                        Text(t("// import into Photos and use [05] to actually optimize"))
                            .font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
                    }
                    HStack {
                        Spacer()
                        Button { model.close() } label: {
                            Text(t("[ CLOSE ]"))
                                .font(Theme.mono(11, .bold)).foregroundStyle(Theme.neonDim)
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        }
                        .buttonStyle(NeonClick())
                    }
                }
                .frame(width: 420)
                .background(Theme.bg)
                .shadow(color: .black.opacity(0.6), radius: 20)
            }
        }
    }
}
