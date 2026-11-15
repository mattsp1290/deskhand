// swift-tools-version: 6.2

// The deskhand spike harness: a throwaway package, separate from the main deskhand package, that
// measures what macOS allows (bn request deskhand-r-waw0). See scripts/run-spike.sh.

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
    .executableTarget(
      name: "DeskhandSpike",
      dependencies: ["SpikeKit", "SpikeInput"],
      path: "Sources/DeskhandSpike",
      swiftSettings: settings
    ),
  ]
)
