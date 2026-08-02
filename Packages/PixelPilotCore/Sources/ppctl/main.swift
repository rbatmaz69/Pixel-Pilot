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
  ppctl audio-devices                 List output devices and their volume properties
  ppctl capabilities [options]        Read the MCCS capability string (slow, one-off)
  ppctl scan [--alt] [options]        Read all 256 VCP registers and classify them.
                                      --alt also scans I2C address 0x50.
  ppctl try <vcp> [options]           Write-probe one register, restoring its value
  ppctl gamma <fraction> [hold]       Apply software dimming (1.0 restores). 'hold'
                                      parks the process so recovery can be tested.
  ppctl gamma-check                   Read the display's gamma table back
  ppctl probe-edid [options]          Experimental IOAVServiceCopyEDID dump
  ppctl watch-brightness [--poll]     Print every native brightness change on the
                                      built-in panel. Answers whether the ambient
                                      light sensor is observable; --poll asks on a
                                      one-second timer instead, as the control.

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

/// One value shared with a timer handler.
///
/// `Mutex` would say this better, but the package's deployment target is lower
/// than the app's and a tool that measures hardware is the wrong place to raise
/// it.
final class Box: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Double

  init(_ value: Double) { self.value = value }

  /// Stores `newValue` and reports whether it was actually different, so the
  /// caller only prints real movement.
  func exchangeIfChanged(to newValue: Double) -> Bool {
    lock.withLock {
      guard abs(value - newValue) > 0.0001 else { return false }
      value = newValue
      return true
    }
  }
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

case "audio-devices":
  // Enumerates every output device and every volume-ish property on it.
  // Written because "the volume is not settable" is a claim worth checking
  // properly before telling someone their monitor cannot do something.
  for device in SystemVolume.outputDevices() {
    let marker = device.isDefault ? " (default output)" : ""
    print("\(device.name)\(marker)")
    print("  uid          \(device.uid)")
    print("  transport    \(device.transportType)")
    print("  channels     \(device.outputChannelCount)")

    for probe in device.volumeProbes {
      let state: String
      switch (probe.exists, probe.isSettable, probe.value) {
      case (false, _, _): state = "absent"
      case (true, false, let value?): state = String(format: "read-only (%.3f)", value)
      case (true, false, nil): state = "read-only, unreadable"
      case (true, true, let value?): state = String(format: "SETTABLE (%.3f)", value)
      case (true, true, nil): state = "SETTABLE, unreadable"
      }
      print("  \(probe.label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(state)")
    }
    print("")
  }

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

case "scan":
  let (display, transport) = selectedTransport()

  // Cross-reference against what the display admits to, so undeclared live
  // registers stand out — those are the ones worth looking at.
  var declared: Set<UInt8> = []
  if let arm64 = transport as? Arm64DDCTransport,
     let raw = try? arm64.readCapabilities(timing: timing) {
    declared = Set(CapabilityString(raw: raw).features.keys)
    print("Capability string declares \(declared.count) features.\n")
  } else {
    print("No capability string — everything will show as undeclared.\n")
  }

  let addresses: [UInt8] = arguments.contains("--alt") ? [0x51, 0x50] : [0x51]

  for address in addresses {
    print("Scanning 256 registers on data address 0x\(String(address, radix: 16)) …")
    let results = VCPScanner.scan(
      transport: transport, dataAddress: address, declared: declared
    ) { done, total in
      if done % 32 == 0 || done == total {
        FileHandle.standardError.write(Data("  \(done)/\(total)\r".utf8))
      }
    }
    FileHandle.standardError.write(Data("\n".utf8))

    let live = results.filter(\.classification.isLive)
    let phantom = results.filter {
      if case .phantom = $0.classification { return true }
      return false
    }

    print("\n  \(live.count) live, \(phantom.count) answered but unusable, "
      + "\(results.count - live.count - phantom.count) absent\n")

    for result in live {
      guard case let .live(current, maximum) = result.classification else { continue }
      let mark = result.isDeclared ? " " : "★"
      let name = VCPCode(rawValue: result.code).standardName ?? "unknown"
      print(String(
        format: "  %@ 0x%02X  %-34@ %5d / %-5d",
        mark, result.code, name as NSString, Int(current), Int(maximum)
      ))
    }

    // Every audio feature MCCS defines, and what this display does with it —
    // the question the scan exists to answer.
    let audioVerdicts = results.filter { VCPScanner.audioCodes.contains($0.code) }
    print("\n  MCCS audio group:")
    for verdict in audioVerdicts.sorted(by: { $0.code < $1.code }) {
      let name = VCPCode(rawValue: verdict.code).standardName ?? "unknown"
      let state: String = switch verdict.classification {
      case let .live(current, maximum): "live \(current)/\(maximum)"
      case let .phantom(_, _, reason): "phantom — \(reason)"
      case let .absent(reason): "absent — \(reason)"
      }
      print(String(format: "    0x%02X  %-30@ %@", verdict.code, name as NSString, state))
    }

    let undeclared = live.filter { !$0.isDeclared }
    if undeclared.isEmpty {
      print("\n  ★ none — the display answers nothing it did not declare.")
    } else {
      print("\n  ★ marks \(undeclared.count) register(s) the display did not declare.")
    }

    let candidates = VCPScanner.audioCandidates(in: results)
    if !candidates.isEmpty {
      print("\n  Audio candidates worth a write test:")
      for candidate in candidates {
        guard case let .live(current, maximum) = candidate.classification else { continue }
        print(String(format: "    0x%02X  %@  (%d / %d)",
                     candidate.code, candidate.name, Int(current), Int(maximum)))
      }
      print("\n  Test one with:  ppctl try 0x<code>")
    } else {
      print("\n  No audio candidates.")
    }
  }
  _ = display
  dumpLogIfVerbose()

