# Pixel Pilot

Brightness, contrast, colour temperature and volume control for external
displays on macOS, over DDC/CI. A menu bar app with its own on-screen
indicator, built to cost nothing while idle.

Requires macOS 26 (Tahoe) on Apple Silicon.

## Install

Download the disk image from
[the latest release](https://github.com/rbatmaz69/Pixel-Pilot/releases/latest),
open it, and drag Pixel Pilot onto the Applications folder.

The first launch is refused: macOS cannot verify the app. It is signed, but not
notarised — notarisation needs the paid Apple developer program, and this is not
in it. Open **System Settings → Privacy & Security**, find the line about Pixel
Pilot near the bottom, and press **Open Anyway**. Right-clicking the app and
choosing Open stopped being a way around this in macOS 15.

Then Pixel Pilot asks for Accessibility permission, which is what lets it act on
the brightness and volume keys — it reads them through a `CGEventTap`. There is
no Dock icon; the app is in the menu bar.

**After an update, the Accessibility permission has to be granted again.** The
released build is signed ad-hoc, so its signature changes with every release,
and macOS ties that grant to the signature rather than to the app's name or
path. Remove Pixel Pilot from System Settings → Privacy & Security →
Accessibility and add it back. See
[Code signing and the Accessibility permission](#code-signing-and-the-accessibility-permission)
for why that is, and why building it yourself does not have the problem.

To build and install from source instead, see [Building](#building) —
`Scripts/install.sh` does it in one step.

## What it does

- **Brightness, contrast and volume** per display, over DDC/CI, with software
  gamma dimming as a fallback and for going below the backlight minimum.
- **Colour temperature** per display, applied through the gamma table. See
  [Warmth, and what it costs](#warmth-and-what-it-costs).
- **A paper finish** per display — Paper, Matte or Ink — which lifts the blacks
  and brings the white down, the way a matte coating and printed ink both do.
  It cannot take a reflection off a glossy panel and says so. See
  [A finish is not a coating](#a-finish-is-not-a-coating).
- **The keyboard's brightness and volume keys**, intercepted and acted on,
  with its own indicator — macOS 26 no longer renders third-party values in
  the system one. The built-in panel included: while the app runs its keys are
  the app's, which also means macOS stops dimming it for the room. They aim at
  the screen you are working on, the one under the pointer, or **all of them at
  once**, keeping the differences you set between them.
- **Fifteen global shortcuts**, for everything the keys cannot reach: contrast,
  warmth, stepping through presets, identifying the displays, opening the panel,
  and moving every screen together whatever the key setting says.
- **Following the built-in panel**, so an external display tracks the light in
  the room. macOS already turns the ambient light sensor into a brightness on
  the Mac's own screen; reading that is a better signal than any curve this app
  could keep. The relationship is taught rather than configured — adjust the
  display by hand while it is following and it remembers that for that light
  level. See [Following](#following-the-built-in-panel).
- **Attention**, off until switched on: the screen holding the window you are
  working in stays where you set it, and the others sink back until you move to
  them. Done in the colour tables rather than the backlight, so the brightness
  slider does not move and nothing goes down the DDC bus when you change window.
  See [Attention, and why it does not fade](#attention-and-why-it-does-not-fade).
- **Test patterns** per display — solid colours for dead pixels, a grey ramp for
  banding, near-black and near-white steps for clipping, flat fields for
  backlight bleed, a one-pixel checkerboard for scaling. The app's own colour
  tables come off that display while one is up, so what you are looking at is
  the panel.
- **A health check**, which walks those patterns in order and asks one question
  of each, and **marking**: drag a box round a bad pixel while it is on screen
  and it is remembered for that monitor — as a fraction of the screen, so it
  still points at the same glass after a resolution change. A drag marks in any
  mode, because nobody drags a box meaning "next picture"; per-pixel work has
  its own mode, reachable from a button on the plate as well as `M`. The result
  is a verdict rather than a score, and it distinguishes a fault in the panel
  from how the panel behaves from a display that is simply not being driven at
  its own resolution.
- **Reanimating stuck pixels**, working the marked spots or the whole screen.
  What flashes is exactly the rectangle the crop marks were drawn around — the
  same function, the same units — and those crop marks stay on screen during the
  pass, so you can see that the spot you marked is the spot being worked.
  Full-screen defaults to colour noise rather than the flashing the repair
  websites use: every sub-pixel swings just as hard, but uncorrelated cells
  leave the screen's average brightness flat, so there is no screen-sized flash.
  The familiar cycle is still there as a choice. See
  [Reanimating is folk practice](#reanimating-is-folk-practice).
- **Scroll over the menu bar icon** to change brightness.
- **One slider for every display**, keeping the differences between them.
- **Presets** carrying brightness, contrast, warmth, finish and volume —
  including warmth and finish switched *off*, so a daytime preset can undo a
  night one rather than only replace it. Applied by
  hand, by global shortcut, by system appearance, on a schedule, or by which
  application is in front. Captured by setting the displays up rather than by
  typing numbers, and adjusted the same way: set the screens, press update. Rest
  the pointer on one and every slider shows where it would go, before it goes
  there. See [Asking before doing](#asking-before-doing).
- **A schedule** following the clock or the sun, with the day drawn as an arc
  you can point along to see what it will do at nine in the evening. A stop
  either sets a brightness and a warmth on every display or applies a preset,
  which is how it reaches one monitor and not the other.
- **Identify**, putting a number on each screen, plus a map of how they are
  arranged — which fills with each screen's own level, and can be dragged.
- **Typing an exact figure**, for the times a slider is the wrong instrument.
- **Dropping an application on the menu bar icon** to give it a preset.
- **A heads-up display you can grab**: the indicator a brightness key puts on
  screen is a slider, and pointing at it stops it counting down.
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

### Asking before doing

Two controls in this app used to do more than the surface showed. A preset was
a button you pressed to find out what it did, and a schedule was a list of
times you had to read like a timetable to know what your evening would look
like. Both are now answerable by pointing.

**Resting on a preset draws where it would go.** Every slider grows a hollow
handle at the value that preset holds for that display, with a bar spanning the
distance it would travel, and the warmth it asks for as a dot in the colour the
screen would be. Nothing is written — the preview reads the preset and draws,
so hovering the row costs no DDC traffic at all. The live figure stays where it
is and keeps telling the truth about the screen; the arrow beside it is the
only thing making a claim about the future. A display the preset says nothing
about steps back rather than announcing itself, because "not mentioned" is the
ordinary case and deserves the quietest signal there is.

The master row deliberately gets no ghost. A preset holds a value per display
and no master value, so any handle drawn there would be a number this app
invented and then did not set.

**Pointing along the day arc says what is in force at that hour.** It resolves
against the arc's own placement rather than through `DaySchedule.currentStop` —
a sunset stop is drawn at a nominal half past seven and may really fall at ten
past nine, and asking the schedule would answer about a moment other than the
one being pointed at, so the picture and the caption under it would disagree.
Pointing at a picture is a question about the picture. It wraps through
midnight, because the early hours are exactly the stretch an evening setting is
most likely to still be governing and the stretch nobody scrubs while checking
their work. `DayArcTests` pins that.

**A stop is either two numbers or a preset, never both.** A brightness and a
warmth apply to every display, which is the right shape for the ordinary case
and no shape at all for "dim the desk monitors and leave the laptop". A preset
already says something per display, so pointing a stop at one is how the
schedule reaches contrast, volume, or one screen and not the other. Both at
once was the tempting third option and would have meant a preset and a
brightness disagreeing with no rule to settle it.

Every schedule anyone has stored is in the shape from before that split, with
`brightness` and `kelvin` flat on the stop, so `ScheduleStop` decodes by hand:
try the action, fall back to the two keys. A `DaySchedule` lives inside
`GlobalSettings`, so a throw there does not lose the schedule — it loses the
theme, the key settings and everything else in the same blob.

A stop whose preset has since been deleted is **marked, not removed.** It says
so in its row and does nothing when it fires. The stop was placed by hand on the
arc; deleting somebody's work on their behalf because something else went is a
decision this app does not get to make. App rules do the opposite, and the
difference is that a rule is created by dropping an icon.

Applying a preset from a stop takes the same path as pressing its button, minus
the haptic. A tap at the wrist at ten in the evening, with nobody touching
anything, is the app claiming credit for a decision made hours ago.

It is a hover rather than a drag, and that is what makes it read as looking
rather than as editing. A drag would have to be told apart from dragging a
stop, and would fight the scroll view the card sits in; hovering has neither
problem, and asking a question by pointing at something is a lighter act than
asking by grabbing it.

### Reaching for the thing you are already looking at

**The arrangement map is also a set of levels.** Each screen fills from the
bottom with its own brightness and can be dragged. Both came out of the same
observation: the map is the only place in the app that shows the displays next
to each other in the shape they actually have, which makes it the only place
"that one is darker than the other" is something you can see rather than two
numbers you have to compare.

The drag is **relative** — a fixed 120 points of pointer travel spans the range,
whatever size the tile is. A tile is around forty points tall, so mapping the
range onto its height would make every pixel two and a half per cent and put
fine adjustment out of reach. It also means two differently sized tiles respond
identically, which is what stops the map from feeling like several controls that
happen to look alike. Four points of movement before it counts as a drag, so a
tap still selects.

**The heads-up display can be grabbed.** The indicator a brightness key puts on
screen carries a real slider, and pointing at it stops the countdown so there is
time to use it.

The slider is there from the first frame rather than appearing on hover, and
that is a correction. Revealing it on hover made the whole feature hostage to
hover detection — in a panel belonging to an app that is never active, which is
the hardest place to get hover right — and it hid the affordance: a control you
can only find by pointing at something that looks like a progress bar is a
control most people never find. Hover now does one thing, which is to hold the
HUD open.

Two AppKit facts had to be met, both following from this app never being the
active one. A tracking area is live only while its application is active unless
it asks for `.activeAlways`, and SwiftUI's `.onHover` does not ask — so the
hover it reported was a hover that never happened. And a click into a window of
an inactive app is normally spent activating it; this panel activates nothing,
so that click went nowhere and the handle moved only on the second attempt.
`OverlayPanelTests` pins both, along with the mistake underneath the first
attempt: a tracking area installed on a subview that still had a zero frame,
because the panel is not sized until later. `OSDInteractionTests` then sends
real mouse events to a real panel, because every other test here checks wiring
and none of them would notice the whole thing being assembled correctly and
still doing nothing when dragged.

Neither caught the actual fault, which is the more interesting one. What a drag
on the HUD means is a closure passed in by whoever asked for the indicator, and
that parameter had a default of `nil`. The media keys — the path that puts this
HUD on screen more often than every other caller together — quietly took the
default and produced an indicator with no handle on it, while every test passed
because each one supplied the closure the app did not. The parameter has no
default now. That is the compiler asking the question at each call site, which
is the only place that can answer it.

This is the one overlay that takes mouse events, and the cost is real and worth
stating. For the second or so the HUD is up, a click on those 210 points goes to
it rather than through it. That is the price of being able to grab the thing you
are already looking at, and it is bounded by the panel being small, short-lived
and always in the same place. The identify overlay keeps refusing mouse events
outright, because it covers whole screens — accepting them there would make
identifying the displays mean not being able to click on any of them.

**A volume key with nowhere to go now says so.** On a monitor with no DDC audio
whose digital output sits at a fixed level, pressing the volume keys used to do
nothing at all — the press was passed through and vanished. From the outside
"the app is not running", "the app ignores this key" and "the app tried and
there is no volume control here" are the same silence, and only the last one is
true. It is also every volume key press, all day.

So the indicator appears: a speaker carrying an exclamation mark, no figure, an
empty track, and one line saying why. The glyph is deliberately not the slashed
speaker that means muted — muted is a state you put something into and can take
it out of again, and this is a control that does not exist. Drawing them the
same would answer "did I just mute it?" with a shrug. There is no fill on the
track either, because a fill of any width is a reading and the point of this HUD
is that there is nothing to read.

The sentence is the short form of `DisplayViewModel.volumeUnavailableReason` and
lives beside it, so the two cannot drift into disagreeing about which of them is
true: the window gets the three sentences with the fix in them, a plate 210
points wide gets the fact.

It is shown only when the press can also be swallowed. Without that, macOS acts
on the same key and draws its own indicator, and the answer to one silent HUD
would have been two of them.

**A figure can be typed.** Click a percentage anywhere in the app and it becomes
a field, prefilled and fully selected, so the first digit replaces the figure
rather than making it ten times bigger. Return writes, Escape and clicking away
both cancel — a figure half typed and then abandoned is not a decision anyone
made. Three digits of width are reserved in both states, measured in the actual
type scale rather than in points, so the row never twitches on the way in or out.

It is a real `NSTextField` behind that, and the thing it replaced is worth
writing down: a focusable label collecting `onKeyPress`, which looked right and
was not. The label took focus, drew a system focus ring nobody asked for in a
corner radius this interface uses nowhere, and then swallowed every digit. A
text field is what macOS gives a caret, a selection and a field editor to, and
none of those are worth reimplementing badly.

The other tempting shape was letting digits typed anywhere in the panel land on
whichever card the pointer happened to be over. That needs an event monitor
rather than focus, has no visible affordance, and leaves "which card did that go
to?" a question the interface cannot answer.

**A key can decline to pick a screen.** `KeyTarget` had two cases and they were
two answers to one question — *which* display — when the common case on a desk
with three monitors is that the room got darker for all of them. The third case
is not a third answer; it says the question does not apply.

It reuses the group the panel's master slider drives rather than growing a
second copy of the same arithmetic. That group exists because moving displays
together is harder than it looks: a screen sitting 20 % below the others hits
zero first, and re-deriving the offsets from where the displays currently are
would quietly flatten the spread the moment it clamped, unrecoverably, because
nothing recorded it. `BrightnessSync` captures the offsets once and clamps only
on the way out. The first press arms it, which is also why the master row then
appears in the panel — that row is this setting, shown.

Two shortcuts move the group regardless of the setting, for "normally one
screen, but this key does all of them". With a single display there is no group,
and both fall through to the ordinary path rather than pretending.

`KeyTargetPolicy.target` still answers for this mode, and answers the same as
the focused-window one. A press that moves everything is still *drawn*
somewhere, and the screen being worked on is the one that will be looked at.
Whether the group moves is a separate property — a `target` that sometimes
returned a list would have rewritten every caller that needs exactly one.

**Every setting is in one window.** There used to be two — a "Displays" window
with the per-monitor controls and configuration, and a "Settings" window with
everything else — and no line anybody could hold in their head between them. The
brightness strategy and the DDC timing are settings by any reading; the accent
colour existed in both places at once. The proof was in the prose: the theme card
had to end a paragraph with "that one is in the Displays window", which is a
footnote apologising for the navigation.

Now the gear in the menu bar panel is the only way in, and the sidebar has two
sections: the displays that are plugged in, then the app itself. Every row
carries a line saying what is on the page — "Media keys, permissions, detection"
under Keys — so finding a setting is reading rather than opening pages to check.
A display's page keeps its sliders at the top and folds "Diagnostics", the
reported features and the DDC log, away at the bottom: worth having, not worth
its height on the way to moving a slider. The window reopens where it was left,
except when a caller knows better — dropping an application on the icon and
choosing "Open Settings…" lands on Apps, because that is the question being
asked.

**An application dropped on the menu bar icon gets a rule.** A preset chosen
from the chips that unroll, and that is the whole flow. It used to be: open
Settings, find the page, work an open panel, hunt through `/Applications`, then
choose a preset — with the application usually sitting in the Dock the whole
time.

The drop target is a view over the status item's button that forwards mouse
events rather than refusing them. Refusing them through `hitTest` would read
more tidily and would put the drop target at the mercy of how AppKit happens to
search for a dragging destination; the feature is worth less than the click it
would be gambling with. Anything that is not an application bundle is refused in
`draggingEntered`, so a folder never shows the plus sign that promises something
will happen. With no presets yet, the sheet says so and offers Settings —
`AppRuleStore.pruneMissingPresets` exists to clear up rules pointing at nothing,
and it must not be possible to make one here.

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
    Health/                Test patterns, marks, reports, the repair cycle
    System/                Preferences, diagnostics log
  Sources/ppctl/           CLI for verifying against real hardware
Sources/PixelPilot/        The app
  DesignSystem/            Tokens, motion, morphing shapes, theme, components
  AppKit/                  Window ownership; the app's shell is AppKit
  Settings/                The one settings window: sidebar, display pages, app pages
  MenuBar/ OSD/ Onboarding/ Input/ Model/
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

Cutting a release — builds ad-hoc signed, packages a disk image, tags and
publishes it. `--dry-run` stops after the disk image:

```bash
./Scripts/release.sh 0.2.0 --dry-run
```

The CLI, for checking what a monitor actually supports:

```bash
cd Packages/PixelPilotCore && swift build && ./.build/debug/ppctl probe
```

`ppctl list` reports whether the private back ends resolved, `ppctl probe` shows
which features a panel really implements, and `ppctl audio` explains which audio
route a display resolves to.

`ppctl watch-brightness` prints every change to the built-in panel's brightness.
It exists because one question could not be answered by reading code: whether
`DisplayServicesRegisterForBrightnessChangeNotifications` fires for the ambient
light sensor's own adjustments, or only for a person pressing a key. `--poll`
asks on a one-second timer instead, as the control group. It needs the built-in
display awake, so on a laptop the lid has to be open.

**It fires for both.** Verified on an M4 MacBook Air under macOS 26: covering
the sensor and waiting produces notifications with no key touched. So following
is genuinely event-driven, and the five-second timer in
`BuiltinBrightnessSource` stays what it was built as — the fallback for a
system where those symbols have gone, not the working path.

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
and the display's page says so.

The system on-screen indicator is not used. macOS 26 reworked the private OSD
interface and third-party values no longer render there; established apps show
an empty indicator on Tahoe. Pixel Pilot draws its own — which is also what
makes it something you can reach into rather than only read. See
[Reaching for the thing you are already looking
at](#reaching-for-the-thing-you-are-already-looking-at).

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

Nothing runs until a display is actually set to follow, and nothing polls once
one does — the private notification turns out to fire for the sensor's own
adjustments as well as for key presses, which is what makes this cost nothing
between changes. See `ppctl watch-brightness`, which was written to establish
exactly that.

There is no on-screen indicator when a following display moves: a HUD that
flashed every time a cloud passed the window would be the most irritating thing
this app could do.

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

## Attention, and why it does not fade

Off by default, like the schedule and like following, and for a sharper version
of the same reason: this one moves the light every time you change window.

It is a **fourth term in the gamma table**, multiplied in beside dimming, warmth
and the finish — not a second use of the dimming one. That is not tidiness.
`BrightnessController` reads `GammaDimmer.dimming(for:)` back to answer what a
gamma-dimmed display is currently set to, so a veil written there would move the
brightness slider every time you switched window, and a preset captured while a
screen happened to be unfocused would record the sunk value as that display's
brightness. Kept apart, the veil is invisible to everything that asks what a
display is set to, which is exactly what it should be.

Three things fall out of that, and they are what make it cheap enough to fire on
every window switch: no DDC round trip, no movement in any slider, and no change
to native brightness — so a display following the built-in panel does not chase
the veil around. Routing this through the backlight instead would have dimmed
every follower whenever the laptop screen lost focus.

On the built-in panel a gamma veil is a grey film over a backlight still running
at full. It costs contrast and saves no power. That is the honest trade for not
touching the value everything else reads, and the settings card says so.

**Two event sources, no timer.** `NSWorkspace.didActivateApplicationNotification`
covers moving between applications; an `AXObserver` on the frontmost process
covers moving between two windows of the same one, which on a two-monitor desk
is the ordinary case. Not `kAXWindowMovedNotification`, which fires continuously
through a drag. Not the pointer, even though the keys can be aimed that way — a
global mouse-moved monitor fires whenever the mouse moves at all, which is an
idle drain in the shape of a feature.

**It does not fade.** Animating a gamma veil means rewriting the table many
times a second, and unlike the overlays' `alphaValue` there is nothing on the
window server's side to hand the animation to. A 120 ms debounce is what stops
the step from reading as a flicker: holding ⌘-Tab settles once on the app you
landed on rather than strobing through everything you passed.

The decision itself — which display sinks, given what is known — lives in
`AttentionPlan` in the UI-free core, so the three cases that matter are tested
without Accessibility, a window server or a second monitor: **nobody focused
veils nothing** (nil is a normal answer, and veiling every screen because nobody
could be found is the failure where you cannot see what to click), **one display
veils nothing**, and a display can opt out on its own page.

## A finish is not a coating

The finish reshapes the tone curve: black lifts off zero, white comes down off
the ceiling, and a softness term moves the midtones between them. Three named
settings — Paper, Matte, Ink — with the numbers behind them available a press
away.

**What is real about it.** A matte panel scatters ambient light back into its
own black level, so its blacks sit higher and its peak white lower than a
glossy one's. Ink on paper does the same: the darkest mark is not zero and the
page is not a light source. That curve is reproducible exactly, and reproducing
it is most of what "looks like paper" means.

**What is not.** It cannot make a glossy screen matte. Gloss is the coating,
the reflection is physical, and no table on the GPU reaches it. The card in
Settings says this rather than letting the name imply otherwise.

It is a third term in the same gamma table as dimming and warmth, and it
composes with both by the same multiplication — so the order the three are asked
for makes no difference, and dimming brings the lifted black down with it rather
than leaving a floor to swamp the picture at low brightness. The identity curve
reproduces the plain scaled ramp bit for bit, which is what lets every test that
pinned the dimming behaviour keep pinning it unchanged.

It is deliberately not a warmth control. Someone who wants paper *and* warm has
both, one card apart; a finish that quietly also moved the Kelvin would be two
things on one control with the second one unlabelled.

## A checkerboard is two pixels, not four million

The one-pixel checkerboard was drawn as a `Canvas` filling one `Path` per device
pixel. On a 4K panel that is 2160 rows of 1920 squares — 4.1 million path
allocations into a display list that is then retained. It measured **1.1 GB for
a single render**, and every re-render after it (a hover, a mark, a change of
mode) added another gigabyte. It is the last pattern in the walk, so finishing a
health check and looking around was enough to take the machine to tens of
gigabytes.

It is now a 2×2 device-pixel image handed to `Image` at the display's scale and
tiled, so its natural size is one point and it repeats exactly on the pixel
grid. Sixteen bytes, and the same picture — in fact a more accurate one, because
the old loop accumulated a float and drifted. `TestPatternRenderTests` pins both
halves, because either alone is satisfied by a bug: a pattern that draws nothing
costs no memory, and a pattern that costs no memory may be drawing nothing. So
the test reads the pixels back and requires exact single-pixel alternation with
no value between black and white, *and* renders ten times at 4K and requires the
footprint not to move.

The general shape is worth remembering: in this app, anything that loops per
device pixel is a bug, and a `Canvas` display list is retained rather than
drawn and discarded.

## Panels lie

Monitors answer DDC queries for features they do not have. The Samsung U32T1
this was developed against reports a volume of 100 with a maximum of 65535
despite having no speakers, and a mute state of "muted" that is simply
uninitialised memory.

Taking those at face value produces sliders that move and do nothing. So every
panel is probed once, the answers are sanity-checked, and controls that fail the
check are not drawn at all. `ppctl probe` shows the verdict per feature, and the
display's Diagnostics fold lists the reason a control is missing.

## Reanimating is folk practice

A stuck pixel is one whose liquid crystal is not relaxing to the voltage it is
being given, so it sits lit in the wrong colour. Swinging that voltage hard
between extremes, many times a second, sometimes frees it. There is no
manufacturer behind this and no study; it works often enough to be worth ten
minutes and not often enough to promise anything. The app says so on the card,
in the sheet, and in the source, rather than letting a button called "repair"
imply otherwise.

It does nothing at all for a **dead** pixel. That is a transistor that is not
switching, and no picture on the screen reaches a transistor. Marks are
classified as stuck or dead from the pattern they were spotted on — something
lit on black is stuck, something dark on white or a primary is dead — which is
a guess rather than a diagnosis, and is why `S` and `D` are there to correct it.

**Why the full-screen pass is noise.** Cycling the whole screen red → green →
blue at speed is what the stuck-pixel websites do, and it is also a textbook
photosensitive-seizure stimulus: a large-area, high-contrast, saturated flash in
the band that matters. You cannot both swing every sub-pixel across the whole
panel and avoid a large-area flash — those are the same event described twice.
Noise resolves it. Each pixel still spends half its time at zero and half at
full on every channel, so the exercise is identical, but because neighbouring
blocks are uncorrelated the screen's average luminance stays flat and there is
no coherent flash. The classic cycle is offered, never as the default, and never
without the warning. Reduce Motion forces the gentle rate — three changes a
second, the line WCAG 2.3.1 draws — and says that it has, because half-honouring
an accessibility setting looks like a broken setting.

**Nothing runs per frame.** The flashing is a discrete `CAKeyframeAnimation`
handed to the render server: 32 noise fields rendered once at 480×270, or the
eight corners of the RGB cube per marked region with neighbours out of phase.
The one line that decides whether any of it works is
`magnificationFilter = .nearest` — bilinear would average the noise back toward
mid grey and exercise nothing. A ten-minute session holds one sleep assertion
and one sleeping task, and both are released in the same teardown that puts the
display's own colour tables back.

## Acknowledgements

The DDC/CI wire protocol implementation follows
[m1ddc](https://github.com/waydabber/m1ddc) and
[MonitorControl](https://github.com/MonitorControl/MonitorControl), both MIT
licensed.

## Licence

[Apache 2.0](LICENSE). MIT code from the two projects above remains under its
own terms; Apache 2.0 is compatible with it in this direction.
