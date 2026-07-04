// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiquidCode",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LiquidCode", targets: ["LiquidCode"])
    ],
    targets: [
        .executableTarget(
            name: "LiquidCode",
            path: "Sources/LiquidCode"
        ),
        .testTarget(
            name: "LiquidCodeTests",
            dependencies: ["LiquidCode"],
            path: "Tests/LiquidCodeTests"
        )
    ]
)
