// swift-tools-version: 6.2

import PackageDescription

let settings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
  name: "deskhand-spike",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "deskhand-spike", targets: ["DeskhandSpike"])
  ],
  targets: [
    .target(name: "SpikeKit", path: "Sources/SpikeKit", swiftSettings: settings),
    .target(
      name: "SpikeInput", dependencies: ["SpikeKit"], path: "Input", swiftSettings: settings),
    .testTarget(name: "SpikeKitTests", dependencies: ["SpikeKit"], swiftSettings: settings),
    .executableTarget(
      name: "DeskhandSpike",
      dependencies: ["SpikeKit", "SpikeInput"],
      path: "Sources/DeskhandSpike",
      swiftSettings: settings
    ),
  ]
)
