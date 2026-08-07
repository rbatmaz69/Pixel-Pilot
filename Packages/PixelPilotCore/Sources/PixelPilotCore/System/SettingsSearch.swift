import Foundation

/// One thing that can be searched for and jumped to.
///
/// Generic over what it points at, because the destination is a user interface
/// type — a settings route, which carries a display's identity — and this
/// package has never heard of one and should not start now. The matching is
/// over strings either way, so the target is carried through and never looked
/// at.
public struct SearchEntry<Target: Hashable & Sendable>: Sendable, Hashable, Identifiable {
  public let id: String
  /// What the card is called, spelled exactly as it is on screen.
  public let title: String
  /// Where it lives — "Keys", "Dell U2720Q". Shown under the title, because a
  /// result that is a word with no idea where it came from is a result you then
  /// have to go and find.
  public let context: String
  /// The words somebody would actually type, including the American spellings
  /// of the words this app spells British. A search that cannot find "color"
  /// has decided to be right rather than useful.
  public let keywords: [String]
  public let target: Target

  public init(
    id: String, title: String, context: String, keywords: [String] = [], target: Target
  ) {
    self.id = id
    self.title = title
    self.context = context
    self.keywords = keywords
    self.target = target
  }
}

/// Ranks search entries against what somebody typed.
///
/// Free functions over plain values, so the whole of the behaviour can be
/// tested without a window, a list or a keystroke.
public enum SettingsSearch {
  /// Best first, at most `limit`.
  ///
  /// **An empty query gives nothing rather than everything.** A field with no
  /// text in it is not a question, and answering it with every card in the app
  /// would replace the sidebar the instant the field was focused.
  ///
  /// Every token has to match somewhere, which is what makes a second word
  /// narrow rather than widen: "key perm" finds Permissions on the Keys page,
  /// and "keyperm" correctly finds nothing at all.
  public static func rank<Target>(
    _ query: String, in entries: [SearchEntry<Target>], limit: Int = 8
  ) -> [SearchEntry<Target>] {
    let tokens = query
      .split(whereSeparator: \.isWhitespace)
      .map { fold(String($0)) }
      .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return [] }

    // `enumerated` and the comparison on index below are what make the sort
    // stable. Swift's `sort` is not guaranteed to be, and declaration order is
    // the tie-break this wants: the index is written in sidebar order, so two
    // equally good answers come back in the order they appear in the window.
    let scored = entries.enumerated().compactMap { index, entry -> (Int, Int, SearchEntry<Target>)? in
      var total = 0
      for token in tokens {
        let best = score(token, against: entry)
        guard best > 0 else { return nil }
        total += best
      }
      return (total, index, entry)
    }

    return scored
      .sorted { lhs, rhs in
        lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
      }
      .prefix(limit)
      .map(\.2)
  }

  /// The best single thing this token matched in this entry, or zero.
  ///
  /// The numbers only have to order correctly relative to each other. What they
  /// encode: a word of the title starting with what you typed is the strongest
  /// signal there is; a keyword you named exactly beats a title you only landed
  /// inside; and the context is the weakest, because every card on a page
  /// shares it and matching on it alone says nothing about which one you meant.
  private static func score<Target>(_ token: String, against entry: SearchEntry<Target>) -> Int {
    let title = fold(entry.title)
    if hasWordPrefix(title, token) { return 100 }
    if title.contains(token) { return 60 }

    var best = 0
    for keyword in entry.keywords {
      let folded = fold(keyword)
      if folded == token { best = max(best, 50) } else if folded.hasPrefix(token) {
        best = max(best, 40)
      }
    }
    if best > 0 { return best }

    return hasWordPrefix(fold(entry.context), token) ? 20 : 0
  }

  /// Case and accents removed, so "Colour" and "colour" and "cölour" are one
  /// word as far as typing is concerned.
  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  /// Whether any word of `text` starts with `token`.
  ///
  /// Word-wise rather than whole-string, so "permissions" finds "Key
  /// permissions" — typing the first word of a two-word title is the common
  /// case, but so is typing the second.
  private static func hasWordPrefix(_ text: String, _ token: String) -> Bool {
    text.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
      .contains { $0.hasPrefix(token) }
  }
}
