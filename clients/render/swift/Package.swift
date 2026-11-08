// swift-tools-version:5.9
// TaudotRender: reads Taudot display lists (../dlist.md) and draws them with Core Graphics.
// taudot-raster: a list → PNG, on the CPU, deterministic (what the harness measures).
import PackageDescription

let package = Package(
  name: "TaudotRender",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "TaudotRender", targets: ["TaudotRender"]),
    .executable(name: "taudot-raster", targets: ["taudot-raster"]),
    // txp-render's `render` verb (driver.c) links this
    .library(name: "TaudotRenderC", type: .static, targets: ["TaudotRenderC"]),
  ],
  targets: [
    .target(name: "TaudotRender"),
    .executableTarget(name: "taudot-raster", dependencies: ["TaudotRender"]),
    .target(name: "TaudotRenderC", dependencies: ["TaudotRender"]),
    .testTarget(name: "TaudotRenderTests", dependencies: ["TaudotRender"]),
  ]
)
