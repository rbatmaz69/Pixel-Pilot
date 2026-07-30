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

    .testTarget(name: "PixelPilotCoreTests", dependencies: ["PixelPilotCore"]),
  ]
)
