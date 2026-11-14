import AppKit
import SwiftUI

private struct PanelFitHeightKey: EnvironmentKey {
  static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
  var fitPanelHeight: @MainActor @Sendable () -> Void {
    get { self[PanelFitHeightKey.self] }
    set { self[PanelFitHeightKey.self] = newValue }
  }
}

/// The popover under the status item.
///
/// **The invariant this type exists to keep.** `MenuBarPanel` documents that
/// SwiftUI only builds it while it is open, and that this is what pays for the
/// staggered entrance: the hierarchy is built fresh on every open, so the
/// arrival plays every single time and costs nothing at all in between. It is
/// also what stops the ambient wash — the one animation in this app that runs
/// on its own — the moment the panel is dismissed.
///
/// `MenuBarExtra` gave that for free. Doing it by hand means `close()` has to
/// destroy the hosting view rather than order the window out and leave it
/// standing, which is what almost every hand-rolled popover does. The test is
/// not subtle: with the panel closed the process must sit at 0.0 % CPU, and if
/// the hierarchy survived, the ambient drift keeps running and it will not.
///
/// `OSDController.teardown()` already makes the same move for the same reason.
@MainActor
final class MenuBarPanelWindow: NSObject {
  private var panel: NSPanel?
  private var hostingView: NSHostingView<AnyView>?
  private let onClose: () -> Void

  private let driver = PanelSpringDriver()
  private let heightSpringDriver = PanelSpringDriver()
  /// Where the panel comes to rest. Its top edge is also where it unrolls from,
  /// which is why no separate anchor is kept: `place` already puts that edge
  /// just under the status item.
  private var restingFrame: CGRect = .zero
  private var isClosing = false

