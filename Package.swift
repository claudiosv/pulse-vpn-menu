// swift-tools-version: 6.4
import PackageDescription

// libopenconnect + headers come from scripts/build-openconnect.sh.
let oc = "\(Context.packageDirectory)/vendor/openconnect"

let package = Package(
    name: "PulseVPNMenu",
    platforms: [
        .macOS(.v27)
    ],
    dependencies: [
        // Drives Chrome for the browser login.
        .package(path: "Packages/ChromeCDP")
    ],
    targets: [
        .target(
            name: "PulseVPNTunnelProtocol",
            path: "Sources/PulseVPNTunnelProtocol"
        ),
        .executableTarget(
            name: "PulseVPNMenu",
            dependencies: [
                "PulseVPNTunnelProtocol",
                .product(name: "ChromeCDP", package: "ChromeCDP"),
            ],
            path: "Sources/PulseVPNMenu",
            linkerSettings: [
                .linkedFramework("NetworkExtension"),
                .linkedFramework("SystemExtensions"),
            ]
        ),
        .target(
            name: "COpenConnectShim",
            path: "Sources/COpenConnectShim",
            cSettings: [.unsafeFlags(["-I\(oc)/include"])],
            linkerSettings: [
                // Only .a files live in lib/, so these link statically.
                .unsafeFlags(["-L\(oc)/lib"]),
                .linkedLibrary("openconnect"), .linkedLibrary("ssl"), .linkedLibrary("crypto"),
                .linkedLibrary("xml2"), .linkedLibrary("z"), .linkedLibrary("iconv"),
            ]
        ),
        .target(
            name: "OpenConnectKit",
            dependencies: ["COpenConnectShim"],
            path: "Sources/OpenConnectKit"
        ),
        .executableTarget(
            name: "OCShimProbe",
            dependencies: ["OpenConnectKit"],
            path: "Sources/OCShimProbe"
        ),
        // Everything the packet tunnel provider does, as a library so it
        // can be tested; PulseVPNTunnel is the system extension's executable.
        .target(
            name: "PulseVPNTunnelCore",
            dependencies: ["PulseVPNTunnelProtocol", "OpenConnectKit"],
            path: "Sources/PulseVPNTunnelCore",
            linkerSettings: [
                .linkedFramework("NetworkExtension")
            ]
        ),
        .executableTarget(
            name: "PulseVPNTunnel",
            dependencies: ["PulseVPNTunnelCore"],
            path: "Sources/PulseVPNTunnel"
        ),
        .testTarget(
            name: "OpenConnectKitTests",
            dependencies: ["OpenConnectKit"],
            path: "Tests/OpenConnectKitTests"
        ),
        .testTarget(
            name: "PulseVPNMenuTests",
            dependencies: ["PulseVPNMenu", "PulseVPNTunnelProtocol"],
            path: "Tests/PulseVPNMenuTests"
        ),
        .testTarget(
            name: "PulseVPNTunnelTests",
            dependencies: ["PulseVPNTunnelCore", "PulseVPNTunnelProtocol", "OpenConnectKit"],
            path: "Tests/PulseVPNTunnelTests"
        )
    ]
)
