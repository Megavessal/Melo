#!/bin/bash
#
# Builds the minimal static `ffmpeg` that Melo bundles for MP3 and Opus export.
#
# ---------------------------------------------------------------------------
# Why this script exists rather than a downloaded binary
# ---------------------------------------------------------------------------
#
# Melo Edit exports MP3 and Opus, and macOS ships no encoder for either, so
# `AudioFileIO` stages a 32-bit float WAV and shells out to ffmpeg to change the
# codec. Nothing else. The binary that does that ships inside a signed app, so
# it is built here from official upstream tarballs — never fetched from
# evermeet.cx, osxexperts, a Homebrew bottle or anyone else's build server. Two
# reasons, and the second is the binding one:
#
#   1. A third-party executable inside a signed bundle is somebody else's code
#      running under Melo's identity and entitlements.
#   2. LGPL-2.1 section 6 obliges us to be able to reproduce and relink what we
#      distribute. This file *is* that obligation discharged.
#
# ---------------------------------------------------------------------------
# Why there is no --enable-gpl (and no --enable-nonfree)
# ---------------------------------------------------------------------------
#
# Melo is GPL-3.0. FFmpeg's default licence is LGPL-2.1-or-later, which is
# compatible with GPL-3 because "or later" allows the upgrade to LGPL-3, which
# in turn upgrades to GPL-3. Passing `--enable-gpl` pulls FFmpeg to
# **GPL-2.0-only**, and GPL-2-only is *incompatible* with GPL-3 — the resulting
# combination could not be distributed at all. That is a licensing defect, not
# a build preference, so the flag is absent on purpose and must stay absent.
#
# Nothing Melo uses needs it. `--enable-gpl` gates x264, x265, and GPL-only
# filters; the audio path here is libmp3lame (LGPL-2.0-or-later) and libopus
# (BSD-3-Clause), both of which are LGPL-compatible and neither of which
# requires the flag. `--enable-nonfree` is absent for the stronger reason that
# it produces a binary that may not be redistributed at all.
#
# Resulting licence of the artifact: LGPL-2.1-or-later.
# Licence texts ship in Resources/ (LAME-LICENSE.txt, Opus-LICENSE.txt,
# FFmpeg-LICENSE.txt) and are catalogued in NOTICE.md.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#
#   ./scripts/build-ffmpeg.sh            # build into .build-ffmpeg/, install to Vendor/
#   ./scripts/build-ffmpeg.sh --clean    # discard the work tree first
#
# Requires Homebrew's nasm, pkg-config, autoconf and automake. Homebrew is not
# on the default PATH on this machine, so the script puts it there itself.
#
# Output: Vendor/ffmpeg/ffmpeg, arm64-only, stripped, statically linked against
# libmp3lame and libopus. Bundling and codesigning are deliberately NOT done
# here.
#
set -euo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${MELO_FFMPEG_WORK:-$REPO_ROOT/.build-ffmpeg}"
SRC="$WORK/src"
PREFIX="$WORK/deps"
OUT_DIR="$REPO_ROOT/Vendor/ffmpeg"
OUT="$OUT_DIR/ffmpeg"

# Match Melo's own deployment target so the bundled tool cannot be the thing
# that raises the app's floor.
export MACOSX_DEPLOYMENT_TARGET=15.4

# ---------------------------------------------------------------------------
# Pinned upstream sources.
#
# Every checksum below was verified against a record independent of the
# download itself before being pinned here:
#
#   ffmpeg 8.1.2  ffmpeg.org publishes only detached GPG signatures (.asc) for
#                 its releases, no .sha256. Cross-checked instead against the
#                 Homebrew formula index (formulae.brew.sh/api/formula/ffmpeg.json,
#                 a text metadata record — not a bottle), which lists the same
#                 digest for the same ffmpeg.org URL.
#   opus 1.6.1    Matches Xiph's own https://downloads.xiph.org/releases/opus/SHA256SUMS.txt
#   lame 3.100    SourceForge publishes no SHA-256. Its file API reports
#                 md5 83e260acbe4389b54fe08e0bdbf7cddb and
#                 sha1 64c53b1a4d493237cef5e74944912cd9f98e618d for this file;
#                 both matched the download, and the SHA-256 below is of the
#                 same bytes.
#
# If a checksum ever mismatches, this script aborts. Do not "fix" it by
# repinning until you know why the bytes changed.
# ---------------------------------------------------------------------------

FFMPEG_VERSION="8.1.2"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"

OPUS_VERSION="1.6.1"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"

LAME_VERSION="3.100"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"
LAME_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"

