// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shorthand",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Shorthand", path: "Sources/Shorthand")
    ]
)
