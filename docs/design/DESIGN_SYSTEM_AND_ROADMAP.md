# Pixel Pilot — „Warm Studio Craft × Native macOS HIG“ Design-Referenz & Roadmap

> **Zweck dieses Dokuments:** Vollständige, kontextunabhängige Design- und Architektur-Referenz für das **„Warm Studio Craft“**-Redesign von Pixel Pilot. Selbst wenn eine neue Chat-Session gestartet wird, enthält dieses Verzeichnis (`docs/design/`) sämtliche interaktiven Mockups, Farb-/Geometrie-Tokens, Architektur-Invarianten und die Zuordnung zu allen GitHub-Meilensteinen (`M1–M5`) und Issues (`#2–#17`).

---

## 1. Dateien in `docs/design/`

- **[`warm-studio-craft-mockup.html`](./warm-studio-craft-mockup.html)** — Vollständiger, interaktiver HTML/CSS/JS-Prototyp aller Oberflächen (Menüleisten-Popover, horizontales Control-Center-HUD, Einstellungsfenster mit allen 10 Tabs, Top-Down Modal Sheets, 4-schrittiges Onboarding sowie Vollbild-Overlays für Identify, 11 Testmuster und Pixel-Massage).
- **[`DESIGN_SYSTEM_AND_ROADMAP.md`](./DESIGN_SYSTEM_AND_ROADMAP.md)** — Dieses Referenzdokument mit allen Tokens, Richtlinien und der Issue-Roadmap.

---

## 2. Leitbild: „Warm Studio Craft × Native macOS HIG“

Pixel Pilot verbindet **100 % treue Apple Human Interface Guidelines (HIG)** in Geometrie, Ergonomie und Fenster-Physik mit der **warmen, haptischen Seele analoger Studio- und Kamera-Hardware** (inspiriert von Dieter Rams / Braun, Leica-Objektiven und Indie-Mac-Klassikern wie *Things 3* oder *Alcove*).

### Die 5 tragenden Design-Säulen

1. **Warm Studio Paper (Light) & Dark Walnut (Dark) statt sterilem Grau**
   - Ablösung des alten getönten Rezepts (`Glass / Vivid / Flat` + schwebende `AmbientBackdrop`-Blobs).
   - **Light Mode (*Warm Studio Paper / Parchment*)**: Elfenbeinfarbener Fensterhintergrund (`#F5F1E9`), cremeweiße Formulargruppen (`#FFFDF9`) mit feiner warmer Rahmenlinie (`rgba(48, 36, 24, 0.11)`), `1px` hellem Specular-Innenrand und kontrastreicher Espresso-Tinte (`#201D1A`).
   - **Dark Mode (*Warm Obsidian & Dark Walnut*)**: Tiefes, warmes Graphit-Walnuss (`#1B1816`), Karten in `rgba(255, 248, 238, 0.055)` mit warmem `1px` Specular-Oberkantenlicht (`rgba(255, 248, 238, 0.07)`) und Creme-Weiß-Text (`#FAF6F0`).
   - **Liquid Glass Opacity (`glassOpacity`)**: Einstellbar von `55 %` bis `98 %` (Standard `82 %`) für Popover, Sidebar und HUD.
   - **Tageszeit-Ambient-Tint (`4–6 %`)**: Sanfter Kopfbereichs-Schimmer auf Glasflächen passend zur Tageszeit (*Morgenlicht*, *Goldener Nachmittag*, *Abend/Kerzenlicht*) – rein on-demand beim Öffnen berechnet (keine Hintergrund-Timer).

