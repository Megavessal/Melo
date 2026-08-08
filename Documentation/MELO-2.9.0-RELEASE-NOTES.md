# Melo 2.9.0 (build 290) — what changed and how to build it

64 files changed, +3,633 / −844. Every file syntax-parses under Swift 6.2.1 and all
eight `verify-*.py` scripts pass. **Nothing here touches the audio engine** — no
`ProcessTapController`, no IOProc, no render-callback changes, per your call.

---

## Build it

```
./Build\ Melo.command --dev     # keeps the developer-update tools (use this one)
./Build\ Melo.command           # shipping build, dev tools not compiled in
```

The build now ends with a **launch test**. If the finished bundle can't start —
missing embedded framework, wrong architecture, anything dyld rejects — the build
fails there with the dyld error, instead of you finding out when you double-click it.

---

## 1. Developer updates: kept, and made reliable

You said it often fails when updates ship. Here is what was actually wrong, in
order of how often it would bite:

**The old swap moved a running app.** The script waited 40s for the old process,
then proceeded regardless. If Melo hadn't quit — and a menu-bar app with an audio
engine, an event tap, and a `flushSync()` that blocks on `ioQueue.sync` at
termination often hasn't — it renamed a live bundle. Launch Services then pointed
at a path the process no longer occupied, `open` reactivated the *old* copy
instead of launching the new one, the startup marker was never written, and 60
seconds later it rolled back. That reads exactly as "the update failed."
→ Now it waits 60s and **aborts with nothing changed** if the process is still
alive. It never moves a live bundle.

**Nothing checked that the new build could launch.** The bare `xcodebuild`
fallback in `UpdateBuildCoordinator` ran with `CODE_SIGNING_ALLOWED=NO` and no
`-resolvePackageDependencies`, so it could produce a bundle with no embedded
Sparkle and no signature — guaranteed to die in dyld. Your `Melo-latest-crash.ips`
is precisely that: `EXC_CRASH/SIGABRT`, `"namespace":"DYLD"`, zero Melo frames,
`Library not loaded: @rpath/Sparkle.framework`.
→ The installer now **test-launches the staged app** (`--melo-preflight`, handled
as the first statement of `MeloApp.init`) and refuses to swap unless it exits 0.
The failure message quotes the actual dyld line. That fallback is also gone —
source builds go through `build-app.sh` only, which is what embeds and signs.

**The swap wasn't atomic.** `ditto` into the live path meant a failure mid-copy
left a half-written app.
→ Staged as `Melo.incoming.app` beside the current one, then **two atomic renames
on one volume**. At no point is there no `Melo.app`.

**Launch Services staleness.** `open` on a freshly replaced bundle can relaunch
the cached old record.
→ `lsregister -f` before `open -n`.

**The startup marker could be satisfied by the wrong app.**
→ The installer writes a **one-time UUID token**; the new build echoes it into the
marker and the script compares. A leftover or rolled-back copy can't fake it.
Confirmation window raised 60s → 150s.

**Folder scanning fully extracted every ZIP, every check — including at launch.**
Your folder has a dozen ~5 MB builds, so that was hundreds of MB of I/O per check.
→ `peekManifest` reads only `manifest.json` via `unzip -p`.

**"No newer build" told you nothing.** A folder of valid-but-older builds looked
identical to a folder of broken ones.
→ It now reports what it checked and why each archive was skipped.

**Errors were opaque.** `invalidBundle` covered every mismatch.
→ Now names the field: "the built app is build 289 but the manifest says build
290". Forgetting to bump the build number is the most common one. Unsigned output
gets its own message pointing at `Build Melo.command`.

**Also:** a cancelled task could overwrite a newer operation's status (generation
token added); `codesign --verify --deep` dropped (Apple-deprecated); `terminate`
now has a hard `exit(0)` fallback so a vetoed quit can't strand the installer.

### Gated, not deleted
`MELO_DEV` is set by `--dev` and by the Debug configuration. Without it,
`DeveloperUpdateManager`, the `.source` build path, and the whole Developer
Updates UI are **not compiled in** — a shipping Melo has no code that downloads
and runs a build script. `UpdateBuildCoordinator` passes `--dev` through when
building a source update, so the loop sustains itself instead of one update
silently landing you on a shipping build.

---

## 2. Search

You were right that it exists — two surfaces plus a 78-entry glossary. The problem
was precision, and I measured it rather than guessed. `IntentSearch` and the guide
catalog are Foundation-only, so I compiled them standalone and ran real queries.

