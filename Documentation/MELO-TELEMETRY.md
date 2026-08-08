# Melo Telemetry

Anonymous, opt-in, and off by default.

Melo is a per-app volume mixer. To do its job it knows, continuously, exactly
which applications are running and playing audio, and which audio devices are
attached. **None of that may ever leave the machine.** App names, bundle
identifiers, and device names (people name AirPods after themselves) are the
hard line. Everything below is built around that one constraint.

`scripts/verify-telemetry.py` enforces it mechanically. Run it with the other
verifiers before shipping.

---

## What is collected

Only when the user has explicitly said yes.

**Environment, attached to every signal:**

| Field | Example | Why it is this coarse |
| --- | --- | --- |
| Melo version | `2.9.3` | Marketing version only. No build number. |
| macOS version | `26.1` | Major.minor. The build string (`25B78`) is dropped — it separates beta testers from everyone else and answers no product question. |
| Hardware class | `appleSiliconM3` | A silicon generation, not a model. `MacBookPro18,3` would pin down screen size, year, and often the configuration. Anything newer than the generations this build knows about folds into `appleSiliconLater`. |
| Language | `pt` | Language only, never the region. `pt-BR` narrows a population far faster than `pt` does. |

Why so blunt: Melo has a small user base. A precise model plus an exact OS build
plus a full locale is, in a population of a few thousand, very close to a unique
row — and cross-referenced with a timestamp it behaves as a fingerprint even
though no single field is an identifier.

**Events:** the closed list in `Sources/Melo/Telemetry/TelemetryEvent.swift`.
Every payload is a fixed enum or a coarse bucket (`one`, `twoToFive`,
`sixToTen`, `moreThanTen`).

