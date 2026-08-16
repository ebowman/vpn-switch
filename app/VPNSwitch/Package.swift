// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VPNSwitch",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "VPNSwitch",
            path: "Sources/VPNSwitch"
        )
    ]
)