# ---------------------------------------------------------------------------

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mbuild-ffmpeg: %s\033[0m\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--clean" ]]; then
    say "Removing $WORK"
    rm -rf "$WORK"
fi

for tool in curl shasum tar make nasm pkg-config lipo strip; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

mkdir -p "$SRC" "$PREFIX" "$OUT_DIR"

# fetch <url> <filename> <sha256>
#
# Downloads only when absent, then always verifies. The verification is not
# advisory: a mismatch removes the file and exits non-zero, because the whole
# point of building from source is knowing which source.
fetch() {
    local url="$1" file="$2" want="$3" path="$SRC/$2"
    if [[ ! -f "$path" ]]; then
        say "Fetching $file"
        curl -fL --retry 3 --max-time 900 -o "$path.part" "$url" || die "download failed: $url"
        mv "$path.part" "$path"
    fi
    local got
    got="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$got" != "$want" ]]; then
        rm -f "$path"
        die "checksum mismatch for $file
       expected $want
       actual   $got
       The file has been deleted. Do not repin until you know why."
    fi
    printf '    sha256 ok  %s\n' "$file"
}

fetch "$FFMPEG_URL" "ffmpeg-${FFMPEG_VERSION}.tar.xz" "$FFMPEG_SHA256"
fetch "$OPUS_URL"   "opus-${OPUS_VERSION}.tar.gz"     "$OPUS_SHA256"
fetch "$LAME_URL"   "lame-${LAME_VERSION}.tar.gz"     "$LAME_SHA256"

unpack() {  # unpack <tarball> <expected-dir>
    if [[ ! -d "$SRC/$2" ]]; then
        say "Unpacking $1"
        tar -C "$SRC" -xf "$SRC/$1"
    fi
}

unpack "ffmpeg-${FFMPEG_VERSION}.tar.xz" "ffmpeg-${FFMPEG_VERSION}"
unpack "opus-${OPUS_VERSION}.tar.gz"     "opus-${OPUS_VERSION}"
unpack "lame-${LAME_VERSION}.tar.gz"     "lame-${LAME_VERSION}"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

export CFLAGS="-arch arm64 -O2 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export LDFLAGS="-arch arm64 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# ---------------------------------------------------------------------------
# libmp3lame — LGPL-2.0-or-later. Encoder only.
#
# --disable-frontend drops the `lame` command-line tool; --disable-decoder
# drops the MPEG decoder (Melo only ever encodes). LAME 3.100 shipped in 2017
# with a config.guess that predates Apple Silicon, so the ones from the
# installed automake are dropped in — otherwise it guesses the host wrong.
# ---------------------------------------------------------------------------
if [[ ! -f "$PREFIX/lib/libmp3lame.a" ]]; then
    say "Building libmp3lame ${LAME_VERSION}"
    cd "$SRC/lame-${LAME_VERSION}"
    for helper in config.guess config.sub; do
        newer="$(find /opt/homebrew/Cellar/automake -name "$helper" -path '*share*' 2>/dev/null | head -1)"
        [[ -n "$newer" ]] && cp "$newer" "./$helper"
    done
    ./configure \
        --prefix="$PREFIX" \
        --host=aarch64-apple-darwin \
        --disable-shared \
        --enable-static \
        --disable-frontend \
        --disable-decoder \
        --disable-analyzer-hooks \
        --disable-dependency-tracking \
        --disable-gtktest
    make -j"$JOBS"
    make install
fi

# ---------------------------------------------------------------------------
# libopus — BSD-3-Clause.
#
# The DNN features added in 1.5 (DRED, deep PLC, OSCE) carry model weights
# worth megabytes and are all decoder-side quality work Melo never reaches.
# They default off; disabling them explicitly keeps that true if the default
# ever flips.
# ---------------------------------------------------------------------------
if [[ ! -f "$PREFIX/lib/libopus.a" ]]; then
    say "Building libopus ${OPUS_VERSION}"
    cd "$SRC/opus-${OPUS_VERSION}"
    ./configure \
        --prefix="$PREFIX" \
        --disable-shared \
        --enable-static \
        --disable-doc \
        --disable-extra-programs \
        --disable-dependency-tracking \
        --disable-dred \
        --disable-deep-plc \
        --disable-osce
    make -j"$JOBS"
    make install
fi

