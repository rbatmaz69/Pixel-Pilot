# Pixel Pilot

Brightness, contrast and volume control for external displays on macOS, over
DDC/CI. A menu bar app with its own on-screen indicator, built to cost nothing
while idle.

Requires macOS 26 (Tahoe) on Apple Silicon.

## Design goals

**Function first.** The DDC engine was built and verified against real hardware
before a single view existed. `ppctl` still exists for exactly that reason.

**Nothing runs when nothing is happening.** No repeating timers, no polling.
Displays are read once when they connect; after that the app writes but never
reads. With every surface closed, measured idle cost is 0.0 % CPU.

The accent washes behind the panels do drift, and that is the one exception —
but only while a panel is actually on screen. The animation lives in the view
hierarchy, and with the panel shut there is no hierarchy for it to live in, so
there is nothing to stop and nothing to clean up. A window that has been left
open behind other windows stops moving too.

**Apple's shapes, Material 3 Expressive's movement.** The interface uses Liquid
Glass, SF Pro, SF Rounded for figures, and a small token layer for spacing,
radii and the roles each display's accent plays. The motion is borrowed from
Android's design language: spring physics instead of easing, handles that morph
as you grab them, staggered arrivals rather than everything at once, and a
strict separation between springs that may overshoot (position, size, shape) and
springs that must not (colour, opacity).

Reduce Motion removes it all — the stagger collapses to zero, every loop is
taken out of the hierarchy rather than slowed down, and the HUD stops springing.

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
  DesignSystem/            Tokens, motion, morphing shapes, accents, components
  MenuBar/ OSD/ MainWindow/ Settings/ Input/ Model/
project.yml                Xcode project definition (the .xcodeproj is generated)
```

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