  /// Live only while the panel is on screen **and staying there**.
  ///
  /// False during the collapse, which matters for the one caller: the status
  /// item toggles on this, and a panel that is halfway out of existence should
  /// answer a click by coming back rather than by being told to close again.
  var isOpen: Bool { panel != nil && !isClosing }

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
  }

  /// Builds and shows a panel, anchored under `anchor`.
  func show(anchoredTo anchor: NSStatusBarButton, content: some View) {
    // A click that lands mid-collapse takes over from it. Torn down here and
    // now rather than left to the driver's completion, which would otherwise
    // fire later and destroy the panel this call is about to build.
    if panel != nil { teardown() }

    // The panel's counterpart to `WindowCoordinator.makeWindow`: the one place
    // the environment is set up, so the view inside can read every value rather
    // than installing them over itself and seeing the defaults.
    let hosting = NSHostingView(rootView: AnyView(
      content
        .withMotionTokens()
        // The field is painted below, over a vibrancy view — so the theme
        // supplies the colours and the ink but must not lay a second backdrop
        // inside the rounded corners.
        .withAppTheme(paintsWindow: false)
        // The panel's own material comes from the window it lives in, so its
        // cards must not lay a second sheet of glass over the first — that
        // reads as a flat wash with none of the depth either layer was drawing
        // for.
        .environment(\.surfaceDepth, .onGlass)
        .environment(\.fitPanelHeight, { [weak self] in
          Task { @MainActor in
            self?.fitContentHeight()
          }
        })
    ))
    hosting.sizingOptions = [.intrinsicContentSize]

    let panel = KeyablePanel(
      contentRect: .zero,
      // .nonactivatingPanel so opening the panel does not pull focus out of
      // whatever the user is working in — the same reasoning as the HUD, and
      // the reason `canBecomeKey` has to be overridden below: the panel still
      // needs key status to know when to dismiss itself.
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    let theme = ThemeStore.shared.theme

    // The visual effect view stays whatever the style is. It owns the corner
    // radius, the masking and the anchors for both subviews, so swapping it for
    // a plain view under a style with no material would mean re-plumbing all of
    // that to achieve something the tint below already does. Its material is
    // switched off instead — `.inactive` stops it sampling the desktop at all,
    // which is a pass saved on a window that opens on every click of the menu
    // bar icon.
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = theme.usesMaterial ? .active : .inactive
    // Without this the material resolves against the system's light/dark
    // setting while everything drawn on top of it follows the theme — which
    // shows up as a pale popover under dark cards, or the reverse.
    background.appearance = theme.appearance
    background.wantsLayer = true
    // Two roundings, because they cut two different things and neither one does
    // the other's job.
    //
    // `maskImage` is what shapes the **material**. A view blending behind the
    // window does not take its extent from its layer — the blur is done by the
    // window server against the region this mask describes, and with no mask
    // that region is the window's square bounds. On a dark desktop nobody sees
    // it. Over a white window it is a flat pale rectangle with hard edges
    // standing out past every corner, which is what this looked like.
    background.maskImage = Self.roundedMask(radius: Layout.radiusPanel)

    let clip = PopoverClipView()
    clip.radius = Layout.radiusPanel
    clip.borderColor = NSColor(theme.groupBorder).cgColor

    // Where the material survives, the desktop blurring through it is real
    // depth, and this is the one surface in the app that has something behind
    // it worth sampling. What it does not have is a colour, so the theme's
    // field goes over it at most of the way to opaque: enough to read as the
    // app's own colour rather than as a grey system popover, and not so much
    // that the blur underneath stops showing through at the edges.
    //
    // How much of "most of the way" is the style's to say, and at 1 the answer
    // is that nothing of the desktop survives — which is how a flat panel is
    // had without touching a line of the structure above.
    let tint = NSView()
    tint.wantsLayer = true
    tint.layer?.backgroundColor = NSColor(theme.backdropTop)
      .withAlphaComponent(theme.panelTintOpacity).cgColor

    // The tint follows the window; the hosting view deliberately does not.
    //
    // Both used to be nailed to all four edges, which was right while the
    // window never moved. It stops being right the moment the frame is
    // animated: a growing window would re-run SwiftUI's layout for the whole
    // panel on every frame, at 120 Hz, on a hierarchy with sliders and an
    // ambient wash in it. So the content is laid out **once** at its resting
    // size and scaled with a layer transform, which is a matrix multiply on the
    // GPU rather than a layout pass.
    //
    // The tint is a single colour and costs nothing to resize, and it has to
    // resize: it is what fills the window's rounded shape while the content
    // inside is still smaller than it.
    clip.translatesAutoresizingMaskIntoConstraints = false
    tint.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(clip)
    clip.addSubview(tint)
    NSLayoutConstraint.activate([
      clip.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      clip.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      clip.topAnchor.constraint(equalTo: background.topAnchor),
      clip.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      tint.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      tint.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      tint.topAnchor.constraint(equalTo: clip.topAnchor),
      tint.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
    ])

    // Autoresizing rather than constraints, because the size is set by hand
    // once `fittingSize` is known and must then stay put no matter what the
    // window does.
    hosting.autoresizingMask = []
    clip.addSubview(hosting)
    hosting.wantsLayer = true

    panel.contentView = background
    panel.appearance = theme.appearance
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // No window shadow, for the reason `OverlayPanel` already gives about the
    // two HUDs: the material draws its own edge, and a second one underneath
    // it is not depth but a double line.
    //
    // Worse here than there, because this window is translucent. macOS lays the
    // shadow *behind* the window, and everything the material lets through
    // shows it — so the dark ring appeared inside the panel, a few points in
    // from its own edge, looking like a seam in the design rather than
    // something cast by the window.
    //
    // It was also the thing arriving late. A shadow is derived from the
    // window's shape, so it has to be re-derived after an animated resize, and
    // an outline that snaps into place once the movement has finished reads as
    // the interface catching up with itself.
    panel.hasShadow = false
    panel.isMovable = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.delegate = self

    self.panel = panel
    self.hostingView = hosting

    self.restingFrame = place(panel, hosting: hosting, under: anchor)
    applyShape(to: background, clip: clip)

    guard !OverlayPanel.reduceMotion else {
      panel.setFrame(restingFrame, display: false)
      panel.makeKeyAndOrderFront(nil)
      return
    }

    panel.alphaValue = 0
    apply(progress: 0)
    panel.makeKeyAndOrderFront(nil)

    driver.run(
      in: background,
      spring: MotionTokens.unfoldSpring,
      reversed: false,
      onFrame: { [weak self] progress in self?.apply(progress: progress) },
      onFinish: { [weak self] in self?.settle() }
    )
  }

  /// Collapses the panel back into the status item, then destroys it.
  ///
  /// The teardown is not optional and not deferrable: dropping the content view
  /// drops the `NSHostingView`, and with it the SwiftUI hierarchy, its
  /// observation and the ambient wash. See the type documentation — an animated
  /// close that forgot this would look better and cost the app its one hard
  /// guarantee.
  func close() {
    guard let panel, !isClosing else { return }

    // From here it is on its way out: it must stop taking clicks, stop
    // reporting itself open, and stop being told about key changes it can no
    // longer act on.
    heightSpringDriver.cancel()
    panel.delegate = nil
    isClosing = true

    guard !OverlayPanel.reduceMotion, let background = panel.contentView else {
      teardown()
      return
    }

    panel.ignoresMouseEvents = true

    driver.run(
      in: background,
      spring: MotionTokens.collapseSpring,
      reversed: true,
      onFrame: { [weak self] progress in self?.apply(progress: progress) },
      onFinish: { [weak self] in self?.teardown() }
    )
  }

  /// Puts the panel and its contents where `progress` says.
  ///
  /// One number driving both the window and the layer transform. That is the
  /// whole arrangement: the material is blurred by the window server against
  /// the window's own shape, so a content transform that ran even a frame ahead
  /// of the frame it belongs to would show as the panel's contents sliding out
  /// from under their own background.
  private func apply(progress: CGFloat) {
    // The clipping view rather than the window's content view: they are the same
    // size, but this is the one the content is actually hung inside.
    guard let panel, let hosting = hostingView, let clip = hostingView?.superview else { return }

    let frame = PanelPresentation.frame(progress: progress, target: restingFrame)
    panel.setFrame(frame, display: false)
    panel.alphaValue = PanelPresentation.alpha(progress: progress)

    // Implicit layer animations off: the driver is already the animation, and
    // Core Animation interpolating between two frames of it would be a second
    // one lagging a few frames behind the first.
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // The **origin** only, and never the size or a scale. The window has rolled
    // up above it, so the content is re-hung from the top edge and the rest of
    // it hangs below the window, where the rounded mask clips it. That is the
    // whole trick: the panel is revealed rather than resized, so nothing in it
    // is ever drawn at a width or a height that is not its own.
    //
    // Changing the size here instead is exactly the SwiftUI layout pass this
    // arrangement exists to avoid.
    // Reset transform before reading frame.height so origin isn't affected by a prior frame's scale.
    hosting.layer?.transform = CATransform3DIdentity
    hosting.setFrameOrigin(CGPoint(
      x: 0,
      y: clip.bounds.height - PopoverShape.arrowHeight - hosting.frame.height
    ))

    // The one transform, and it only ever acts on the overshoot. Vertical, and
    // about the top edge — written as translate-then-scale rather than by
    // moving the layer's `anchorPoint`, because AppKit owns that on a
    // layer-backed view and changing it shifts the layer by half its own height
    // the moment the frame is next set.
    let stretch = PanelPresentation.contentStretch(frame: frame, target: restingFrame)
    let contentHeight = hosting.frame.height
    var transform = CATransform3DMakeTranslation(0, contentHeight * (1 - stretch) / 2, 0)
    transform = CATransform3DScale(transform, 1, stretch, 1)
    hosting.layer?.transform = transform

    CATransaction.commit()
  }

  /// The end of the opening run: exact resting geometry, with nothing left
  /// interpolated.
  private func settle() {
    guard let panel else { return }
    apply(progress: 1)
    panel.alphaValue = 1
  }

  /// Resizes the open panel smoothly at 120 Hz via `PanelSpringDriver` when
  /// inline Studio drawers expand or collapse inside `MenuBarPanel`, keeping
  /// the width constant and the top edge pinned below the menu bar icon.
  func fitContentHeight() {
    guard let panel, !isClosing, !driver.isRunning, let hosting = hostingView else { return }
    hosting.layoutSubtreeIfNeeded()
    let newSize = hosting.fittingSize
    guard newSize != .zero else { return }

    let topY = restingFrame.maxY
    let windowHeight = newSize.height + PopoverShape.arrowHeight
    let lockedWidth = restingFrame.width > 0 ? restingFrame.width : newSize.width
    let updatedFrame = CGRect(
      x: restingFrame.minX,
      y: topY - windowHeight,
      width: lockedWidth,
      height: windowHeight
    )
    guard abs(updatedFrame.height - restingFrame.height) > 0.5
      || abs(panel.frame.height - updatedFrame.height) > 0.5 else { return }

    restingFrame = updatedFrame

    guard !OverlayPanel.reduceMotion,
          panel.isVisible,
          panel.alphaValue > 0.5,
          let background = panel.contentView
    else {
      heightSpringDriver.cancel()
      hosting.frame = CGRect(
        origin: CGPoint(x: 0, y: updatedFrame.height - PopoverShape.arrowHeight - newSize.height),
        size: newSize
      )
      panel.setFrame(updatedFrame, display: true)
      return
    }

    let startHeight = panel.frame.height
    let targetHeight = updatedFrame.height
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hosting.frame = CGRect(
      origin: CGPoint(x: 0, y: startHeight - PopoverShape.arrowHeight - newSize.height),
      size: newSize
    )
    CATransaction.commit()

    heightSpringDriver.run(
      in: background,
      spring: MotionTokens.drawerSpring,
      reversed: false,
      onFrame: { [weak self] progress in
        guard let self, let panel = self.panel, let hosting = self.hostingView else { return }
        let minHeight = PopoverShape.arrowHeight + 40
        let currentHeight = max(minHeight, startHeight + (targetHeight - startHeight) * progress)
        let frame = CGRect(
          x: updatedFrame.minX,
          y: topY - currentHeight,
          width: lockedWidth,
          height: currentHeight
        )
        panel.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosting.setFrameOrigin(CGPoint(
          x: 0,
          y: frame.height - PopoverShape.arrowHeight - newSize.height
        ))
        CATransaction.commit()
      },
      onFinish: { [weak self] in
        guard let self, let panel = self.panel, let hosting = self.hostingView else { return }
        panel.setFrame(updatedFrame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosting.setFrameOrigin(CGPoint(
          x: 0,
          y: updatedFrame.height - PopoverShape.arrowHeight - newSize.height
        ))
        CATransaction.commit()
      }
    )
  }

  private func teardown() {
    heightSpringDriver.cancel()
    driver.cancel()
    panel?.orderOut(nil)
    panel?.contentView = nil
    panel = nil
    hostingView = nil
    isClosing = false
  }

  /// Sizes the content and works out where the panel comes to rest.
  ///
  /// The resting frame is also what the unroll is derived from: its top edge is
  /// just under the status item, and `PanelPresentation.frame` grows downward
  /// from there. So there is no separate anchor to keep in step with it.
  ///
  /// The hosting view is given an explicit frame here and never resized again —
  /// see the constraints above for why. Measuring has to happen before the
  /// window is sized rather than after, because the window's size is now
  /// derived from the content rather than imposed on it.
  private func place(
    _ panel: NSPanel, hosting: NSView, under anchor: NSStatusBarButton
  ) -> CGRect {
    panel.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize == .zero
      ? CGSize(width: 320, height: 200)
      : hosting.fittingSize
    hosting.frame = CGRect(origin: .zero, size: size)

    guard let anchorWindow = anchor.window else {
      anchorMidX = size.width / 2
      return CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height + PopoverShape.arrowHeight))
    }
    let anchorFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let screen = anchorWindow.screen ?? NSScreen.main

    // Centred on the icon, so the arrow sits in the middle of the panel
    // wherever there is room for it to.
    var x = anchorFrame.midX - size.width / 2
    if let visible = screen?.visibleFrame {
      // Keep it on screen when the status item is near a corner, which is where
      // it usually is once a few other menu bar apps are installed. The arrow
      // then moves along the edge to keep pointing at the icon.
      x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
    }
    anchorMidX = anchorFrame.midX

    let height = size.height + PopoverShape.arrowHeight
    return CGRect(
      x: x, y: anchorFrame.minY - height - 2, width: size.width, height: height
    )
  }

  /// Where the icon's centre is on screen; the arrow points at it.
  private var anchorMidX: CGFloat = 0

  /// Shapes both the blur and the clip so the arrow points at the icon.
  private func applyShape(to background: NSVisualEffectView, clip: PopoverClipView) {
    let tip = PopoverShape.clampedTip(
      anchorMidX - restingFrame.minX, width: restingFrame.width, radius: Layout.radiusPanel
    )
    clip.tipX = tip
    background.maskImage = PopoverShape.maskImage(
      width: restingFrame.width, radius: Layout.radiusPanel, tipX: tip
    )
  }

  /// A rounded rectangle to shape the behind-window blur with.
  ///
  /// Stretchable rather than drawn at the panel's size: the cap insets pin the
  /// four corners and let the middle repeat, so one small image fits a panel of
  /// any height — and the height here changes with the number of displays.
  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.set()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

