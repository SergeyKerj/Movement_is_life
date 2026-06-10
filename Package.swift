// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MovementIsLife",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MovementIsLife",
            path: "Sources/MovementIsLife",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
