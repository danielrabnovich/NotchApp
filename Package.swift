// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "NotchApp",
    platforms: [.macOS("14.2")],
    dependencies: [
        // Tells the voices on the other side of a call apart (speaker diarization), on this Mac.
        // Apache-2.0. No traits: without its text-normalisation engine, which only text-to-speech uses.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "NotchApp",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/NotchApp",
            swiftSettings: [
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
                // Constant values the App Intents metadata is read from (build.sh), as Xcode asks for them.
                .unsafeFlags(["-emit-const-values", "-Xfrontend", "-const-gather-protocols-file",
                              "-Xfrontend", "\(Context.packageDirectory)/Resources/appintents-protocols.json"]),
            ],
            linkerSettings: [.linkedLibrary("IOReport")]
        ),
        // The `notch` command, shipped inside the app (Contents/MacOS/notch).
        .executableTarget(name: "notch", path: "Sources/notch"),
    ],
    swiftLanguageModes: [.v5]
)
