// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DesktopAgentPilot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DesktopAgentPilot", targets: ["DesktopAgentPilot"])
    ],
    targets: [
        .executableTarget(name: "DesktopAgentPilot")
    ]
)
