// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "taudot-mac",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "taudot-app", targets: ["TaudotApp"])],
  dependencies: [.package(path: "../render/cursor")],
  targets: [
    .target(name: "TaudotShared"),
    .target(name: "TaudotNeovim", dependencies: ["TaudotShared"]),
    .target(name: "TaudotPDF", dependencies: ["TaudotShared", .product(name: "TaudotCursor", package: "cursor")]),
    .target(name: "TaudotReview", dependencies: ["TaudotShared"]),
    .target(name: "TaudotEditor", dependencies: ["TaudotShared", "TaudotPDF"]),
    .target(name: "TaudotHome", dependencies: ["TaudotShared", "TaudotPDF"]),
    .target(name: "TaudotHistory", dependencies: ["TaudotShared", "TaudotPDF", "TaudotReview"]),
    .executableTarget(name: "TaudotApp", dependencies: ["TaudotShared", "TaudotNeovim", "TaudotPDF", "TaudotReview", "TaudotHome", "TaudotEditor", "TaudotHistory"]),
    .executableTarget(name: "PDFHost", dependencies: ["TaudotShared", "TaudotPDF"]),
    .executableTarget(name: "ReviewHost", dependencies: ["TaudotShared", "TaudotReview"]),
    .executableTarget(name: "HomeHost", dependencies: ["TaudotShared", "TaudotHome"]),
    .executableTarget(name: "EditorHost", dependencies: ["TaudotShared", "TaudotEditor", "TaudotPDF", "TaudotReview"]),
    .testTarget(name: "TaudotTests", dependencies: ["TaudotShared", "TaudotNeovim", "TaudotPDF", "TaudotReview", "TaudotHome", "TaudotEditor", "TaudotHistory"]),
  ]
)
