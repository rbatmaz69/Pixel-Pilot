import AppKit
import PixelPilotCore
import SwiftUI

/// The exerciser: the only thing in this app that deliberately flashes.
///
/// **Not a `TimelineView`, and not a `CADisplayLink`.** The house rule against
/// the first is stated on `AmbientBackdrop` and `Illustrations` — a timeline
/// re-runs its body on the main actor every frame — and a display link is the
/// same cost with more bookkeeping and a teardown path to get wrong. What
/// happens instead is a discrete `CAKeyframeAnimation` handed to the render
/// server: the frames are decided once, and this actor does nothing per frame
/// for the whole ten minutes.
///
/// Wrapped as an `NSViewRepresentable` rather than built as its own window so
/// it lives inside the panel's existing hosting view, and dies with
/// `panel.contentView = nil` like everything else in this app.
struct RepairSurfaceView: NSViewRepresentable {
  let settings: DisplayHealthController.RepairSettings
  let refreshHz: Double

  func makeNSView(context: Context) -> RepairLayerView {
    let view = RepairLayerView()
    view.install(settings: settings, refreshHz: refreshHz)
    return view
  }

  func updateNSView(_ view: RepairLayerView, context: Context) {
    // Deliberately nothing. The animation is installed once and left to the
    // render server; reinstalling it on every SwiftUI update — and the
    // countdown causes one every second — would restart the cycle from its
    // first field once a second, which is a slower exercise than doing nothing.
    view.resizeIfNeeded()
  }

  static func dismantleNSView(_ view: RepairLayerView, coordinator: ()) {
    view.teardown()
  }
}

/// The layers themselves.
final class RepairLayerView: NSView {
  /// The noise fields, pre-rendered once.
  ///
  /// 480×270 and 32 of them: about 518 KB each, so ~16 MB resident for a
  /// session. Each noise cell lands as roughly an 8-point block on a 4K panel —
  /// small enough to stay visually incoherent, large enough to be affordable.
  /// Full-resolution fields would be 33 MB each and a gigabyte for the set,
  /// which is why they are not full resolution, and every physical pixel inside
  /// a block still gets the full 0→1 swing, which is the only thing that
  /// matters for exercising a cell.
  private static let fieldSize = CGSize(width: 480, height: 270)
  private static let fieldCount = 32

  private var settings: DisplayHealthController.RepairSettings?
  private var installedSize: CGSize = .zero

  override var isFlipped: Bool { true }

  func install(settings: DisplayHealthController.RepairSettings, refreshHz: Double) {
    self.settings = settings
    wantsLayer = true
    layer?.backgroundColor = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    rebuild(refreshHz: refreshHz)
  }

  func teardown() {
    layer?.sublayers?.forEach {
      $0.removeAllAnimations()
      $0.removeFromSuperlayer()
    }
    settings = nil
  }

  /// The panel is sized before this view is, so the first layout is where the
  /// regions actually get their frames.
  func resizeIfNeeded() {
    guard bounds.size != installedSize, bounds.width > 0, settings != nil else { return }
    rebuild(refreshHz: lastRefreshHz)
  }

  override func layout() {
    super.layout()
    resizeIfNeeded()
  }

  private var lastRefreshHz: Double = 60

  private func rebuild(refreshHz: Double) {
    guard let settings, bounds.width > 0, bounds.height > 0 else { return }
    lastRefreshHz = refreshHz
    installedSize = bounds.size
    layer?.sublayers?.forEach {
      $0.removeAllAnimations()
      $0.removeFromSuperlayer()
    }

    if settings.regions.isEmpty {
      switch settings.style {
      case .noise: addNoiseLayer(settings, refreshHz: refreshHz)
      case .classic: addColourLayer(bounds, phase: 0, settings: settings, refreshHz: refreshHz)
      }
    } else {
      for (index, region) in settings.regions.enumerated() {
        // Out of phase with each other on purpose. Neighbouring regions
        // flashing in lockstep would be a small local flash, which is the one
        // thing this whole design is avoiding.
        //
        // Through `MarkGeometry` rather than straight to `denormalised`, so the
        // rectangle that flashes is the rectangle the crop marks were drawn
        // around — the same function, the same units, the same result. Growing
        // it here rather than before it was handed over is what makes that
        // possible: this is the only place that knows the view's own size.
        addColourLayer(
          MarkGeometry.region(region, in: bounds.size), phase: index, settings: settings,
          refreshHz: refreshHz
        )
      }
    }
  }

