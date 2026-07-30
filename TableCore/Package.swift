// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TableCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TableCore", targets: ["TableCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TableCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "TableCoreTests",
            dependencies: ["TableCore"]
        ),
    ]
)
