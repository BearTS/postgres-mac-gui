// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DevServices",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "DevServicesApp", targets: ["DevServicesApp"]),
        .library(name: "ServiceKit", targets: ["ServiceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.0"),
        // Pre-1.0, but it is the only native Swift Kafka client and it vendors librdkafka, so
        // reading messages needs no Homebrew package and no JVM. Pinned exactly: an alpha is
        // free to break its API between releases.
        .package(url: "https://github.com/swift-server/swift-kafka-client.git", exact: "1.0.0-alpha.9"),
    ],
    targets: [
        .target(
            name: "ServiceKit",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Kafka", package: "swift-kafka-client"),
            ]
        ),
        .executableTarget(
            name: "DevServicesApp",
            dependencies: ["ServiceKit"]
        ),
        // Note: with Command Line Tools and no Xcode, swift-testing needs an extra plugin path
        // and two rpaths. Those are passed by Scripts/test.sh rather than hardcoded here, so
        // this manifest stays portable to machines (and CI runners) that do have Xcode.
        .testTarget(
            name: "ServiceKitTests",
            dependencies: ["ServiceKit"]
        ),
    ]
)
