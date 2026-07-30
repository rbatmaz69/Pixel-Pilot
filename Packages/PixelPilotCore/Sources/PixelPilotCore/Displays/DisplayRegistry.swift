import CoreGraphics
import Foundation
import IOKit

/// The identifying block macOS keeps for a panel, read from the IORegistry
/// framebuffer node rather than from a raw EDID.
///
/// This is the production identification path. It is preferred over parsing an
/// EDID because macOS has already done the decoding, normalised the vendor code
/// and — importantly — it works on panels whose EDID we cannot read at all.
public struct ProductAttributes: Sendable, Equatable {
  public var productName: String?
  public var manufacturerID: String?
  public var alphanumericSerialNumber: String?
  public var legacyManufacturerID: UInt32?
  public var productID: UInt32?
  public var serialNumber: UInt32?
  public var yearOfManufacture: Int?
  public var weekOfManufacture: Int?

  init(dictionary: [String: Any]) {
    self.productName = dictionary["ProductName"] as? String
    self.manufacturerID = dictionary["ManufacturerID"] as? String
    self.alphanumericSerialNumber = dictionary["AlphanumericSerialNumber"] as? String
    self.legacyManufacturerID = (dictionary["LegacyManufacturerID"] as? NSNumber)?.uint32Value
    self.productID = (dictionary["ProductID"] as? NSNumber)?.uint32Value
    self.serialNumber = (dictionary["SerialNumber"] as? NSNumber)?.uint32Value
    self.yearOfManufacture = (dictionary["YearOfManufacture"] as? NSNumber)?.intValue
    self.weekOfManufacture = (dictionary["WeekOfManufacture"] as? NSNumber)?.intValue
  }
}

/// A display macOS knows about, paired with a DDC path when one exists.
public struct DiscoveredDisplay: Sendable {
  public let displayID: CGDirectDisplayID
  public let key: DisplayKey
  public let name: String
  public let isBuiltin: Bool
  public let vendorNumber: UInt32
  public let modelNumber: UInt32
  public let serialNumber: UInt32
  public let attributes: ProductAttributes?
  /// nil when this panel has no reachable I2C path — internal displays, and
  /// external ones behind an adapter that does not pass DDC through.
  public let transport: (any DDCTransport)?

  public var supportsDDC: Bool { transport != nil }

  /// Public so tests can stand up a display set without hardware. The real
  /// path builds these in `DisplayRegistry.discover`.
  public init(
    displayID: CGDirectDisplayID,
    key: DisplayKey,
    name: String,
    isBuiltin: Bool,
    vendorNumber: UInt32 = 0,
    modelNumber: UInt32 = 0,
    serialNumber: UInt32 = 0,
    attributes: ProductAttributes? = nil,
    transport: (any DDCTransport)? = nil
  ) {
    self.displayID = displayID
    self.key = key
    self.name = name
    self.isBuiltin = isBuiltin
    self.vendorNumber = vendorNumber
    self.modelNumber = modelNumber
    self.serialNumber = serialNumber
    self.attributes = attributes
    self.transport = transport
  }
}

/// Where the list of displays comes from.
///
/// A seam, so the reconnect and disappearance paths can be exercised without
/// physically unplugging a monitor. Those paths are hard to reach by hand and
/// easy to get wrong: a `CGDirectDisplayID` is reassigned across
/// reconfigurations, so "the same display" only means anything via `DisplayKey`.
public protocol DisplayDiscovering: Sendable {
  func discoverDisplays(log: DiagnosticsLog?) -> [DiscoveredDisplay]
}

/// The real one.
public struct SystemDisplayDiscovery: DisplayDiscovering {
  public init() {}

  public func discoverDisplays(log: DiagnosticsLog?) -> [DiscoveredDisplay] {
    DisplayRegistry.discover(log: log)
  }
}

/// Enumerates displays and wires each one up to its DDC transport.
public enum DisplayRegistry {
  /// A `DCPAVServiceProxy` node plus the framebuffer attributes it belongs to.
  private struct Candidate {
    let ioService: io_service_t
    let attributes: ProductAttributes?
  }

  /// Registry node names that carry `DisplayAttributes`.
  ///
  /// `AppleCLCD2` is what older macOS releases used; macOS 26 on Apple Silicon
  /// exposes `IOMobileFramebufferShim` instead. Both are matched so the code
  /// does not quietly stop finding displays on either side of that change.
  private static let framebufferNodeNames: Set<String> = [
    "IOMobileFramebufferShim", "AppleCLCD2",
  ]
  private static let avServiceNodeName = "DCPAVServiceProxy"

