import Foundation

/// How much attention something wants, as four steps rather than a colour.
///
/// A colour is a decision about how to draw; this is a decision about what is
/// true, and the two belong on opposite sides of the package boundary. The app
/// maps this onto `Status.ok` / `.info` / `.warn` / `.bad` in exactly one
/// place, which is what stops a second table of greens and oranges appearing
/// the first time somebody needs a status somewhere new.
///
/// `Comparable` is the point of the raw values. A surface that shows several
/// things at once — the overview board shows every display — needs "the worst
/// of these", and `max` over an ordering is that. A count is not: three notes
/// and one fault is a fault, not four of something.
public enum StatusLevel: Int, Comparable, Sendable, CaseIterable {
  /// Nothing to say. The ordinary case, and the one that must stay silent.
  case ok
  /// Worth knowing, not worth worrying about.
  case info
  /// Something is not doing what it looks like it should.
  case warn
  /// Something is broken.
  case bad

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
