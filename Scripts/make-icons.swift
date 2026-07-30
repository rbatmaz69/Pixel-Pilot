#!/usr/bin/env swift
//
// Generates the app icon and the menu bar template image.
//
//   swift Scripts/make-icons.swift
//
// The artwork is drawn as vector paths rather than scaled from a bitmap, for
// two reasons: the menu bar needs a clean silhouette that can only be derived
// from closed paths, and an icon rendered at each target size stays crisp at
// 16pt where a downscaled bitmap turns to mush.
//
// Everything is laid out on a 1024-unit square and scaled, so the numbers below
// can be read directly against a 1024x1024 reference.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// The poppy, described once in reference coordinates.
enum Poppy {
  static let reference: CGFloat = 1024

  static let centre = CGPoint(x: 512, y: 590) // CG origin is bottom-left
  static let coreRadius: CGFloat = 92

  /// The four petals, as rounded shapes arranged around the core. Overlapping
  /// on purpose — the seams are what make it read as separate petals rather
  /// than one blob.
  static let petals: [(rect: CGRect, radius: CGFloat)] = [
    (CGRect(x: 380, y: 650, width: 264, height: 200), 96),  // top
    (CGRect(x: 306, y: 500, width: 220, height: 240), 100), // left
    (CGRect(x: 500, y: 500, width: 220, height: 240), 100), // right
    (CGRect(x: 386, y: 420, width: 252, height: 190), 92),  // bottom
  ]

  static let stem = CGRect(x: 492, y: 190, width: 40, height: 300)
  static let stemRadius: CGFloat = 20

  /// One leaf, sweeping out and up from the base of the stem. Mirrored for the
  /// other side.
  ///
  /// Drawn as an outer sweep and an inner sweep that do not meet along the top
  /// edge, which leaves the crescent notch. Without it the shape reads as a
  /// flat almond rather than a folded leaf.
  static func leafPath(mirrored: Bool) -> CGPath {
    let path = CGMutablePath()
    let tip = CGPoint(x: 268, y: 460)
    let join = CGPoint(x: 496, y: 232)

    // Outer edge: tip, bulging down and round, to the stem.
    path.move(to: tip)
    path.addCurve(
      to: join,
      control1: CGPoint(x: 286, y: 300),
      control2: CGPoint(x: 380, y: 232)
    )
    // Inner edge back to the tip, cutting higher so a sliver of background
    // stays open between the two.
    path.addCurve(
      to: tip,
      control1: CGPoint(x: 396, y: 330),
      control2: CGPoint(x: 322, y: 386)
    )
    path.closeSubpath()

    guard mirrored else { return path }
    var flip = CGAffineTransform(translationX: reference, y: 0).scaledBy(x: -1, y: 1)
    return path.copy(using: &flip) ?? path
  }

  /// Everything except the core, as one path — the silhouette used for the
  /// menu bar.
  static func silhouette() -> CGPath {
    let path = CGMutablePath()
    for petal in petals {
      path.addPath(CGPath(
        roundedRect: petal.rect, cornerWidth: petal.radius, cornerHeight: petal.radius,
        transform: nil
      ))
    }
    path.addPath(CGPath(
      roundedRect: stem, cornerWidth: stemRadius, cornerHeight: stemRadius, transform: nil
    ))
    path.addPath(leafPath(mirrored: false))
    path.addPath(leafPath(mirrored: true))
    return path
  }
}

// MARK: - Colours

enum Palette {
  static let petalTop = CGColor(red: 0.86, green: 0.25, blue: 0.18, alpha: 1)
  static let petalSide = CGColor(red: 0.76, green: 0.19, blue: 0.13, alpha: 1)
  static let coreOuter = CGColor(red: 0.29, green: 0.13, blue: 0.04, alpha: 1)
  static let coreInner = CGColor(red: 0.16, green: 0.06, blue: 0.02, alpha: 1)
  static let leafLight = CGColor(red: 0.44, green: 0.78, blue: 0.27, alpha: 1)
  static let leafDark = CGColor(red: 0.13, green: 0.55, blue: 0.20, alpha: 1)
  static let plate = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
}

// MARK: - Drawing

func makeContext(size: Int) -> CGContext {
  guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { fatalError("could not create a bitmap context at \(size)px") }
  return context
}

func verticalGradient(_ context: CGContext, in rect: CGRect, from: CGColor, to: CGColor) {
  guard let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [from, to] as CFArray, locations: [0, 1]
  ) else { return }
  context.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY),
    options: []
  )
}

