// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacProton",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "macproton", targets: ["macproton"]),
        .library(name: "MacProtonCore", targets: ["MacProtonCore"]),
    ],
    targets: [
        .target(name: "MacProtonCore"),
        .executableTarget(name: "macproton", dependencies: ["MacProtonCore"]),
        .testTarget(name: "MacProtonCoreTests", dependencies: ["MacProtonCore"]),
    ]
)
