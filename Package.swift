// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TinyTimer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TinyTimerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "TinyTimer",
            dependencies: ["TinyTimerCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