2. **Lebendige Mini-Monitore mit echtem macOS-Wallpaper & Live Backlight Bleed**
   - Physische Silhouetten in der `DisplayMap` („Dein Schreibtisch“) und auf der neuen **Live Studio-Monitor Hero-Card** in `DisplayPage.swift`:
     - MacBook-Display mit feiner Kamera-Notch und Aluminium-Unibody-Lippe.
     - Externe Monitore mit schlankem Rahmen, Standfuß-Hals und Standfuß-Basis.
   - **Echtes Wallpaper**: Gecachtes Thumbnail via `NSWorkspace.shared.desktopImageURL(for:)` mit Echtzeit-Simulation von Helligkeit, Kontrast, Farbtemperatur (`Kelvin`) und `Paper Finish` (`Off / Paper / Matte / Ink`).
   - **Live Backlight Bleed**: Ein weicher radialer Lichtkegel auf der virtuellen Studio-Wand hinter dem Monitor, dessen Leuchtkraft und Farbtemperatur live auf die Regler reagieren.

3. **Taktile Analoge Hardware-Details (`ExpressiveSlider` & `AccentDot`)**
   - **Control Center Pill Slider (`26pt` Standard / `22pt` kompakt)**:
     - Im Light Mode eine klar abgedunkelte warme Rinne (`rgba(48, 36, 24, 0.14)`), damit sich der helle Elfenbein-/Weiß-Füllbalken (`#FFFDF9` → `#FFFFFF`) gestochen scharf abhebt.
     - **Leica-Skalen-Gravur (`.cc-scale-ticks`)**: Feine Teilstriche im Track, die bei Hover/Drag warm aufleuchten (`opacity: 0.25 → 0.75`).
     - **Magnetische Detents bei `25 %`, `50 %`, `75 %`** mit kurzem Aufleuchten und Trackpad-Haptik (`NSHapticFeedbackManager`).
     - **Mitdrehende Sonne**: Das eingebettete `sun.max.fill`-Symbol dreht sich beim Ziehen sanft mit (`0° ... 180°`).
   - **Warme analoge Glas-LEDs (`AccentDot`)**: Sanft glimmende Status-Leuchtdioden mit äußerem Halo und innerem Glanzpunkt statt flacher Kreise.

4. **Persönlicher Schreibtisch-Begleiter & Stimmungs-Szenen**
   - **Companion-Header im Menüleisten-Popover**: Begrüßt den Nutzer nach Tageszeit (*„Guten Morgen im Studio“*, *„Goldener Nachmittag“*, *„Gemütlicher Feierabend“*) samt Sonnen-/Mond-Badge und Schnellzugriff auf die aktuelle Farbtemperatur.
   - **Atmosphärische Licht-Szenen-Karten (Presets)**: Mit dezentem Stimmungs-Verlauf und **Live-Ghost-Preview-Brücke** auf den Monitor-Slidern beim Überfahren mit der Maus.
   - **„In Bestform“ Panel-Fürsorge-Siegel**: Beruhigendes Pflege-Badge in `HealthSection.swift`.

5. **Interaktiver „Tageshorizont“ (`DayArc` Panorama) in `ScheduleSettings.swift`**
   - Geschichtete Hügellandschaft mit dynamischem Himmelsverlauf (Nacht-Indigo, Morgenrot/Goldene Stunde, Atelier-Blau) und leuchtendem Sonnen-/Mond-Orb, der beim Überfahren mit der Maus (`Time Scrubbing`) entlang des Bogens gleitet.

---

## 3. Strikte Apple HIG Geometrie & Motion-Spezifikation

### Corner-Radii & Konzentrizität (`Theme.swift` → `Layout`)

| Oberfläche / Element | Radius (`pt`) | Token in `Layout` | Anmerkung |
| :--- | :--- | :--- | :--- |
| Standard-Fenster (`NSWindow`) | `12pt` | `radiusWindow = 12` | Kontinuierliche Kurve (`.continuous`) |
| Menüleisten-Popover & OSD-HUD-Pille | `14pt` | `radiusPanel = 14` | Äußerer Glas-Container |
| Konzentrische Control-Center-Module & `Form(.grouped)`-Gruppen | `10pt` | `radiusCard = 10` / `radiusHero = 10` | `r_inner = 14pt - 4pt padding = 10pt` |
| Push-Buttons (`NSButton`), Textfelder, Popups, Sidebar-Zeilen | `6pt` | `radiusControl = 6` | Keinerlei Schrumpfen (`scaleEffect`) beim Klick |
| Aktives Innensegment in `SegmentedMorphPicker` | `5pt` | `radiusSegment = 5` | Innerhalb einer `6pt`-Wanne mit `2pt` Padding |

