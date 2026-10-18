// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Kestrel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "kestrel", targets: ["kestrel"]),
        .executable(name: "KestrelApp", targets: ["KestrelApp"]),
        .library(name: "KestrelCore", targets: ["KestrelCore"]),
        .library(name: "KestrelKeymap", targets: ["KestrelKeymap"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.11.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    ],
    targets: [
        .target(name: "KestrelCore"),
        .target(name: "KestrelKeymap"),
        .target(name: "KestrelPlay", dependencies: ["KestrelCore", "KestrelKeymap", "KestrelStream"]),
        .target(name: "KestrelStream", dependencies: [
            "KestrelCore",
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
            .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ], plugins: [
            .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf"),
        ]),
        .executableTarget(name: "kestrel", dependencies: ["KestrelCore", "KestrelKeymap", "KestrelPlay"]),
        .executableTarget(name: "KestrelApp", dependencies: ["KestrelCore", "KestrelKeymap", "KestrelPlay"]),
        .executableTarget(name: "ProductLauncherProbe", dependencies: ["KestrelCore"],
                          path: "diagnostics/ProductLauncherProbe"),
        .executableTarget(name: "NativeSessionWindowProbe", dependencies: ["KestrelCore", "KestrelPlay"],
                          path: "diagnostics/NativeSessionWindowProbe"),
        .executableTarget(name: "PlayerSessionProbe", dependencies: ["KestrelCore", "KestrelStream"],
                          path: "diagnostics/PlayerSessionProbe"),
        .executableTarget(name: "NativeStreamProbe", dependencies: ["KestrelCore", "KestrelStream"],
                          path: "diagnostics/NativeStreamProbe"),
        .executableTarget(name: "NativePlayerProbe", dependencies: ["KestrelCore", "KestrelKeymap", "KestrelPlay", "KestrelStream"],
                          path: "diagnostics/NativePlayerProbe"),
        .testTarget(name: "KestrelCoreTests", dependencies: ["KestrelCore"]),
        .testTarget(name: "KestrelPlayTests", dependencies: ["KestrelCore", "KestrelKeymap", "KestrelPlay"]),
        .testTarget(name: "KestrelStreamTests", dependencies: ["KestrelCore", "KestrelStream"]),
        .testTarget(name: "KestrelKeymapTests", dependencies: ["KestrelKeymap"]),
    ],
    swiftLanguageModes: [.v5]
)
