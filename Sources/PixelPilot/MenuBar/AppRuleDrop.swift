import AppKit
import PixelPilotCore
import SwiftUI
import UniformTypeIdentifiers

/// An application, as far as making a rule for it is concerned.
struct DroppedApplication: Equatable {
  let bundleIdentifier: String
  let name: String

  /// Reads a dropped file as an application, or decides it is not one.
  ///
  /// A bundle with no identifier is not usable here even though it is an
  /// application: `AppRule` matches on the identifier, so a rule without one
  /// would be a row in the settings that never fires.
  init?(url: URL) {
    guard let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
    bundleIdentifier = identifier
    name = FileManager.default.displayName(atPath: url.path)
  }
}

/// The status item, as somewhere to drop an application.
///
/// Making a rule used to cost: open Settings, find the page, work an open panel,
/// hunt through `/Applications`, then choose a preset. The application is
/// usually sitting in the Dock while all that happens. This is the same rule
/// in one gesture.
///
/// **It does not eat the click.** A view registered for dragged types has to
/// stay hit-testable — dragging is delivered through the ordinary view search —
/// so mouse events are forwarded to the button underneath instead of being
/// refused. Refusing them via `hitTest` would be tidier to read and would put
/// the drop target at the mercy of an AppKit implementation detail; the whole
/// feature is worth less than the click it would be gambling with.
///
/// Scrolling is unaffected either way: `StatusItemController` watches for it
/// with an event monitor keyed to the window, which runs before any view sees
/// the event.
final class ApplicationDropView: NSView {
  /// Called with an application bundle that has actually been dropped.
  var onDrop: ((DroppedApplication) -> Void)?
  /// Called when a droppable thing enters or leaves, for the button's highlight.
  var onHighlight: ((Bool) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("ApplicationDropView is not loaded from a nib")
  }

  override func mouseDown(with event: NSEvent) {
    superview?.mouseDown(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    superview?.rightMouseDown(with: event)
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    // Refused up front rather than on the drop, so a folder or a document never
    // shows the plus sign that promises something will happen.
    guard application(from: sender) != nil else { return [] }
    onHighlight?(true)
    Haptics.detent()
    return .copy
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    onHighlight?(false)
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    onHighlight?(false)
    guard let application = application(from: sender) else { return false }
    onDrop?(application)
    return true
  }

  private func application(from sender: any NSDraggingInfo) -> DroppedApplication? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: [UTType.application.identifier],
    ]
    let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: options
    ) as? [URL]
    return urls?.lazy.compactMap(DroppedApplication.init(url:)).first
  }
}

/// "Which preset, when this app is in front?"
///
/// Shown in the menu bar panel's own window, so a rule made by dropping arrives
/// through the same unroll, in the same theme, as everything else that comes
/// out of the status item.
///
/// The presets are chips rather than a menu. There are rarely more than four,
/// they all fit, and the gesture that got here was one drop — following it with
/// a menu to open and an item to find would spend the thing that made it worth
/// doing.
struct AppRuleDropSheet: View {
  let application: DroppedApplication
  let model: AppModel
  var onDone: () -> Void = {}
  var onOpenSettings: () -> Void = {}

  @Environment(\.theme) private var theme

  /// The rule this app already has, if any. Shown as chosen rather than
  /// silently replaced — `AppRuleStore.save` enforces one rule per app, so a
  /// second drop is an edit and should look like one.
  private var existing: AppRule? {
    model.appRuleList.first { $0.bundleIdentifier == application.bundleIdentifier }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      header.entrance(index: 0)

      if model.presetList.isEmpty {
        noPresets.entrance(index: 1)
      } else {
        presetChips.entrance(index: 1)
        CardFooter(
          "Applied whenever \(application.name) is the frontmost app, and undone by "
            + "whichever rule matches next."
        )
        .entrance(index: 2)
      }
    }
    .padding(Layout.normal)
    .frame(width: 320)
  }

  private var header: some View {
    HStack(spacing: Layout.snug) {
      AppIcon(bundleIdentifier: application.bundleIdentifier, size: 34)

      VStack(alignment: .leading, spacing: 1) {
        Text(application.name)
          .font(TypeScale.cardTitle)
          .lineLimit(1)
        Text(existing == nil ? "Choose a preset for it" : "Change its preset")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      Button(action: onDone) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.soft)
      .help("Close")
    }
  }

  private var presetChips: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      ForEach(model.presetList) { preset in
        Button {
          model.saveAppRule(
            AppRule(
              // The existing rule's identity is kept, so a second drop edits
              // the rule rather than replacing it — and its place in the list
              // stays where the user last put it.
              id: existing?.id ?? UUID(),
              bundleIdentifier: application.bundleIdentifier,
              name: application.name,
              presetID: preset.id
            )
          )
          Haptics.confirm()
          onDone()
        } label: {
          HStack(spacing: Layout.tight) {
            Image(systemName: preset.symbolName)
            Text(preset.name)
            Spacer(minLength: 0)
            if existing?.presetID == preset.id {
              Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.soft(theme.tone))
      }
    }
  }

  /// A rule pointing at nothing is the state `AppRuleStore.pruneMissingPresets`
  /// exists to clear up. It must not be possible to create one here.
  private var noPresets: some View {
    VStack(alignment: .leading, spacing: Layout.snug) {
      StatusRow(
        symbol: "square.stack.3d.up.slash",
        tint: Status.warn,
        title: "No presets yet",
        detail: "A rule points at a preset, so there has to be one first. Set the displays "
          + "the way you want them, then capture it."
      )

      Button("Open Settings…", action: onOpenSettings)
        .buttonStyle(.soft(Status.warn))
        .font(TypeScale.detail.weight(.medium))
        .padding(.leading, 22)
    }
    .padding(Layout.snug)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(accent: Status.warn)
  }
}
