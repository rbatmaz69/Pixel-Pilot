import SwiftUI

/// A field to type at, in the app's own clothes.
///
/// Not `.searchable`. That modifier installs the system's search chrome, and in
/// a `NavigationSplitView` it places itself where the system thinks a search
/// field goes — which is not where this one goes, and the sidebar it would be
/// placed into is deliberately hand-built. The result would be one control in
/// the window that belonged to a different design.
///
/// So: the fill `SoftButtonStyle` uses at rest, and the shape `ShortcutRecorder`
/// and `ExpressiveSlider` already use. This is not a new idiom, it is the
/// existing control surface with a caret in it.
struct SettingsSearchField: View {
  @Binding var query: String
  var isFocused: FocusState<Bool>.Binding

  @Environment(\.motion) private var motion

  var body: some View {
    HStack(spacing: Layout.tight) {
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.secondary)

      TextField("Search settings", text: $query)
        .textFieldStyle(.plain)
        .focused(isFocused)

      if !query.isEmpty {
        Button {
          query = ""
          isFocused.wrappedValue = false
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .transition(.blurReplace)
        .accessibilityLabel("Clear the search")
      }
    }
    .padding(.horizontal, Layout.snug)
    .padding(.vertical, Layout.tight)
    .background {
      MorphingRoundedRectangle(cornerRadius: Layout.radiusControl)
        .fill(Color.primary.opacity(0.06))
    }
    .animation(motion.effectDefault, value: query.isEmpty)
  }
}