  public static func discover(log: DiagnosticsLog? = nil) -> [DiscoveredDisplay] {
    let displays = onlineDisplays()
    let candidates = externalAVServiceCandidates(log: log)
    defer { candidates.forEach { IOObjectRelease($0.ioService) } }

    log?.record(.info("Found \(displays.count) online display(s), \(candidates.count) external AV service(s)"))

    var claimed = Set<Int>()
    var results: [DiscoveredDisplay] = []

    for display in displays {
      var transport: (any DDCTransport)?
      var attributes: ProductAttributes?

      if !display.isBuiltin,
         let index = bestCandidateIndex(for: display, in: candidates, excluding: claimed) {
        claimed.insert(index)
        attributes = candidates[index].attributes
        transport = Arm64DDCTransport(ioService: candidates[index].ioService, log: log)
        if transport == nil {
          log?.record(.warning("Could not open IOAVService for display \(display.displayID)"))
        }
      }

      let name = attributes?.productName
        ?? (display.isBuiltin ? "Built-in Display" : "Display \(display.displayID)")

      results.append(
        DiscoveredDisplay(
          displayID: display.displayID,
          key: DisplayKey(
            vendor: display.vendorNumber,
            model: display.modelNumber,
            serial: display.serialNumber,
            isBuiltin: display.isBuiltin
          ),
          name: name,
          isBuiltin: display.isBuiltin,
          vendorNumber: display.vendorNumber,
          modelNumber: display.modelNumber,
          serialNumber: display.serialNumber,
          attributes: attributes,
          transport: transport
        )
      )
    }

    return results
  }

  // MARK: - CoreGraphics side

  private struct OnlineDisplay {
    let displayID: CGDirectDisplayID
    let isBuiltin: Bool
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
  }

  private static func onlineDisplays() -> [OnlineDisplay] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

    return ids.prefix(Int(count)).map { id in
      OnlineDisplay(
        displayID: id,
        isBuiltin: CGDisplayIsBuiltin(id) != 0,
        vendorNumber: CGDisplayVendorNumber(id),
        modelNumber: CGDisplayModelNumber(id),
        serialNumber: CGDisplaySerialNumber(id)
      )
    }
  }

  // MARK: - IORegistry side

  /// Walks the IOService plane depth-first, pairing each external
  /// `DCPAVServiceProxy` with the framebuffer node that most recently preceded
  /// it.
  ///
  /// The proxy is not a direct child of the framebuffer node — both hang off the
  /// same DCP subtree — so proximity in traversal order is what links them. This
  /// is the same association the established implementations rely on, and it
  /// holds because the DCP publishes one service subtree per connected panel.
  private static func externalAVServiceCandidates(log: DiagnosticsLog?) -> [Candidate] {
    guard Arm64DDCTransport.isSupported else {
      log?.record(.warning("IOAVService entry points unavailable — DDC disabled, gamma dimming only"))
      return []
    }

    var iterator = io_iterator_t()
    guard IORegistryCreateIterator(
      kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
    ) == KERN_SUCCESS else {
      log?.record(.failure("Could not create IORegistry iterator"))
      return []
    }
    defer { IOObjectRelease(iterator) }

    var candidates: [Candidate] = []
    var currentAttributes: ProductAttributes?

    while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
      // IORegistryEntryGetName writes into an io_name_t, which is char[128].
      var nameBuffer = [CChar](repeating: 0, count: 128)
      guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS else {
        IOObjectRelease(entry)
        continue
      }
      let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self)

      if framebufferNodeNames.contains(name) {
        currentAttributes = productAttributes(of: entry)
        IOObjectRelease(entry)
        continue
      }

      guard name == avServiceNodeName else {
        IOObjectRelease(entry)
        continue
      }

      let location = property(of: entry, key: "Location") as? String
      guard location == "External" else {
        // "Embedded" is the internal panel; it has no DDC to speak of.
        IOObjectRelease(entry)
        continue
      }

      // Ownership of `entry` transfers to the candidate; released by the caller.
      candidates.append(Candidate(ioService: entry, attributes: currentAttributes))
    }

    return candidates
  }

  private static func productAttributes(of entry: io_service_t) -> ProductAttributes? {
    guard let displayAttributes = property(of: entry, key: "DisplayAttributes") as? [String: Any],
          let product = displayAttributes["ProductAttributes"] as? [String: Any]
    else { return nil }
    return ProductAttributes(dictionary: product)
  }

  private static func property(of entry: io_service_t, key: String) -> Any? {
    guard let value = IORegistryEntryCreateCFProperty(
      entry, key as CFString, kCFAllocatorDefault, 0
    ) else { return nil }
    return value.takeRetainedValue()
  }

  // MARK: - Matching

  /// Scores each unclaimed candidate against a display and returns the best, or
  /// nil if nothing is even plausible.
  ///
  /// With a single external monitor this is trivially correct. The scoring
  /// exists for the multi-monitor case, where identical panels are common and
  /// traversal order alone is not enough to tell them apart.
  private static func bestCandidateIndex(
    for display: OnlineDisplay,
    in candidates: [Candidate],
    excluding claimed: Set<Int>
  ) -> Int? {
    var best: (index: Int, score: Int)?

    for (index, candidate) in candidates.enumerated() where !claimed.contains(index) {
      var score = 0
      if let attributes = candidate.attributes {
        if attributes.legacyManufacturerID == display.vendorNumber { score += 4 }
        if attributes.productID == display.modelNumber { score += 4 }
        if attributes.serialNumber == display.serialNumber { score += 2 }
      }
      // An attribute-less candidate still beats no candidate at all: a display
      // whose framebuffer node reports nothing may well still answer DDC.
      if best == nil || score > best!.score {
        best = (index, score)
      }
    }

    return best?.index
  }
}
