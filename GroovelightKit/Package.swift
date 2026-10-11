// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GroovelightKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
        .library(name: "Visualizers", targets: ["Visualizers"]),
        .library(name: "MetadataKit", targets: ["MetadataKit"]),
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
        .testTarget(
            name: "GroovelightKitTests",
            dependencies: ["PlayerCore", "LibraryKit", "Visualizers", "MetadataKit", .product(name: "SFBAudioEngine", package: "SFBAudioEngine"), .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
