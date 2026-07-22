// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PulseVPNMenu",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "PulseVPNHelperProtocol",
            path: "Sources/PulseVPNHelperProtocol"
        ),
        .executableTarget(
            name: "PulseVPNMenu",
            dependencies: ["PulseVPNHelperProtocol"],
            path: "Sources/PulseVPNMenu",
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "PulseVPNMenuHelper",
            dependencies: ["PulseVPNHelperProtocol"],
            path: "Sources/PulseVPNMenuHelper"
        )
    ]
)
