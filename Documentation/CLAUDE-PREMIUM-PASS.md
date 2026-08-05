# Melo — premium pass

Patched source tree. **This is source, not a built app.** Building requires
Xcode on macOS; it could not be compiled in the environment this patch was
prepared in (Linux, no Apple frameworks).

## Contents

```
source/          Full patched tree (Melo/ + MeloFull/), drop-in replacement
premium-pass.diff        Unified diff vs. the original archive
verify.py                Static checker (see below)
verification-report.txt  Output of verify.py against this tree
```

## Build

```sh
./scripts/build-app.sh     # from the project root, per the project README
```

`MeloFull/Utilities/Haptics.swift` is a **new file**. If the project uses an
`.xcodeproj` with explicit file references rather than a synchronised folder
or Swift Package target, it must be added to the target manually or it will
not compile in.

## What changed

15 files. Three groups:

**1. Motion — graded scale, Reduce Motion honored centrally**

The tree previously carried 23 distinct animation literals for roughly six
classes of motion, including seven springs clustered between 0.28–0.42
response / 0.72–0.86 damping. Those differences were not deliberate choices.
30 of them now resolve to named tokens.

Reduce Motion was previously handled in 6 of ~45 view files, each with a
different fallback (`nil`, `.linear(0.15)`, a shortened duration); the other
~39 ignored the setting. `DesignTokens.Animation` tokens are now computed
properties that grade themselves, so a call site cannot forget.

Two tokens are deliberately exempt from grading:
- `vuMeterLevel` — a data readout. Freezing it misrepresents audio state.
- `track` — follows the pointer, which is already the user's own motion.

**2. Elevation — two-layer shadows**

`DesignTokens.Elevation` provides contact + ambient shadow pairs, applied via
`.meloElevation(_:)`. A single shadow reads as a sticker; two read as height.

Adopted at the EQ card (previously a contact shadow only, so it sat *on* the
glass rather than above it) and both dropdown panels (previously hairline
border only, no shadow at all — native AppKit menus cast a pronounced one).

**3. Controls**

- Slider: recessed groove with lit-from-above gradient, specular line on the
  fill, thumb shadow, and trackpad detent haptics at unity and the range ends.
  Haptics fire only during active drags, never on media-key or restore-driven
  changes.
- `design: .monospaced` → `.monospacedDigit()` on the percentage and EQ band
  labels. The former swapped SF for SF Mono, putting a code font inside a
  consumer UI; the latter keeps the type family while fixing numeral widths.
- Hover-grow (`scale 1.02`) on glass buttons replaced with a lift. Growing on
  hover is a web convention; on macOS it reads as the button inflating and
  resamples the label every frame.
- Press scale 0.96 → 0.975. The former reads as the control lurching.
- Keyboard-nav scroll moved off the 0.12s hover curve, which snapped the list
  too abruptly to track where focus had gone.

## verify.py

Static analysis, **not** a compiler. It checks the class of mistake a
mechanical token-adoption pass actually produces: unresolved token
references, dead tokens, surviving inline literals, delimiter balance, and
properties left declared but unread after an edit.

```sh
python3 verify.py source/MeloFull
```

Exits 0 clean, 1 on error. It does not check SwiftUI type inference,
`@MainActor` isolation, or overload resolution.

## Known risk before you build

The animation tokens changed from `static let` to `@MainActor` computed
properties. Every consuming file was checked and is a `View`, `ViewModifier`,
or `ButtonStyle` — all MainActor-isolated by default — and the `nonisolated`
types in the tree do not reference them. If a Swift 6 concurrency error
appears, this is the first place to look.

The mapping of those 30 springs onto tokens is a semantic judgment.
`0.35/0.85 → panel` is defensible, but some sites may want `rowChange` once
you see them move.

14 `.easeOut`/`.easeInOut` literals were left in place deliberately. They sit
in files that already handle Reduce Motion themselves, so converting them is
now a simplification rather than a fix — worth doing, but not something to
bundle into a mechanical pass.
