// swift-tools-version:5.9
import PackageDescription

// Priostack Agent Context Network (ACN) — official Swift client.
//
// Pure Foundation: URLSession + Codable + async/await. No third-party
// dependencies, so nothing to vendor or pin beyond the toolchain itself.
let package = Package(
    name: "PriostackACN",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "PriostackACN", targets: ["PriostackACN"]),
        .executable(name: "quickstart", targets: ["quickstart"]),
    ],
    targets: [
        .target(name: "PriostackACN"),
        .executableTarget(
            name: "quickstart",
            dependencies: ["PriostackACN"]
        ),
    ]
)
