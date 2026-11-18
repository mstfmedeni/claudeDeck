// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeDeck",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ClaudeDeck", targets: ["ClaudeDeck"]),
        .executable(name: "claudedeck-ptyd", targets: ["claudedeck-ptyd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.20.0")),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "ClaudeDeckCore"),
        .executableTarget(
            name: "ClaudeDeck",
            dependencies: [
                "ClaudeDeckCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        // Session helper: keeps ptys alive while the app is closed (PtydServer).
        .executableTarget(name: "claudedeck-ptyd", dependencies: ["ClaudeDeckCore"]),
        .testTarget(
            name: "ClaudeDeckCoreTests",
            // The helper is built too: the integration tests run it as a child process.
            dependencies: ["ClaudeDeckCore", "claudedeck-ptyd"],
            exclude: ["Fixtures"]
        ),
    ]
)
