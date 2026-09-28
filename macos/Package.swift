// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevDashBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DevDashBar",
            path: "Sources/DevDashBar"
        ),
    ]
)
