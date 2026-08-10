# Melo — project anchor

Decisions that have already been made, so the next pass inherits them instead of
re-deriving a default. Keep this under a page. If it grows into a manual, the
decisions belong in a skill instead.

## Claim standard

A claim about this app is verified when it names the evidence:

- **Visual** — a frame rendered by `./scripts/dev-verify.sh <dir>` that you
  opened and looked at. Naming the file is not looking at it.
- **Behavioural** — a command you ran and its output, or a `scripts/verify-*.py`
  assertion that you proved can fail (break the behaviour, watch it go red).
- **Anything else** — say **unverified**, in that word. It is an acceptable and
  useful answer here. A confident guess is worse than an honest gap, because it
  ends work that isn't finished.

`dev-verify.sh` is the only supported way to build. It serialises, renders, runs
the verify scripts, and exits non-zero when any of that fails. Do not run
`Build Melo.command` or `xcodebuild` directly, and never delete a build cache —
another agent may be mid-build in it.

## What the render harness cannot see

Treat this as a map of where defects hide, not as a disclaimer.

- **Material blur, translucency, vibrancy.** `cacheDisplay` captures the layer
  tree, not the window server's composite, so a material renders flat. **Do not
  add fills, borders, or card chrome because a frame looks flat.**
- **`glassEffect` / `meloGlassSurface`** — a glass island is composited by the
  window server *and takes its content with it*. `MenuBarPopupView.swift:515`
  wraps the popup's entire header in one, so a layer capture shows blank where
  the Melo mark, Audio disclosure, Output/Input toggle, ⌘K, edit-priority and
  Settings gear are. **Blank is not absent.** Judge the header from a
  `capture: .imageRenderer` frame (`popup-header-*`, `tour-header-*`); its glass
  finish stays unverified.
- **`ImageRenderer` cannot draw `ScrollView` content, `TextField` or
  `ProgressView`.** Measured with a control probe 2026-08-09, not inferred: a
  plain `VStack` renders in the same frame while a scrolled one comes back
  blank, and the other two come out as solid yellow bars with a no-entry glyph —
  that is the renderer's placeholder for a control it cannot draw, not a styling
  bug. So on the `.imageRenderer` path a text field is always a yellow bar, a
  determinate progress bar is always a yellow bar, and a list longer than its
  visible rows is blank. Seed fewer rows than the scroll threshold, or capture
  that scene with `cacheDisplay` instead.
- **Reduce Motion** — read-only system value; read motion behaviour from source.
- **Accent tint** — the harness window is never key, so macOS desaturates
  tinted controls and a prominent button looks like an ordinary one.
