// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchApp",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "NotchApp",
            path: "Sources/NotchApp",
            swiftSettings: [
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
                // Constant values the App Intents metadata is read from (build.sh), as Xcode asks for them.
                .unsafeFlags(["-emit-const-values", "-Xfrontend", "-const-gather-protocols-file",
                              "-Xfrontend", "\(Context.packageDirectory)/Resources/appintents-protocols.json"]),
            ],
            linkerSettings: [.linkedLibrary("IOReport")]
        )
    ]
)
