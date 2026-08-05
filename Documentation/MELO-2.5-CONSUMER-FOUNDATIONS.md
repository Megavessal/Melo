# Melo 2.5.0 — Consumer Foundations

This release implements the feature brief in priority order while keeping the
primary interface consumer-facing. Existing mixer, routing, EQ, AutoEQ, Audio
Unit, normalization, adaptive-audio, device, media-key, pinning, layout, and
design-system capabilities were verified in the source tree and were not
reimplemented.

## 1. First-run tutorial

### Files

- **Created and verified:** `Sources/Melo/Views/Onboarding/FirstRunOnboardingView.swift`
- **Created and verified:** `Sources/Melo/Coordination/OnboardingWindowController.swift`
- **Modified and verified existing:** `Sources/Melo/FineTuneApp.swift`
- **Modified and verified existing:** `Sources/Melo/Settings/SettingsManager.swift`

### User-facing copy

1. **Meet Melo**
   - “Control each app's volume and choose where it plays, right from the menu bar.”
   - “Your sound stays on this Mac. Melo does not upload or record it.”
2. **One Permission, Explained**
   - “Melo uses Accessibility so your Mac's volume keys can control Melo.”
   - “macOS asks you to approve this once. You can remove access later in System Settings.”
   - Actions: **Allow Access** and **Open System Settings**
3. **Try One Small Thing**
   - “Play audio in any app, open Melo from the menu bar, then move only that app's slider.”
   - “The rest of your Mac stays at the same volume.”

The tutorial is three screens, can be skipped, and is shown once through the
`onboardingVersionCompleted` migration-safe setting.

### Terminology

“Accessibility” remains because it is the exact macOS permission name. The UI
does not expose event taps, process taps, or other implementation terms.

### Swift 6 concurrency

The view and controller are `@MainActor`. Permission requests, window creation,
and settings mutations remain on the main actor. No permission work is performed
from the Core Audio callback.

## 2. Searchable Settings guide

### Files

- **Created and verified:** `Sources/Melo/Models/SettingsGuide.swift`
- **Created and verified:** `Sources/Melo/Views/Settings/Guide/SettingsGuideView.swift`
- **Modified and verified existing:** `Sources/Melo/Views/Settings/SettingsRootView.swift`

### User-facing copy

- Tab: **Guide**
- Heading: **Melo Guide**
- Prompt: “Search for a setting or describe what you are trying to do.”
- Search field: **Search settings**

The guide contains 72 entries grouped by Getting Started, Everyday,
General, Volume & Calls, Apps, Devices, Sound, Shortcuts, and Privacy & Data.
Each future setting has one obvious insertion point in the flat searchable
catalog.

Examples:

- **Always Show:** “Keep an app's row visible even when the app is closed.”
- **Balanced Volume and Fuller Sound:** “Keeps apps closer in volume and preserves fullness when listening quietly.”
- **Clearer Voices:** “Bring speech forward in movies, calls, and videos.”
- **Use Less Processing on Battery:** “Pauses automatic sound enhancements while unplugged. App volume and routing keep working.”

### Terminology

Technical names are retained only when they identify an existing advanced area,
such as optional Audio Unit effects. The primary explanations use task-oriented
language.

### Swift 6 concurrency

The guide model is immutable and `Sendable`. The SwiftUI view is `@MainActor`.
Search and category filtering are local value operations and do not enter the
audio layer.

## 3. Quiet-app move delay and Always Show

### Files

- **Modified and verified existing:** `Sources/Melo/Models/AppActivityPresentationPolicy.swift`
- **Modified and verified existing:** `Sources/Melo/Views/MenuBarPopupView.swift`
- **Modified and verified existing:** `Sources/Melo/Views/Rows/AppEditRow.swift`
- **Modified and verified existing:** `Sources/Melo/Views/Settings/Tabs/GeneralTab.swift`
- **Modified and verified existing:** `Sources/Melo/Settings/SettingsManager.swift`