case "try":
  guard let codeArgument = arguments.first else { fail("`try` needs a VCP code") }
  let vcp = parseVCP(codeArgument)
  let (display, transport) = selectedTransport()

  guard !WriteProbe.forbidden.contains(vcp.rawValue) else {
    fail("\(vcp) is on the forbidden list — writing it could reset the display "
      + "or take away the picture")
  }

  print("Probing \(vcp) on \(display.name) — the original value is restored afterwards.\n")
  switch WriteProbe.probe(vcp, transport: transport, timing: timing, log: log) {
  case let .accepted(wrote, maximum):
    print("  ACCEPTED — wrote \(wrote) and read it back (max \(maximum))")
    print("  This register is real. Now check whether anything is connected to it:")
    print("  play audio and run `ppctl set 0x\(String(vcp.rawValue, radix: 16)) <value>`.")
    print("  A register can store values and drive nothing.")
  case let .rejected(wrote, readBack):
    print("  REJECTED — wrote \(wrote), read back \(readBack)")
  case let .unreadable(detail):
    print("  UNREADABLE — \(detail)")
  case .forbiddenCode:
    print("  refused")
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

case "watch-brightness":
  // The question this answers cannot be answered by reading code, or by reading
  // Apple's headers, because there are none: does
  // `DisplayServicesRegisterForBrightnessChangeNotifications` fire when the
  // *ambient light sensor* moves the panel, or only when a person does?
  //
  // Everything built on top of it — a display following the built-in one —
  // depends on the answer, so it gets a command of its own before it gets a
  // toggle in a window. `--poll` asks on a timer instead, as the control group:
  // if the poll sees a change the callback did not, the callback is not enough.
  let usePoll = takeFlag(["--poll"])

  let target: DiscoveredDisplay
  if let index = displayIndexArgument {
    guard displays.indices.contains(index) else {
      fail("no display at index \(index); run `ppctl list`")
    }
    target = displays[index]
  } else if let builtin = displays.first(where: \.isBuiltin) {
    target = builtin
  } else {
    fail("no built-in display found; pass -d <index> to watch another one")
  }

  print("Watching \(target.name) (display \(target.displayID))")
  print("  native brightness available: \(NativeBrightness.isAvailable)")
  print("  drivable natively:           \(NativeBrightness.isSupported(target.displayID))")
  print("  notifications available:     \(NativeBrightness.canObserve)")
  guard let start = NativeBrightness.get(target.displayID) else {
    fail("could not read brightness for \(target.name)")
  }
  print(String(format: "  starting at:                 %.4f", start))
  print("")
  print("Press the brightness keys, then cover the light sensor and wait.")
  print("Ctrl-C to stop.")
  print("")

  let began = Date()
  @Sendable func report(_ source: String, _ value: Double) {
    print(String(format: "%8.2fs  %@  %.4f  (%3d%%)",
                 Date().timeIntervalSince(began), source, value, Int((value * 100).rounded())))
  }

  if usePoll {
    // One second, and only in this command. Nothing in the app polls at this
    // rate; this is a measuring instrument, not a design.
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    let lastPolled = Box(start)
    timer.setEventHandler {
      guard let value = NativeBrightness.get(target.displayID) else { return }
      guard lastPolled.exchangeIfChanged(to: value) else { return }
      report("poll  ", value)
    }
    timer.resume()
    dispatchMain()
  }

  guard NativeBrightness.observe(target.displayID, handler: { report("notify", $0) }) else {
    fail("could not register for brightness notifications; try --poll")
  }
  dispatchMain()

case "-h", "--help", "help":
  print(usage)

default:
  fail("unknown command '\(command)'\n\n\(usage)")
}
