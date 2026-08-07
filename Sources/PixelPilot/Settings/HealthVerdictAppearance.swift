import PixelPilotCore
import SwiftUI

/// How a health verdict is drawn.
///
/// Two surfaces show one: the Health card on a display's own page, and the row
/// for that display on the overview board. This is the table they both read, so
/// a verdict cannot be a green tick in one place and an orange triangle in the
/// other.
///
/// In the app rather than beside `HealthReport` in the package for the usual
/// reason: `Color` and an SF Symbol name are decisions about drawing, and the
/// package's job is to know what is true.
extension HealthReport.Verdict {
  var symbolName: String {
    switch self {
    case .clean: "checkmark.circle.fill"
    case .characteristics: "info.circle.fill"
    case .faults: "exclamationmark.triangle.fill"
    case .incomplete: "clock.badge.questionmark"
    }
  }

  /// Nil for `incomplete`, which is deliberately colourless: a check that was
  /// not finished is not a finding, and tinting it would make an interruption
  /// look like a result.
  var tint: Color? {
    switch self {
    case .clean: Status.ok
    case .characteristics: Status.info
    case .faults: Status.warn
    case .incomplete: nil
    }
  }
}

/// What a display with no report at all shows. Not a verdict — the absence of
/// one — so it sits beside the table rather than in it.
enum HealthVerdictAppearance {
  static let neverCheckedSymbol = "questionmark.circle"
}