extension MenuBarPanelWindow: NSWindowDelegate {
  /// Borderless panels do not become key by default, and without key status
  /// there is no `resignKey` to dismiss on — which would mean a global event
  /// monitor, and a permission, for something the window server already knows.
  func windowDidResignKey(_ notification: Notification) {
    close()
    onClose()
  }
}

/// `NSPanel` refuses key status while borderless unless asked.
final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// The popover outline: a rounded body with a small arrow on its top edge that
/// points up at the status item, like a system `NSPopover`.
enum PopoverShape {
  static let arrowHeight: CGFloat = 9
  static let arrowHalfWidth: CGFloat = 11

  /// Keeps the tip clear of the rounded corners whatever the panel's position.
  static func clampedTip(_ tipX: CGFloat, width: CGFloat, radius: CGFloat) -> CGFloat {
    let lower = radius + arrowHalfWidth + 2
    let upper = width - radius - arrowHalfWidth - 2
    guard upper > lower else { return width / 2 }
    return min(max(tipX, lower), upper)
  }

  /// Path in a bottom-left origin (AppKit, unflipped) rectangle.
  static func path(in rect: CGRect, radius: CGFloat, tipX: CGFloat) -> CGPath {
    let arrowH = min(arrowHeight, max(0, rect.height - radius * 2))
    let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - arrowH)
    let r = max(0, min(radius, body.height / 2, body.width / 2))
    let tip = clampedTip(tipX, width: rect.width, radius: r) + rect.minX
    let half = arrowHalfWidth
    let p = CGMutablePath()