  private func addColourLayer(
    _ frame: CGRect,
    phase: Int,
    settings: DisplayHealthController.RepairSettings,
    refreshHz: Double
  ) {
    let cycle = RepairPlan.sequence(for: settings.intensity)
    let colours = (0 ..< cycle.count).map { tick -> CGColor in
      let colour = RepairPlan.colour(at: tick, phase: phase, intensity: settings.intensity)
      return CGColor(srgbRed: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
    }

    let cell = CALayer()
    cell.frame = frame
    // The model value as well as the animation, the same way the noise layer
    // sets `contents` before animating it. An animation only overrides what a
    // layer already is, so without this the cell shows nothing until the first
    // field lands — and nothing at all for good if the animation is ever
    // dropped.
    cell.backgroundColor = colours.first

    let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
    animation.values = colours
    // Discrete, not interpolated: a cross-fade between two cube corners spends
    // most of its time in the middle, which is where a cell is not being worked
    // at all.
    animation.calculationMode = .discrete
    animation.duration = RepairPlan.cycleDuration(
      fields: cycle.count, refreshHz: refreshHz, intensity: settings.intensity
    )
    animation.repeatCount = .greatestFiniteMagnitude
    animation.isRemovedOnCompletion = false
    cell.add(animation, forKey: "exercise")
    layer?.addSublayer(cell)
  }

  private func addNoiseLayer(
    _ settings: DisplayHealthController.RepairSettings, refreshHz: Double
  ) {
    let noise = CALayer()
    noise.frame = bounds
    // **The single line that decides whether this feature does anything.**
    // Bilinear magnification averages neighbouring cells toward mid grey, which
    // destroys the per-pixel swing that is the entire point — the screen would
    // look busy and exercise nothing.
    noise.magnificationFilter = .nearest
    noise.minificationFilter = .nearest

    let fields = (0 ..< Self.fieldCount).compactMap { _ in
      Self.noiseField(intensity: settings.intensity)
    }
    guard !fields.isEmpty else { return }

    let animation = CAKeyframeAnimation(keyPath: "contents")
    animation.values = fields
    animation.calculationMode = .discrete
    animation.duration = RepairPlan.cycleDuration(
      fields: fields.count, refreshHz: refreshHz, intensity: settings.intensity
    )
    animation.repeatCount = .greatestFiniteMagnitude
    animation.isRemovedOnCompletion = false
    noise.contents = fields[0]
    noise.add(animation, forKey: "exercise")
    layer?.addSublayer(noise)
  }

  /// One field of independent per-cell colour.
  ///
  /// Every channel of every cell is chosen independently, so each sub-pixel
  /// spends half its time at the bottom of the span and half at the top —
  /// exactly what a whole-screen colour cycle does to it. What it does *not* do
  /// is make the screen change brightness together, because uncorrelated cells
  /// average out: the panel stays at a steady mid grey to look at while every
  /// cell in it is swinging.
  private static func noiseField(intensity: RepairPlan.Intensity) -> CGImage? {
    let width = Int(fieldSize.width)
    let height = Int(fieldSize.height)
    let low = UInt8(intensity.span.lowerBound * 255)
    let high = UInt8(intensity.span.upperBound * 255)

    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var generator = SystemRandomNumberGenerator()
    for index in stride(from: 0, to: pixels.count, by: 4) {
      pixels[index] = Bool.random(using: &generator) ? high : low
      pixels[index + 1] = Bool.random(using: &generator) ? high : low
      pixels[index + 2] = Bool.random(using: &generator) ? high : low
      pixels[index + 3] = 255
    }

    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }

    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}

/// The exerciser plus the furniture around it.
///
/// The plate is ordinary SwiftUI on top and does not flash — which is the
/// point, because it holds the way out.
struct RepairView: View {
  let settings: DisplayHealthController.RepairSettings
  let displayName: String
  /// When the session ends, or `nil` for "until I stop it". Handed over as a
  /// deadline rather than as a number of seconds so this view can keep its own
  /// clock — see `DisplayHealthController.beginRepairSession` for why the
  /// controller must not be the thing counting.
  let endsAt: Date?
  let refreshHz: Double
  let onStop: () -> Void