# ---------------------------------------------------------------------------
# ffmpeg — LGPL-2.1-or-later. Everything off, then back on only what the one
# command line in AudioFileIO.ffmpegArguments(input:settings:) touches:
#
#   ffmpeg -hide_banner -nostdin -y -loglevel error -progress pipe:1 \
#          -i <staged.wav> -c:a libmp3lame -b:a 320k  <out.mp3>
#          -c:a libopus    -b:a 160k  <out.opus>
#
# Component notes, because several of these are non-obvious:
#
#   demuxer wav          the staged intermediate is always WAV
#   decoders pcm_*       f32le is what Melo writes; s16le/s24le are there so a
#                        differently-staged WAV is not a mystery failure
#   muxers mp3, ogg      ...plus `opus`, which is the muxer lavf actually picks
#                        for a `.opus` extension. Without it, `-c:a libopus
#                        out.opus` fails to find an output format. `ogg` alone
#                        is not enough; `oga` covers .oga.
#   filters aresample,   the ffmpeg CLI auto-inserts these into every audio
#     anull, aformat     graph; abuffer/abuffersink are the graph's endpoints
#                        and are named explicitly rather than assumed.
#   protocol file        input and output
#   protocol pipe        REQUIRED BY `-progress pipe:1`. `-progress` opens its
#                        destination through avio like any other URL, so a
#                        build with only the file protocol reports
#                        "Protocol not found" and Melo's progress bar dies.
#                        This is one component beyond the brief's list and it
#                        is not optional.
#
# No --enable-gpl. See the header.
# ---------------------------------------------------------------------------
say "Building ffmpeg ${FFMPEG_VERSION}"
cd "$SRC/ffmpeg-${FFMPEG_VERSION}"

if [[ ! -f config.h ]]; then
    ./configure \
        --prefix="$WORK/ffmpeg-install" \
        --arch=arm64 \
        --cc=clang \
        --pkg-config-flags="--static" \
        --extra-cflags="-I$PREFIX/include $CFLAGS" \
        --extra-ldflags="-L$PREFIX/lib $LDFLAGS" \
        \
        --disable-everything \
        --disable-autodetect \
        --disable-network \
        --disable-doc \
        --disable-debug \
        --disable-shared \
        --enable-static \
        --enable-small \
        \
        --disable-ffplay \
        --disable-ffprobe \
        --disable-avdevice \
        --disable-swscale \
        --disable-iconv \
        --disable-zlib \
        --disable-bzlib \
        --disable-lzma \
        --disable-sdl2 \
        --disable-xlib \
        --disable-securetransport \
        --disable-videotoolbox \
        --disable-audiotoolbox \
        --disable-coreimage \
        --disable-appkit \
        --disable-avfoundation \
        \
        --enable-libmp3lame \
        --enable-libopus \
        --enable-demuxer=wav \
        --enable-muxer=mp3,ogg,oga,opus \
        --enable-decoder=pcm_f32le,pcm_s16le,pcm_s24le \
        --enable-encoder=libmp3lame,libopus \
        --enable-filter=aresample,anull,aformat,abuffer,abuffersink \
        --enable-protocol=file,pipe
fi

make -j"$JOBS"

# ---------------------------------------------------------------------------
# Thin, strip, install. Melo thins every binary to arm64, so this one arrives
# already thin rather than making the app build do it.
# ---------------------------------------------------------------------------
BUILT="$SRC/ffmpeg-${FFMPEG_VERSION}/ffmpeg"
[[ -f "$BUILT" ]] || die "ffmpeg did not produce a binary at $BUILT"

# Staged under its final name, not as `ffmpeg.tmp`. On arm64 every Mach-O
# carries an ad-hoc linker signature whose identifier is taken from the file
# name, and a shipped binary identifying itself as `ffmpeg.tmp` is a small lie
# that survives into `codesign -dvv`.
STAGE="$WORK/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$BUILT" "$STAGE/ffmpeg"
if [[ "$(lipo -archs "$STAGE/ffmpeg")" != "arm64" ]]; then
    lipo -thin arm64 "$STAGE/ffmpeg" -output "$STAGE/ffmpeg.thin"
    mv "$STAGE/ffmpeg.thin" "$STAGE/ffmpeg"
fi
strip -S -x "$STAGE/ffmpeg"
chmod 755 "$STAGE/ffmpeg"

# -------------------------------------------------------------------------
# Licence guard. `ffmpeg -L` prints the licence the binary was actually built
# under, which is the only version that cannot be wrong. GPL here would mean
# GPL-2.0-only inside a GPL-3 app — undistributable — so it aborts rather than
# warns, and the artifact is never installed.
# -------------------------------------------------------------------------
LICENCE_LINE="$("$STAGE/ffmpeg" -hide_banner -L 2>&1 | head -4 | tr '\n' ' ')"
case "$LICENCE_LINE" in
    *"Lesser General Public License"*) : ;;
    *) die "built binary reports a non-LGPL licence, refusing to install:
       $LICENCE_LINE" ;;
esac
CONFIG_LINE="$("$STAGE/ffmpeg" -hide_banner -version | grep -m1 configuration || true)"
case "$CONFIG_LINE" in
    *--enable-gpl*|*--enable-nonfree*)
        die "configuration contains --enable-gpl or --enable-nonfree:
       $CONFIG_LINE" ;;
esac

