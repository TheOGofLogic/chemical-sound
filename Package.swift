// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LiquidAnalyzer",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LiquidAnalyzer",
            targets: ["LiquidAnalyzer"]
        )
    ],
    targets: [
        .target(
            name: "LiquidAnalyzer",
            path: "LiquidAnalyzer",
            exclude: ["Info.plist", "Assets.xcassets"]
        ),
        .testTarget(
            name: "LiquidAnalyzerTests",
            dependencies: ["LiquidAnalyzer"],
            path: "LiquidAnalyzerTests"
        )
    ]
)