### User-facing copy

- Setting: **Move Quiet Apps**
- Options: **Off**, **15 sec**, **30 sec**, **1 min**, **Never**
- Dynamic explanation:
  - Off: “Move quiet apps right away”
  - 15 sec: “Wait 15 seconds before moving them”
  - 30 sec: “Wait 30 seconds before moving them”
  - 1 min: “Wait 1 minute before moving them”
  - Never: “Keep quiet apps in the main list”
- Per-app affordance: **Always show**
- Help: “Always show this app. Melo still releases audio access when it is not needed.”

This remains a relocation between the main and Inactive sections. It is not an
opacity-based inactivity treatment.

### Privacy boundary

`AppActivityPresentationPolicy.swift` retains an explicit boundary: row
visibility never controls tap activation or audio-engine lifetime. The setting
only schedules main-list presentation changes.

### Terminology

The internal persistence names `pinnedApps` and `isPinned` remain unchanged for
backward compatibility. The user sees **Always show**, not “Pin.”

### Swift 6 concurrency

The delay tasks are `Task { @MainActor ... }` values owned by the popup. Each task
is cancelled when the app becomes active, the setting changes, or a replacement
task is scheduled. Process-tap policy remains in the audio engine and is not
called by this UI grace timer.

## 4. Lower other apps during calls

### Files

- **Created and verified:** `Sources/Melo/Coordination/CallDuckingManager.swift`
- **Modified and verified existing:** `Sources/Melo/Audio/Engine/AudioEngine.swift`
- **Modified and verified existing:** `Sources/Melo/Views/Settings/Tabs/AudioTab.swift`
- **Modified and verified existing:** `Sources/Melo/FineTuneApp.swift`
- **Modified and verified existing:** `Sources/Melo/Settings/SettingsManager.swift`

### User-facing copy

- Section: **Calls**
- Toggle: **Lower Other Apps During Calls**
- Explanation: “Gently lower other apps while a call app is making sound, then bring them back.”
- Setting: **Call Apps**
- Default explanation: “Zoom, FaceTime, Teams, Discord, and Slack are recognized automatically.”
- Picker explanation: “Melo already recognizes common calling apps. Choose the browser you use for Google Meet, or add another app here.”
- Privacy explanation: “Melo checks only whether these apps are making sound. It does not save or record their audio.”

### Behavior

- Selected communication apps are monitored through Melo's existing level data.
- Other app gains ramp to 20% over 180 ms.
- Restoration begins after 1.5 seconds of quiet and ramps back over 260 ms.
- Saved volume sliders are never rewritten, so the previous level restores exactly.
- A browser must be selected for Google Meet because Melo sees browser audio at
the app-process level, not as individual tabs.

### Terminology

“Auto-duck” does not appear in the primary UI. The user sees **Lower Other Apps
During Calls**.

### Swift 6 concurrency

`CallDuckingManager` is `@MainActor` and polls existing published level values.
The audio engine passes a scalar temporary gain into its existing tap state; the
realtime callback does not perform actor hops, allocate tasks, or mutate saved
settings. Monitoring taps exist only while this feature is enabled.

## 5. Apple Shortcuts actions

### Files

- **Created and verified:** `Sources/Melo/Shortcuts/MeloAppIntents.swift`
- **Modified and verified existing:** `Sources/Melo/FineTuneApp.swift`
- **Created and structurally verified:** `Melo.xcodeproj/project.pbxproj`
- **Created and structurally verified:** `Melo.xcodeproj/xcshareddata/xcschemes/Melo.xcscheme`
- **Modified and verified existing:** `Package.swift`
- **Modified and verified existing:** `scripts/build-app.sh`

### User-facing actions

