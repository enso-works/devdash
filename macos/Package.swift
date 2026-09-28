// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevDashBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "DevDashBar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DevDashBar",
            // The app bundle embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
