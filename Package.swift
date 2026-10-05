// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacNeutron",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "macneutron", targets: ["macneutron"]),
        .executable(name: "MacNeutronApp", targets: ["MacNeutronApp"]),
        .library(name: "MacNeutronCore", targets: ["MacNeutronCore"]),
    ],
    targets: [
        .target(name: "MacNeutronCore"),
        .executableTarget(name: "macneutron", dependencies: ["MacNeutronCore"]),
        .executableTarget(name: "MacNeutronApp", dependencies: ["MacNeutronCore"]),
        .testTarget(name: "MacNeutronCoreTests", dependencies: ["MacNeutronCore", "MacNeutronApp"]),
    ]
)