- **Use Melo Scene** — “Restore a saved Melo sound setup.”
- **Set App Volume in Melo** — “Set one app's volume without changing the rest of your Mac.”
- **Mute or Unmute App in Melo**
- **Start Melo Sleep Timer** — “Fade out and mute after a chosen number of minutes.”
- **Fix Melo Audio** — “Rebuild Melo's audio connections without deleting settings.”

The preconfigured Shortcuts tiles are **Use Scene**, **Sleep Timer**, and **Fix Audio**.

### Terminology

The Settings UI calls this **Apple Shortcuts**. “App Intents” remains an internal
framework and source-code name.

### Swift 6 concurrency

Intent `perform()` methods enter `@MainActor` before touching `AudioEngine`,
`SettingsManager`, or `SleepTimerManager`. Entity queries use `MainActor.run` to
read live scenes and apps. No intent accesses Core Audio state directly from an
unisolated executor.

### Build integration

The Xcode application target includes every Swift source file and enables App
Intents metadata extraction. The build script now uses `xcodebuild` and fails if
`Metadata.appintents` is absent from the resulting bundle.

## 6. Remaining features

### Focus-to-Scene setup

**Modified and verified existing:** `Sources/Melo/Views/Settings/Tabs/EverydayTab.swift`

Copy:

- **Match a Scene to a Focus**
- “For example, use your Work Scene when Work Focus turns on.”
- A three-step sheet opens Apple Shortcuts and explains how to pair a Focus
automation with Melo's **Use Scene** action.

The public Focus status API provides a generic focused/not-focused value, not a
stable named Focus identifier. Named mappings therefore use Apple's own Focus
automation trigger in Shortcuts rather than private APIs.

Concurrency: opening Shortcuts and presenting the setup sheet stay on the main actor.

### Clearer Voices

**Modified and verified existing:**

- `Sources/Melo/Audio/Loudness/AdaptiveAudioSettings.swift`
- `Sources/Melo/Audio/Loudness/AdaptiveAudioProcessor.swift`
- `Sources/Melo/Audio/Engine/AudioEngine.swift`
- `Sources/Melo/Views/Settings/Tabs/AudioTab.swift`

Copy: **Clearer Voices** — “Bring speech forward in movies, calls, and videos.”

The existing broad-band content analysis receives a restrained voice lift. The
UI does not expose frequency ranges or gain values.

Concurrency: immutable settings are copied into the realtime processor; the DSP
path performs no actor hop or allocation.

### Same Sound in Both Ears

**Modified and verified existing:**

- `Sources/Melo/Audio/Engine/TapInitialState.swift`
- `Sources/Melo/Audio/Engine/ProcessTapControlling.swift`
- `Sources/Melo/Audio/Engine/ProcessTapController.swift`
- `Sources/Melo/Audio/Engine/AudioEngine.swift`
- `Sources/Melo/Views/Settings/Tabs/AudioTab.swift`

Copy: **Same Sound in Both Ears** — “Combine left and right so both sides play the same sound.”

The primary UI does not use “mono.” The DSP averages the first left/right pair
and writes the same sample to both channels.

Concurrency: the main actor updates the same lock-free tap state pattern used by
existing realtime settings. The Core Audio callback reads the value without an
actor hop.

### Sleep timer

**Created and verified:** `Sources/Melo/Coordination/SleepTimerManager.swift`

**Modified and verified existing:** `Sources/Melo/Views/Settings/Tabs/EverydayTab.swift`

Copy:

- **Sleep Timer**
- **Fade Out, Then Mute**
- “Choose how long you want to keep listening.”
- Presets: **15 min**, **30 min**, **45 min**, **60 min**

The final ten seconds fade down over 20 steps, then mute. Melo restores the saved
volume while muted so the next manual unmute returns to the user's previous level.

Concurrency: the countdown is an owned `@MainActor` task. Cancelling the timer
cancels the task; device writes occur on the main actor.

### Settings backup and restore

**Modified and verified existing:**

- `Sources/Melo/Settings/SettingsManager.swift`
- `Sources/Melo/Views/Settings/Tabs/GeneralTab.swift`
- `Sources/Melo/Views/Settings/SettingsRootView.swift`