  /// Long enough to look away or press escape. The warning was in the sheet
  /// before any of this appeared, but a warning read a moment ago is not the
  /// same as time to act on it.
  private static let countIn = 3

  var body: some View {
    ZStack(alignment: .topLeading) {
      if countdown > 0 {
        Color.black.ignoresSafeArea()
      } else {
        RepairSurfaceView(settings: settings, refreshHz: refreshHz)
          .ignoresSafeArea()
      }

      // The same crop marks the marking overlay drew, around the same
      // rectangles, so you can see that what is flashing is what you marked.
      // Shown during the count-in as well — that is when they are legible, and
      // when knowing where to look is worth most.
      if !settings.regions.isEmpty {
        Canvas { context, size in
          for region in settings.regions {
            context.stroke(
              MarkGeometry.brackets(around: MarkGeometry.region(region, in: size)),
              with: .color(.white.opacity(0.5)),
              style: StrokeStyle(lineWidth: 1, lineCap: .butt)
            )
          }
        }
        .allowsHitTesting(false)
      }

      if countdown > 0 {
        Text("\(countdown)")
          .font(TypeScale.identityNumeral)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel("Starting in \(countdown)")
      }

      plate
        .padding(Layout.loose)
    }
    .background(Color.black)
    .task {
      // Two things at human speed, in one loop: the count-in before anything
      // flashes, and the time left afterwards. Nothing here touches the
      // animation, which is why it can tick once a second without costing the
      // exercise anything.
      while !Task.isCancelled {
        if countdown > 0 {
          try? await Task.sleep(for: .seconds(1))
          countdown -= 1
          continue
        }
        guard let endsAt else { return }
        let left = endsAt.timeIntervalSinceNow
        guard left > 0 else { return }
        secondsLeft = Int(left.rounded(.up))
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private var plate: some View {
    VStack(alignment: .leading, spacing: Layout.tight) {
      Text(displayName)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
      Text("Exercising")
        .font(TypeScale.rowTitle)

      Text(what)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

      Divider().padding(.vertical, 2)

      Text(scopeLine)
        .font(TypeScale.detail)
        .foregroundStyle(.secondary)

      if let remaining {
        Text(remaining)
          .font(TypeScale.readout)
          .contentTransition(.numericText())
      }

      HStack(spacing: Layout.snug) {
        Button("Stop", action: onStop)
          .buttonStyle(PlateButtonStyle(ink: .primary))
        Text("or esc")
          .font(TypeScale.detail)
          .foregroundStyle(.secondary)
      }
      .padding(.top, Layout.hair)
    }
    .padding(Layout.normal)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Layout.radiusCard))
    .overlay {
      RoundedRectangle(cornerRadius: Layout.radiusCard)
        .strokeBorder(.separator, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
  }

  /// The style only describes what a *whole screen* does. With marks, the
  /// screen stays dark and each spot runs the colour cube, so quoting the style
  /// here would describe something that is not happening.
  private var what: String {
    guard settings.regions.isEmpty else {
      return "Each marked spot runs through every corner of the colour cube, so every "
        + "sub-pixel under it spends half its time off and half at full."
    }
    return settings.style.summary
  }

  private var scopeLine: String {
    if settings.regions.isEmpty {
      return "The whole screen, because nothing is marked on this display."
    }
    let count = settings.regions.count
    return count == 1 ? "1 marked spot" : "\(count) marked spots"
  }

  private var remaining: String? {
    guard let secondsLeft else { return nil }
    return String(format: "%d:%02d left", secondsLeft / 60, secondsLeft % 60)
  }

  @State private var countdown = RepairView.countIn
  @State private var secondsLeft: Int?
}
