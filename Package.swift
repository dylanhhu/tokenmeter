// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenMeter", targets: ["TokenMeter"]),
        .library(name: "TokenMeterKit", targets: ["TokenMeterKit"]),
    ],
    targets: [
        .target(
            name: "TokenMeterKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TokenMeter",
            dependencies: ["TokenMeterKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TokenMeterKitTests",
            dependencies: ["TokenMeterKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
