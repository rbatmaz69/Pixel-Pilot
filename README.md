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
reads. Measured idle cost is 0.0 % CPU.

**Apple's shapes, Material 3 Expressive's movement.** The interface uses Liquid
Glass, SF Pro and macOS metrics. The motion is borrowed from Android's design
language: spring physics instead of easing, handles that morph as you grab them,
and a strict separation between springs that may overshoot (position, size,
shape) and springs that must not (colour, opacity).

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
  DesignSystem/            Motion tokens, morphing shapes, accents, slider
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
Accessibility permission. macOS ties that permission to the app's code
signature.

Without a signing identity the app is signed ad-hoc, and the signature changes
on every build — so the permission has to be granted again after each rebuild.
The fix is free and takes a minute:

1. Xcode → Settings → Accounts → add your Apple ID.
2. In `project.yml`, replace the `CODE_SIGN_*` settings with
   `CODE_SIGN_STYLE: Automatic` and `DEVELOPMENT_TEAM: <your team id>`.
3. `./Scripts/generate.sh`

No paid developer program is needed. Everything except the media keys works
without this.

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
