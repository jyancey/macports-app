// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortsApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PortsKit"),
        .executableTarget(name: "PortsApp", dependencies: ["PortsKit"]),
        .testTarget(name: "PortsKitTests", dependencies: ["PortsKit"]),
    ]
)
