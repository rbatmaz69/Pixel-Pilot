import PixelPilotCore
import SwiftUI

/// The keys on the keyboard, the permissions they need, and what is being seen
/// coming from them.
///
/// One page rather than three scattered cards, because they are one story: the
/// switch that claims the keys, the two grants without which claiming them does
/// nothing, and the readout that says which of the two is missing.
struct KeySettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme

  @State private var global = Preferences.shared.global
  @State private var isLearningKey = false

  var body: some View {
    CardStack {
      keysCard.entrance(index: 0)
      attentionCard.entrance(index: 1)
      permissionsCard.entrance(index: 2)
      detectionCard.entrance(index: 3)
    }
    .animation(motion.spatialDefault, value: model.needsRelaunchForPermissions)
    // Re-check on appearance as well as on activation: opening this page is
    // itself a moment the answer may have changed.
    .onAppear { model.refreshPermissions() }
    .sheet(isPresented: $isLearningKey) {
      KeyLearningSheet(model: model, isPresented: $isLearningKey)
        .withMotionTokens()
    }
  }

  private var keysCard: some View {
    PanelCard(title: "Keyboard keys", systemImage: "keyboard") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Use the keyboard's brightness and volume keys", isOn: $global.mediaKeysEnabled)
          .onChange(of: global.mediaKeysEnabled) { _, _ in apply() }

        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Keys act on").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: $global.keyTarget,
            options: KeyTarget.allCases.map { ($0, $0.displayName) }
          )
          .onChange(of: global.keyTarget) { _, _ in apply() }
          Text(global.keyTarget.summary)
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }
        .animation(motion.effectDefault, value: global.keyTarget)

        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Per key press").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: $global.keyStep,
            options: [
              (1.0 / 8.0, "13%"),
              (1.0 / 16.0, "6%"),
              (1.0 / 24.0, "4%"),
              (1.0 / 32.0, "3%"),
            ]
          )
          .onChange(of: global.keyStep) { _, _ in apply() }
        }

        Toggle("Show the on-screen indicator", isOn: $global.showsOSD)
          .onChange(of: global.showsOSD) { _, _ in apply() }

        Toggle("Tap the trackpad at ends and quarters", isOn: $global.hapticsEnabled)
          .onChange(of: global.hapticsEnabled) { _, _ in apply() }

        CardFooter("While this is on the keys belong to Pixel Pilot — including on the "
          + "built-in panel, which means macOS no longer dims it as the room gets darker. "
          + "That trade is the point: one indicator and one step size on every screen. "
          + "Turning this off hands every key straight back. Hold Shift and Option while "
          + "pressing for finer steps. The trackpad taps only on hardware that can — macOS "
          + "decides that, and its own setting in Trackpad preferences wins over this one. "
          + "An external display can be set to follow the built-in panel on its own page "
          + "under Displays, which is how the light in the room reaches it. Aiming at the "
          + "window you're working in needs the Accessibility permission below — the same "
          + "one the keys already need — and falls back to the pointer whenever it cannot "
          + "tell. Aiming at all of them instead moves the group the panel's master slider "
          + "drives, so that slider appears the first time a key is pressed. The global "
          + "shortcuts follow this setting too.")
      }
    }
  }

  /// On this page rather than under General, because this page is already about
  /// where input is aimed — `keyTarget` is three rows up. This asks the same
  /// question of attention instead of keystrokes, and answers it from the same
  /// Accessibility grant listed below.
  private var attentionCard: some View {
    PanelCard(title: "Attention", systemImage: "rectangle.inset.filled.on.rectangle") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Toggle("Push back the screens you're not working on", isOn: $global.attention.isEnabled)
          .onChange(of: global.attention.isEnabled) { _, _ in apply() }

        if global.attention.isEnabled {
          amountSlider.transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
        }

        CardFooter(global.attention.isEnabled
          ? "The screen holding the window you're working in stays where you set it; the "
            + "others sink back and return the moment you move to them. It's done in the "
            + "colour tables, not the backlight — so the brightness slider doesn't move, a "
            + "preset captured now records what you set rather than what you're looking at, "
            + "and nothing goes down the DDC bus when you change window. On the built-in "
            + "panel that means a grey film over a backlight still running at full: it costs "
            + "contrast and saves no power. It doesn't fade, because fading a colour table "
            + "means rewriting it many times a second. A display can sit this out on its own "
            + "page under Displays."
          : "Off. Nothing sinks, and the app asks nothing about which window you're in.")
      }
      .animation(motion.spatialDefault, value: global.attention.isEnabled)
    }
  }

  private var amountSlider: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      HStack(alignment: .firstTextBaseline) {
        Text("How far they sink")
          .font(TypeScale.rowTitle)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(Int((global.attention.amount * 100).rounded()))%")
          .font(TypeScale.readout)
          .contentTransition(.numericText(value: global.attention.amount))
          .animation(motion.effectFast, value: global.attention.amount)
      }

      ExpressiveSlider(
        value: $global.attention.amount,
        range: AttentionSettings.amountRange,
        accent: theme.tone,
        // Not the quarters: this track starts at 10 % and ends at 70 %, so a
        // mark at "half of the track" would sit at 40 % and mean nothing.
        detents: [],
        onCommit: { _ in apply() }
      )
    }
  }

  private var permissionsCard: some View {
    PanelCard(title: "Permissions", systemImage: "lock.shield") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        // Both statuses are always shown, granted or not. A warning that only
        // appears when something is missing leaves no way to tell "granted"
        // from "the app has not noticed yet".
        PermissionRow(
          title: "Accessibility",
          detail: "Needed to see the keys at all.",
          isGranted: model.accessibilityGranted,
          action: model.requestAccessibilityPermission
        )
        PermissionRow(
          title: "Input Monitoring",
          detail: "Needed for brightness keys on keyboards other than Apple's.",
          isGranted: model.inputMonitoringGranted,
          action: model.requestInputMonitoringPermission
        )

        if model.needsAccessibilityPermission || model.needsInputMonitoringPermission {
          CardFooter("If Pixel Pilot is already ticked in System Settings but still shows as "
            + "missing here, remove it with the “−” button and add it again. macOS keys "
            + "these grants to the app's signature, and entries from earlier builds go "
            + "stale.")
        }

        // Permission granted and the listener still not running is its own
        // state, and the only cure is a relaunch: macOS decides HID access when
        // the connection is opened, and a process that was refused stays
        // refused for its lifetime.
        if model.needsRelaunchForPermissions {
          Divider()
          StatusRow(
            symbol: "arrow.clockwise.circle.fill",
            tint: Status.info,
            title: "Restart to finish enabling",
            detail: "The permission is granted, but this running copy was already refused. "
              + "macOS only re-checks when the app starts."
          ) {
            Button("Restart") { model.relaunch() }
              .buttonStyle(.soft(Status.info))
              .font(TypeScale.detail.weight(.medium))
          }
          // This row appears the moment a grant is noticed, which is exactly
          // when the window is being looked at. Without a transition the whole
          // card jumps under the pointer.
          .transition(.blurReplace)
        }
      }
    }
  }

  private var detectionCard: some View {
    PanelCard(title: "Key detection", systemImage: "dot.radiowaves.left.and.right") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        // Which keyboards are being watched, and what the last one sent. These
        // two together separate "never matched" from "matched but silent",
        // which need completely different fixes.
        VStack(alignment: .leading, spacing: Layout.hair) {
          if model.watchedKeyboards.isEmpty {
            Text("Watching no keyboards.")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
          } else {
            Text("Watching: \(model.watchedKeyboards.joined(separator: ", "))")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          if let observed = model.lastObservedKey {
            Text(String(
              format: "Last key: usage 0x%02X from %@", observed.usage, observed.device
            ))
            .font(TypeScale.mono)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
          } else {
            Text("No media key seen yet — press one now.")
              .font(TypeScale.detail)
              .foregroundStyle(.tertiary)
          }
        }
        .animation(motion.effectDefault, value: model.lastObservedKey?.usage)

        learnedKeys

        Divider()

        VStack(alignment: .leading, spacing: Layout.hair) {
          Toggle("Also read keys at the hardware level", isOn: $global.hidMediaKeysEnabled)
            .onChange(of: global.hidMediaKeysEnabled) { _, _ in apply() }
          // Stated because it is the one thing in this app that is not free
          // when nothing is happening, and because the trade is real: some
          // keyboards need it and some do not.
          CardFooter("Needed for brightness keys on keyboards macOS does not recognise. "
            + "Costs about 0.3% of one CPU core while running; without it Pixel Pilot "
            + "uses none when idle.")
        }
      }
    }
  }

  /// Keys taught for keyboards the automatic detection does not cover.
  ///
  /// Automatic detection can only handle schemes that were anticipated. A
  /// keyboard using its own usage page cannot be recognised in advance — only
  /// observed — which is what this is for.
  @ViewBuilder
  private var learnedKeys: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      ForEach(model.keyBindingList) { binding in
        StatusRow(
          symbol: binding.action.symbolName,
          title: binding.action.displayName,
          detail: "\(binding.keyboardName) — \(binding.signature.description)"
        ) {
          Button {
            model.forgetLearnedKey(binding.signature)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.soft)
          .help("Forget this key")
        }
        // Teaching and forgetting a key both happen with this list on screen,
        // so both should be visible as changes rather than as jumps.
        .transition(.blurReplace)
      }

      HStack(spacing: Layout.tight) {
        Button("Teach a key…") { isLearningKey = true }
          .buttonStyle(.soft)
        Text("For keyboards whose keys are not recognised automatically.")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .animation(motion.spatialDefault, value: model.keyBindingList.count)
  }

  private func apply() {
    Preferences.shared.updateGlobal { $0 = global }
    model.startMediaKeys()
    // Straight through rather than waiting for the next window change: someone
    // who just moved this slider is looking at the screens while they do it.
    model.attentionSettingsChanged()
  }
}
