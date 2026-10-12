// swift-tools-version: 6.2
// Package.swift - Swift package manifest for the MacPortsApp app, its PortsKit library, and their tests.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
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
