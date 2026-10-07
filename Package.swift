// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchApp",
            path: "Sources/NotchApp",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        )
    ]
)
