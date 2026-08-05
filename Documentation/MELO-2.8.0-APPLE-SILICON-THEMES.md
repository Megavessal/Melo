# Melo 2.8.0 — Apple Silicon and Theme Studio

## Submitted developer-update failure

The 2.7.1 source update reached Xcode but failed in `MenuBarIconCoordinator.swift` because Swift 6 would not allow non-Sendable `NSEvent` to be captured by `MainActor.assumeIsolated`. Version 2.8.0 removes that actor transfer and uses the local AppKit event monitor directly.

## Apple-silicon-only release path

The Xcode project and both source-build paths set:

```text
ARCHS=arm64
EXCLUDED_ARCHS=x86_64
```

`build-app.sh` also scans the final app bundle, thins universal embedded Mach-O files to arm64, signs the result, and fails if any x86_64 slice remains.

## Animated themes

`MeloThemeBackdrop` is shared by Settings and the menu-bar panel. This is what makes theme motion continue across both UI surfaces without duplicating screen-specific implementations.

- Space: 21 restrained twinkling stars and the white/red rocket.
- Galaxy: 28 restrained stars, a nebula glow, and the rocket.
- Aurora: a very dark night gradient, faint stars, slow blurred aurora ribbons, mountain silhouettes, and the rocket.
- Reduce Motion: pauses star and aurora movement and presents the rocket as a quiet static element.

## Theme Studio boundary

AI-created themes are `GeneratedMeloTheme` values. They can contain only:

- a short name
- one renderer style: stars, aurora, nebula, or gradient
- six-digit colors
- star density from 0 through 48
- sparkle strength from 0.04 through 0.28
- whether Melo's existing rocket is shown

They cannot contain Swift, JavaScript, shell commands, URLs, file paths, arbitrary assets, window definitions, controls, or audio instructions.

## OpenAI and ChatGPT paths

Connected mode sends the user’s description to the OpenAI Responses API and requires strict JSON-schema output. The user supplies a personal API key, which Melo stores in Keychain. No developer key is included in the project.

Guest mode copies the same constrained design request to the clipboard, opens ChatGPT in the browser, and validates pasted JSON locally. It does not sign into ChatGPT from Melo or read ChatGPT conversations.
