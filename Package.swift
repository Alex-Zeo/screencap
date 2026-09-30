// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "screencap",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "screencap", path: "Sources/screencap")
    ],
    swiftLanguageModes: [.v5]
)
