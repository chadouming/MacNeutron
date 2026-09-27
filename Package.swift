// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacNeutron",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "macneutron", targets: ["macneutron"]),
        .library(name: "MacNeutronCore", targets: ["MacNeutronCore"]),
    ],
    targets: [
        .target(name: "MacNeutronCore"),
        .executableTarget(name: "macneutron", dependencies: ["MacNeutronCore"]),
        .testTarget(name: "MacNeutronCoreTests", dependencies: ["MacNeutronCore"]),
    ]
)
