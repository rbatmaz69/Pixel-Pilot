#!/usr/bin/env swift
//
// Builds the app icon and the menu bar template from Art/poppy-source.png.
//
//   swift Scripts/make-icons.swift
//
// An earlier version redrew the artwork as vector paths. That was the wrong
// call: reproducing someone's drawing by eye lands somewhere near it and never
// on it. The source image is used directly instead, and the only thing derived
// from it is the menu bar silhouette — which needs a shape, not colours.
//

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Art/poppy-source.png")

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let source = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  FileHandle.standardError.write(Data("error: could not read \(sourceURL.path)\n".utf8))
  exit(1)
}

// MARK: - Pixel access

/// The source image as straight RGBA, so the artwork can be measured rather
/// than assumed — where it sits in the frame, and which parts are background.
struct Bitmap {
  let width: Int
  let height: Int
  var pixels: [UInt8]

  init(_ image: CGImage) {
    width = image.width
    height = image.height
    pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let index = (y * width + x) * 4
    return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]), Int(pixels[index + 3]))
  }

  /// True where the pixel is part of the drawing rather than the white ground.
  func isArtwork(x: Int, y: Int) -> Bool {
    let (r, g, b, a) = rgb(x: x, y: y)
    guard a > 16 else { return false }
    return !(r > 236 && g > 236 && b > 236)
  }

  /// True where the pixel belongs to the flower's dark core.
  ///
  /// The core is brown: red-dominant and dark. Distinguishing it by colour
  /// rather than by position keeps this working if the artwork is ever
  /// replaced. The shadowed green at the base of the leaves is also dark, but
  /// green-dominant, which is what separates the two.
  func isCore(x: Int, y: Int) -> Bool {
    let (r, g, b, _) = rgb(x: x, y: y)
    guard isArtwork(x: x, y: y) else { return false }
    return r >= g && g >= b && max(r, max(g, b)) < 150
  }

  /// Bounding box of the drawing, in pixel coordinates with y running down.
  var artworkBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int) {
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0 ..< height {
      for x in 0 ..< width where isArtwork(x: x, y: y) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
      }
    }
    return (minX, minY, maxX, maxY)
  }
}

let bitmap = Bitmap(source)
let bounds = bitmap.artworkBounds
let artWidth = bounds.maxX - bounds.minX + 1
let artHeight = bounds.maxY - bounds.minY + 1

print("Source \(bitmap.width)x\(bitmap.height); artwork occupies "
  + "\(artWidth)x\(artHeight) at (\(bounds.minX), \(bounds.minY))")

/// The drawing cropped to its own edges, so padding is decided here rather than
/// inherited from however much white the source happened to carry.
guard let cropped = source.cropping(to: CGRect(
  x: bounds.minX, y: bounds.minY, width: artWidth, height: artHeight
)) else {
  FileHandle.standardError.write(Data("error: could not crop the source\n".utf8))
  exit(1)
}

// MARK: - Rendering

func makeContext(size: Int) -> CGContext {
  guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { fatalError("could not create a bitmap context at \(size)px") }
  context.interpolationQuality = .high
  return context
}

/// The macOS icon grid: the plate covers 824 of 1024 units with a 185.4 corner
/// radius, leaving the margin the system expects around it.
func drawAppIcon(size: Int) -> CGImage {
  let context = makeContext(size: size)
  let canvas = CGFloat(size)
  let scale = canvas / 1024

  let plateInset = 100 * scale
  let plate = CGRect(
    x: plateInset, y: plateInset,
    width: canvas - plateInset * 2, height: canvas - plateInset * 2
  )
  let plateRadius = 185.4 * scale

  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: -6 * scale),
    blur: 16 * scale,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22)
  )
  context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  context.addPath(CGPath(
    roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil
  ))
  context.fillPath()
  context.restoreGState()

  // Inset the artwork inside the plate so it does not crowd the rounded corners.
  let padding = plate.width * 0.12
  let available = plate.insetBy(dx: padding, dy: padding)
  let fit = min(available.width / CGFloat(artWidth), available.height / CGFloat(artHeight))
  let drawn = CGSize(width: CGFloat(artWidth) * fit, height: CGFloat(artHeight) * fit)

  context.saveGState()
  context.addPath(CGPath(
    roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil
  ))
  context.clip()
  context.draw(cropped, in: CGRect(
    x: plate.midX - drawn.width / 2,
    y: plate.midY - drawn.height / 2,
    width: drawn.width, height: drawn.height
  ))
  context.restoreGState()

  guard let image = context.makeImage() else { fatalError("could not render \(size)px icon") }
  return image
}

