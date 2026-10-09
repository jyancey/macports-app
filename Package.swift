// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PortsApp",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "PortsKit"),
        .executableTarget(name: "PortsApp", dependencies: ["PortsKit"],
                          resources: [.process("Resources")]),
        .testTarget(name: "PortsKitTests", dependencies: ["PortsKit"]),
    ]
)
