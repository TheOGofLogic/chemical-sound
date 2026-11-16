// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ChemicalSound",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ChemicalSound",
            targets: ["ChemicalSound"]
        )
    ],
    targets: [
        .target(
            name: "ChemicalSound",
            path: "ChemicalSound",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ChemicalSoundTests",
            dependencies: ["ChemicalSound"],
            path: "ChemicalSoundTests"
        )
    ]
)
