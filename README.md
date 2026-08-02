# Pixel Pilot

Brightness, contrast, colour temperature and volume control for external
displays on macOS, over DDC/CI. A menu bar app with its own on-screen
indicator, built to cost nothing while idle.

Requires macOS 26 (Tahoe) on Apple Silicon.

## What it does

- **Brightness, contrast and volume** per display, over DDC/CI, with software
  gamma dimming as a fallback and for going below the backlight minimum.
- **Colour temperature** per display, applied through the gamma table. See
  [Warmth, and what it costs](#warmth-and-what-it-costs).
- **The keyboard's brightness and volume keys**, intercepted and acted on,
  with its own indicator — macOS 26 no longer renders third-party values in
  the system one. The built-in panel included: while the app runs its keys are
  the app's, which also means macOS stops dimming it for the room.
- **Following the built-in panel**, so an external display tracks the light in
  the room. macOS already turns the ambient light sensor into a brightness on
  the Mac's own screen; reading that is a better signal than any curve this app
  could keep. The relationship is taught rather than configured — adjust the
  display by hand while it is following and it remembers that for that light
  level. See [Following](#following-the-built-in-panel).
- **Scroll over the menu bar icon** to change brightness.
- **One slider for every display**, keeping the differences between them.
- **Presets** carrying brightness, contrast and warmth — including warmth
  switched off, so a daytime preset can undo a night one. Applied by hand, by
  global shortcut, by system appearance, on a schedule, or by which application
  is in front. Captured by setting the displays up rather than by typing
  numbers, and adjusted the same way: set the screens, press update.
- **A schedule** following the clock or the sun.
- **Identify**, putting a number on each screen, plus a map of how they are
  arranged.
- **A colour theme** for the whole interface — window, menu bar panel, HUD and
  all — chosen from the same palette the displays use, in one of three styles:
  translucent, vivid, or flat. See [The theme](#the-theme).

## Design goals

**Function first.** The DDC engine was built and verified against real hardware
before a single view existed. `ppctl` still exists for exactly that reason.

**Nothing runs when nothing is happening.** No repeating timers, no polling.
Displays are read once when they connect; after that the app writes but never
reads. With every surface closed, measured idle cost is 0.0 % CPU.

Two things are allowed to be scheduled, and both are bounded. The accent washes
behind the panels drift, but only while a panel is actually on screen: the
animation lives in the view hierarchy, and closing a panel destroys the
hierarchy, so there is nothing to stop and nothing to clean up. A window left
open behind other windows stops moving too, and the flat style has no wash at
all — taken out of the hierarchy rather than faded to nothing, because an
invisible animation still asks for a frame.

And the day schedule sleeps until its next stop — one task, re-armed after it
fires, four to six wake-ups a day with nothing at all in between. That is not a
timer, and it is why the schedule is made of stops rather than a slow fade: a
schedule easing continuously from one value to the next would be a repeating
timer wearing a costume.

**Apple's shapes, Material 3 Expressive's movement.** The interface uses SF Pro,
SF Rounded for figures, Liquid Glass where there is something behind it to
refract, and a small token layer for spacing, radii and the roles a colour
plays. The motion is borrowed from
Android's design language: spring physics instead of easing, handles that morph
as you grab them, staggered arrivals rather than everything at once, and a
strict separation between springs that may overshoot (position, size, shape) and
springs that must not (colour, opacity).

Reduce Motion removes it all — the stagger collapses to zero, every loop is
taken out of the hierarchy rather than slowed down, and the HUD stops springing.
Haptics are deliberately *not* suppressed by it: that setting is about visible
motion, and taking away the tap as well would leave the people who asked for
less movement with the least feedback of anyone.

### The theme

Two colours and a style, chosen in Settings → General.

**Glass** is the look above: surfaces mostly drained toward white or black, real
material where there is something behind it to refract. **Vivid** is the same
eight tones mixed far less — every surface carries the colour, rims and fills
are at strength, and the material stays. **Flat** has no material, no gradients
and no drift: one flat field, and a card told apart by its edge rather than by
its depth.

A style governs **colour and material, and nothing else**. It never changes a
corner radius and never changes a spring — `Layout` stays a set of plain statics
and `Motion` is untouched — so choosing one cannot quietly move the furniture.
That boundary is kept by the type rather than by discipline: the record a style
is made of holds no `CGFloat` and no `Animation`, so there is nothing in it to
reach a radius with.

The **accent** is what a control is
at full strength — a filled track, a switch that is on, a card's edge. The
**background** is what the window field, the cards, the menu bar panel, the HUD
and the identify overlay are made of; leave it unset and it follows the accent,
which is the whole interface in one colour. They are separate because a colour
that is right for a 42 pt switch is rarely right for several hundred square
points of wall behind everything else.

There is no grey and no black-or-white state — "light" is a pale wash of the
background colour and "dark" is a deep one, and Automatic follows the system.
Each display keeps its own accent on top of all this, because that is what tells
two monitors apart.

Surface colours are derived arithmetically from the two tones rather than picked
by hand, so they can be *checked*: `ThemeTests` holds all 8 × 8 combinations, in
both modes, in all three styles — 384 themes — to WCAG contrast ratios: 7∶1 for
body text on a card, 4.5∶1 on the window field, on a card under the pointer and
on a card in the menu bar panel, and 4.5∶1 for any accent set as type on any
background. It then renders a real card in each style to confirm the pixels come
out as the colour the theme claims. That test exists because of a real bug:
cards used to draw Liquid Glass in windows, where there is nothing behind them
to refract, and it rendered as an even milky plate with unreadable labels on it.
Glass is now kept to the two overlays, which float over the desktop and do have
something to work with — and only under the styles that draw material at all.
Flat gives those overlays an opaque plate instead, for exactly the same reason
cards stopped drawing glass.

One number governs how far Vivid can go, and it is the least obvious fact in the
feature. WCAG's ratio is `(L₁+0.05)/(L₂+0.05)`, so a surface of luminance `L`
can offer at most `max(1.05/(L+0.05), (L+0.05)/0.05)` — and reaching 7∶1 needs
`L ≤ 0.10` or `L ≥ 0.30`. **Between those two figures 7∶1 is arithmetically
unreachable**, whatever colour the text is. Glass never came near that band;
putting more colour into a surface walks straight toward it. So the amounts a
style asks for are targets rather than results: each one is walked back toward
white or black until the surface is out of the band. The palette's tones do not
all have the same luminance, so Vivid comes out a shade quieter in amber than it
does in blue. That is what "the same eight tones, mixed less" has to mean once
the contrast is not negotiable, and it is done by arithmetic rather than by a
hand-tuned cap per tone — eight numbers nobody would maintain, which would break
silently the first time a tone was retuned.

One rule runs through the whole interface: **nothing that contains a slider is
ever scaled.** A `scaleEffect` changes the coordinate space a drag is mapped
into, so the handle would land somewhere other than the pointer. Hover lifts,
scroll transitions and card presses are all built from translation, shadow and
opacity for that reason.

## Layout

```
Packages/PixelPilotCore/   UI-free core, unit tested
  Sources/CDDCPrivate/     C shim over undocumented IOAVService / DisplayServices
  Sources/PixelPilotCore/
    DDC/                   Packet construction, transport, coalescing queue
    Displays/              EDID, registry, capability probing
    Control/               Brightness, gamma dimming, volume
    System/                Preferences, diagnostics log
  Sources/ppctl/           CLI for verifying against real hardware
Sources/PixelPilot/        The app
  DesignSystem/            Tokens, motion, morphing shapes, theme, components
  AppKit/                  Window ownership; the app's shell is AppKit
  MenuBar/ OSD/ MainWindow/ Settings/ Onboarding/ Input/ Model/
project.yml                Xcode project definition (the .xcodeproj is generated)
```

The shell is AppKit rather than SwiftUI's `App`. The menu bar item is a
hand-built `NSStatusItem` and `NSPanel`, because `MenuBarExtra` can neither
receive a scroll event nor let the icon be drawn — and once it is gone, no
scene is eagerly instantiated, so `openWindow` and `SettingsLink` have nothing
to bind to. Every surface inside the shell is still SwiftUI.

The property that arrangement has to keep: closing the menu bar panel drops its
hosting view, not just the window. The panel's staggered entrance is free
precisely because the hierarchy is rebuilt on every open, and the ambient drift
stops because there is nothing left for it to run in.

## Building

```bash
./Scripts/generate.sh
open PixelPilot.xcodeproj
```

Tests:

```bash
./Scripts/test.sh
```

The CLI, for checking what a monitor actually supports:

```bash
cd Packages/PixelPilotCore && swift build && ./.build/debug/ppctl probe
```

`ppctl list` reports whether the private back ends resolved, `ppctl probe` shows
which features a panel really implements, and `ppctl audio` explains which audio
route a display resolves to.

`ppctl watch-brightness` prints every change to the built-in panel's brightness,
and exists to answer the one question the follow feature rests on: whether the
ambient light sensor's own adjustments are observable, or only a person's.
`--poll` asks on a one-second timer instead, as the control group — if the poll
sees a change the notification did not, the notification is not enough. It needs
the built-in display awake, so on a laptop the lid has to be open.

**Quit BetterDisplay, MonitorControl or Lunar before testing.** They drive the
same I2C bus, and concurrent traffic produces failures that look like hardware
faults.

## Code signing and the Accessibility permission

The brightness keys are intercepted with a `CGEventTap`, which needs
Accessibility permission, and macOS ties that permission to the app's code
signature. An ad-hoc signature changes on every build, so the permission has to
be granted again each time — which makes the app unusable as a daily tool.

`project.yml` therefore sets `CODE_SIGN_STYLE: Automatic` with a
`DEVELOPMENT_TEAM`. A free Apple ID is enough; no paid developer program is
involved.

Worth knowing if you clone this on another machine: **signing in to Xcode alone
does nothing.** Xcode only issues a development certificate when a target asks
for one, so with manual ad-hoc signing the account sits there registered and the
certificate list stays empty. Setting up a new machine takes:

1. Xcode → Settings → Accounts → add the Apple ID.
2. Open the project, select the target, Signing & Capabilities → pick the Team.
3. Put that team id into `project.yml` as `DEVELOPMENT_TEAM` — `Scripts/generate.sh`
   rewrites the project from that file, so a selection made only in the UI is
   lost on the next regeneration.

`Scripts/install.sh` falls back to ad-hoc signing when no certificate exists, so
it keeps working through that setup.

To confirm the signature is actually stable, install twice and compare:

```bash
codesign -dvvv "/Applications/Pixel Pilot.app" 2>&1 | grep CDHash
```

The hash must not change between builds. That is the property the Accessibility
grant depends on — not the file path.

## Notes on the private APIs

DDC on Apple Silicon has no public API. Displays hang off the DCP coprocessor,
where the legacy `IOFramebuffer` I2C calls silently fail, and the replacement
`IOAVService*` functions are undocumented — though they are exported from IOKit
and present in the macOS 26 SDK.

Both `IOAVService*` and `DisplayServices` are resolved with `dlsym` rather than
linked. If a future macOS drops them, the app degrades to gamma dimming and says
so in the diagnostics log, instead of failing to launch.

`IOAVServiceCopyEDID` is exported but its signature is a guess, so it is
reachable only from `ppctl probe-edid`. Display identification uses the
IORegistry's `DisplayAttributes` instead, which is both documented enough and
more reliable.

`DisplayServicesRegisterForBrightnessChangeNotifications` is what lets a display
follow the built-in panel without polling for it. Its signature is undocumented,
so the handler installed on it takes five pointer-sized parameters and **reads
none of them** — on arm64 those are register slots, and an argument that is never
read cannot be misread. All the notification is used for is "something changed";
the value itself comes back through `DisplayServicesGetBrightness`, which the app
already depends on. If the symbols are missing, `BuiltinBrightnessSource` falls
back to a five-second timer that runs only while a display is actually following,
and the Displays window says so.

The system on-screen indicator is not used. macOS 26 reworked the private OSD
interface and third-party values no longer render there; established apps show
an empty indicator on Tahoe. Pixel Pilot draws its own.

## Software dimming survives a crash

Anything that dims a display owes the user a guarantee that the screen comes
back. The obvious approach — signal handlers calling
`CGDisplayRestoreColorSyncSettings` — turned out to be both unnecessary and
harmful.

Measured with `ppctl gamma 0.85 hold`, then `kill -9`, then `ppctl gamma-check`:
the table was identity again. The window server ties gamma to the client
connection that set it and reverts when that connection dies, so a crash cannot
leave the screen dark.

The handlers were removed. They called a function that is not async-signal-safe
from inside a crash, risking a hang during crash reporting, to provide a
guarantee the system already made. `atexit` is kept for the orderly-exit path.

Both commands stay in `ppctl` so the finding can be re-checked on a future macOS
rather than taken on faith.

## Finding out what a display really implements

The capability string is a self-report, and displays under-declare. `ppctl scan`
reads all 256 VCP registers and sorts them into three groups:

| | |
|---|---|
| `absent` | no reply, or the display declined the feature |
| `phantom` | a well-formed reply that cannot describe a control — 0xFFFF or 0 maximum, or current above maximum |
| `live` | a well-formed reply with a plausible range |

The middle group is the reason the command exists. A dead register still answers:
asking this panel for its speaker volume returns a correctly checksummed reply
carrying a maximum of 0xFFFF. A scan that only asked "did it respond?" would call
that a working control.

`ppctl try <vcp>` write-probes a single register and restores its value on every
path. Factory-reset codes, input source and power mode are refused outright —
that guard is in code, with a test, because a sweep of undocumented registers is
exactly how a monitor ends up reset or switched to an input that takes the
picture and the DDC channel with it.

Two things worth knowing before trusting a scan. The scan timing keeps
`writeCycles` at 2: with one cycle this panel reported 255 of 256 registers
absent, brightness included. And a register that accepts a write proves only that
it stores a value — whether anything is connected to it is a separate question,
answered by looking or listening.

### The audio verdict on the development panel

For the record, since the question keeps coming up: this display has no audio
control over DDC at all. Seven of the nine MCCS audio features are explicitly
declined; speaker volume and mute are phantoms. Scanning the alternate I2C
address 0x50 returns the identical 34 registers, so nothing is hidden there.

Its speakers and headphone jack can only be driven from its own on-screen menu.
The menu bar's volume row therefore controls the system output and offers a
device picker, which is the one thing that helps when audio is going somewhere
with a fixed level.

## Following the built-in panel

Taking over the brightness keys costs something, and the settings window has
always admitted it: while Pixel Pilot runs, macOS stops dimming the built-in
panel for the room. External displays never had that behaviour to lose — no Mac
has ever adjusted one to the ambient light.

The signal is the built-in panel, not the sensor. Going after the ambient light
sensor directly would mean a second private framework and a raw lux figure with
no mapping to a backlight; macOS already does that conversion, calibrated to the
machine and to the person's own corrections, and `DisplayServicesGetBrightness`
reads the answer.

**The mapping is taught, not configured.** An offset is wrong in a way that only
shows up in a dark room: the two panels share no backlight range, and the bottom
of the built-in one means "almost no light in here", not "turn the monitor off".
So `FollowCurve` holds two anchors and a straight line between them, and holds
rather than extrapolates outside them. Moving a following display's slider is
not treated as a conflict to correct — it is the only reliable statement of
intent the app ever gets, made while the person can see both the room and the
screen, so it becomes an anchor. Dim it once in a dark room and once in a bright
one and the curve is complete. A minimum separation of a tenth of the range
keeps the line from going vertical, where a flicker of the sensor would swing
the monitor end to end.

Presets and the schedule still win the moment they are applied, and hold until
the room next changes. They teach nothing, because a preset is a statement about
now rather than about the light.

Nothing runs until a display is actually set to follow, and there is no
on-screen indicator when one moves: a HUD that flashed every time a cloud passed
the window would be the most irritating thing this app could do.

## Warmth, and what it costs

Colour temperature goes through the gamma table, even on panels that expose
VCP 0x0C. Those implement it as the four or five coarse presets their own menu
offers, and one slider meaning "continuous" on one monitor and "four steps" on
another is worse than a mechanism that behaves the same everywhere. The probe
still runs, and the colour card reports what your panel really has.

Two properties of the maths, both tested across the range. No channel ever
exceeds unity — a component above 1 asks the panel for output it cannot make,
and the hardware answers by flattening the highlights. And some channel is
always at full, by normalising to the peak rather than to 255, so warming does
not double as an unlabelled second brightness control. Warmth and dimming
compose by multiplication, so the order they are asked for makes no difference.

**Night Shift writes the same table.** There is no public way to ask whether it
is running — `CBBlueLightClient` is private and is not used here — so the app
counts how often its own tables are reset in a burst and says what it sees. It
cannot win that fight, and it does not pretend to.

## Panels lie

Monitors answer DDC queries for features they do not have. The Samsung U32T1
this was developed against reports a volume of 100 with a maximum of 65535
despite having no speakers, and a mute state of "muted" that is simply
uninitialised memory.

Taking those at face value produces sliders that move and do nothing. So every
panel is probed once, the answers are sanity-checked, and controls that fail the
check are not drawn at all. `ppctl probe` shows the verdict per feature, and the
main window lists the reason a control is missing.

## Acknowledgements

The DDC/CI wire protocol implementation follows
[m1ddc](https://github.com/waydabber/m1ddc) and
[MonitorControl](https://github.com/MonitorControl/MonitorControl), both MIT
licensed.
