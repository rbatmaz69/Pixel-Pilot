import CoreGraphics
import Foundation
import PixelPilotCore

/// Reads and atomically applies physical display coordinates via CoreGraphics.
///
/// Used when arranging monitors interactively inside `DisplayMap` or moving the
/// macOS menu bar onto another screen (`assignPrimary`). All work runs only in
/// response to an explicit user drop gesture — zero polling (`0.0% idle CPU`).
@MainActor
enum DisplayArrangementController {
  /// Snapshot of current Quartz global bounds (`Y` increases downward from main `(0, 0)`).
  static func currentEntries(for displays: [DisplayViewModel]) -> [DisplayLayout.ArrangementEntry] {
    displays.map { display in
      DisplayLayout.ArrangementEntry(
        id: display.displayID,
        frame: CGDisplayBounds(display.displayID)
      )
    }
  }

  /// Applies `entries` atomically via `CGBeginDisplayConfiguration` and
  /// `CGCompleteDisplayConfiguration`.
  @discardableResult
  static func apply(
    _ entries: [DisplayLayout.ArrangementEntry],
    log: DiagnosticsLog? = nil
  ) -> Bool {
    guard !entries.isEmpty else { return true }
    if commit(entries, option: .permanently, log: log) {
      return true
    }
    return commit(entries, option: .forSession, log: log)
  }

  private static func commit(
    _ entries: [DisplayLayout.ArrangementEntry],
    option: CGConfigureOption,
    log: DiagnosticsLog?
  ) -> Bool {
    var config: CGDisplayConfigRef?
    let beginResult = CGBeginDisplayConfiguration(&config)
    guard beginResult == .success, let config else {
      log?.record(.warning("DisplayArrangement: CGBeginDisplayConfiguration failed (\(beginResult.rawValue))"))
      return false
    }

    for entry in entries {
      let x = Int32(entry.frame.origin.x.rounded())
      let y = Int32(entry.frame.origin.y.rounded())
      let stepResult = CGConfigureDisplayOrigin(config, entry.id, x, y)
      if stepResult != .success {
        log?.record(.warning("DisplayArrangement: CGConfigureDisplayOrigin failed for #\(entry.id) (\(stepResult.rawValue))"))
        CGCancelDisplayConfiguration(config)
        return false
      }
    }

    let completeResult = CGCompleteDisplayConfiguration(config, option)
    guard completeResult == .success else {
      log?.record(.warning("DisplayArrangement: CGCompleteDisplayConfiguration(\(option.rawValue)) failed (\(completeResult.rawValue))"))
      return false
    }
    return true
  }
}
