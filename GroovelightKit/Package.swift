// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GroovelightKit",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
        .library(name: "Visualizers", targets: ["Visualizers"]),
        .library(name: "MetadataKit", targets: ["MetadataKit"]),
        .library(name: "Scrobbler", targets: ["Scrobbler"]),
        .library(name: "WirelessSync", targets: ["WirelessSync"]),
        .library(name: "WirelessSyncClient", targets: ["WirelessSyncClient"]),
        .library(name: "ControlKit", targets: ["ControlKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine.git", from: "0.9.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "PlayerCore",
            dependencies: [.product(name: "SFBAudioEngine", package: "SFBAudioEngine")]
        ),
        .target(
            name: "LibraryKit",
            dependencies: [
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "Visualizers",
            dependencies: ["PlayerCore"]
        ),
        .target(
            name: "MetadataKit",
            dependencies: ["LibraryKit"]
        ),
        .target(
            name: "Scrobbler",
            dependencies: ["LibraryKit", "MetadataKit"]
        ),
        .target(
            name: "WirelessSync",
            dependencies: ["LibraryKit"]
        ),
        // The device's side of wireless sync (Groovelight for iOS); builds on macOS too, so its tests run against the server.
        .target(
            name: "WirelessSyncClient",
            dependencies: ["WirelessSync", "LibraryKit"]
        ),
        // The command line tool talking to the app (no dependencies: the tool links only this).
        .target(name: "ControlKit"),
        .testTarget(
            name: "GroovelightKitTests",
            dependencies: ["PlayerCore", "LibraryKit", "Visualizers", "MetadataKit", "Scrobbler", "WirelessSync", "WirelessSyncClient", "ControlKit", .product(name: "SFBAudioEngine", package: "SFBAudioEngine"), .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
