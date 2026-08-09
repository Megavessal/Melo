# Melo notices

Melo is free software and is distributed under the GNU General Public License,
version 3. See `LICENSE` for the complete terms and warranty disclaimer.

The per-application audio engine, EQ, AutoEQ, device controls, media-key support,
and substantial portions of the interface are derived from FineTune by Ronit
Singh (Copyright 2026 Ronit Singh), licensed under GPL-3.0. Melo modifies that
work with new branding, a redesigned liquid-glass presentation, additional
effects and routing features, and a standalone Swift Package build.

FineTune source: https://github.com/ronitsingh10/FineTune

Melo also links the following MIT-licensed Swift packages. Their complete
license texts are included in the app bundle and source archive:

- KeyboardShortcuts by Sindre Sorhus and contributors
  https://github.com/sindresorhus/KeyboardShortcuts
- FluidMenuBarExtra by Wade Tregaskis
  https://github.com/wadetregaskis/FluidMenuBarExtra

Melo does not contain SoundSource source code, artwork, trademarks, or Rogue
Amoeba's proprietary Audio Capture Engine. SoundSource is a product of Rogue
Amoeba Software, Inc.


## Sparkle 2

Melo uses Sparkle 2.9.5 for secure macOS software updates. Sparkle is distributed under the MIT license and includes separately licensed components. See `Sparkle-LICENSE.txt` in the application resources.


## FFmpeg, LAME and Opus

Melo bundles a copy of the `ffmpeg` command-line tool. macOS has no MP3 or
Opus encoder, so exporting either format from the Cutting Room stages a WAV
and asks `ffmpeg` to change the codec. That is the whole of what it is used
for, and the build is configured to do nothing else.

- FFmpeg 8.1.2 — LGPL-2.1-or-later — https://ffmpeg.org/
  `FFmpeg-LICENSE.txt`
- LAME (libmp3lame) 3.100 — LGPL-2.0-or-later — https://lame.sourceforge.io/
  `LAME-LICENSE.txt`
- libopus 1.6.1 — BSD-3-Clause — https://opus-codec.org/
  `Opus-LICENSE.txt`

The bundled binary is **not** a third-party download. It is built from the
official upstream source releases by `scripts/build-ffmpeg.sh`, which pins
every version and SHA-256 and aborts on a mismatch, and which contains the
complete configure line. That script is how anyone reproduces or relinks what
we ship, which is what LGPL-2.1 section 6 asks for.

The build passes neither `--enable-gpl` nor `--enable-nonfree`, so it stays
LGPL-2.1-or-later. This matters: Melo is GPL-3.0, and `--enable-gpl` would
place FFmpeg under GPL-2.0-only, which is incompatible with GPL-3. None of
FFmpeg's GPL-only components are needed to transcode audio. Do not add the
flag.
