// swift-tools-version: 6.4
import PackageDescription

// libopenconnect + headers come from scripts/build-openconnect.sh.
let oc = "\(Context.packageDirectory)/vendor/openconnect"

let package = Package(
    name: "OpenConnectMenu",
    platforms: [
        .macOS(.v27)
    ],
    dependencies: [
        // Drives Chrome for the browser login.
        .package(path: "Packages/ChromeCDP")
    ],
    targets: [
        .target(
            name: "OpenConnectTunnelProtocol",
            path: "Sources/OpenConnectTunnelProtocol"
        ),
        .executableTarget(
            name: "OpenConnectMenu",
            dependencies: [
                "OpenConnectTunnelProtocol",
                .product(name: "ChromeCDP", package: "ChromeCDP"),
            ],
            path: "Sources/OpenConnectMenu",
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
        // can be tested; OpenConnectTunnel is the system extension's executable.
        .target(
            name: "OpenConnectTunnelCore",
            dependencies: ["OpenConnectTunnelProtocol", "OpenConnectKit"],
            path: "Sources/OpenConnectTunnelCore",
            linkerSettings: [
                .linkedFramework("NetworkExtension")
            ]
        ),
        .executableTarget(
            name: "OpenConnectTunnel",
            dependencies: ["OpenConnectTunnelCore"],
            path: "Sources/OpenConnectTunnel"
        ),
        .testTarget(
            name: "OpenConnectKitTests",
            dependencies: ["OpenConnectKit"],
            path: "Tests/OpenConnectKitTests"
        ),
        .testTarget(
            name: "OpenConnectMenuTests",
            dependencies: ["OpenConnectMenu", "OpenConnectTunnelProtocol"],
            path: "Tests/OpenConnectMenuTests"
        ),
        .testTarget(
            name: "OpenConnectTunnelTests",
            dependencies: ["OpenConnectTunnelCore", "OpenConnectTunnelProtocol", "OpenConnectKit"],
            path: "Tests/OpenConnectTunnelTests"
        )
    ]
)
