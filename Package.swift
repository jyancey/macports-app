// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MacPortsApp",
  platforms: [.macOS(.v26)],
  targets: [
    .target(name: "PortsKit"),
    .executableTarget(
      name: "MacPortsApp", dependencies: ["PortsKit"],
      path: "Sources/PortsApp",
      resources: [.process("Resources")]),
    .testTarget(name: "PortsKitTests", dependencies: ["PortsKit"]),
    .testTarget(name: "MacPortsAppTests", dependencies: ["MacPortsApp", "PortsKit"]),
  ]
)
