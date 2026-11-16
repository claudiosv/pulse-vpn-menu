// swift-tools-version: 6.4
import PackageDescription

// A small Chrome DevTools Protocol client: find and launch Chrome, talk to it
// over its WebSocket, and read cookies after a manual login. Foundation only.
let package = Package(
    name: "ChromeCDP",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .library(name: "ChromeCDP", targets: ["ChromeCDP"])
    ],
    targets: [
        .target(name: "ChromeCDP"),
        .testTarget(name: "ChromeCDPTests", dependencies: ["ChromeCDP"]),
    ]
)
