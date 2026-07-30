import Foundation

/// A parsed MCCS capability string.
///
/// This is the only reliable way to learn which *values* a feature accepts.
/// Reading a feature tells you its current value and a maximum, and for
/// enumerated features like input source that maximum is meaningless — the
/// Samsung U32T1 this was developed against reports a maximum of 14 while
/// DisplayPort is 15 under MCCS. Guessing from the maximum would mean writing
/// values that switch the monitor to a dead input.
///
/// A real string looks like:
///
/// ```
/// (prot(monitor)type(lcd)model(U32T1)cmds(01 02 03 07 0C E3 F3)
///  vcp(02 04 10 12 14(01 05 08) 60(0F 11 12) D6(01 04 05))mccs_ver(2.1))
/// ```
public struct CapabilityString: Sendable, Equatable {
  /// Exactly what the display sent, kept for the diagnostics view. Panels emit
  /// malformed strings often enough that the raw text is frequently the only
  /// way to work out what went wrong.
  public let raw: String

  public let model: String?
  public let type: String?
  public let mccsVersion: String?

  /// VCP code to the values it accepts. An empty array means the feature was
  /// listed but takes a continuous range rather than an enumeration — which is
  /// the normal case for brightness and contrast.
  public let features: [UInt8: [UInt8]]

  public init(raw: String) {
    self.raw = raw
    let sections = Self.topLevelSections(in: raw)
    self.model = sections["model"]?.trimmingCharacters(in: .whitespaces)
    self.type = sections["type"]?.trimmingCharacters(in: .whitespaces)
    self.mccsVersion = sections["mccs_ver"]?.trimmingCharacters(in: .whitespaces)
    self.features = sections["vcp"].map(Self.parseFeatures) ?? [:]
  }

  public func values(for vcp: VCPCode) -> [UInt8]? {
    features[vcp.rawValue]
  }

  public var isUsable: Bool { !features.isEmpty }

  // MARK: - Parsing

  /// Splits `name(body)` pairs at the outermost level.
  ///
  /// Written as a scanner rather than a regular expression because the bodies
  /// nest — `vcp(... 60(0F 11) ...)` — and a regex that matches balanced
  /// parentheses is worse to read than the loop.
  private static func topLevelSections(in text: String) -> [String: String] {
    // Control characters first. Displays pad the string with a trailing NUL,
    // and that single byte is enough to make the closing parenthesis no longer
    // the last character — at which point the outer layer is not stripped, the
    // whole string is read as one unnamed group, and every section vanishes.
    let sanitized = text.filter { character in
      guard let ascii = character.asciiValue else { return true }
      return ascii >= 0x20 && ascii < 0x7F
    }

    var characters = Array(sanitized.trimmingCharacters(in: .whitespacesAndNewlines))
    if characters.first == "(", characters.last == ")" {
      characters = Array(characters.dropFirst().dropLast())
    }

    var sections: [String: String] = [:]
    var name = ""
    var index = 0

    while index < characters.count {
      let character = characters[index]

      if character == "(" {
        var depth = 1
        var body = ""
        index += 1
        while index < characters.count, depth > 0 {
          let inner = characters[index]
          if inner == "(" { depth += 1 }
          if inner == ")" {
            depth -= 1
            if depth == 0 { break }
          }
          body.append(inner)
          index += 1
        }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty {
          sections[key] = body
        }
        name = ""
      } else if character == ")" {
        name = ""
      } else {
        name.append(character)
      }
      index += 1
    }

    return sections
  }

  /// Parses the body of `vcp(...)`: hex codes, each optionally followed by a
  /// parenthesised list of permitted values.
  private static func parseFeatures(_ body: String) -> [UInt8: [UInt8]] {
    var features: [UInt8: [UInt8]] = [:]
    var token = ""
    var index = body.startIndex

    func commitToken(values: [UInt8]) {
      defer { token = "" }
      let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let code = UInt8(trimmed, radix: 16) else { return }
      features[code] = values
    }

    while index < body.endIndex {
      let character = body[index]

      switch character {
      case "(":
        // The values belong to the code we just finished reading.
        var depth = 1
        var inner = ""
        index = body.index(after: index)
        while index < body.endIndex, depth > 0 {
          let value = body[index]
          if value == "(" { depth += 1 }
          if value == ")" {
            depth -= 1
            if depth == 0 { break }
          }
          inner.append(value)
          index = body.index(after: index)
        }
        commitToken(values: parseHexList(inner))

      case " ", "\t", "\n", "\r":
        commitToken(values: [])

      default:
        token.append(character)
      }

      if index < body.endIndex {
        index = body.index(after: index)
      }
    }
    commitToken(values: [])

    return features
  }

  private static func parseHexList(_ text: String) -> [UInt8] {
    text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
      .compactMap { UInt8($0, radix: 16) }
  }
}

// MARK: - Input sources

/// MCCS input source codes (VCP 0x60).
///
/// Only used to *label* values the display actually reported. Nothing here is
/// ever offered as a target unless the capability string listed it: a code that
/// looks plausible but is not implemented switches the monitor to an input with
/// no signal, and since the DDC channel rides on the video link, there is no way
/// back except the monitor's own buttons.
public enum InputSource {
  private static let names: [UInt8: String] = [
    0x01: "VGA 1", 0x02: "VGA 2",
    0x03: "DVI 1", 0x04: "DVI 2",
    0x05: "Composite 1", 0x06: "Composite 2",
    0x07: "S-Video 1", 0x08: "S-Video 2",
    0x09: "Tuner 1", 0x0A: "Tuner 2", 0x0B: "Tuner 3",
    0x0C: "Component 1", 0x0D: "Component 2", 0x0E: "Component 3",
    0x0F: "DisplayPort 1", 0x10: "DisplayPort 2",
    0x11: "HDMI 1", 0x12: "HDMI 2",
    0x1B: "USB-C",
  ]

  /// A display name for a code. Vendors deviate from MCCS freely, so an unknown
  /// code is shown as its hex value rather than guessed at.
  public static func name(for value: UInt8) -> String {
    names[value] ?? String(format: "Input 0x%02X", value)
  }

  /// True when the code has a standard meaning. The UI uses this to mark a
  /// label as a guess rather than a fact.
  public static func isStandard(_ value: UInt8) -> Bool {
    names[value] != nil
  }
}

/// Power states for VCP 0xD6.
public enum PowerMode: UInt8, Sendable, CaseIterable {
  case on = 1
  case standby = 2
  case suspend = 3
  case off = 4
  case powerOff = 5

  public var displayName: String {
    switch self {
    case .on: "On"
    case .standby: "Standby"
    case .suspend: "Suspend"
    case .off: "Off (DPMS)"
    case .powerOff: "Hard off"
    }
  }
}
