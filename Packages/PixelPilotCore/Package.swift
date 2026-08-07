// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PixelPilotCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PixelPilotCore", targets: ["PixelPilotCore"]),
    .executable(name: "ppctl", targets: ["ppctl"]),
  ],
  targets: [
    // Declarations for the undocumented IOAVService I2C entry points. The symbols
    // themselves are exported from the public IOKit.tbd of the macOS 26 SDK, so no
    // dlopen is required — we only need the prototypes.
    .target(name: "CDDCPrivate", linkerSettings: [.linkedFramework("IOKit")]),

    .target(name: "PixelPilotCore", dependencies: ["CDDCPrivate"]),

    .executableTarget(name: "ppctl", dependencies: ["PixelPilotCore"]),

    // The fixture is a real answer from GitHub's releases API, captured rather
    // than hand-written, so the decoding is checked against the shape the
    // service actually sends instead of the shape we remember it sending.
    .testTarget(
      name: "PixelPilotCoreTests",
      dependencies: ["PixelPilotCore"],
      resources: [.process("Fixtures")]
    ),
  ]
)
