import CoreGraphics
import Foundation
import PixelPilotCore

// ppctl — the verification tool for the DDC layer.
//
// The app UI is built on top of PixelPilotCore, but the UI is a bad place to
// find out whether a panel actually speaks DDC. This CLI exercises the same code
// paths with nothing else in the way, so "does this monitor work" is answerable
// before a single view exists.
//
// Argument parsing is hand-rolled rather than pulled from swift-argument-parser:
// four subcommands do not justify a package dependency in a tool whose whole
// point is to have as little between it and the hardware as possible.

let usage = """
ppctl — DDC/CI diagnostics for Pixel Pilot

USAGE
  ppctl list                          List displays and their DDC status
  ppctl probe [options]               Probe which VCP features a display supports
  ppctl get <vcp> [options]           Read one VCP feature
  ppctl set <vcp> <value> [options]   Write one VCP feature
  ppctl audio [options]               Show which audio route a display resolves to
  ppctl capabilities [options]        Read the MCCS capability string (slow, one-off)
  ppctl gamma <fraction> [hold]       Apply software dimming (1.0 restores). 'hold'
                                      parks the process so recovery can be tested.
  ppctl gamma-check                   Read the display's gamma table back
  ppctl probe-edid [options]          Experimental IOAVServiceCopyEDID dump

OPTIONS
  -d, --display <n>   Index from `ppctl list` (default: first DDC-capable one)
  --relaxed           Use the slower timing profile for fussy panels
  -v, --verbose       Print the diagnostics log afterwards

VCP may be a name (brightness, contrast, volume, mute, input, power)
or a hex code such as 0x10.

NOTE
  Quit BetterDisplay and MonitorControl first. They drive the same I2C bus,
  and concurrent traffic produces failures that look like hardware faults.
"""

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor
func takeFlag(_ names: [String]) -> Bool {
  guard let index = arguments.firstIndex(where: { names.contains($0) }) else { return false }
  arguments.remove(at: index)
  return true
}

@MainActor
func takeOption(_ names: [String]) -> String? {
  guard let index = arguments.firstIndex(where: { names.contains($0) }),
        index + 1 < arguments.count
  else { return nil }
  let value = arguments[index + 1]
  arguments.removeSubrange(index ... (index + 1))
  return value
}

@MainActor
func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
  exit(1)
}

let verbose = takeFlag(["-v", "--verbose"])
let timing: DDCTiming = takeFlag(["--relaxed"]) ? .relaxed : .default
let displayIndexArgument = takeOption(["-d", "--display"]).flatMap(Int.init)

guard let command = arguments.first else {
  print(usage)
  exit(0)
}
arguments.removeFirst()

// MARK: - Shared setup

let log = DiagnosticsLog()
let displays = DisplayRegistry.discover(log: log)

@MainActor
func dumpLogIfVerbose() {
  guard verbose else { return }
  print("\n--- diagnostics ---")
  for record in log.snapshot() {
    print(String(format: "  %.3f  %@", record.timestamp.timeIntervalSince1970, record.entry.message))
  }
}

/// Resolves `--display`, defaulting to the first display that can actually do DDC.
@MainActor
func selectedDisplay() -> DiscoveredDisplay {
  if let index = displayIndexArgument {
    guard displays.indices.contains(index) else {
      fail("no display at index \(index); run `ppctl list`")
    }
    return displays[index]
  }
  guard let display = displays.first(where: \.supportsDDC) else {
    fail("no DDC-capable display found; run `ppctl list`")
  }
  return display
}

@MainActor
func selectedTransport() -> (DiscoveredDisplay, any DDCTransport) {
  let display = selectedDisplay()
  guard let transport = display.transport else {
    fail("display \(display.name) has no DDC path")
  }
  return (display, transport)
}

@MainActor
func parseVCP(_ text: String) -> VCPCode {
  switch text.lowercased() {
  case "brightness", "luminance": return .luminance
  case "contrast": return .contrast
  case "volume": return .audioSpeakerVolume
  case "mute": return .audioMute
  case "input": return .inputSource
  case "power", "standby": return .powerMode
  default: break
  }
  let cleaned = text.hasPrefix("0x") || text.hasPrefix("0X")
    ? String(text.dropFirst(2))
    : text
  guard let value = UInt8(cleaned, radix: 16) else {
    fail("could not read '\(text)' as a VCP name or hex code")
  }
  return VCPCode(rawValue: value)
}

// MARK: - Commands