/// The plant as a flat black shape with the core punched out.
///
/// Template images are tinted by macOS, so only alpha matters. The mask is
/// built at the source resolution and then scaled down, which keeps the edges
/// smooth — thresholding after scaling produces a ragged outline.
func makeSilhouetteMask() -> CGImage {
  let context = makeContext(size: max(artWidth, artHeight))
  let mask = Bitmap(cropped)

  var pixels = [UInt8](repeating: 0, count: artWidth * artHeight * 4)
  for y in 0 ..< artHeight {
    for x in 0 ..< artWidth {
      let index = (y * artWidth + x) * 4
      let opaque = mask.isArtwork(x: x, y: y) && !mask.isCore(x: x, y: y)
      // Premultiplied black: only the alpha channel carries anything.
      pixels[index + 3] = opaque ? 255 : 0
    }
  }

  guard let provider = CGDataProvider(data: Data(pixels) as CFData),
        let image = CGImage(
          width: artWidth, height: artHeight, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: artWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
          provider: provider, decode: nil, shouldInterpolate: true,
          intent: .defaultIntent
        )
  else { fatalError("could not build the silhouette mask") }

  _ = context
  return image
}

let silhouetteMask = makeSilhouetteMask()

func drawMenuBarIcon(size: Int) -> CGImage {
  let context = makeContext(size: size)
  let canvas = CGFloat(size)

  // No plate here, so the artwork gets nearly the whole canvas — inheriting the
  // app icon's margin would waste a third of the height at the one size where
  // every pixel counts.
  let margin = canvas * 0.04
  let available = canvas - margin * 2
  let fit = min(available / CGFloat(artWidth), available / CGFloat(artHeight))
  let drawn = CGSize(width: CGFloat(artWidth) * fit, height: CGFloat(artHeight) * fit)

  context.draw(silhouetteMask, in: CGRect(
    x: (canvas - drawn.width) / 2,
    y: (canvas - drawn.height) / 2,
    width: drawn.width, height: drawn.height
  ))

  guard let image = context.makeImage() else { fatalError("could not render menu bar icon") }
  return image
}

// MARK: - Symmetry

let mirrorTolerance = 32

/// Compares an image against its own horizontal mirror.
func mirrorMismatch(_ image: CGImage) -> (worst: Int, offending: Int) {
  let bitmap = Bitmap(image)
  var worst = 0
  var offending = 0
  for y in 0 ..< bitmap.height {
    for x in 0 ..< (bitmap.width / 2) {
      let left = bitmap.rgb(x: x, y: y)
      let right = bitmap.rgb(x: bitmap.width - 1 - x, y: y)
      for delta in [abs(left.r - right.r), abs(left.g - right.g),
                    abs(left.b - right.b), abs(left.a - right.a)] {
        if delta > worst { worst = delta }
        if delta > mirrorTolerance { offending += 1 }
      }
    }
  }
  return (worst, offending)
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

let assets = root.appendingPathComponent("Sources/PixelPilot/Resources/Assets.xcassets")
let appIconSet = assets.appendingPathComponent("AppIcon.appiconset")
let menuBarSet = assets.appendingPathComponent("MenuBarIcon.imageset")

for directory in [appIconSet, menuBarSet] {
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

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
  let images = entries.map {
    """
        {
          "filename" : "icon_\($0.size * $0.scale).png",
          "idiom" : "mac",
          "scale" : "\($0.scale)x",
          "size" : "\($0.size)x\($0.size)"
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

try appIconContents().write(
  to: appIconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
)
try """
{
  "images" : [
    { "filename" : "menubar.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menubar@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
""".write(to: menuBarSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try """
{
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("Wrote \(iconPixelSizes.count) app icon sizes and the menu bar template")

// Reported rather than enforced: any asymmetry now comes from the source
// drawing, and silently "fixing" someone's artwork is not this script's call.
let sourceCheck = mirrorMismatch(cropped)
let menuCheck = mirrorMismatch(drawMenuBarIcon(size: 36))
print("")
print("Symmetry (worst channel delta, pixels over tolerance \(mirrorTolerance)):")
print("  source art  \(sourceCheck.worst), \(sourceCheck.offending)")
print("  menu bar    \(menuCheck.worst), \(menuCheck.offending)")
