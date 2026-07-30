import PixelPilotCore
import SwiftUI

/// Input switching and power control.
///
/// Main window only, both behind a confirmation, and neither reachable from a
/// keyboard shortcut. Both actions end with the Mac no longer showing anything
/// on this display, and both are recovered the same way — by walking over to the
/// monitor. That asymmetry between how easy they are to trigger and how annoying
/// they are to undo is the whole reason for the placement.
struct InputAndPowerSection: View {
  @Bindable var display: DisplayViewModel

  @State private var pendingInput: UInt8?
  @State private var pendingPowerMode: PowerMode?

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        inputs
        if !display.availablePowerModes.isEmpty {
          Divider()
          power
        }
      }
      .padding(6)
    } label: {
      Label("Input and power", systemImage: "cable.connector")
    }
    .confirmationDialog(
      pendingInput.map { "Switch to \(InputSource.name(for: $0))?" } ?? "",
      isPresented: Binding(get: { pendingInput != nil }, set: { if !$0 { pendingInput = nil } }),
      titleVisibility: .visible
    ) {
      Button("Switch input", role: .destructive) {
        if let value = pendingInput { display.switchInput(to: value) }
        pendingInput = nil
      }
      Button("Cancel", role: .cancel) { pendingInput = nil }
    } message: {
      Text(switchInputWarning)
    }
    .confirmationDialog(
      pendingPowerMode.map { "Set \(display.name) to \($0.displayName)?" } ?? "",
      isPresented: Binding(
        get: { pendingPowerMode != nil }, set: { if !$0 { pendingPowerMode = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Turn off display", role: .destructive) {
        if let mode = pendingPowerMode { display.setPowerMode(mode) }
        pendingPowerMode = nil
      }
      Button("Cancel", role: .cancel) { pendingPowerMode = nil }
    } message: {
      Text("Wake it again by moving the mouse or pressing the monitor's power button. "
        + "The Mac itself stays awake.")
    }
  }

  /// The confirmation text, which has to be sharper when the current input is
  /// unlisted — "you can switch back with the monitor's buttons" is misleading
  /// when the input you are on does not appear in the list at all.
  private var switchInputWarning: String {
    let base = "This Mac will stop appearing on \(display.name). Pixel Pilot talks to the "
      + "display over the video connection, so it cannot switch back."
    if display.currentInputIsUnlisted {
      return base + " Your current connection is not even among the inputs this display "
        + "lists, so there is no entry here to return to — only the monitor's own buttons."
    }
    return base + " You will need the monitor's own buttons."
  }

  // MARK: - Inputs

  @ViewBuilder
  private var inputs: some View {
    if display.availableInputs.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Input switching")
          .font(.callout.weight(.medium))
        Text(display.isReadingCapabilityString
          ? "Reading the display's capability list…"
          : "Pixel Pilot only offers inputs the display lists itself. Reading that list "
            + "takes a few seconds and is done once.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          Task { await display.readCapabilityString() }
        } label: {
          if display.isReadingCapabilityString {
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("Reading…")
            }
          } else {
            Text("Read available inputs")
          }
        }
        .disabled(display.isReadingCapabilityString)
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Input")
            .font(.callout.weight(.medium))
          Spacer()
          Text(currentInputDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // A row of buttons rather than a picker: a picker implies the selection
        // reflects reality, and here we usually cannot tell which input is live.
        HStack(spacing: 8) {
          ForEach(display.availableInputs, id: \.self) { value in
            Button(InputSource.name(for: value)) {
              pendingInput = value
            }
            .disabled(value == display.currentInput)
          }
        }

        unlistedInputWarning
      }
    }
  }

  /// Says "unknown" rather than pointing at the wrong entry.
  ///
  /// This display reports input 0x07 while declaring only 0x0F, 0x10, 0x11 and
  /// 0x12 — so the reported value is not trustworthy, and showing it as the
  /// current input would be inventing information.
  private var currentInputDescription: String {
    if let current = display.currentInput {
      return "currently \(InputSource.name(for: current))"
    }
    if let reported = display.reportedInput {
      return String(format: "reports 0x%02X — not one it lists", reported)
    }
    return "current input unknown"
  }

  /// The stronger warning, for when the connection in use is not in the list.
  ///
  /// Not the same as merely not knowing which entry is current. It means there
  /// is no entry to come back to — the case for a USB-C connection on a display
  /// that lists only DisplayPort and HDMI.
  @ViewBuilder
  private var unlistedInputWarning: some View {
    if display.currentInputIsUnlisted {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.caption)
        Text("The connection you are using is not among the inputs this display lists, "
          + "so there is nothing here to switch back to. Only the monitor's own buttons "
          + "can return you to it.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Power

  private var power: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Power")
        .font(.callout.weight(.medium))

      HStack(spacing: 8) {
        // "On" is pointless from here — if the display were off, this window
        // would not be visible on it.
        ForEach(display.availablePowerModes.filter { $0 != .on }, id: \.self) { mode in
          Button(mode.displayName) { pendingPowerMode = mode }
        }
      }

      Text("The Mac stays awake; only the display sleeps.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
