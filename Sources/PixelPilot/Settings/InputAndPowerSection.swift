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
    PanelCard(title: "Eingang & Ruhezustand", systemImage: "cable.connector", accent: display.accent) {
      if display.availableInputs.isEmpty {
        compactRow
      } else {
        VStack(alignment: .leading, spacing: Layout.normal) {
          inputs
          if !display.availablePowerModes.isEmpty {
            Divider()
            power
          }
        }
      }
    }
    .confirmationDialog(
      pendingInput.map { "Zu \(InputSource.name(for: $0)) wechseln?" } ?? "",
      isPresented: Binding(get: { pendingInput != nil }, set: { if !$0 { pendingInput = nil } }),
      titleVisibility: .visible
    ) {
      Button("Eingang wechseln", role: .destructive) {
        if let value = pendingInput { display.switchInput(to: value) }
        pendingInput = nil
      }
      Button("Abbrechen", role: .cancel) { pendingInput = nil }
    } message: {
      Text(switchInputWarning)
    }
    .confirmationDialog(
      pendingPowerMode.map { "\(display.name) in „\($0.displayName)“ versetzen?" } ?? "",
      isPresented: Binding(
        get: { pendingPowerMode != nil }, set: { if !$0 { pendingPowerMode = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Display ausschalten", role: .destructive) {
        if let mode = pendingPowerMode { display.setPowerMode(mode) }
        pendingPowerMode = nil
      }
      Button("Abbrechen", role: .cancel) { pendingPowerMode = nil }
    } message: {
      Text("Bewege die Maus oder drücke die Power-Taste am Monitor zum Aufwecken. Der Mac selbst bleibt wach.")
    }
  }

  /// The confirmation text, which has to be sharper when the current input is
  /// unlisted — "you can switch back with the monitor's buttons" is misleading
  /// when the input you are on does not appear in the list at all.
  private var switchInputWarning: String {
    let base = "Das Bild dieses Macs verschwindet von \(display.name)."
    if display.currentInputIsUnlisted {
      return base + " Die aktuelle Verbindung ist nicht gelistet – der Rückwechsel ist nur direkt am Monitor möglich."
    }
    return base + " Zurückwechseln ist direkt über die Monitortasten möglich."
  }

  // MARK: - Inputs

  private var compactRow: some View {
    HStack(spacing: Layout.snug) {
      Button {
        Task { await display.readCapabilityString() }
      } label: {
        if display.isReadingCapabilityString {
          HStack(spacing: Layout.tight) {
            ProgressView().controlSize(.small)
            Text("Lese Eingänge…")
          }
        } else {
          Label("Eingänge einlesen", systemImage: "arrow.trianglehead.2.clockwise")
        }
      }
      .buttonStyle(.soft(display.accent))
      .disabled(display.isReadingCapabilityString)
      .animation(.default, value: display.isReadingCapabilityString)

      Spacer(minLength: 0)

      ForEach(display.availablePowerModes.filter { $0 != .on }, id: \.self) { mode in
        Button(mode.displayName) { pendingPowerMode = mode }
          .buttonStyle(.soft(Status.warn))
      }
    }
  }

  private var inputs: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack {
        Text("Eingangsquelle")
          .font(TypeScale.rowTitle)
        Spacer()
        Text(currentInputDescription)
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
      }

      // A row of buttons rather than a picker: a picker implies the selection
      // reflects reality, and here we usually cannot tell which input is live.
      HStack(spacing: Layout.tight) {
        ForEach(display.availableInputs, id: \.self) { value in
          Button(InputSource.name(for: value)) {
            pendingInput = value
          }
          .buttonStyle(.soft(display.accent))
          .disabled(value == display.currentInput)
        }
      }

      unlistedInputWarning
    }
  }

  /// Says "unknown" rather than pointing at the wrong entry.
  ///
  /// This display reports input 0x07 while declaring only 0x0F, 0x10, 0x11 and
  /// 0x12 — so the reported value is not trustworthy, and showing it as the
  /// current input would be inventing information.
  private var currentInputDescription: String {
    if let current = display.currentInput {
      return "aktuell \(InputSource.name(for: current))"
    }
    if let reported = display.reportedInput {
      return String(format: "meldet 0x%02X (ungelistet)", reported)
    }
    return "aktueller Eingang unbekannt"
  }

  /// The stronger warning, for when the connection in use is not in the list.
  ///
  /// Not the same as merely not knowing which entry is current. It means there
  /// is no entry to come back to — the case for a USB-C connection on a display
  /// that lists only DisplayPort and HDMI.
  @ViewBuilder
  private var unlistedInputWarning: some View {
    if display.currentInputIsUnlisted {
      StatusRow(
        symbol: "exclamationmark.triangle.fill",
        tint: Status.warn,
        title: "Aktive Verbindung nicht gelistet",
        detail: "Diese Verbindung fehlt in der Eingangsliste – zum Zurückwechseln werden die Monitortasten benötigt."
      )
      .transition(.blurReplace)
    }
  }

  // MARK: - Power

  private var power: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      Text("Ruhezustand")
        .font(TypeScale.rowTitle)

      HStack(spacing: Layout.tight) {
        // "On" is pointless from here — if the display were off, this window
        // would not be visible on it.
        ForEach(display.availablePowerModes.filter { $0 != .on }, id: \.self) { mode in
          Button(mode.displayName) { pendingPowerMode = mode }
            .buttonStyle(.soft(Status.warn))
        }
      }

      Text("Der Mac bleibt wach – nur das Display geht schlafen.")
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
    }
  }
}
