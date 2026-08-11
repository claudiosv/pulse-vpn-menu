// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPNHelper",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "VPNHelper",
            path: "Sources/VPNHelper"
        )
    ]
)
