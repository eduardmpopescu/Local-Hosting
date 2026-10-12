// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LocalHosting",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "LocalHosting", path: "Sources/LocalHosting")
    ],
    swiftLanguageModes: [.v5]
)