- **Dynamic Type** — the scene parameter was removed. It never drove macOS text
  scaling (Melo's type is fixed-size), so `xxxl` frames were default frames
  wearing an accessibility name. Large-text layout is unverified and cannot be
  exercised by this harness.
- **Transitions** are capturable now via `SnapshotHarness.transition(…)`, whose
  `act` must call the method the control calls. `mustDifferFrom` fails the run
  when an "after" frame is pixel-identical to its "before" — that identity is
  the dead-button signature. Identity proves failure; difference proves nothing,
  because an animation phase can differ. Still open the frames.
- Every frame carries a provenance band naming the scene, the capture path, and
  any uniform region that may be uncaptured content. Read it before judging.
- **The band's `CLIPPED?` warning is unconditional for any themed window and is
  not evidence.** `featurelessRows` samples 32 points across the last row and
  calls it featureless at three or fewer distinct colours; `meloThemeBackground`
  paints a diagonal gradient to every edge, so the last row always has more.
  Measured 2026-08-09: the Cutting Room's frames scored 6 distinct colours,
  while Melo's own `settings-audio-guide-*` frames scored 11 and 15 — the
  reference bar fails the same test harder. No layout change can clear it. The
  lead cited it as evidence of a real overflow; the overflow was real and the
  citation was wrong, which is the more dangerous half.

**A correction worth keeping, because it was believed for two runs.** "Dark
frames render nearly text-free" was blamed on materials in every brief and in an
earlier version of this file. That was wrong. `cacheDisplay` captures the
*hosting view*, not the window, so the window's opaque backing colour was never
in the image and unpainted pixels came back `(0,0,0,0)` — transparent, which
every viewer shows as white, which is where Melo's white dark-mode text landed.
Measured, fixed by compositing with `destinationOver`, and every dark frame is
now legible. **A plausible explanation for an artifact is not a diagnosis**, and
this one caused two agents to be told to ignore evidence that was really there.

## Decisions, with what they beat

- **Pixel-art app icon and menu-bar mark.** Deliberate. Stair-stepped curves and
  checkerboard dithering are the technique, not upscaling damage. Rejected:
  smooth vector redraw. Judge the mark against the style it is in — an
  inconsistent pixel grid *within* it is a real defect; anti-aliasing is not.
- **Flat rows at rest.** `glassFill` and `glassRowBorder` resolve to `.clear` on
  purpose — rows blend with the popup material, `hoverSurface` is the
  interaction signal. Rejected: resting fills and borders. 41 call sites depend
  on this.
- **One menu bar extra, ever.** `NSStatusBar.system.statusItem(` is constructed
  zero times in `Sources/`. Melo does not add an item the user did not choose,
  and does not rely on one being visible. Rejected: a second status item for
  pending updates, and the same behind a preference — the objection is to the
  app deciding at all.
- **`SUEnableAutomaticChecks` true, `SUAutomaticallyUpdate` false.** Checking is
  passive and reversible; installing unasked is a materially bigger promise and
  not what macOS does. Rejected: both false (meant *never* for anyone who
  skipped onboarding) and both true.
- **Tour steps anchor controls, not containers.** Every step highlights the
  specific control its copy names. A step whose control is absent shows an
  alternate that is true about the absence. Rejected: anchoring a section and
  nudging a pointer with pixel constants — that is what shipped broken.
- **Telemetry event payloads are closed enums, never `String`.** The enum *is*
  the redaction guard: `case themeChanged(name: String)` would pass every check
  `verify-telemetry.py` can express while leaking a user-typed string.

- **Releases are ad-hoc signed and not notarized. Settled by the owner
  2026-08-08. Do not raise it again.** `scripts/build-app.sh:119` signs with
  `codesign --sign -` on both `--dev` and `--release`, and there is no
  `notarytool` or `stapler` anywhere. Rejected: Developer ID signing plus
  notarization. The owner has been told the consequences, has accepted all of
  them, and does not want to be asked a fourth time.

  The consequences, recorded so nobody has to rediscover and re-report them:
  `spctl -a -vv` **rejects** a downloaded build, so first launch needs the
  right-click-Open path — which `scripts/release.sh`'s own closing message and
  the download page already document. TCC keys a grant to the **cdhash** when
  there is no team identifier, and every build produces a new one, so permission
  prompts recur on each update; that is expected, not a bug, and not a symptom
  to investigate. `Config/Melo.local.entitlements` ships
  `com.apple.security.cs.disable-library-validation`, which is a consequence of
  the same choice.

  This is a business decision, not an engineering oversight. An agent that finds
  the unsigned state and reports it as a defect is reporting something already
  decided — which this file exists to prevent.

## Dead patterns in this project

Dated 2026-08-07.

- `Documentation/MELO-<version>-<TOPIC>.md` — eleven of these exist and they are
  session reports named like documentation. Do not add another. Durable
  documentation goes in a file named for its subject; a run's narrative goes to
  the person who asked for the run.
- Checked-in `.diff` blobs in `Documentation/` (three, ~440KB). Git holds diffs.
- Verify assertions that check a symbol *exists* rather than that a behaviour
  *holds*. One such assertion kept a dead function alive after the page that
  called it was deleted.
- **Release notes and UI copy written as paragraphs.** One or two sentences.
  Name what changed and stop. Anything the user will *hear, see, or press* needs
  announcing, not explaining — prose is for what they cannot discover by using
  the thing. Measured 2026-08-09: a 3.0 note spent **87 words** explaining that
  the app now has a theme song, which they hear the moment setup opens. The
  house voice is not the problem and must not be flattened; the length is.
  A note that has to describe how something works is usually evidence the thing
  itself is unclear.
- **Release notes that cover only the last piece of work.** Write them against
  the diff since the previous release, not against the brief for this round.
  Measured 2026-08-09: 2.9.4 shipped three notes for roughly a dozen
  user-facing changes — search highlighting, the command palette rewrite, the
  first-run windows that stopped being dead, three new theme visitors — because
  the notes were written from a task list rather than from what actually
  changed.
- **Checks that prove a rule is correct and never prove it is connected.**
  Measured 2026-08-07: four wiring points were severed at once — the EQ preamp
  dropped from its only call site (the parameter defaults to `1`, so it still
  compiles), `supportsAutoEQ()` short-circuited to `true`, a headroom label
  gated behind `if false`, and a row's `× 100` changed to `× 10` — and the tree
  built, rendered 83 frames, and passed **all eleven verify scripts**. The
  mutated frames really did render `20%` and no dB label. Every assertion that
  should have caught it tested a *pure function nothing proved was called*, and
  the source-level checks meant to cover that gap were substring and ordering
  tests that survive their subject being severed. Executing a function proves
  the rule; only a check that observes the call, or reads the rendered result,
  proves the product uses it.

- **Search vocabulary: an alias beats a synonym group whenever one topic owns
  the word.** Measured 2026-08-09 while indexing the Cutting Room. An alias is
  worth 200–350 points on the one entry that should win; a synonym group is
  worth 24 on *every* entry that happens to contain the Melo-side word, so it
  lifts siblings as much as the target. Five groups were written and four were
  measured out: `["trim","crop","cut","shorten","chop"]` pushed *Trim a Sound*
  out of the top five for "crop the start", because "cut" runs through half the
  Cutting Room's own copy; `["clip","snippet","excerpt"]` was actively wrong,
  since "clip" prefix-matches "clipping" and "snippet" then returned *Prevent
  Profile Clipping*. Groups only earn their precision cost when a word must
  span topics. `groupLookup` also splits multi-word phrases into single tokens
  and unions them, which is why "fade out" in the sleep-timer group already
  makes "out" expand to "fade" app-wide — every phrase added should be one
  distinctive word.

- **`scripts/add-source-file.py` quotes paths, and it has to.** An unquoted
  OpenStep plist string may hold only `[A-Za-z0-9_./-]`. Registering
  `EditorFormat+Precision.swift` unquoted made `xcodebuild` report *"The project
  'Melo' is damaged"* — which reads like an unresolved merge conflict and sends
  you looking for one. The bug was latent from the day the script was written;
  Xcode itself quotes these, which is why `AudioDeviceID+Volume.swift` was fine.

- **A pre-check only covers the configuration you ran it in.** Three separate
  instances in one run, 2026-08-09, each caught by the next tool up rather than
  by the one before it: `swiftc -parse` was green for hours on a missing
  `import SwiftUI` that `-typecheck` caught immediately; `-typecheck` is blind
  to Swift 6 isolation errors inside a `deinit`, which only the full Xcode build
  reported; and `-typecheck` without `-D MELO_DEV` never parses the
  `#if MELO_DEV` blocks at all, so harness fixtures went unchecked by every
  pre-check run that session. The lesson is not "use a stronger tool" — it is
  that a check has to run in the configuration the code ships in. Fixture code
  behind a compilation condition is the worst case, because its only consumer is
  the render harness and its characteristic failure is producing output that
  looks right.

- **A `Codable` fingerprint that mixes `.iso8601` with a filesystem timestamp
  is always unequal to itself.** Measured 2026-08-09. `EditorSession.Fingerprint`
  is byte count plus modification date; `.iso8601` formats whole seconds and
  APFS reports `…147.1700807`, so the saved value never matched the file it
  described, every sidecar was discarded on the next open, and **session restore
  would have shipped dead and silent** — no crash, no error, just a move stack
  that never came back and a user assuming they misremembered. Floor the date to
  whole seconds so both sides agree. Invisible to the compiler, to a rendered
  frame, and to any check that a symbol exists; only an executed round trip
  finds it. Same shape as the four-severed-wiring-points entry below.

## What this project deliberately does not do

- Ship developer-update machinery. It is `#if MELO_DEV` and not compiled into
  release builds at all; that is a safety property, not a convenience.
- Send any audio-tap data off the machine. `scripts/verify-telemetry.py` is the
  mechanism, not a promise.
- Install an update without being asked.
- Add a menu bar item the user did not ask for.
- **Delete the user's own audio, ever.** The Cutting Room moves recordings and
  link extractions out of `temporaryDirectory` into
  `Application Support/Melo/CuttingRoom/Sources/` so a temp sweep cannot take
  audio that exists nowhere else, and it never removes them. The folder is
  reachable from the UI instead. Rejected 2026-08-09: pruning anything untouched
  for thirty days, which was well-argued — age is predictable where a byte
  ceiling is not — and still wrong. `verify-unasked-actions.py` guards three
  things Melo used to do unasked, the mildest of which is fetching a URL at
  launch; deleting a forty-minute recording is orders past that, and the failure
  is silent until the month is up and the file is gone. Unbounded growth of the
  user's own files in their own folder is the correct behaviour.

- **Two scenes in the render harness are flaky on their own.**
  `settings-audio-guide-devices` and `settings-audio-guide-smartsound` fail
  together about two runs in five, and each outcome is byte-identical: passing
  frames hash `9c168550` / `733defd4`, failing frames `039886d8` / `62119bfa`.
  A red there is not evidence about whatever changed last — re-run twice before
  diagnosing. Three mechanisms were tested in an isolated SwiftUI probe and
  refuted (a `.scrollPosition(id:)` registration race, a dependence on the
  animation clock, and content above the target changing after the scroll
  lands). Both scenes now assert the live `NSScrollView` offset as a number, so
  the next failure says how far the pane actually got instead of what fraction
  of pixels moved.
- **Wait for `dev-verify.sh` to exit, not for `_complete`.** The sentinel is
  written when the last frame lands; twenty verify scripts then run against the
  source tree. Editing source in that window makes them fail with "frames are
  older than the source they are evidence about", which is the staleness guard
  working — but the red belongs to whoever edited, not to the code.
- **A profiler changes the thing it profiles.** `sample` attaching to Melo made
  a launch stall read 1163ms; the same build with no sampler attached read
  487ms. `dlopen` blocks on `RemoteNotificationResponder::blockOnSynchronousEvent`
  while an observer is attached, so any launch measurement taken under `sample`
  is roughly double. Take the number from `MainThreadStall`'s watchdog, which
  runs unattached, and use the sample only to find *where* the time goes.
