# Melo 2.8.3 — Full Audit & Path to "Apple Made This"

Audited: 190 Swift files, ~41,400 LOC, plus build scripts, entitlements, crash log, and the 2.8.3 verification scripts.
Date: August 4, 2026

---

## 0. Verdict in one line

The bones are better than most shipping Mac apps — the design-token layer, the haptics engine, the arm64 build script, and the AI-theme schema clamps are all genuinely well-built. What separates Melo from "Apple made this" is not ambition; it's **consistency, accessibility, and the ship pipeline**. Three things would currently stop it from being a real product: it **cannot launch outside the custom build script**, it is **unusable with VoiceOver**, and the **only working update channel is a remote-code-execution vector**.

---

## 1. MUST FIX — blockers

### Build & ship
- **The Xcode project has no Embed Frameworks phase.** `project.pbxproj:424` links Sparkle; `:651` lists only `(Sources, Frameworks, Resources)`. Any build not run through `scripts/build-app.sh` produces a bundle that dies at launch with `Library not loaded: @rpath/Sparkle.framework`. **This is exactly what your `Melo-latest-crash.ips` is** — `EXC_CRASH/SIGABRT`, `"namespace":"DYLD"`, `dyld4::halt`, zero Melo frames. It is not a code bug. Add a `PBXCopyFilesBuildPhase` (`dstSubfolderSpec = 10`, `CodeSignOnCopy`).
- **The developer-update path is remote code execution.** `DeveloperUpdateManager.swift:66` takes a pasted URL, downloads a zip, and `UpdateBuildCoordinator.swift:35-45` runs `Build Melo.command` from *inside the downloaded archive* via `/bin/bash`. The only check is `codesign --verify` with no `-R` requirement — an ad-hoc-signed attacker bundle passes trivially. Delete the `.source` path from shipping builds; require a pinned EdDSA signature + `spctl --assess`.
- **Sparkle is inert.** `SUFeedURL` and `SUPublicEDKey` are empty in `Info.plist`, so `SparkleUpdateController.swift:33` never starts the updater. There is currently no signed, resumable update channel at all.
- **No Hardened Runtime, no notarization, ad-hoc `codesign --deep`** (Apple explicitly documents `--deep` as unsupported). `Melo.local.entitlements` disables library validation only because Sparkle is unsigned. Bundle ID is the placeholder `dev.local.Melo`, which will break Sparkle, App Intents donation, and notarization.
- **No tests, no CI.** `scripts/test.sh` runs eight Python scripts that are `if needle not in text: fail` grep checks. No `Tests/` target, no `.github/`. The biquad math, crossfade state machine, settings migration, and archive validator are all pure logic and trivially testable.

### Accessibility
- **VoiceOver cannot set volume.** `LiquidGlassSlider.swift` has zero accessibility modifiers, and it backs every volume control (`DeviceRow:209`, `AppRowControls:94`, `InputDeviceRow:114`, `TahoeStyleHUD:91`). App-wide: **0 `accessibilityAdjustableAction`, 2 `accessibilityValue`, 44 labels across 121 interactive control sites (~36%). 22 files in the popup surface have none at all.**
- **Full Keyboard Access is broken in the popup.** `MenuBarPopupView.swift:298` calls `.focusEffectDisabled()` globally and `:1919` hijacks Tab for the Input/Output swap. There is no focus ring; keyboard selection renders identically to mouse hover.
- **`TahoeStyleHUD.swift:132`** uses `.accessibilityElement(children: .ignore)`, erasing the interactive slider inside the HUD.

### Real-time audio safety
- **Weak-self load inside the HAL IOProc.** `ProcessTapController.swift:916` (also `:1332`, `:1538`) does `guard let self` on a `[weak self]` capture — that's a side-table spinlock + atomic retain on the real-time thread, which the file's own header comment forbids. Priority inversion here = clicks and pops.
- **`:2113-2122`** reads strong class refs (`eqProcessor`, `autoEQProcessor`, …) per buffer → retain/release per callback; these are overwritten non-atomically from the main actor at `:1400`, with a `0.5s asyncAfter` sleep as the only lifetime guarantee. The `RealtimeAudioUnitChainSlot` class already in the tree is the correct pattern — use it everywhere.

---

## 2. SHOULD FIX — the "premium" gap

