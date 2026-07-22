// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PulseVPNMenu",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "PulseVPNMenu",
            path: "Sources/PulseVPNMenu",
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
