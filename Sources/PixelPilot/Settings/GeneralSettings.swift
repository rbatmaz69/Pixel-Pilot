import PixelPilotCore
import ServiceManagement
import SwiftUI

/// How the app looks, and whether it is there at login.
///
/// The page the settings window opens on, because both of its cards are about
/// the app as a whole rather than about any one display or any one key.
/// The only page that takes no `AppModel`: nothing here goes through the
/// displays. The theme is a store of its own and login registration is
/// `SMAppService`'s business.
struct GeneralSettings: View {
  let model: AppModel

  @Environment(\.motion) private var motion

  /// The store rather than `\.theme`: this card writes to it, and the resolved
  /// theme in the environment is derived from it one level further out.
  private var theme: ThemeStore { .shared }

  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var launchAtLoginError: String?

  var body: some View {
    CardStack {
      themeCard.entrance(index: 0)
      startupCard.entrance(index: 1)
      welcomeCard.entrance(index: 2)
    }
  }

  /// A way back to the welcome guide.
  ///
  /// It exists because there was none, and the consequence was worse than a
  /// missing convenience: the guide is shown once, on the first launch, and
  /// records that it has been. Deleting the app does not take that record with
  /// it — preferences live in the user's Library, not in the bundle — so
  /// reinstalling could not bring the guide back either, and somebody who
  /// dismissed it without reading it had no way to ever see it again.
  ///
  /// The card says that, rather than leaving the reinstall that does not work
  /// as the obvious thing to try.
  private var welcomeCard: some View {
    PanelCard(title: "Welcome guide", systemImage: "sparkles") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        Button("Show the welcome guide") { model.showWelcome() }
          .buttonStyle(.soft)

        CardFooter("What the app showed you the first time it ran: the permissions it "
          + "needs and why, and what the menu bar icon does. Reinstalling will not bring "
          + "it back on its own — it is shown once and remembers that, and what it "
          + "remembers is kept with your settings rather than inside the app.")
      }
    }
  }

  /// The colour the whole application is drawn in.
  ///
  /// First card on the first page, because it is the only setting here that
  /// changes something the moment it is touched — every open window repaints
  /// while this card is being looked at, which is the demonstration.
  private var themeCard: some View {
    PanelCard(title: "Colour theme", systemImage: "paintpalette") {
      VStack(alignment: .leading, spacing: Layout.normal) {
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text("Accent").font(TypeScale.rowTitle)
            Text("Sliders, switches and highlights")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: Layout.snug)
          AccentSwatchPicker(
            selection: Binding(
              get: { theme.toneIndex },
              // There is always an accent: no derived fallback to return to the
              // way a display has, so `allowsNone` is off and this can only
              // ever be handed an index.
              set: { value in if let value { theme.toneIndex = value } }
            ),
            allowsNone: false,
            accessibilityLabel: "Accent colour"
          )
        }

        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text("Background").font(TypeScale.rowTitle)
            Text(theme.backdropToneIndex == nil
              ? "Following the accent — pick one to set it apart"
              : "Windows, menus and cards")
              .font(TypeScale.detail)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: Layout.snug)
          // Allows none, and that is the difference from the row above: with
          // nothing chosen the field follows the accent, which is what the
          // whole interface looked like before these could differ. Tapping the
          // selected swatch again goes back to that.
          AccentSwatchPicker(
            selection: Binding(
              get: { theme.backdropToneIndex },
              set: { theme.backdropToneIndex = $0 }
            ),
            accessibilityLabel: "Background colour"
          )
        }
        .animation(motion.effectDefault, value: theme.backdropToneIndex)

        // Above Depth rather than below it, so the card reads as two questions
        // rather than four rows: which colour, then how it is drawn. The two
        // swatch rows answer the first and these two segmented pickers answer
        // the second.
        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Style").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: Binding(get: { theme.style }, set: { theme.style = $0 }),
            options: ThemeStyle.allCases.map { ($0, $0.displayName) }
          )
          Text(theme.style.summary)
            .font(TypeScale.detail)
            .foregroundStyle(.secondary)
        }
        .animation(motion.effectDefault, value: theme.style)

        VStack(alignment: .leading, spacing: Layout.tight) {
          Text("Depth").font(TypeScale.rowTitle)
          SegmentedMorphPicker(
            selection: Binding(get: { theme.mode }, set: { theme.mode = $0 }),
            options: ThemeMode.allCases.map { ($0, $0.displayName) }
          )
        }

        CardFooter("Glass keeps the translucent look the app shipped with, Vivid puts far "
          + "more of the colour into every surface, and Flat drops the material and the "
          + "gradients for colour and clear edges. Neither end of Depth is grey: light is a "
          + "pale wash of the background colour and dark is a deep one. Automatic follows "
          + "the system. Each display also keeps its own accent for telling monitors apart "
          + "— that one is on the display's own page, under Displays.")
      }
    }
  }

  private var startupCard: some View {
    PanelCard(title: "Startup", systemImage: "power") {
      VStack(alignment: .leading, spacing: Layout.tight) {
        Toggle("Open at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        if let launchAtLoginError {
          Text(launchAtLoginError)
            .font(TypeScale.detail)
            .foregroundStyle(Status.bad)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.blurReplace)
        }
      }
      .animation(motion.spatialDefault, value: launchAtLoginError)
    }
  }

  /// `SMAppService` registration fails for an unsigned or ad-hoc signed build,
  /// so the error is surfaced rather than leaving a toggle that flips back on
  /// its own with no explanation.
  private func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginError = nil
    } catch {
      launchAtLogin = SMAppService.mainApp.status == .enabled
      launchAtLoginError = "Could not change this: \(error.localizedDescription)"
    }
  }
}
