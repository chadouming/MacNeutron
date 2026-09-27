// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacProton",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MacProtonCore", targets: ["MacProtonCore"]),
    ],
    targets: [
        .target(name: "MacProtonCore"),
        .testTarget(name: "MacProtonCoreTests", dependencies: ["MacProtonCore"]),
    ]
)
