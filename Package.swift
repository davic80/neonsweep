// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NeonSweep",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Los Command Line Tools no traen XCTest ni Testing: se usa el paquete
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
    ],
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
        ),
        .testTarget(
            name: "NeonSweepTests",
            dependencies: [
                "NeonSweep",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/NeonSweepTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