### Design system
- **No type scale.** `Typography` defines 11 tokens, used 52 times, against **260 raw `.system(size:)` calls in 21 distinct sizes** (7, 8, 9, 10, 10.5, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 23, 24, 25, 28, 44). `EverydayTab.swift` alone has 42 distinct font declarations. Collapse to 7 steps backed by system text styles.
- **13 corner radii for 3 tokens** (0.5, 2, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14 in the wild, 68 literal sites). `Dimensions.cornerRadius` is referenced *only in previews*.
- **100 of 125 `RoundedRectangle`s use circular, not continuous corners** — including both HUDs at r=16/22 sitting next to the system HUD, and every row/button background. Make the tokens *shapes*, not numbers, so `.continuous` can't be forgotten.
- **Non-concentric nesting.** `MenuBarPopupView.swift:502` — the header uses a fixed r=16 while its inset varies 12/16/20 by size preference, so it's wrong at all three sizes and differently wrong at each; the window corner (~11) is *smaller* than the header's, which reads as a sticker.
- **Four of six themes paint over the material they sit on** (`.space` 0.97/0.92/0.94, `.galaxy`, `.aurora`, `.aiGenerated` 0.98). You pay for behind-window vibrancy and ship a painted panel. Drop backdrop alphas to ≤0.72 or skip the effect view entirely.
- **AI themes can produce unreadable UI.** `SettingsUITypes.swift:143` clamps density and validates hex *format* but never luminance, while `.aiGenerated` forces dark appearance (white text). A light background hex = white on white. Add a relative-luminance clamp.
- **23 distinct padding values, 20 distinct spacings** against a 7-step scale; 3 different theme-tile styles in one pane; 3 spellings of "accent"; SF Rounded used in 6 files with no rule (EverydayTab headers are Rounded, GeneralTab's are not — adjacent tabs disagree on typeface).
- **Menu-bar glyph strokes at 2.4pt** on an 18pt canvas (`MenuBarIconImage+NSImage.swift:83`); SF Symbols at that size stroke ~1.6–1.8pt, so Melo reads heavier than every neighbour. No `SymbolConfiguration` is applied.

### Interaction
- **Volume slider hit target is 10pt tall** (`LiquidGlassSlider.swift:178`); `minTouchTarget` token is 16 (`DesignTokens.swift:438`) against a 28pt HIG minimum.
- **No fine-adjust modifier anywhere**, and `MenuBarPopupView.swift:1971` makes Shift *coarsen* — the inverse of the macOS convention. ⌥ / ⇧⌥ should give quarter steps on arrows, scroll, and drag.
- **Command palette shows a ⏎ glyph on every row but has no keyboard activation** (`ConsumerCommandPalette.swift:130`) — no selection index, no `onSubmit`. `AutoEQSearchPanel.swift:137` already does it right.
- **Dropdowns and device pickers have zero keyboard support** — no arrows, Return, type-select, or default focus. Every native macOS menu has all four.
- **The volume HUD never appears in fullscreen** (`HUDWindowController.swift:77`) — but the media-key monitor has already swallowed the key, so watching a fullscreen video gives no feedback at all. It also always targets `NSScreen.main` and never observes screen-parameter changes.
- **~22 animations bypass the token layer** and ignore Reduce Motion, including the tour pointer's `repeatForever` at `GuidedTourOverlay.swift:164`. And `DesignTokens.Animation.isReduced` reads `NSWorkspace` statically rather than via `@Environment`, so flipping the setting mid-session doesn't invalidate views.
- **`Haptics.step()` and `.commit()` are defined but never called** — arrow-key volume, boost chevrons, mode toggle, and preset apply are all silent. Only slider detents fire.

### Onboarding
- **The guided-tour callout uses a hardcoded `cardHeight: 188`** (`GuidedTourOverlay.swift:177`) against a content-sized card. Any step wrapping past ~3 lines pushes Back/Next off the bottom and gets clipped. **This is the clipping you saw in your screenshot.**
- **On the "Keep quiet apps visible?" modal: it is not in the 2.8.3 source.** It was removed after 2.6 and the verification scripts now *assert its absence* (`verify-2.8.3-refinement.py:37`). Default is `.never` in three places and back-filled on migration. Your screenshot is from an older binary — confirm the tester's `CFBundleVersion` is `283`.
- **The tour blocks the controls it points at.** `GuidedTourOverlay.swift:84` dims with `allowsHitTesting(true)`; the spotlight is `blendMode(.destinationOut)`, a visual hole only. It tells; it never lets you try.
- **Notification permission is requested cold at launch** (`FineTuneApp.swift:312`), ~0.5s before the welcome window, for a feature the user hasn't met.
- **Closing the welcome window with the red X replays onboarding forever** — completion is only written by Skip/Show Me Around (`OnboardingWindowController.swift:50` is `.closable` with no delegate).
- **First-run intro sound auto-plays** on page 2 at system volume while the copy is still being read, even though a "Play Melo Sound" button exists.
- **Permission copy leaks plumbing:** "event tap", "main-thread stall" (`MediaKeyOfflineCard.swift:29`), "system-audio engine" (`PermissionBannerView.swift:79`), "intercept F10/F11/F12" (`AccessibilityPromptStrip.swift:88`).

### Performance
- **`MenuBarIconCoordinator.swift:172`** — a 0.16s repeating main-thread timer starts unconditionally and only checks whether it's needed *inside* the callback. Default style doesn't need it: ~6 wakeups/sec forever, doing nothing.
- **`CallDuckingManager.swift:44`** — a 250ms `@MainActor` loop started at launch, running even when the feature is off.
- **`AppRowWithLevelPolling.swift:170`** — one 30Hz timer *per app row*; 8 audible apps = 240 main-thread wakeups/sec.
- **`MeloVisualTheme.swift:242`** — a 24fps `TimelineView` with no `paused:` argument; and no backdrop pauses when the popup is closed, even though `isPopupVisible` is already tracked.
- **`SettingsManager.scheduleSave()`** JSON-encodes the entire settings blob (every app volume, EQ curve, preset, theme) **on the main actor** on every debounced mutation; `flushSync()` blocks main at termination. Corrupt data silently resets everything to defaults with no user notice.
- **`FineTuneApp.init()` (lines 139–349) is the whole app bootstrap** — audio engine, `CGEventTap`, hotkeys, observers, five async blocks — inside a SwiftUI `App` struct initializer, which carries no once-only guarantee. Move to `applicationDidFinishLaunching`. It also contains three `as! DeviceVolumeMonitor` forced downcasts and a force-unwrapped SF Symbol lookup.

### Features, IA & copy
- **Eight settings tabs, ~60 controls, no search, no sidebar.** Apple has used `NavigationSplitView` since Ventura and ships search in every first-party settings window. Melo's only `.searchable` is in the Audio Unit browser.
- **The Guide tab is a settings search index wired to the wrong surface.** `SettingsGuide.swift` is a 74-entry scored catalog of every setting — with aliases. Make it the search index; delete the tab.
- **Ship the developer-update UI to nobody.** "Choose Update File…", "Inspect Link", "Build and Install", "Show Build Log", and a warning that updates "run Xcode build scripts" are all consumer-facing today.
- **Theme Studio is a ChatGPT clipboard pipeline in General** — copy prompt → open ChatGPT → paste JSON into a monospaced `TextEditor` → apply. Cut it or bury it; the raw JSON editor should never be visible.
- **Effects (Audio Units) is pro plumbing** — per-app plug-in chains, manufacturer/subtype strings, raw error alerts. Melo's own guide says it's "intended for people who already use Audio Unit effects."
- **"Everyday" is a junk drawer** (Scenes, Compare, Automations, Focus, Sleep Timer, Recent Changes, Audio Help — the last two are troubleshooting, including a 10pt monospace diagnostic dump).
- **Four settings that should just be defaults:** Process Only When Needed, Reduce Processing on Battery, Pause on Headphone Disconnect, Loudness Compensation.
- **Zero localization.** No `NSLocalizedString`, no String Catalog, in 190 files. Plurals are hand-rolled (`scene.appCount == 1 ? "1 app" : "\(count) apps"`). It cannot ship in a second language without touching every call site.
- **One feature, four names:** "Melo AI Auto EQ" / "Smart Sound" / "Melo AI Audio" / "sound shaping". Same for Scene / setup / preset / "remembered sound".
- **Legacy naming leaks:** About links to `github.com/ronitsingh10/FineTune`, the asset catalog still has `fineTuneIcon.appiconset`, and HUD previews ship "Ronit's AirPods Pro". GPL attribution is required but belongs in an Acknowledgements sheet.

### Copy — worst offenders

| file:line | Current | Rewrite |
|---|---|---|
| GeneralTab.swift:69 | "Could Not Complete That" | "Melo couldn't save the backup." |
| GeneralTab.swift:291 | "That file is not a valid Melo settings backup." | "This file isn't a Melo settings backup." |
| AudioUnitsTab.swift:68 | "Unknown Audio Unit error" | "This plug-in couldn't be loaded." |
| EverydayTab.swift:370 | "Made a mistake?" | "Recent changes" |
| EverydayTab.swift:414 | "Sound not behaving correctly?" | "Audio isn't working" |
| GeneralTab.swift:199 | "Create an AI-readable report…" | "Includes logs, crash details, and a summary of your settings." |
| AudioTab.swift:240 | "Balanced Volume and Fuller Sound" | "Sound Check — keep apps at a similar volume" |
| AudioTab.swift:145 | "…normal audio path to reduce the purple macOS indicator" | "Apps you haven't adjusted stay on the system audio path." |
| MediaKeyOfflineCard.swift:29 | "The system disabled Melo's event tap — usually after a sleep/wake cycle or a main-thread stall." | "macOS turned off Melo's volume keys after your Mac woke up." |
| UpdatesTab.swift:229 | "Developer update could not be completed" | "The update couldn't be installed." |
| UpdatesTab.swift:121 | "Inspect Link" | "Check Link" |
| MenuBarPopupView.swift:490 | "Set device priority" | "Drag to reorder devices" |
| EverydayTab.swift:163 | "Use This Scene" | "Apply" |
| AutoEQSearchPanel.swift:221 | "Loading profile..." | "Loading profile…" (U+2026; 3 sites use ASCII) |
| SmartAutoEQControl.swift:32 | "Melo AI Auto EQ" | "Smart Sound" (pick one name, use it everywhere) |

---

## 3. SHOULD ADD

- **Settings search** (index already exists in `SettingsGuide.swift`).
- **Now Playing integration** — no `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` anywhere.
- **iCloud sync of Scenes and EQ presets** — currently manual JSON export.
- **App Intents coverage:** only 5 intents exist. Missing: switch output device, apply EQ preset, apply headphone profile, set system volume, mute all.
- **Native Focus filter support** — today it's a 3-step sheet telling users to go open Shortcuts.
- **Control Center module / widget** — no WidgetKit.
- **Spatial Audio & AirPods awareness** — AirPods are detected today by icon-name string matching.
- **Right-click context menus on all rows** (only 2 of ~15 row types have one).
- **Dynamic Type support** — 248 hardcoded sizes, zero `@ScaledMetric`; the popup ignores Larger Text entirely.
- **`differentiateWithoutColor` handling** — boost level and mute state are color-only today.

---

## 4. Why (five sentences)

Apple software feels premium because a small number of decisions are made once and then applied without exception, and Melo currently makes most of those decisions many times — 21 font sizes, 13 corner radii, 23 paddings, and four names for one feature are each individually invisible but collectively read as "assembled" rather than "designed." Accessibility is not a checkbox here but the difference between a product and a demo: a volume app that VoiceOver cannot adjust and that breaks under Full Keyboard Access would fail Apple's own internal review before it ever reached a user. The pipeline problems are more urgent than either, because an app that only launches from one bash script, has no signed update channel, and whose sole working updater executes downloaded shell scripts is not shippable at any level of polish. Performance and real-time-safety issues — timers running for features that are off, a weak-self load inside the audio render callback — are precisely the class of defect users experience as "this app makes my Mac warm" and "I hear clicks," which is the fastest way to lose the premium impression the UI worked so hard to build. Everything else on this list is subtraction rather than addition: cutting the developer-update UI, the JSON theme editor, the Audio Units tab, and four settings that should just be defaults will do more for the Apple feeling than any new feature, because restraint is the actual house style.

---

## 5. Recommended order of work

| Phase | Scope | Why first |
|---|---|---|
| **2.8.4 — Foundation** | Embed Frameworks phase; kill `.source` update path; Developer ID + Hardened Runtime + notarization; populate Sparkle feed/key; real bundle ID; add `Tests/` + GitHub Actions | Nothing else matters if it can't launch or update safely |
| **2.9 — Accessibility & input** | `LiquidGlassSlider` a11y + adjustable action; fix Tab/focus rings; keyboard nav in dropdowns and palette; hit targets to 28pt; ⌥ fine-adjust; wire `Haptics.step/commit` | Largest single quality jump; also the hardest to retrofit later |
| **2.10 — Design system lockdown** | 7-step type scale, 5-step radius scale (as shapes, `.continuous`), 9-step spacing; delete raw `.system(size:)`; SwiftLint rules to enforce | Mechanical, high-volume, and blocks regression permanently |
| **2.11 — Subtraction & IA** | Sidebar settings + search; cut Theme Studio JSON, developer updates, Audio Units tab; 4 settings → defaults; one name per feature; copy pass | The restraint pass |
| **2.12 — Performance & motion** | Gate the three unconditional timers; pause backdrops when popup closed; move settings encode off main; route the 22 stray animations through tokens; `@Environment` Reduce Motion | Energy + polish |
| **2.13 — Real-time audio** | `Unmanaged` IOProc context; migrate all processors to `RealtimeAudioUnitChainSlot` | Isolated, risky, deserves its own release |
| **3.0 — Additions** | Now Playing, iCloud sync, full App Intents, Focus filters, widget, String Catalog | Only once the base is unimpeachable |