/// Draws the plant. `scale` maps reference units to pixels.
func drawPoppy(in context: CGContext, scale: CGFloat) {
  context.saveGState()
  context.scaleBy(x: scale, y: scale)

  // Leaves first, so the stem overlaps them at the join.
  for mirrored in [false, true] {
    context.saveGState()
    context.addPath(Poppy.leafPath(mirrored: mirrored))
    context.clip()
    verticalGradient(
      context, in: Poppy.leafPath(mirrored: mirrored).boundingBox,
      from: Palette.leafLight, to: Palette.leafDark
    )
    context.restoreGState()
  }

  context.saveGState()
  context.addPath(CGPath(
    roundedRect: Poppy.stem, cornerWidth: Poppy.stemRadius, cornerHeight: Poppy.stemRadius,
    transform: nil
  ))
  context.clip()
  verticalGradient(context, in: Poppy.stem, from: Palette.leafLight, to: Palette.leafDark)
  context.restoreGState()

  // Side petals sit behind, top and bottom in front — the same stacking as the
  // reference drawing.
  for (index, petal) in Poppy.petals.enumerated() {
    let isSide = index == 1 || index == 2
    context.setFillColor(isSide ? Palette.petalSide : Palette.petalTop)
    context.addPath(CGPath(
      roundedRect: petal.rect, cornerWidth: petal.radius, cornerHeight: petal.radius,
      transform: nil
    ))
    context.fillPath()
  }

  let coreRect = CGRect(
    x: Poppy.centre.x - Poppy.coreRadius, y: Poppy.centre.y - Poppy.coreRadius,
    width: Poppy.coreRadius * 2, height: Poppy.coreRadius * 2
  )
  context.saveGState()
  context.addEllipse(in: coreRect)
  context.clip()
  verticalGradient(context, in: coreRect, from: Palette.coreOuter, to: Palette.coreInner)
  context.restoreGState()

  context.restoreGState()
}

/// The macOS icon grid: the plate occupies 824 of 1024 units with a 185.4
/// corner radius, leaving the margin the system expects for shadows.
func drawAppIcon(size: Int) -> CGImage {
  let context = makeContext(size: size)
  let scale = CGFloat(size) / Poppy.reference

  let inset: CGFloat = 100 * scale
  let plate = CGRect(
    x: inset, y: inset,
    width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2
  )
  let radius = 185.4 * scale

  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: -6 * scale),
    blur: 16 * scale,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22)
  )
  context.setFillColor(Palette.plate)
  context.addPath(CGPath(
    roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
  ))
  context.fillPath()
  context.restoreGState()

  // Keep the artwork inside the plate.
  context.saveGState()
  context.addPath(CGPath(
    roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
  ))
  context.clip()
  drawPoppy(in: context, scale: scale)
  context.restoreGState()

  guard let image = context.makeImage() else { fatalError("could not render \(size)px icon") }
  return image
}

/// A flat black silhouette with the core punched out.
///
/// Template images are tinted by macOS, so only the alpha channel matters. The
/// hole is what keeps it legible at 18pt: a solid blob of petals reads as a
/// circle, and the gap is the only thing that says "flower".
func drawMenuBarIcon(size: Int) -> CGImage {
  let context = makeContext(size: size)

  // Fit the artwork to the canvas rather than reusing the app icon's scale.
  // The app icon needs margin for its plate and shadow; a menu bar template has
  // no plate, and inheriting that margin would waste a third of the height at
  // the one size where every pixel counts.
  let silhouette = Poppy.silhouette()
  let bounds = silhouette.boundingBox
  let margin = CGFloat(size) * 0.06
  let available = CGFloat(size) - margin * 2
  let scale = min(available / bounds.width, available / bounds.height)

  context.saveGState()
  context.translateBy(
    x: (CGFloat(size) - bounds.width * scale) / 2 - bounds.minX * scale,
    y: (CGFloat(size) - bounds.height * scale) / 2 - bounds.minY * scale
  )
  context.scaleBy(x: scale, y: scale)

  context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
  context.addPath(silhouette)
  context.fillPath()

  // Punch the core out. At 18pt a solid mass of petals reads as a circle; the
  // hole is the only thing that says "flower".
  context.setBlendMode(.clear)
  context.addArc(
    center: Poppy.centre, radius: Poppy.coreRadius * 0.82,
    startAngle: 0, endAngle: .pi * 2, clockwise: false
  )
  context.fillPath()

  context.restoreGState()

  guard let image = context.makeImage() else { fatalError("could not render menu bar icon") }
  return image
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
  guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, "public.png" as CFString, 1, nil
  ) else { fatalError("could not write \(url.path)") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    fatalError("could not finalise \(url.path)")
  }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Sources/PixelPilot/Resources/Assets.xcassets")
let appIconSet = assets.appendingPathComponent("AppIcon.appiconset")
let menuBarSet = assets.appendingPathComponent("MenuBarIcon.imageset")

for directory in [appIconSet, menuBarSet] {
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

// macOS wants each size at 1x and 2x; the 2x of one size is the 1x pixel count
// of the next, so the pixel sizes collapse to this set.
let iconPixelSizes = [16, 32, 64, 128, 256, 512, 1024]
for pixels in iconPixelSizes {
  write(drawAppIcon(size: pixels), to: appIconSet.appendingPathComponent("icon_\(pixels).png"))
}

for (pixels, suffix) in [(18, ""), (36, "@2x")] {
  write(drawMenuBarIcon(size: pixels), to: menuBarSet.appendingPathComponent("menubar\(suffix).png"))
}

func appIconContents() -> String {
  let entries: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
  ]
  let images = entries.map { entry in
    """
        {
          "filename" : "icon_\(entry.size * entry.scale).png",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.size)x\(entry.size)"
        }
    """
  }
  return """
  {
    "images" : [
  \(images.joined(separator: ",\n"))
    ],
    "info" : { "author" : "xcode", "version" : 1 }
  }
  """
}

let menuBarContents = """
{
  "images" : [
    { "filename" : "menubar.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menubar@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
"""

let catalogContents = """
{
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

try appIconContents().write(
  to: appIconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
)
try menuBarContents.write(
  to: menuBarSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
)
try catalogContents.write(
  to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
)

print("Wrote \(iconPixelSizes.count) app icon sizes and the menu bar template to")
print("  \(assets.path)")
