// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NeonSweep",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "NeonSweep",
            path: "Sources/NeonSweep",
            resources: [.copy("Resources/es.lproj")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // El shim _AVKit_SwiftUI (VideoPlayer) no arrastra AVKit por sí solo
            // con SPM/CLT: sin esto, abrir la preview de un vídeo aborta en
            // getSuperclassMetadata (AVPlayerView no cargada).
            linkerSettings: [.linkedFramework("AVKit")]
        )
    ]
)