### Motion & Interaktions-Physik (`Motion.swift`)

- **Sofortiger Button-Press (`0ms`)**: Push-Buttons (`SoftButtonStyle`) wechseln bei `configuration.isPressed` verzögerungsfrei ihre Helligkeit/Füllung wie ein nativer `NSButton` – **kein** `scaleEffect(0.94)`.
- **Kritisch gedämpfte Kurven ohne Toy-Bounce**:
  - `fastSpring`: `duration: 0.14, bounce: 0.0`
  - `expressiveSpring`: `duration: 0.18, bounce: 0.0`
  - `slowSpring`: `duration: 0.22, bounce: 0.0` (analog `cubic-bezier(0.2, 0.9, 0.25, 1)`)
  - `unfoldSpring`: `response: 0.18, dampingFraction: 0.96`
- **Keine Zahlen-Stauchung & kein Stagger-Wasserfall**: `SquashOnChange` nutzt nur noch `.contentTransition(.numericText())` ohne `scaleEffect`; `entrance(index:)` verzögert das Erscheinen von Einstellungsseiten nicht mehr.

---

## 4. Unverhandelbare Architektur-Invariante: `0.0% CPU while idle`

1. **Deterministischer View-Teardown**:
   - `MenuBarPanelWindow.close()`, `OSDController.teardown()` und `WindowCoordinator.windowWillClose(_:)` setzen `contentView = nil`, sobald die Oberfläche geschlossen ist.
2. **Keine Hintergrund-Timer für UI-Effekte**:
   - Der Tageszeit-Ambient-Tint, der Companion-Header und das `DayArc`-Horizont-Panorama werden rein ereignisgesteuert (beim Öffnen bzw. bei Mausbewegung) berechnet.
3. **Wallpaper-Thumbnail-Caching**:
   - Das macOS-Hintergrundbild für die Mini-Monitore (`DisplayMap` & `DisplayPage`) wird pro `NSScreen` einmalig als kleines Thumbnail gecacht und nur bei `NSWorkspace.activeSpaceDidChangeNotification` / Display-Änderung invalidiert.

---

## 5. GitHub Meilensteine & Issues (Implementierungs-Reihenfolge)

