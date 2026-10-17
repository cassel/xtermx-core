// swift-tools-version: 6.0
import PackageDescription

let nio: [Target.Dependency] = ["NIOCore", "NIOPosix", "NIOHTTP1", "NIOWebSocket", "NIOConcurrencyHelpers"]
    .map { .product(name: $0, package: "swift-nio") }

let package = Package(
    name: "XTermXKit",
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "XTermXKit", targets: ["XTermXKit"]),
        .library(name: "XTermXHost", targets: ["XTermXHost"]),
        .library(name: "XTermXTerminalUI", targets: ["XTermXTerminalUI"]),
        .executable(name: "xtermx", targets: ["xtermx"]),
        .executable(name: "xtermx-doc-previews", targets: ["DocumentationPreview"]),
    ],
    dependencies: [
        .package(url: "https://github.com/adam-fowler/swift-srp", exact: "2.4.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/fwcd/swift-qrcode-generator", from: "2.0.0"),
    ],
    targets: [
        // Shared by every platform, watchOS included: models, wire protocol, crypto, remote client.
        .target(
            name: "XTermXKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "SRP", package: "swift-srp", condition: .when(platforms: [.macOS, .iOS, .linux]))
            ]
        ),
        // macOS + Linux: the network transport every node uses (WebSocket server/client, HTTP).
        .target(name: "XTermXNIO", dependencies: ["XTermXKit"] + nio, swiftSettings: [.swiftLanguageMode(.v5)]),
        // macOS + Linux: a node — PTY panes, agents, the remote and agent-tool servers.
        .target(
            name: "XTermXHost",
            dependencies: [
                "XTermXKit",
                "XTermXNIO",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS, .linux])),
            ]
        ),
        // macOS + iOS: terminal views and SSH sessions.
        .target(
            name: "XTermXTerminalUI",
            dependencies: [
                "XTermXKit",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "Citadel", package: "Citadel", condition: .when(platforms: [.macOS, .iOS])),
            ],
            // Citadel/NIO SSH types are not Sendable yet.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `xtermx`: the headless node (`xtermx serve`) and a terminal client for other nodes.
        .executableTarget(
            name: "xtermx",
            dependencies: [
                "XTermXKit",
                "XTermXHost",
                "XTermXNIO",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
            ],
            // swift-crypto's BoringSSL has C++ parts.
            linkerSettings: [.linkedLibrary("stdc++", .when(platforms: [.linux]))]
        ),
        // Offscreen documentation artwork using fixtures only; never opens an AppModel or PTY.
        .executableTarget(name: "DocumentationPreview", dependencies: ["XTermXKit"]),
        .testTarget(name: "XTermXKitTests", dependencies: ["XTermXKit", "XTermXHost", "XTermXNIO", .target(name: "XTermXTerminalUI", condition: .when(platforms: [.macOS]))]),
    ]
)
