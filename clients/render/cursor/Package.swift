// swift-tools-version:5.10
// TaudotCursor: the user's source cursor ↔ a glyph on the typeset page.
import PackageDescription

let package = Package(
  name: "TaudotCursor",
  platforms: [.macOS(.v14)],
  products: [.library(name: "TaudotCursor", targets: ["TaudotCursor"])],
  targets: [
    .target(name: "TaudotCursor"),
    .executableTarget(name: "taudot-cursor-eval", dependencies: ["TaudotCursor"]),
    .executableTarget(name: "taudot-cursor-host", dependencies: ["TaudotCursor"]),
    .testTarget(name: "TaudotCursorTests", dependencies: ["TaudotCursor"]),
  ]
)
