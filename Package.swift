// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TT",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TTCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "TT",
            dependencies: ["TTCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