### [M1: Design System Foundation — Warm Studio Craft & Apple HIG](https://github.com/rbatmaz69/Pixel-Pilot/milestone/1)
- **[Issue #2](https://github.com/rbatmaz69/Pixel-Pilot/issues/2)**: `[Design System]` Warm Studio Paper & Dark Walnut Farbpalette + Liquid Glass Opacity in `AppTheme.swift` & `Preferences.swift`
- **[Issue #3](https://github.com/rbatmaz69/Pixel-Pilot/issues/3)**: `[Design System]` Strikte Apple HIG Corner-Radii (`12/14/10/6/5pt`) & Typografie-Hierarchie in `Theme.swift`
- **[Issue #4](https://github.com/rbatmaz69/Pixel-Pilot/issues/4)**: `[Motion]` Kritisch gedämpfte macOS-Animationen & `0ms` NSButton-Press-Physik in `Motion.swift`
- **[Issue #5](https://github.com/rbatmaz69/Pixel-Pilot/issues/5)**: `[Design System]` Ablösung der `AmbientBackdrop`-Blobs & Einführung von Tageszeit-Ambient-Tint

### [M2: Tactile Analog Hardware Controls & Core Components](https://github.com/rbatmaz69/Pixel-Pilot/milestone/2)
- **[Issue #6](https://github.com/rbatmaz69/Pixel-Pilot/issues/6)**: `[Controls]` Taktiler Control-Center-Pill-Slider mit Leica-Skalengravur, `25/50/75%`-Detents & rotierender Sonne (`ExpressiveSlider.swift`)
- **[Issue #7](https://github.com/rbatmaz69/Pixel-Pilot/issues/7)**: `[Components]` Native macOS `Form(.grouped)`-Container (`10pt`) mit `1px` Specular Rim & `6pt` Push-Buttons (`Components.swift`, `Controls.swift`)
- **[Issue #8](https://github.com/rbatmaz69/Pixel-Pilot/issues/8)**: `[Components]` Warme analoge Glas-LED-Indikatoren (`AccentDot`) & `NSSwitch` / `SegmentedControl` (`6pt/5pt`)

### [M3: Menu Bar Popover & Interactive Horizontal HUD Pill](https://github.com/rbatmaz69/Pixel-Pilot/milestone/3)
- **[Issue #9](https://github.com/rbatmaz69/Pixel-Pilot/issues/9)**: `[Menu Bar]` Persönlicher Tageszeit-Companion-Header, `14pt/10pt` Control-Center-Module & Popover-Unfold (`MenuBarPanel.swift`, `MenuBarPanelWindow.swift`)
- **[Issue #10](https://github.com/rbatmaz69/Pixel-Pilot/issues/10)**: `[Menu Bar]` Atmosphärische Licht-Szenen-Karten (Presets) mit Live-Ghost-Preview-Brücke auf den Slidern
- **[Issue #11](https://github.com/rbatmaz69/Pixel-Pilot/issues/11)**: `[OSD / HUD]` Umbau von `OSDView.swift` zur kompakten horizontalen Control-Center-Pill (`296pt`) mit Maus-Scrubbing

### [M4: Settings Window, Living Mini-Monitors & Display Studio Hero](https://github.com/rbatmaz69/Pixel-Pilot/milestone/4)
- **[Issue #12](https://github.com/rbatmaz69/Pixel-Pilot/issues/12)**: `[Settings & DisplayMap]` Full-Height macOS Sidebar (`6pt` Rows) & `DisplayMap.swift` mit physischen Monitor-Silhouetten
- **[Issue #13](https://github.com/rbatmaz69/Pixel-Pilot/issues/13)**: `[DisplayPage]` Live Studio-Monitor Hero-Card mit echtem macOS-Wallpaper, Backlight-Bleed & Paper-Finish (`DisplayPage.swift`)
- **[Issue #14](https://github.com/rbatmaz69/Pixel-Pilot/issues/14)**: `[DisplayPage & Health]` „In Bestform“ Panel-Fürsorge-Siegel, Farb-/Konfigurations-Gruppen & VCP-Diagnose (`HealthSection.swift`, `ColorSection.swift`)

### [M5: Tageshorizont (DayArc), Detail-Tabs, Sheets, Overlays & Tests](https://github.com/rbatmaz69/Pixel-Pilot/milestone/5)
- **[Issue #15](https://github.com/rbatmaz69/Pixel-Pilot/issues/15)**: `[Schedule]` „Tageshorizont“ (`DayArc`) als interaktives Horizont-Panorama mit Hügellandschaft & Sonnen-/Mond-Orb (`ScheduleSettings.swift`)
- **[Issue #16](https://github.com/rbatmaz69/Pixel-Pilot/issues/16)**: `[Settings & Sheets]` Licht-Szenen, App-Begleiter, 15 Kurzbefehle, Tasten/Fokus, Updates & Top-Down Sheets
- **[Issue #17](https://github.com/rbatmaz69/Pixel-Pilot/issues/17)**: `[Onboarding & Overlays]` Warm Studio Willkommens-Tour (`OnboardingSteps.swift`), Vollbild-Overlays & Swift-6-Unit-Test-Suite (`ThemeTests.swift`, `PanelPresentationTests.swift`)