switch command {
case "list":
  // Which private back ends resolved on this system. When DDC "mysteriously"
  // stops working after a macOS update, this is the first line to look at.
  print("DDC/CI (IOAVService):      \(Arm64DDCTransport.isSupported ? "available" : "UNAVAILABLE")")
  print("Native (DisplayServices):  \(NativeBrightness.isAvailable ? "available" : "UNAVAILABLE")")
  print("")

  guard !displays.isEmpty else {
    print("No displays found.")
    exit(0)
  }
  for (index, display) in displays.enumerated() {
    let kind = display.isBuiltin ? "built-in" : "external"
    let ddc = display.supportsDDC ? "DDC" : "no DDC"
    print("[\(index)] \(display.name)  (\(kind), \(ddc))")
    print("     key      \(display.key)")
    print(String(
      format: "     cg       id=%u vendor=%u model=%u serial=%u",
      display.displayID, display.vendorNumber, display.modelNumber, display.serialNumber
    ))
    if let attributes = display.attributes {
      var parts: [String] = []
      if let value = attributes.manufacturerID { parts.append("mfr=\(value)") }
      if let value = attributes.alphanumericSerialNumber, !value.isEmpty { parts.append("sn=\(value)") }
      if let week = attributes.weekOfManufacture, let year = attributes.yearOfManufacture {
        parts.append("made=\(year)-W\(week)")
      }
      if !parts.isEmpty { print("     panel    " + parts.joined(separator: "  ")) }
    }
  }
  dumpLogIfVerbose()

case "probe":
  let (display, transport) = selectedTransport()
  print("Probing \(display.name) …\n")

  let capabilities = DisplayCapabilities.probe(transport: transport, timing: timing, log: log)
  for vcp in VCPCode.probeSet {
    let verdict: String = switch capabilities.support(for: vcp) {
    case let .supported(current, maximum):
      String(format: "✓  %d / %d", Int(current), Int(maximum))
    case let .implausible(current, maximum, reason):
      String(format: "✗  %d / %d — %@", Int(current), Int(maximum), reason)
    case .unsupported:
      "✗  display declined the feature"
    case let .unreachable(detail):
      "✗  \(detail)"
    }
    print("  " + vcp.description.padding(toLength: 22, withPad: " ", startingAt: 0) + verdict)
  }

  let usable = VCPCode.probeSet.filter { capabilities.isUsable($0) }
  print("\n  \(usable.count) of \(VCPCode.probeSet.count) features usable.")
  dumpLogIfVerbose()

case "get":
  guard let vcpArgument = arguments.first else { fail("`get` needs a VCP code") }
  let (display, transport) = selectedTransport()
  let vcp = parseVCP(vcpArgument)
  do {
    let reading = try transport.read(vcp, timing: timing)
    print("\(display.name)  \(vcp): \(reading.current) / \(reading.maximum)")
  } catch {
    dumpLogIfVerbose()
    fail("\(error)")
  }
  dumpLogIfVerbose()

case "set":
  guard arguments.count >= 2 else { fail("`set` needs a VCP code and a value") }
  let vcp = parseVCP(arguments[0])
  guard let value = UInt16(arguments[1]) else { fail("'\(arguments[1])' is not a number") }
  let (display, transport) = selectedTransport()
  do {
    try transport.write(vcp, value: value, timing: timing)
    print("\(display.name)  \(vcp) ← \(value)")
  } catch {
    dumpLogIfVerbose()
    fail("\(error)")
  }
  dumpLogIfVerbose()

case "audio":
  let display = selectedDisplay()
  let capabilities = display.transport.map {
    DisplayCapabilities.probe(transport: $0, timing: timing, features: [.audioSpeakerVolume, .audioMute], log: log)
  }
  let controller = VolumeController(
    queue: display.transport.map { DDCQueue(transport: $0, timing: timing, log: log) },
    capabilities: capabilities,
    log: log
  )
  await controller.prime()

  let route = await controller.route
  print("\(display.name)")
  print("  route    \(route.displayName)")
  if route == .unavailable {
    print("           No controllable volume: the display's DDC audio is a stub and")
    print("           the default output device has no settable volume (fixed digital output).")
  } else {
    print("  volume   \(Int(await controller.volume() * 100))%")
    print("  muted    \(await controller.isMuted() ? "yes" : "no")")
  }
  dumpLogIfVerbose()

case "probe-edid":
  let (display, transport) = selectedTransport()
  guard let arm64Transport = transport as? Arm64DDCTransport else {
    fail("EDID probe needs the Apple Silicon transport")
  }
  print("Calling IOAVServiceCopyEDID on \(display.name) — this signature is a guess.\n")
  guard let bytes = arm64Transport.experimentalCopyEDID() else {
    fail("IOAVServiceCopyEDID returned nothing")
  }
  for offset in stride(from: 0, to: bytes.count, by: 16) {
    let chunk = bytes[offset ..< min(offset + 16, bytes.count)]
    let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
    print(String(format: "  %04X  %@", offset, hex))
  }
  if let edid = try? EDID(bytes: bytes, strictChecksum: false) {
    print("\n  parsed: \(edid.manufacturerCode) \(edid.displayName ?? "—") "
      + "product=\(edid.productCode) serial=\(edid.serialNumber) year=\(edid.manufactureYear)")
  }
  dumpLogIfVerbose()

case "capabilities", "caps":
  let (display, transport) = selectedTransport()
  guard let arm64 = transport as? Arm64DDCTransport else {
    fail("capability reading needs the Apple Silicon transport")
  }
  print("Reading the capability string from \(display.name) — this takes a moment …\n")

  let raw: String
  do {
    raw = try arm64.readCapabilities(timing: timing)
  } catch {
    dumpLogIfVerbose()
    fail("\(error)")
  }

  print("RAW (\(raw.utf8.count) bytes)\n  \(raw)\n")
  let unprintable = Array(raw.utf8).enumerated().filter { $0.element < 0x20 || $0.element > 0x7E }
  if !unprintable.isEmpty {
    let described = unprintable.prefix(8)
      .map { String(format: "@%d=0x%02X", $0.offset, $0.element) }
      .joined(separator: " ")
    print("  non-printable bytes: \(described)\n")
  }

  let parsed = CapabilityString(raw: raw)
  if let model = parsed.model { print("  model      \(model)") }
  if let type = parsed.type { print("  type       \(type)") }
  if let version = parsed.mccsVersion { print("  mccs       \(version)") }
  print("  features   \(parsed.features.count) listed")

  if let inputs = parsed.values(for: .inputSource), !inputs.isEmpty {
    print("\nINPUT SOURCES (0x60)")
    for value in inputs.sorted() {
      let marker = InputSource.isStandard(value) ? " " : " (non-standard code)"
      print(String(format: "  0x%02X  %@%@", value, InputSource.name(for: value), marker))
    }
  } else {
    print("\n  No enumerated input sources — switching stays disabled.")
  }

  if let powerStates = parsed.values(for: .powerMode), !powerStates.isEmpty {
    print("\nPOWER MODES (0xD6)")
    for value in powerStates.sorted() {
      let name = PowerMode(rawValue: value)?.displayName ?? "unknown"
      print(String(format: "  0x%02X  %@", value, name))
    }
  }
  dumpLogIfVerbose()

case "gamma":
  // Deliberately a separate command from anything the app uses: this exists to
  // answer one question that cannot be answered by reading code — does the
  // display come back if the process dies without running any cleanup?
  let display = selectedDisplay()
  let fraction = Double(arguments.first ?? "") ?? 0.85

  if fraction >= 1.0 {
    GammaDimmer.shared.clearAll()
    print("Gamma restored on all displays.")
  } else {
    GammaDimmer.shared.setDimming(fraction, for: display.displayID)
    print("\(display.name): gamma set to \(Int(fraction * 100))%.")
    if arguments.count > 1, arguments[1] == "hold" {
      print("Holding (pid \(ProcessInfo.processInfo.processIdentifier)). "
        + "Kill this process to test recovery.")
      // Park forever without spinning, so the process can be killed in a
      // defined state.
      dispatchMain()
    }
  }

case "gamma-check":
  // Reads the table back rather than trusting that a write took effect.
  let display = selectedDisplay()
  var red = [CGGammaValue](repeating: 0, count: 256)
  var green = red
  var blue = red
  var count: UInt32 = 0
  let result = CGGetDisplayTransferByTable(
    display.displayID, 256, &red, &green, &blue, &count
  )
  guard result == .success, count > 0 else {
    fail("could not read the gamma table (CGError \(result.rawValue))")
  }
  let peak = Double(red[Int(count) - 1])
  print("\(display.name): \(count) entries, peak \(String(format: "%.4f", peak))")
  print(peak >= 0.999 ? "  identity — no dimming applied" : "  DIMMED to \(Int(peak * 100))%")

case "-h", "--help", "help":
  print(usage)

default:
  fail("unknown command '\(command)'\n\n\(usage)")
}