    p.move(to: CGPoint(x: body.minX + r, y: body.minY))
    p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
    p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
             tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
    p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
    p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
             tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)

    if arrowH > 0.5 {
      // Soft shoulders and a softly rounded tip, the way the system draws it.
      p.addLine(to: CGPoint(x: tip + half, y: body.maxY))
      p.addCurve(
        to: CGPoint(x: tip + 1.6, y: body.maxY + arrowH - 0.9),
        control1: CGPoint(x: tip + half * 0.55, y: body.maxY),
        control2: CGPoint(x: tip + 3.2, y: body.maxY + arrowH - 2.4)
      )
      p.addQuadCurve(
        to: CGPoint(x: tip - 1.6, y: body.maxY + arrowH - 0.9),
        control: CGPoint(x: tip, y: body.maxY + arrowH + 0.4)
      )
      p.addCurve(
        to: CGPoint(x: tip - half, y: body.maxY),
        control1: CGPoint(x: tip - 3.2, y: body.maxY + arrowH - 2.4),
        control2: CGPoint(x: tip - half * 0.55, y: body.maxY)
      )
    }

    p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
    p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
             tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
    p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
    p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
             tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
    p.closeSubpath()
    return p
  }

  /// Mask for the behind-window blur. Drawn at the panel's exact width with
  /// everything but one row stretch-locked, so it follows the panel's height
  /// through the unroll without being redrawn per frame.
  static func maskImage(width: CGFloat, radius: CGFloat, tipX: CGFloat) -> NSImage {
    let height = arrowHeight + radius * 2 + 1
    let size = NSSize(width: max(width, radius * 2 + 1), height: height)
    let image = NSImage(size: size, flipped: false) { rect in
      NSColor.black.set()
      let path = NSBezierPath(cgPath: path(in: rect, radius: radius, tipX: tipX))
      path.fill()
      return true
    }
    image.capInsets = NSEdgeInsets(
      top: arrowHeight + radius, left: size.width - radius - 1, bottom: radius, right: radius
    )
    image.resizingMode = .stretch
    return image
  }
}

