import Foundation

/// Why a control is not doing what it looks like it should.
///
/// Written out as cases rather than as an optional string, because the same
/// fact is wanted at two lengths: the menu bar panel has one line under a
/// display's name, and a settings card has a paragraph. A string built at the
/// first of those call sites cannot be lengthened at the second, and a string
/// built at the second cannot be shortened at the first.
///
/// **What is deliberately not here.** There is no `notAnswering` case. It is
/// the obvious one to want — a display that has stopped replying — and nothing
/// in this app can currently produce it: `DisplayViewModel.activate()` sets
/// `isReady` at the end of its probe regardless of what came back, and after
/// that the app writes and never reads. The two things that *are* true are
/// "there is no DDC channel at all" and "the strategy resolved to gamma", and
/// those are what the cases below say. A case nothing can produce is a sentence
/// the app would never show and a test that would never fail.
public enum ControlBlock: Equatable, Sendable, CaseIterable {
  /// The first probe has not come back yet. Resolves itself, usually within a
  /// second of the display appearing.
  case stillProbing
  /// A capability re-probe is running, so the answers may change underneath.
  case reprobing
  /// There is no DDC channel to this display at all — nothing to send on.
  case noDDCChannel
  /// The panel has no usable DDC luminance, so the gamma table is doing the
  /// dimming. Works on anything, costs contrast, shows up in screenshots.
  case softwareDimming
  case noContrastControl
  /// Nowhere for a volume slider to go. The sentence naming the current output
  /// device is the app's to build, because only the app can ask what it is
  /// called; this is only the fact that there is nothing to drive.
  case noVolumePath

  /// One clause, for the caption under a display's name in the panel.
  ///
  /// Lower case and no full stop: these are read as the tail of a line, not as
  /// sentences of their own.
  public var short: String {
    switch self {
    case .stillProbing: "still probing"
    case .reprobing: "re-probing features"
    case .noDDCChannel: "not answering on DDC"
    case .softwareDimming: "dimming in software"
    case .noContrastControl: "no contrast control"
    case .noVolumePath: "no volume over this output"
    }
  }

  /// The whole answer, for a settings card that has the room for it.
  public var explanation: String {
    switch self {
    case .stillProbing:
      "The display is being asked what it can do. The controls come alive as soon as it answers."
    case .reprobing:
      "The features are being read again. What is offered here may change when that finishes."
    case .noDDCChannel:
      "There is no DDC/CI channel to this display, so nothing can be sent to it. "
        + "A hub or an adaptor in the way is the usual reason."
    case .softwareDimming:
      "This panel does not answer DDC brightness, so the gamma table is doing the dimming. "
        + "It works on anything, but it costs contrast rather than dimming the backlight, "
        + "and it shows up in screenshots."
    case .noContrastControl:
      "This display did not offer a usable contrast control."
    case .noVolumePath:
      "This display has no speakers to drive, so its volume goes to the system output instead."
    }
  }

  public var level: StatusLevel {
    switch self {
    case .stillProbing, .reprobing: .info
    case .softwareDimming, .noContrastControl, .noVolumePath: .info
    case .noDDCChannel: .warn
    }
  }
}

/// Whether a control is live, and if not, why not.
///
/// Free functions over plain values rather than methods on the view model, so
/// the decision can be tested without a display, a bus, or a main actor. The
/// view model passes its own state in and does nothing else.
public enum ControlAvailability {
  /// Nil when the brightness slider is live and behaving ordinarily.
  ///
  /// The order of the checks is the order of the answers' usefulness: a display
  /// that has not finished probing will answer the other questions differently
  /// in a moment, so there is no point saying anything else about it yet.
  ///
  /// The built-in panel is exempt from both of the last two. It has no DDC
  /// channel by definition and macOS dims it in its own way, so saying either
  /// out loud would be reporting the ordinary state of every MacBook as a
  /// finding.
  public static func brightness(
    isReady: Bool,
    isProbing: Bool,
    hasDDCChannel: Bool,
    isBuiltin: Bool,
    strategy: BrightnessStrategy
  ) -> ControlBlock? {
    if !isReady { return .stillProbing }
    if isProbing { return .reprobing }
    guard !isBuiltin else { return nil }
    if !hasDDCChannel { return .noDDCChannel }
    if strategy == .gamma { return .softwareDimming }
    return nil
  }

  public static func contrast(capabilities: DisplayCapabilities?) -> ControlBlock? {
    capabilities?.isUsable(.contrast) == true ? nil : .noContrastControl
  }

  public static func volume(route: VolumeController.Route) -> ControlBlock? {
    route == .unavailable ? .noVolumePath : nil
  }
}
