import AppKit
import CoreGraphics
import ImageIO
import Observation

/// Caches downsampled (`maxPixelSize: 360`) macOS desktop wallpaper thumbnails per display
/// so `StudioWallpaperCanvas` reflects the user's real wallpaper with `0.0% idle CPU`.
///
/// Cache entries are populated lazily on demand and cleared strictly on event-driven
/// workspace/display notifications — never via background timers or polling.
@MainActor
@Observable
final class WallpaperCache {
  static let shared = WallpaperCache()

  /// Incremented when active Space or screen parameters change so observing views refresh once.
  private(set) var revision = 0

  @ObservationIgnored private var cache: [CGDirectDisplayID: NSImage] = [:]
  @ObservationIgnored private var unavailable: Set<CGDirectDisplayID> = []
  @ObservationIgnored private var tokens: [any NSObjectProtocol] = []

  private init() {
    let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.invalidate()
      }
    }
    let screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.invalidate()
      }
    }
    tokens = [spaceObserver, screenObserver]
  }

  /// Drops cached thumbnails so the next view pass loads fresh thumbnails once.
  func invalidate() {
    cache.removeAll()
    unavailable.removeAll()
    revision &+= 1
  }

  /// Returns a downsampled (`<= 360 px`) wallpaper thumbnail for `displayID`, or `nil`
  /// when unavailable/unreadable so callers seamlessly fall back to the Warm Studio gradient.
  func thumbnail(for displayID: CGDirectDisplayID) -> NSImage? {
    _ = revision
    if let cached = cache[displayID] { return cached }
    if unavailable.contains(displayID) { return nil }

    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }),
          let rawURL = NSWorkspace.shared.desktopImageURL(for: screen),
          let imageURL = Self.resolvableImageURL(from: rawURL),
          let thumbnail = Self.loadDownsampledThumbnail(from: imageURL, maxPixelSize: 360)
    else {
      unavailable.insert(displayID)
      return nil
    }

    cache[displayID] = thumbnail
    return thumbnail
  }

  private static func resolvableImageURL(from url: URL) -> URL? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return nil
    }
    if !isDirectory.boolValue {
      return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }
    let allowedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "webp"]
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }
    return children.first {
      allowedExtensions.contains($0.pathExtension.lowercased())
        && FileManager.default.isReadableFile(atPath: $0.path)
    }
  }

  private static func loadDownsampledThumbnail(from url: URL, maxPixelSize: Int) -> NSImage? {
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
      return nil
    }
    let thumbOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }
}