Copy:

- **Settings Backup** — “Save a copy you can restore or move to another Mac.”
- Actions: **Save…**, **Restore…**
- Confirmation: “Your current Melo settings will be replaced. The backup file will not be changed.”

Backups include a Melo format marker, backup-format version, export date, and
settings payload. Import remains compatible with the raw JSON exported by Melo
2.4. Restoring also reconciles Launch at Login and refreshes runtime audio state.

Concurrency: settings remain `@MainActor`; file payloads are small and are read
or written synchronously from explicit modal actions. Normal debounced settings
writes remain serialized on the existing utility queue.

### Device-switch fade

**Verified existing; intentionally not reimplemented:**

- `Sources/Melo/Audio/Engine/CrossfadeOrchestrator.swift`
- `Sources/Melo/Audio/Engine/ProcessTapController.swift`

Melo already performs a 50 ms equal-power crossfade during normal live-device
switches. When a source device has physically disappeared, the existing code
uses an immediate fallback because there is no old signal left to blend.

No new UI or technical terminology was added. The existing realtime single-writer
crossfade state remains unchanged.

### Pause when headphones disconnect

**Created and verified:** `Sources/Melo/Audio/Keys/PlaybackPauseService.swift`

**Modified and verified existing:**

- `Sources/Melo/Audio/Engine/AudioEngine.swift`
- `Sources/Melo/Views/Settings/Tabs/AudioTab.swift`
- `Sources/Melo/Settings/SettingsManager.swift`

Copy: **Pause When Headphones Disconnect** — “Pause playback if the current headphones unexpectedly disconnect.”

Melo sends play/pause only when an affected app was audibly playing and the
disconnected headphones were the default output or that app's only route. This
avoids accidentally starting media that was already paused.

Concurrency: disconnect handling and event posting are `@MainActor`. The helper
posts a system media-key event and does not enter the Core Audio callback.

### Use less processing on battery

**Created and verified:** `Sources/Melo/Coordination/PowerSourceMonitor.swift`

**Modified and verified existing:**

- `Sources/Melo/Audio/Engine/AudioEngine.swift`
- `Sources/Melo/Views/Settings/Tabs/AudioTab.swift`
- `Sources/Melo/Settings/SettingsManager.swift`

Copy: **Use Less Processing on Battery** — “Pause automatic sound enhancements while unplugged; app volume and routing keep working.”

Only automatic loudness and adaptive processing pause. Manual volume, routing,
EQ, AutoEQ, effects, and balance remain available.

Concurrency: the monitor owns a `@MainActor` polling task. The power-source read
is isolated in a `nonisolated` helper; the resulting state is applied on the
main actor. Realtime processors receive updated immutable state through existing
engine reconciliation.

## Verify before merging

1. Run a native Xcode 26 Release build on macOS. The Linux preparation runtime
   can parse Swift but cannot type-check Apple-only frameworks or link the app.
2. Confirm Xcode emits `Metadata.appintents` and that all five actions appear in
   Shortcuts after launching Melo once.
3. Test Accessibility approval from a clean macOS user account, including Skip,
   Allow Access, and returning from System Settings.
4. Validate call detection with each supported communication app. Browser calls
   intentionally operate at browser-process level, not individual-tab level.
5. Test play/pause delivery with Music, Podcasts, Safari, Chrome, and third-party
   players. The system media-key command is best-effort and depends on
   Accessibility access and the active media session.
6. Test IOKit power reporting on a MacBook and confirm desktop Macs remain in the
   normal-processing state.
7. Test settings backup compatibility with a Melo 2.4 raw JSON export and a new
   2.5 wrapped backup.
8. Confirm the Xcode project opens cleanly and package dependencies resolve to
   FluidMenuBarExtra 1.0.0 and KeyboardShortcuts 2.4.0.
