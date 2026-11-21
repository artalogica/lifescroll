// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Lifescroll",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "Lifescroll",
      path: "Sources/Lifescroll",
      linkerSettings: [.linkedLibrary("sqlite3")]
    )
  ]
)
