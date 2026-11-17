// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "deskhand",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DeskhandCore", targets: ["DeskhandCore"]),
        .library(name: "DeskhandServer", targets: ["DeskhandServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        // Patch releases only: the listener tests pin BoringSSL's TLS behaviour (session resumption,
        // certificate checks), so take a new minor version deliberately.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", .upToNextMinor(from: "2.37.6")),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "DeskhandCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(
            name: "DeskhandServer",
            dependencies: [
                "DeskhandCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "DeskhandTestSupport",
            dependencies: ["DeskhandCore"],
            path: "Tests/DeskhandTestSupport"
        ),
        .testTarget(
            name: "DeskhandCoreTests",
            dependencies: [
                "DeskhandCore",
                "DeskhandTestSupport",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "DeskhandServerTests",
            dependencies: [
                "DeskhandServer",
                "DeskhandTestSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
    ]
)

// macOS-only targets are added only when the manifest is evaluated on macOS, so a Linux
// `swift build` / `swift test` never sees AppKit, ScreenCaptureKit or CoreGraphics sources.
#if os(macOS)
    package.products += [
        .executable(name: "DeskhandApp", targets: ["DeskhandApp"]),
        .executable(name: "DeskhandLogDaemon", targets: ["DeskhandLogDaemon"]),
    ]
    package.targets += [
        .target(
            name: "DeskhandPlatform",
            dependencies: ["DeskhandCore"]
        ),
        .executableTarget(
            name: "DeskhandApp",
            dependencies: ["DeskhandCore", "DeskhandServer", "DeskhandPlatform"]
        ),
        .executableTarget(
            name: "DeskhandLogDaemon",
            dependencies: ["DeskhandCore"]
        ),
        .testTarget(
            name: "DeskhandPlatformTests",
            dependencies: ["DeskhandPlatform", "DeskhandTestSupport"]
        ),
    ]
#endif
