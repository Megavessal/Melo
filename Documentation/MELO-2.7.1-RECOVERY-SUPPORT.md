# Melo 2.7.1 — Recovery and Support

This update adds the recovery and support controls requested after testing Melo 2.7.0.

## Added

- Reliable right-click menu on the menu-bar icon using an AppKit event monitor.
- Open Melo, Settings, Replay Tutorial, Show in Dock, Launch at Login, Check for Updates, Report a Problem, and Quit commands.
- Replay Tutorial in Settings → General → Getting Started.
- Optional Dock presence. When enabled, Melo behaves like a regular Mac app and is easier to find in Force Quit.
- Erase All Melo Data with a confirmation, clean shutdown, complete local-data removal, and automatic relaunch.
- AI-readable diagnostic ZIP reports containing a summary, versioned JSON, recent Melo logs, the latest crash report, and recent update logs. No audio is recorded; home-directory paths are redacted.
- A future `MeloDiagnosticsEndpoint` configuration key. Upload remains disabled until an HTTPS endpoint is configured in a later release.
- Corrected Sparkle runtime search paths.
- Developer update builds no longer wait for keyboard input after compilation.

## Preserved

- macOS Accessibility and system-audio permissions remain managed by macOS and are not erased by Melo.
- Normal updates do not replay onboarding.
- Melo remains a universal arm64/x86_64 app in this release.
