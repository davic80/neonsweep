import Testing
import Foundation
import CryptoKit
@testable import NeonSweep

@Suite struct LogicTests {

    // MARK: prefijo de fabricante (huérfanos)

    @Test func vendorPrefix() {
        #expect(UninstallerModel.vendorPrefix("com.spotify.client") == "com.spotify.client")
        #expect(UninstallerModel.vendorPrefix("group.com.spotify.client") == "com.spotify.client")
        #expect(UninstallerModel.vendorPrefix("COM.Microsoft.Word") == "com.microsoft.word")
        #expect(UninstallerModel.vendorPrefix("org.mozilla") == "org.mozilla")
    }

    /// Caso real: CleanMyMac desinstalado, The Unarchiver (mismo fabricante)
    /// sigue instalado. Sus restos deben distinguirse.
    @Test func orphanKeySeparatesAppsOfSameVendor() {
        let cleanMyMac = UninstallerModel.vendorPrefix("com.macpaw.CleanMyMac5")
        let cmmOldVersion = UninstallerModel.vendorPrefix("S8EX82NJP6.com.macpaw.CleanMyMac4")
        let unarchiver = UninstallerModel.vendorPrefix("com.macpaw.site.theunarchiver")

        #expect(cleanMyMac == "com.macpaw.cleanmymac")
        #expect(cmmOldVersion == cleanMyMac, "el Team ID y la versión no deben separar restos")
        #expect(unarchiver != cleanMyMac,
                "una app instalada del mismo fabricante no puede blindar los restos de otra")
    }

    // MARK: familia de bundle ID (caso CleanMyMac: restos de v4 al borrar v5)

    @Test func familyID() {
        #expect(UninstallerModel.familyID("com.macpaw.CleanMyMac5") == "com.macpaw.cleanmymac")
        #expect(UninstallerModel.familyID("com.spotify.client") == nil,
                "sin sufijo de versión no hay familia distinta del bundle ID")
        #expect(UninstallerModel.familyID("com.a.b2") == nil, "familias muy cortas se descartan")
    }

    /// La familia de CleanMyMac5 debe cazar los restos reales encontrados en el
    /// Mac (v4, servicios auxiliares) sin tocar otras apps del mismo fabricante.
    @Test func familyMatchesRealLeftovers() throws {
        let family = try #require(UninstallerModel.familyID("com.macpaw.CleanMyMac5"))
        let shouldMatch = [
            "S8EX82NJP6.com.macpaw.CleanMyMac4",
            "S8EX82NJP6.com.macpaw.CleanMyMac5",
            "com.macpaw.CleanMyMac5.FinderSyncExtension",
            "com.macpaw.CleanMyMac5.HealthMonitor.plist",
            "com.macpaw.CleanMyMac5.Agent",
        ]
        for entry in shouldMatch {
            #expect(entry.lowercased().contains(family), "debería cazar \(entry)")
        }
        let mustNotMatch = [
            "com.macpaw.site.theunarchiver",       // otra app instalada y en uso
            "com.macpaw.site.Gemini2.binarycookies",
        ]
        for entry in mustNotMatch {
            #expect(!entry.lowercased().contains(family), "NO debe tocar \(entry)")
        }
    }

    @Test func normalizedName() {
        #expect(UninstallerModel.normalized("CleanMyMac 5") == "cleanmymac")
        #expect(UninstallerModel.normalized("CleanMyMac_5") == "cleanmymac",
                "carpetas con guion bajo y versión coinciden con el nombre de la app")
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
