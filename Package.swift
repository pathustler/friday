// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FRIDAY",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FRIDAY", path: "Sources/FRIDAY")
    ]
)