# -------------------------------------------------------------------------
# Self-test. Verify by running the thing, not by reading configure's summary:
# a component silently missing from --disable-everything shows up here as a
# non-zero exit, and nowhere earlier. Both codecs, on a real WAV, with the
# exact argv AudioFileIO.ffmpegArguments builds — including `-progress pipe:1`,
# whose output must carry out_time_us / out_time_ms for
# AudioFileIO.ffmpegProgressMicroseconds to parse.
# -------------------------------------------------------------------------
say "Self-test"
TEST="$WORK/selftest"
rm -rf "$TEST"; mkdir -p "$TEST"
python3 - "$TEST/tone.wav" <<'PY'
import math, struct, sys
rate, secs, ch = 48000, 4.0, 2
frames = int(rate * secs)
data = bytearray()
for i in range(frames):
    t = i / rate
    data += struct.pack('<ff', 0.35 * math.sin(2 * math.pi * 440 * t),
                                0.35 * math.sin(2 * math.pi * 554.365 * t))
fmt = struct.pack('<HHIIHH', 3, ch, rate, rate * ch * 4, ch * 4, 32)
body = (b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt
        + b'data' + struct.pack('<I', len(data)) + bytes(data))
open(sys.argv[1], 'wb').write(b'RIFF' + struct.pack('<I', len(body)) + body)
PY

selftest() {  # selftest <codec> <bitrate> <extension>
    local codec="$1" rate="$2" ext="$3"
    local out="$TEST/tone.$ext" progress="$TEST/$codec-progress.txt" errs="$TEST/$codec-stderr.txt"
    "$STAGE/ffmpeg" -hide_banner -nostdin -y -loglevel error -progress pipe:1 \
        -i "$TEST/tone.wav" -c:a "$codec" -b:a "$rate" "$out" \
        > "$progress" 2> "$errs" \
        || die "$codec encode failed: $(tail -1 "$errs")"
    [[ -s "$out" ]] || die "$codec produced an empty file"
    grep -qE '^out_time_us=[0-9]+' "$progress" \
        || die "$codec emitted no out_time_us; -progress pipe:1 is broken (missing pipe protocol?)"
    grep -qE '^out_time_ms=[0-9]+' "$progress" \
        || die "$codec emitted no out_time_ms; AudioFileIO accepts either key"
    grep -q '^progress=end' "$progress" || die "$codec never reported progress=end"
    printf '    %-12s %s bytes, %s progress blocks\n' \
        "$codec" "$(stat -f%z "$out")" "$(grep -c '^progress=' "$progress")"
}

selftest libmp3lame 320k mp3
selftest libopus    160k opus

# The intermediate is not always float: s16/s24 decoders are enabled so a
# differently-staged WAV is not a mystery failure. Prove they are really there.
for depth in 16 24; do
    python3 - "$TEST/pcm$depth.wav" "$depth" <<'PY'
import math, struct, sys
path, bits = sys.argv[1], int(sys.argv[2])
rate, secs, ch = 48000, 1.0, 2
peak = (1 << (bits - 1)) - 1
data = bytearray()
for i in range(int(rate * secs)):
    for f in (440, 554.365):
        v = int(0.35 * math.sin(2 * math.pi * f * i / rate) * peak)
        data += (v & ((1 << bits) - 1)).to_bytes(bits // 8, 'little')
fmt = struct.pack('<HHIIHH', 1, ch, rate, rate * ch * (bits // 8), ch * (bits // 8), bits)
body = (b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt
        + b'data' + struct.pack('<I', len(data)) + bytes(data))
open(path, 'wb').write(b'RIFF' + struct.pack('<I', len(body)) + body)
PY
    "$STAGE/ffmpeg" -hide_banner -nostdin -y -loglevel error -i "$TEST/pcm$depth.wav" \
        -c:a libmp3lame -b:a 320k "$TEST/pcm$depth.mp3" 2>"$TEST/pcm$depth.err" \
        || die "pcm_s${depth}le decode failed: $(tail -1 "$TEST/pcm$depth.err")"
    printf '    pcm_s%sle    ok\n' "$depth"
done

mv "$STAGE/ffmpeg" "$OUT"
shasum -a 256 "$OUT" | awk '{print $1"  ffmpeg"}' > "$OUT_DIR/ffmpeg.sha256"

say "Built $OUT"
printf '    version   ffmpeg %s + libmp3lame %s + libopus %s\n' \
    "$FFMPEG_VERSION" "$LAME_VERSION" "$OPUS_VERSION"
printf '    archs     %s\n' "$(lipo -archs "$OUT")"
printf '    size      %s (%s bytes)\n' \
    "$(du -h "$OUT" | awk '{print $1}')" "$(stat -f%z "$OUT")"
printf '    sha256    %s\n' "$(awk '{print $1}' < "$OUT_DIR/ffmpeg.sha256")"
printf '    links     %s\n' "$(otool -L "$OUT" | tail -n +2 | awk '{print $1}' | tr '\n' ' ')"
"$OUT" -hide_banner -version | head -2 | sed 's/^/    /'
