// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GhosttySessions",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "GhosttySessions",
      path: "Sources/GhosttySessions",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
