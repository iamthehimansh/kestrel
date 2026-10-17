// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kestrel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "kestrel", targets: ["kestrel"]),
        .library(name: "KestrelCore", targets: ["KestrelCore"]),
        .library(name: "KestrelKeymap", targets: ["KestrelKeymap"]),
    ],
    targets: [
        .target(name: "KestrelCore"),
        .target(name: "KestrelKeymap"),
        .target(name: "KestrelPlay", dependencies: ["KestrelCore", "KestrelKeymap"]),
        .executableTarget(name: "kestrel", dependencies: ["KestrelCore", "KestrelKeymap", "KestrelPlay"]),
        .testTarget(name: "KestrelCoreTests", dependencies: ["KestrelCore"]),
        .testTarget(name: "KestrelKeymapTests", dependencies: ["KestrelKeymap"]),
    ]
)
