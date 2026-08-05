# Melo 2.6.0 Apple refinement

## First launch

The welcome window now uses four short pages: what Melo does, system-audio setup,
volume-key setup, and an invitation to the guided tour. The old privacy tagline was
removed. The primary copy is direct and uses the names shown by macOS.

A 2.35-second local Melo chime starts the system-audio permission flow at a predictable
time. `AudioDeviceStart` runs on a worker queue because macOS may wait for the user while
showing its permission sheet. Resource creation and all app state remain on `@MainActor`.
After permission succeeds, the chime is replayed through the temporary Melo route and the
tap is released.

## Guided tour

The menu-bar popup can present a dimmed, four-step overlay. It spotlights the app list,
per-app controls, and devices, then asks how long quiet apps should remain in the main
list. Fresh installs default to **Never** so rows remain available during the tour. Existing
installations keep their prior 15-second behavior unless the user already chose another
value. **Always show** remains presentation-only and never extends audio-capture lifetime.

## Guide and search

The Guide sidebar uses explicit buttons rather than selection-driven list rows. Search now
scores titles, summaries, details, aliases, synonym groups, intent phrases, and small typos.
The same local matcher powers **Find an Action**. Find an Action is rendered inside the
menu-bar popup instead of as a detached sheet, so Back returns to the mixer without a
visual context switch.

## Updates

The native updater is inactive until the publisher adds an HTTPS feed URL and an Ed25519
public key to `Config/Info.plist`. It supports manual and automatic checks, verified
downloads, optional automatic installation, staged replacement, and rollback. It rejects
an insecure URL, invalid signature, mismatched SHA-256 checksum, wrong bundle identifier,
or wrong build number. See `UPDATE-SERVER-SETUP.md`.

Onboarding and guided-tour completion are not compared with the current app version.
Installing Melo 2.6 or any later update therefore does not replay first-run setup.

## Icon

The Xcode app-icon set was regenerated from the original blue `Resources/Melo.icns` icon.
This restores the pre-2.5 icon in Finder, the Dock, About, and onboarding while keeping the
existing menu-bar icon choices unchanged.

## Swift 6 boundaries

- Onboarding, guide, tour, updater state, and UI coordination are `@MainActor`.
- The single potentially blocking Core Audio start call is isolated in a nonisolated static
  helper and receives an `@unchecked Sendable` request containing only Core Audio handles.
- The audio callback and realtime DSP paths receive no SwiftUI or updater work.
- Update hashing, extraction, and code-signature verification run in detached utility work.
- The intent matcher is immutable and `nonisolated`.

## Validation completed outside macOS

- Parsed all 182 Swift files with Swift 6 syntax
- Passed premium, Everyday, Consumer Foundations, and Apple Refinement guards
- Confirmed all 182 Swift files are included in the Xcode target
- Confirmed the introduction sound is included in the resources phase
- Validated the Swift package, property lists, and shell scripts
- Confirmed version 2.6.0 / build 260 and restored app-icon assets

Native AppKit, Core Audio, CryptoKit, App Intents, and final linking still require the
included Xcode build on macOS.
