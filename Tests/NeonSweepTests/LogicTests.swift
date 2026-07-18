import Testing
import Foundation
import CryptoKit
@testable import NeonSweep

@Suite struct LogicTests {

    // MARK: prefijo de fabricante (huérfanos)

    @Test func vendorPrefix() {
        #expect(UninstallerModel.vendorPrefix("com.spotify.client") == "com.spotify")
        #expect(UninstallerModel.vendorPrefix("group.com.spotify.client") == "com.spotify")
        #expect(UninstallerModel.vendorPrefix("COM.Microsoft.Word") == "com.microsoft")
        #expect(UninstallerModel.vendorPrefix("org.mozilla") == "org.mozilla")
    }

    // MARK: escapado de rutas para shell admin

    @Test func adminQuoted() {
        #expect(AdminOps.quoted("/Library/App Support/x") == "'/Library/App Support/x'")
        #expect(AdminOps.quoted("/tmp/o'hara") == "'/tmp/o'\\''hara'")
    }

    // MARK: grupo de duplicados de fichero — cuál se queda

    @Test func fileDupeGroupKeep() {
        let g = FileDupeGroup(id: "h", size: 100,
                              files: ["/a/muy/larga/ruta/doc.pdf", "/a/doc.pdf", "/b/doc.pdf"])
        #expect(g.keep == "/a/doc.pdf", "gana la ruta más corta (alfabética en empate)")
        #expect(g.wasted == 200, "desperdicio = (n-1) × tamaño")
    }

    // MARK: SHA-256 en streaming

    @Test func sha256Streaming() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ns-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = Data((0..<5_000_000).map { UInt8($0 % 251) })   // varios chunks
        try data.write(to: tmp)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(ICloudDupesModel.sha256(of: tmp.path) == expected)
    }

    // MARK: umbral de vídeos gemelos (2% de tamaño)

    @Test func dupeVideoSizeThreshold() {
        let a: Int64 = 632_700_000
        let b: Int64 = 632_100_000
        #expect(abs(a - b) < max(a, b) / 50, "0,1% de diferencia cuenta como gemelo")
        let c: Int64 = 600_000_000
        #expect(abs(a - c) > max(a, c) / 50, "5% de diferencia no es gemelo")
    }
}
