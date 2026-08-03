import AppKit
import SwiftUI

/// Turns typed digits into a level.
///
/// A free function with a test rather than a method on the view, because it is
/// the one part of typing a figure that can be wrong in a way nobody notices
/// for weeks: `7` meaning 7 % rather than 70 %, `000` refusing rather than
/// meaning zero, `999` clamping to full rather than wrapping to nine.
enum ReadoutInput {
  /// Digits as typed, to a 0...1 level, or `nil` if they say nothing.
  ///
  /// Total by construction even though the view only ever hands it three
  /// characters: a parser that relies on its caller to keep it in range is a
  /// parser that overflows the first time it acquires a second caller.
  static func level(fromDigits digits: String) -> Double? {
    let figures = digits.filter(\.isNumber).prefix(3)
    guard let number = Int(figures) else { return nil }
    return Double(min(100, number)) / 100
  }
}

/// A percentage you can type into.
///
/// A slider is the right control for "a bit dimmer" and the wrong one for
/// "exactly 40" — and exact figures are what someone building a preset is
/// after, because a preset is a number they will want to reproduce tomorrow.
///
/// **Click the figure; do not type at it.** The obvious alternative was to let
/// digits typed anywhere in the panel land on whichever card the pointer
/// happened to be over. That needs an event monitor rather than focus, has no
/// visible affordance, and leaves "which card did that go to?" a question the
/// interface cannot answer. A figure that lights up under the pointer and takes
/// a caret when clicked answers it before it is asked.
///
/// **A real `TextField`, and not a focusable label collecting `onKeyPress`.**
/// The hand-built version is written down here because it looked right and was
/// not: the label took focus, drew a system focus ring nobody asked for, and
/// then swallowed every digit — `onKeyPress(characters:)` never fired for it.
/// A text field is what macOS gives a caret, a selection, a field editor and an
/// insertion point to, and none of those are worth reimplementing badly.
///
/// The field arrives prefilled and fully selected, so typing replaces the
/// figure rather than appending to it, and a click that turns out to have been
/// a misclick can be dismissed with Escape without having lost anything. Three
/// digits of width are reserved in both states, so the row never twitches on
/// the way in or out.
struct EditableReadout: View {
  /// 0...1, like everything else this app calls a level.
  let value: Double
  var font: Font = TypeScale.readout
  var accent: Color?
  /// Called once, with a fresh 0...1 value, when a typed figure is accepted.
  ///
  /// Never called while typing. That is the same split `ExpressiveSlider` draws
  /// between `onChange` and `onCommit`, for the same reason: one verified write
  /// per gesture, rather than a DDC round trip per keystroke.
  let onCommit: (Double) -> Void

  @Environment(\.motion) private var motion
  @Environment(\.theme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  @FocusState private var isFocused: Bool
  @State private var isEditing = false
  @State private var typed = ""
  @State private var isHovered = false

  private var tone: Color { accent ?? theme.tone }

  var body: some View {
    HStack(spacing: 1) {
      // Three digits' worth of the actual font, drawn and hidden, so the width
      // is the same before, during and after an edit — and stays right if the
      // type scale is ever retuned. A number in points here would be a number
      // that quietly stops matching.
      ZStack(alignment: .trailing) {
        Text("000").hidden()

        if isEditing {
          TextField("", text: $typed)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onChange(of: typed) { _, updated in
              // Filtered as it arrives rather than at the end, so a stray
              // letter never appears in a field that is going to refuse it.
              let digits = String(updated.filter(\.isNumber).prefix(3))
              if digits != updated { typed = digits }
            }
            .onChange(of: isFocused) { _, focused in
              // Clicking away cancels and never commits: a figure half typed
              // and then abandoned is not a decision anyone made.
              if !focused { cancel() }
            }
        } else {
          Text("\(Int((value * 100).rounded()))")
            .contentTransition(.numericText(value: value))
            .animation(motion.effectFast, value: value)
        }
      }

      Text("%")
        .foregroundStyle(isEditing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
    .font(font)
    .padding(.horizontal, 4)
    .background {
      MorphingRoundedRectangle(cornerRadius: Layout.radiusControl)
        .fill(isEditing ? theme.wash(for: tone) : (isHovered ? Color.primary.opacity(0.07) : .clear))
    }
    .overlay {
      if isEditing {
        MorphingRoundedRectangle(cornerRadius: Layout.radiusControl)
          .strokeBorder(theme.fill(for: tone), lineWidth: 1)
      }
    }
    .animation(motion.effectFast, value: isHovered)
    .animation(motion.effectFast, value: isEditing)
    // The app draws its own indication of an edit — the wash and the accent
    // edge above. The system focus ring on top of that was a second, squarer
    // answer to the same question, in a corner radius this interface does not
    // use anywhere.
    .focusEffectDisabled()
    .contentShape(.rect)
    .onHover { isHovered = $0 && isEnabled }
    .onTapGesture { beginEditing() }
    .help("Click to type an exact percentage")
    .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
  }

  private func beginEditing() {
    guard isEnabled, !isEditing else { return }
    typed = String(Int((value * 100).rounded()))
    isEditing = true
    isFocused = true

    // Select the whole figure, so the first digit typed replaces it instead of
    // making it ten times bigger. SwiftUI has no spelling for this; the field
    // editor is on the responder chain and has had one for thirty years. After
    // a beat, because focus has to land before there is an editor to ask.
    Task {
      try? await Task.sleep(for: .milliseconds(30))
      // `keyWindow` can be nil while the app is not the active one, which is
      // most of this app's life — the menu bar panel is key without anything
      // being activated. Falling back to the search costs nothing and is the
      // difference between this working in the panel and only in the window.
      let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isKeyWindow }
      (window?.firstResponder as? NSTextView)?.selectAll(nil)
    }
  }

  private func commit() {
    guard let level = ReadoutInput.level(fromDigits: typed) else {
      cancel()
      return
    }
    isEditing = false
    isFocused = false
    Haptics.confirm()
    onCommit(level)
  }

  private func cancel() {
    isEditing = false
    isFocused = false
  }
}
