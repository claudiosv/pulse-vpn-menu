// swift-tools-version: 6.4
import PackageDescription

// libopenconnect + headers come from scripts/build-openconnect.sh.
let oc = "\(Context.packageDirectory)/vendor/openconnect"

let package = Package(
    name: "PulseVPNMenu",
    platforms: [
        .macOS(.v27)
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
        .executableTarget(
            name: "PulseVPNMenuHelper",
            dependencies: ["PulseVPNHelperProtocol", "OpenConnectKit"],
            path: "Sources/PulseVPNMenuHelper"
        ),
        .testTarget(
            name: "OpenConnectKitTests",
            dependencies: ["OpenConnectKit"],
            path: "Tests/OpenConnectKitTests"
        ),
        .testTarget(
            name: "PulseVPNMenuHelperTests",
            dependencies: ["PulseVPNMenuHelper", "PulseVPNHelperProtocol"],
            path: "Tests/PulseVPNMenuHelperTests"
        )
    ]
)