/// Clips the panel's contents to `PopoverShape` and strokes its outline on top.
/// Reshaped in `layout()`, which runs only while the window's frame changes.
final class PopoverClipView: NSView {
  var radius: CGFloat = Layout.radiusPanel { didSet { needsLayout = true } }
  var tipX: CGFloat = 0 { didSet { needsLayout = true } }
  var borderColor: CGColor = NSColor.separatorColor.cgColor {
    didSet { borderLayer.strokeColor = borderColor }
  }

  private let maskLayer = CAShapeLayer()
  private let borderLayer = CAShapeLayer()
  private let borderView = PassthroughView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.mask = maskLayer
    borderView.wantsLayer = true
    borderLayer.fillColor = nil
    borderLayer.lineWidth = 1
    borderView.layer?.addSublayer(borderLayer)
    borderView.autoresizingMask = [.width, .height]
    addSubview(borderView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Keeps the outline above content added after it.
  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    if subview !== borderView {
      addSubview(borderView, positioned: .above, relativeTo: nil)
    }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    borderView.frame = bounds
    let shape = PopoverShape.path(in: bounds, radius: radius, tipX: tipX)
    maskLayer.frame = bounds
    maskLayer.path = shape
    borderLayer.frame = bounds
    borderLayer.path = PopoverShape.path(in: bounds.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5, tipX: tipX - 0.5)
    CATransaction.commit()
  }
}

private final class PassthroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
