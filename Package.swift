// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PostgresManager",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "PostgresManagerApp", targets: ["PostgresManagerApp"]),
        .library(name: "PGKit", targets: ["PGKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.0"),
    ],
    targets: [
        .target(
            name: "PGKit",
            dependencies: [.product(name: "PostgresNIO", package: "postgres-nio")]
        ),
        .executableTarget(
            name: "PostgresManagerApp",
            dependencies: ["PGKit"]
        ),
        // Note: with Command Line Tools and no Xcode, swift-testing needs an extra plugin path
        // and two rpaths. Those are passed by Scripts/test.sh rather than hardcoded here, so
        // this manifest stays portable to machines (and CI runners) that do have Xcode.
        .testTarget(
            name: "PGKitTests",
            dependencies: ["PGKit"]
        ),
    ]
)
