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
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