| Query | Before | After |
|---|---|---|
| `volume` | 22 results, unranked | 8, led by Volume Display / Volume Key Step |
| `eq` | **0 results** | app-eq, eq-preset |
| `airpods` | **0 results** | bluetooth |
| `fix audio` | 9 results | 1 — exact |
| `how do I mute an app` | Mute an App tied with help topics | Mute an App, decisively |
| `keep Spotify visible` | Show Melo in Dock first | **always-show first** (the app's own placeholder) |

What changed:

- **Field weighting.** Title ≫ keywords ≫ body. Before, every field was equal, so
  a hit buried in a 200-character `details` paragraph scored the same as an exact
  title match.
- **A coverage gate.** A result must account for at least half the user's words.
  This is the main precision control and it's what collapsed "volume" from 22 to 8.
- **Synonyms broadened but stopped promoting.** They score a fraction of a literal
  hit and give half coverage credit. The group `["audio","sound","volume","loudness"]`
  was deleted outright — in an audio app where nearly every entry says "sound",
  that one group matched the whole catalog.
- **Stopwords.** "how do I" carried synonym expansions into the help topics.
- **Short queries work.** Prefix matching from 2 characters; the old typo matcher
  required 4, which excluded `eq`, `mic`, and `hud`.
- **A relevance floor and a cap.** `IntentSearch.rank` drops the weak tail rather
  than showing everything above zero.
- **`percentage(in:)` tightened** — a bare number now needs a `%` or an explicit
  "to"/"at", so an app called "Studio 3" isn't read as a volume.
- **All 78 guide entries got 3–5 natural-language keywords** (only 8 had any).

And the structural fix: **the Guide can now take you there.** Entries carry a
destination and render a "Show me" button that switches to the right tab.
`SettingsRootView` has a real **search field** using the same index, with ↑/↓/
Return/Escape. The command palette's ⏎ glyph finally does something — selection
index, arrow keys, Return, with the highlight drawn as an accent ring rather than
the hover fill. `DropdownMenu` and `DevicePicker` got arrow/Return/Escape, and
DevicePicker got type-select.

---

## 3. Accessibility

- **VoiceOver can set volume.** `LiquidGlassSlider` had zero accessibility
  modifiers and backs every volume control in the app. It now has a label, a
  percent value, and an adjustable action; all four call sites pass real labels
  ("Spotify volume"). App-wide there were **0 adjustable actions and 2 values**.
- The Tahoe HUD no longer erases its own slider (`children: .ignore` → `.contain`).
- **Full Keyboard Access works.** Tab was hijacked for the Input/Output swap and
  focus rings were globally disabled — the popup was unnavigable and keyboard
  position rendered identically to mouse hover. Tab falls through now, the swap
  moved to ⌥⇥ / ⌘[ / ⌘], and focus draws an accent ring.
- **Hit targets:** `minTouchTarget` 16 → 28 (HIG floor); the slider's live area
  10pt → 20pt with the visual track unchanged.
- **Fine adjust:** Option (and ⇧⌥) gives quarter steps. Shift used to *coarsen*,
  which is backwards from every other macOS control.
- **Haptics:** `Haptics.step()` and `.commit()` were defined and never called.
  Now on arrow-key volume, boost chevrons, mode toggle, and mute — gated so
  media-key changes stay silent.
- EQ bands: labels, values, adjustable actions, keyboard, and a 0 dB detent tick.
- `VUMeter` hidden from VoiceOver.
- **The HUD appears in fullscreen.** It used to hard-return — but the media-key
  monitor had already swallowed the key, so a fullscreen video gave *no* feedback
  at all. Level raised above `.floating`, and it now targets the screen under the
  pointer rather than always `NSScreen.main`.

---

## 4. Idle energy and motion

- **Menu-bar timer:** 0.16s repeating, started unconditionally, checked whether it
  was needed *inside* the callback. Default icon style doesn't need it — ~6
  wakeups/sec forever, doing nothing. Now started/stopped by the setting.
- **Call ducking:** a 250ms `@MainActor` loop running at launch even with the
  feature off. Now only spins while enabled.
- **App level polling:** one 30Hz timer *per row* — 8 apps = 240 main-thread
  wakeups/sec. Consolidated onto one shared ticker.
- **Theme backdrops never paused.** One `TimelineView` had no `paused:` argument at
  all. All four now pause when the popup is closed.
- **Themes stopped painting over their own material.** Space/galaxy/aurora/
  AI-generated ran at 0.86–0.98 alpha over `VisualEffectBackground(.popover)` —
  Melo paid for behind-window vibrancy every frame and shipped a painted panel.
  Now ≤0.70, so it reads as glass.
- **AI themes can't produce unreadable UI.** Hex was validated for format but never
  luminance, while `.aiGenerated` forces dark appearance (white text) — a light
  background hex gave white on white. Backgrounds now clamp to L ≤ 0.18, accents
  to L ≥ 0.25, applied at render time so existing saved themes are fixed without
  rewriting your data.
- **Reduce Motion applies immediately.** `isReduced` read `NSWorkspace` statically,
  which SwiftUI doesn't observe, so toggling it mid-session did nothing until an
  unrelated redraw. New `MotionPreference` observable watches the system
  notification. ~22 stray animations routed through the token layer, including the
  tour pointer's infinite `repeatForever` — exactly the motion Reduce Motion exists
  for.
- **Settings no longer JSON-encode the whole blob on the main actor** on every
  save. Corrupt settings now restore from backup instead of silently resetting
  everything to defaults, and the bad file is quarantined rather than overwriting
  the backup.

---

## 5. Onboarding

- **Your clipped-button screenshot is fixed.** `GuidedTourOverlay` clamped against
  a hardcoded `cardHeight: 188` on a content-sized card, so any step wrapping past
  ~3 lines pushed Back/Next off the bottom. Height is measured now, with a max and
  a scroll fallback.
  *(Separately: the "Keep quiet apps visible?" question in that screenshot is not
  in 2.8.3 source — it was removed after 2.6 and `verify-2.8.3-refinement.py`
  asserts its absence. That build was older than 283.)*
- **The tour lets you use the control it highlights.** The dim layer swallowed all
  hit testing and the spotlight was a visual hole only — it pointed at a slider you
  couldn't move. Now an even-odd scrim: blocked outside, live inside.
- **Closing the welcome window no longer replays setup forever.** Completion was
  only written by Skip and Show Me Around, so the red X meant first-run every
  launch, permanently.
- **Notification permission is no longer cold-requested at launch**, half a second
  before the welcome window, for a feature the user hasn't met. It's asked when
  onboarding completes or when the toggle is switched on.
- The first-run sound no longer auto-plays over the copy you're still reading.
- Onboarding scrolls, so large accessibility text sizes don't clip it.

---

## 6. Design system

Tokens added and adopted across the popup, both HUDs, rows, and shared components
(settings tabs deferred, per your call):

- **`Typography.Scale`** — 7 steps. There were **21 distinct sizes** across 260 raw
  `.system(size:)` calls, 10.5pt and 23pt among them.
- **`Dimensions.Shape`** — 5 radii as *shapes*, all `.continuous`. There were 13
  radii for 3 tokens, and **100 of 125** `RoundedRectangle`s used circular corners
  — including both HUDs at r=16/22, sitting right next to the system volume HUD.
  Handing out finished shapes makes the right curve the only option.
- **`Spacing.xs2` (6) and `sm2` (10)** — the two off-scale values that were
  genuinely load-bearing, so the other sixteen can go.
- **`innerRadius(outer:inset:)`** for concentric nesting.

I also fixed the token-existence check in `verify-premium-pass.py`: it used a
single "current enum" variable, so nested enums silently reparented everything
after them. It now walks brace depth properly and validates **142 tokens across 12
groups** — which is how I confirmed every token reference in this release is real.

---

## Copy

One name per feature: "Melo AI Auto EQ" / "Melo AI Audio" → **Smart Sound**.
Jargon out of permission surfaces ("event tap", "main-thread stall", "intercept
F10/F11/F12"). Errors state what failed instead of blaming your file ("That file
is not a valid…" → "This file isn't a Melo settings backup."). "Made a mistake?" →
"Recent changes". "Unknown Audio Unit error" → "This plug-in couldn't be loaded."
ASCII `...` → `…`. Demo data no longer ships the original author's device names.

---

## What I did not do

- **Audio engine internals** — the IOProc weak-self load and the processor
  lifetime hack. Your call, and the right one: it's the clicks-and-pops fix but
  it's the change that can break working audio, and I can't test it. Its own
  release.
- **Settings tabs design-system conversion** — `EverydayTab` alone has 42 distinct
  font declarations. Bounded to high-traffic surfaces this round.
- **Localization, Developer ID + notarization, tests + CI, IA restructure** — all
  still open from the audit.

## Honest correction to the audit

I reported the crash as a missing Embed Frameworks phase in the Xcode project.
That was wrong — modern Xcode auto-embeds SPM binary frameworks, and your build
script's own guard passing proves Sparkle *is* embedded in normal builds. The
real cause was the bare-`xcodebuild` source-update path producing an unsigned,
unembedded bundle. I didn't touch the project's framework configuration; the
preflight launch test is what makes the class of failure impossible to ship.

## Suggested next

1. Build with `--dev`, confirm it launches and the Updates tab still shows the
   developer tools.
2. Run one folder-based update end to end and read
   `~/Library/Application Support/Melo/Updates/install-developer-update-290.log`.
   It's much more talkative now.
3. Try VoiceOver on a volume slider, and Tab through the popup.
4. Search "keep Spotify visible" in the Guide and in the new settings search.
