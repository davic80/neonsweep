import Testing
@testable import NeonSweep

@Suite struct ParsersTests {

    // MARK: brew outdated --json=v2

    @Test func parseBrew() {
        let json = """
        {"formulae":[{"name":"wget","installed_versions":["1.21"],"current_version":"1.24"},
                     {"name":"jq","installed_versions":["1.6","1.7"],"current_version":"1.7.1"}],
         "casks":[{"name":"firefox","installed_versions":["120.0"],"current_version":"121.0"}]}
        """
        let items = UpdatesModel.parseBrew(json)
        #expect(items.count == 3)
        #expect(items[0].name == "wget")
        #expect(items[0].installed == "1.21")
        #expect(items[0].latest == "1.24")
        #expect(items[1].installed == "1.7", "usa la última versión instalada")
        #expect(items[2].kind == .cask)
    }

    @Test func parseBrewMalformed() {
        #expect(UpdatesModel.parseBrew("no es json").isEmpty)
        #expect(UpdatesModel.parseBrew("").isEmpty)
    }

    // MARK: mas outdated

    @Test func parseMas() {
        let out = """
        446107677  Magnet (2.4.5 -> 2.14.0)
        409183694  Keynote (13.1 -> 14.0)
        línea que no cuadra
        """
        let items = UpdatesModel.parseMas(out)
        #expect(items.count == 2)
        #expect(items[0].masID == "446107677")
        #expect(items[0].name == "Magnet")
        #expect(items[0].installed == "2.4.5")
        #expect(items[0].latest == "2.14.0")
        #expect(items[1].name == "Keynote")
    }

    // MARK: nombres de nube

    @Test func prettyCloudName() {
        #expect(ScanModel.prettyCloudName("GoogleDrive-david@gmail.com")
                == "Google Drive (david@gmail.com, local)")
        #expect(ScanModel.prettyCloudName("Dropbox") == "Dropbox (local)")
    }
}