**Crashes:** stack traces from Sentry, with `sendDefaultPii` off, session
tracking off, screenshots off, and a `beforeSend` hook that strips the `device`
context (which carries the machine's name), `serverName`, and `user`.

## What is never collected

- Application names or bundle identifiers — not as event names, not as payloads,
  not in crash context.
- Audio device names, device UIDs, or the Mac's own name.
- The user's name, Apple ID, serial number, hardware UUID, or IP-derived
  location beyond what the vendor sees at the TLS layer.
- Anything about what is playing: no titles, no levels, no audio.
- Names of user-created EQ presets or scenes (user-typed text is free text, and
  free text is the one thing that must never be forwarded).
- Exact counts of anything that could act as a quasi-identifier.

## Why the event type is a closed enum

There is deliberately no `send(_ name: String)` anywhere in the module. A
free-form string API is how an app name eventually reaches a server: somebody
interpolates one into an event name in a hurry and no reviewer notices. Making
the type system the redaction guard means a leak has to arrive as a new enum
case, which is a visible diff. `verify-telemetry.py` fails the build if a
string-taking send API reappears.

---

## Consent state machine

`AnalyticsConsent` (in `Sources/Melo/Settings/SettingsManager.swift`) is
`unasked | granted | denied`. It is three states rather than a `Bool` because
"has not been asked" and "said no" must behave differently — the first may raise
a prompt exactly once, the second must never raise one again.

```
                      ┌──────────────────────────────────┐
                      │  .unasked   (default, always)    │
                      └───┬───────────────────────┬──────┘
    setup page button     │                       │   setup page button
    "Share Anonymous"     │                       │   "Don't Share"
    one-time prompt       │                       │   one-time prompt
    "Share Anonymous"     │                       │   "Don't Share"
                          │                       │   window closed unanswered
                          │                       │   setup skipped / closed
                          ▼                       ▼
                    ┌──────────┐  Settings   ┌──────────┐
                    │ .granted │◄───────────►│ .denied  │
                    └──────────┘   switch    └──────────┘
```

- `.unasked` is the only permitted default, and an absent key in an older
  settings file decodes to `.unasked` (never `.denied`, never `.granted`).
- Nothing may write `.granted` except the three controls a user operates: the
  setup page, the one-time prompt, and the Settings switch. The verifier keeps
  an allow-list of exactly those three files.
- Every exit from a consent surface writes a definite answer. Closing the
  window, skipping setup, or walking past the page all settle as `.denied` —
  silence is not agreement, and leaving it `.unasked` would re-ask the question
  at the next launch, which is the nag an opt-in model exists to avoid.
- Once `.granted` or `.denied`, no prompt is ever shown again. The switch in
  Settings › General is the only way back.

### Who gets asked, and how

**New users** answer inside first-run setup, on page 7 of 8 (immediately before
the tour page). Two buttons, no pre-ticked toggle.

**Existing users** get `AnalyticsConsentPrompt` — a small standalone window with
one question, two buttons, and a line on exactly what is collected.
`MeloExperienceVersion.onboarding` is deliberately **not** bumped for this
release: bumping it would replay the entire seven-page setup flow at everyone
who already finished it, just to ask one question.

### Launch ordering

The 0.5 s launch block in `FineTuneApp` runs, in order:

1. `installLocation.showIfNeeded()` — may relaunch the app from a new path.
2. `onboarding.showIfNeeded()` — first-run setup.
3. `whatsNew.showIfNeeded(suppressedByOnboarding:)` — release notes.
4. `analyticsConsent.showIfNeeded(suppressedByOnboarding:suppressedByWhatsNew:)`

The consent prompt is last and stands down entirely if either of the other two
windows is up. Suppression is passed as a fact the caller already has
(`onboarding.isSetupPending`, `whatsNew.isPresenting` read straight after
`showIfNeeded`) rather than inferred from a timer — a timing guess is how this
ordering breaks silently a year from now.

---

## Adding the packages

The repository ships with **zero** telemetry dependencies. Every vendor call
sits behind `#if canImport(...)` with a no-op fallback, so the tree builds today
and lights up when the packages are added. Do not add them to `Package.swift`
(the SwiftPM manifest is not what builds the app bundle).

### TelemetryDeck — product analytics

1. Xcode ▸ **File ▸ Add Package Dependencies…**
2. URL: `https://github.com/TelemetryDeck/SwiftSDK`
3. Dependency Rule: **Up to Next Major Version**, from `2.0.0`.
4. Add to target **Melo**.

### Sentry — crash reporting

1. Xcode ▸ **File ▸ Add Package Dependencies…**
2. URL: `https://github.com/getsentry/sentry-cocoa`
3. Dependency Rule: **Up to Next Major Version**, from `8.0.0`.
4. Add the **Sentry** library product to target **Melo**.

Adding either package makes `canImport` succeed and the corresponding block
compile. Nothing else changes: consent still gates everything.

### Where the credentials go

Both live in `Config/Info.plist`, not in source, so a fork or a local build
cannot silently report into Melo's own project:

```xml
<key>MeloAnalyticsAppID</key>
<string>YOUR-TELEMETRYDECK-APP-ID</string>
<key>MeloCrashReportingDSN</key>
<string>https://…@…ingest.sentry.io/…</string>
```

The keys ship **empty**, which is the normal state of this repository and means
"no vendor configured". With an empty value the service stays on `NoOpSink`
even with consent granted, so a build without credentials cannot half-work.

The plist keys are deliberately vendor-neutral (`MeloAnalyticsAppID`, not
`MeloTelemetryDeckAppID`): the verifier bans vendor names outside
`#if canImport(...)` blocks, and plist keys are read by ordinary,
always-compiled code.

---

## Architecture

```
Sources/Melo/Telemetry/
  TelemetryEvent.swift        closed enum of every signal + coarse payloads
  TelemetryEnvironment.swift  the four blunt context fields
  TelemetrySink.swift         TelemetrySink protocol, NoOpSink,
                              ConsoleSink (#if MELO_DEV), vendor sink
  TelemetryService.swift      @MainActor @Observable singleton, consent gate
Sources/Melo/Coordination/
  AnalyticsConsentPrompt.swift  the one-time ask for existing users
```

`TelemetryService` has two invariants:

1. **Nothing is sent unless consent is `.granted`.** `send(_:)` guards on it.
2. **The SDKs are not started unless consent is `.granted`.** `start()` guards
   on it too. Starting a crash reporter at launch and then "choosing not to
   send" is not consent — the SDK installs signal handlers, opens a session, and
   writes an envelope to disk before any of Melo's own code gets a say.

Withdrawing consent drops the sink back to `NoOpSink` and calls
`SentrySDK.close()`. A reporter that has already installed its handlers cannot
be fully un-started, which is exactly why it is never started before consent.

### Seeing what would be sent

Build with `MELO_DEV` (the Debug configuration sets it) and grant consent. With
no vendor package linked, `ConsoleSink` logs each signal to the
`dev.melo.telemetry` subsystem:

```
would send app.launched hardware=appleSiliconM3 language=en meloVersion=2.9.3 systemVersion=26.1
```

That line is the complete wire payload for one event. There is nothing else.
