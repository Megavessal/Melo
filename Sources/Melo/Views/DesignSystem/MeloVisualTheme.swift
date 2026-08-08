import AppKit
import SwiftUI

extension MeloVisualTheme {
    @MainActor
    func accentColor(
        customHex: String,
        generatedTheme: GeneratedMeloTheme? = nil
    ) -> Color {
        switch self {
        case .systemAccent:
            return Color(nsColor: .controlAccentColor)
        case .space:
            return Color(red: 0.36, green: 0.68, blue: 1.0)
        case .galaxy:
            return Color(red: 0.91, green: 0.36, blue: 0.94)
        case .aurora:
            return Color(red: 0.34, green: 0.92, blue: 0.78)
        case .custom:
            return Color(meloHex: customHex) ?? Color(nsColor: .controlAccentColor)
        case .aiGenerated:
            // Same legibility floor as the backdrop's own accent — this color
            // tints controls sitting on a forced-dark panel.
            let theme = (generatedTheme ?? .fallback).normalized
            return ThemeContrast.foreground(
                theme.accentHex,
                fallback: Color(nsColor: .controlAccentColor)
            )
        }
    }

    @MainActor
    func resolvedColorScheme(appearance: AppearancePreference) -> ColorScheme? {
        prefersDarkAppearance ? .dark : appearance.swiftUIColorScheme
    }

    var resolvedNSAppearance: NSAppearance? {
        prefersDarkAppearance ? NSAppearance(named: .darkAqua) : nil
    }
}

extension Color {
    init?(meloHex: String) {
        let value = meloHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    @MainActor
    var meloHexRGB: String? {
        guard let rgb = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}

/// A themed layer over native macOS glass. The same backdrop is used by both
/// the menu-bar panel and Settings, so animated themes remain visually
/// continuous throughout Melo without altering the layout of either surface.
struct MeloThemeBackdrop: View {
    let theme: MeloVisualTheme
    let customAccentHex: String
    let generatedTheme: GeneratedMeloTheme?
    /// Whether the surface hosting this backdrop is actually on screen. The
    /// animated themes previously kept their timelines running whenever the
    /// view existed, so a closed menu-bar popup still drove a 24 fps `Canvas`
    /// redraw loop in the background. Defaults to `true` so the Settings
    /// window, which is only alive while visible, needs no call-site change.
    var isVisible: Bool = true

    @MainActor private var accent: Color {
        theme.accentColor(customHex: customAccentHex, generatedTheme: generatedTheme)
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
            Color.popupBackgroundOverlay

            switch theme {
            case .systemAccent:
                LinearGradient(
                    colors: [accent.opacity(0.10), .clear, accent.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                DeskMacPeek(accent: accent, isVisible: isVisible)

            case .space:
                // Alphas were 0.97/0.92/0.94, which painted over the
                // `.popover` material completely: Melo paid for behind-window
                // vibrancy on every frame and then hid the result behind an
                // opaque panel. Kept at or below 0.70 so the desktop reads
                // through and the popup is still glass, while staying dark
                // enough for white label text.
                LinearGradient(
                    colors: [
                        Color(red: 0.018, green: 0.045, blue: 0.13).opacity(0.70),
                        Color(red: 0.065, green: 0.025, blue: 0.15).opacity(0.64),
                        .black.opacity(0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // 21 stars is 16.7% above the prior 18-star field.
                AnimatedStarField(tint: .cyan, density: 21, sparkleStrength: 0.22, isVisible: isVisible)
                RocketFlight(isVisible: isVisible)

            case .galaxy:
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.015, blue: 0.21).opacity(0.70),
                        Color(red: 0.30, green: 0.035, blue: 0.34).opacity(0.62),
                        Color(red: 0.015, green: 0.10, blue: 0.25).opacity(0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.pink.opacity(0.27), Color.purple.opacity(0.09), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 380
                )
                // 28 stars is 16.7% above the prior 24-star field.
                AnimatedStarField(tint: .pink, density: 28, sparkleStrength: 0.23, isVisible: isVisible)
                RocketFlight(isVisible: isVisible)

            case .aurora:
                // The rocket belongs to Space and Galaxy. Aurora is the one
                // themed sky with ground under it, and its own visitor lives
                // there — see `CabinWindowLight`.
                AuroraNightBackdrop(isVisible: isVisible)

            case .custom:
                LinearGradient(
                    colors: [accent.opacity(0.24), .clear, accent.opacity(0.11)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                PaintBrushStroke(accent: accent, isVisible: isVisible)

            case .aiGenerated:
                GeneratedThemeBackdrop(
                    theme: (generatedTheme ?? .fallback).normalized,
                    isVisible: isVisible
                )
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

// MARK: - Stars

/// A restrained two-depth star field. Stars drift by fractions of a point at
/// different rates, creating a mild parallax impression without following the
/// pointer or competing with the controls. A subset grows short cross-shaped
/// glints on a comfortable three-to-five-second rhythm so the sparkle remains
/// visible without looking like a flashing effect.
private struct AnimatedStarField: View {
    let tint: Color
    let density: Int
    let sparkleStrength: Double
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStatic: Bool { reduceMotion || !isVisible }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: isStatic)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let time = isStatic ? 0 : timeline.date.timeIntervalSinceReferenceDate

                for index in 0..<max(density, 0) {
                    let normalizedX = CGFloat(deterministicUnit(index: index, salt: 17))
                    let normalizedY = CGFloat(deterministicUnit(index: index, salt: 71))
                    let depth = 0.28 + deterministicUnit(index: index, salt: 97) * 0.72
                    let radius = CGFloat(0.62 + deterministicUnit(index: index, salt: 113) * 1.18)
                    let period = 3.15 + deterministicUnit(index: index, salt: 149) * 2.10
                    let angularSpeed = (.pi * 2) / period
                    let phase = deterministicUnit(index: index, salt: 193) * .pi * 2
                    let wave = (sin(time * angularSpeed + phase) + 1) * 0.5

                    // Less than one point of motion on most windows. Near stars
                    // move a little farther than distant stars for gentle parallax.
                    let driftX = CGFloat(sin(time * (0.055 + depth * 0.018) + phase)) * CGFloat(0.28 + depth * 0.72)
                    let driftY = CGFloat(cos(time * (0.041 + depth * 0.014) + phase * 0.7)) * CGFloat(0.18 + depth * 0.46)
                    let center = CGPoint(
                        x: size.width * normalizedX + driftX,
                        y: size.height * normalizedY + driftY
                    )

                    let highlighted = index.isMultiple(of: 5)
                    let base = highlighted ? 0.31 : 0.20
                    let opacity = min(base + wave * sparkleStrength, 0.66)
                    let starColor = highlighted ? tint : Color.white
                    let rect = CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )

                    context.opacity = opacity
                    context.fill(Path(ellipseIn: rect), with: .color(starColor))

                    // Only some stars flare, and only around the top third of
                    // their brightness cycle. This makes the animation visible
                    // without turning the background into a blinking field.
                    if highlighted && !isStatic {
                        let flare = max(0, min(1, (wave - 0.62) / 0.38))
                        if flare > 0 {
                            let arm = radius * CGFloat(1.8 + flare * 1.8)
                            var cross = Path()
                            cross.move(to: CGPoint(x: center.x - arm, y: center.y))
                            cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
                            cross.move(to: CGPoint(x: center.x, y: center.y - arm))
                            cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
                            context.opacity = min(0.24, flare * sparkleStrength * 1.35)
                            context.stroke(cross, with: .color(starColor), lineWidth: 0.65)
                        }
                    }
                }
                context.opacity = 1
            }
        }
    }

    private func deterministicUnit(index: Int, salt: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: index &* 1_103_515_245 &+ salt &* 12_345)
        value ^= value >> 16
        value &*= 0x7FEB352D
        value ^= value >> 15
        return Double(value % 10_000) / 10_000
    }
}

// MARK: - Rocket

/// Small pixel-art rockets. Three lanes fly independently, each on its own
/// cycle length and phase, so the sky is usually empty or holds one rocket and
/// occasionally holds three. The lane periods are deliberately not multiples of
/// one another — equal periods would make all three cross together every time,
/// which reads as a formation rather than as traffic.
private struct RocketFlight: View {
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStatic: Bool { reduceMotion || !isVisible }

    /// Three at once is the ceiling, not the norm.
    private static let laneCount = 3

    /// flight, rest, phase offset — per lane, in seconds.
    private static let laneTiming: [(flight: Double, rest: Double, offset: Double)] = [
        (10.8, 8.2, 0.0),
        (12.7, 17.3, 6.4),
        (9.4, 25.1, 13.9)
    ]

    /// 15% smaller than the previous 54×26 / 50×24 pair.
    private static let flyingSize = CGSize(width: 46, height: 22)
    private static let restingSize = CGSize(width: 43, height: 20)

    var body: some View {
        GeometryReader { geometry in
            if isStatic {
                PixelRocketGlyph(flamePhase: 0)
                    .frame(width: Self.restingSize.width, height: Self.restingSize.height)
                    .rotationEffect(.degrees(-4))
                    .position(
                        x: max(geometry.size.width - 40, 30),
                        y: min(46, max(geometry.size.height * 0.15, 26))
                    )
                    .opacity(0.54)
            } else {
                // This was the one timeline in the file with no `paused:`
                // argument at all, so the rocket kept flying behind a closed
                // popup.
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: isStatic)) { timeline in
                    let now = meloEggTime(timeline.date)
                    ForEach(0..<Self.laneCount, id: \.self) { lane in
                        rocket(lane: lane, now: now, size: geometry.size)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rocket(lane: Int, now: TimeInterval, size: CGSize) -> some View {
        let timing = Self.laneTiming[lane]
        let cycleDuration = timing.flight + timing.rest
        let shifted = now + timing.offset
        let cycleIndex = Int(floor(shifted / cycleDuration))
        let elapsed = shifted - Double(cycleIndex) * cycleDuration
        let isFlying = elapsed < timing.flight

        if isFlying {
            let rawProgress = min(max(elapsed / timing.flight, 0), 1)
            let progress = rawProgress * rawProgress * (3 - 2 * rawProgress)
            let travelsRight = (cycleIndex &+ lane).isMultiple(of: 2)

            let margin: CGFloat = 62
            let travelDistance = size.width + margin * 2
            let startLane = edgeLane(index: cycleIndex - 1, lane: lane, height: size.height)
            let proposedEndLane = edgeLane(index: cycleIndex, lane: lane, height: size.height)
            let maxVerticalChange = CGFloat(tan(Double.pi / 12)) * travelDistance
            let endLane = min(
                max(proposedEndLane, startLane - maxVerticalChange),
                startLane + maxVerticalChange
            )
            let y = startLane + (endLane - startLane) * CGFloat(progress)
            let startX = travelsRight ? -margin : size.width + margin
            let endX = travelsRight ? size.width + margin : -margin
            let x = startX + (endX - startX) * CGFloat(progress)
            let pathAngle = atan2(Double(endLane - startLane), Double(travelDistance)) * 180 / .pi
            let visualAngle = travelsRight ? pathAngle : -pathAngle

            PixelRocketGlyph(flamePhase: now + Double(lane) * 0.37)
                .frame(width: Self.flyingSize.width, height: Self.flyingSize.height)
                .scaleEffect(x: travelsRight ? 1 : -1, y: 1)
                .rotationEffect(.degrees(max(-15, min(15, visualAngle))))
                .position(x: x, y: y)
                // Lanes further back are fainter, so overlapping passes read as
                // depth instead of as a collision.
                .opacity(0.70 - Double(lane) * 0.11)
        }
    }

    /// Each lane owns a horizontal band of the popup, so two rockets in the air
    /// at once never trace the same line.
    private func edgeLane(index: Int, lane: Int, height: CGFloat) -> CGFloat {
        let usableMin = max(28, height * 0.16)
        let usableMax = max(usableMin + 1, min(height - 30, height * 0.66))
        let bandHeight = (usableMax - usableMin) / CGFloat(Self.laneCount)
        let bandStart = usableMin + bandHeight * CGFloat(lane)
        let unit = deterministicUnit(index: index, salt: 811 &+ lane &* 197)
        return bandStart + bandHeight * CGFloat(unit)
    }

    private func deterministicUnit(index: Int, salt: Int) -> Double {
        var value = UInt64(bitPattern: Int64(index &* 1_103_515_245 &+ salt &* 12_345))
        value ^= value >> 16
        value &*= 0x7FEB352D
        value ^= value >> 15
        return Double(value % 10_000) / 10_000
    }
}

/// Drawn on an 18×9 logical pixel grid. The pale exhaust pixels are short and
/// low-opacity so they read as movement without leaving a distracting trail.
private struct PixelRocketGlyph: View {
    let flamePhase: TimeInterval

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let pixel = min(size.width / 18, size.height / 9)
            let xInset = (size.width - pixel * 18) / 2
            let yInset = (size.height - pixel * 9) / 2
            let flicker = (sin(flamePhase * 7.2) + 1) * 0.5

            context.addFilter(.shadow(color: .black.opacity(0.30), radius: 2, x: 0, y: 1))

            fillPixel(&context, color: Color.white.opacity(0.72), x: 0, y: 4, pixel: pixel, xInset: xInset, yInset: yInset, opacity: 0.10 + flicker * 0.05)
            fillPixel(&context, color: Color(red: 0.72, green: 0.82, blue: 0.90), x: 1, y: 4, pixel: pixel, xInset: xInset, yInset: yInset, opacity: 0.16)
            fillPixel(&context, color: Color(red: 0.72, green: 0.82, blue: 0.90), x: 2, y: 3, pixel: pixel, xInset: xInset, yInset: yInset, opacity: 0.22)
            fillPixel(&context, color: .white, x: 2, y: 4, width: 2, pixel: pixel, xInset: xInset, yInset: yInset, opacity: 0.24 + flicker * 0.08)

            // Flame and engine.
            fillPixel(&context, color: Color(red: 1.0, green: 0.35, blue: 0.20), x: 3, y: 3, width: 2, height: 3, pixel: pixel, xInset: xInset, yInset: yInset, opacity: 0.64 + flicker * 0.14)
            fillPixel(&context, color: Color(red: 1.0, green: 0.82, blue: 0.35), x: 4, y: 4, pixel: pixel, xInset: xInset, yInset: yInset, opacity: 0.76)
            fillPixel(&context, color: Color(red: 0.50, green: 0.54, blue: 0.60), x: 5, y: 3, height: 3, pixel: pixel, xInset: xInset, yInset: yInset)

            // White body with cool-gray lower shading.
            fillPixel(&context, color: Color.white.opacity(0.96), x: 6, y: 2, width: 8, height: 5, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: Color(red: 0.82, green: 0.88, blue: 0.94), x: 6, y: 6, width: 8, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: Color.white.opacity(0.96), x: 5, y: 3, height: 3, pixel: pixel, xInset: xInset, yInset: yInset)

            // Red nose and fins.
            let red = Color(red: 0.88, green: 0.10, blue: 0.16)
            fillPixel(&context, color: red, x: 14, y: 2, height: 5, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: red, x: 15, y: 3, height: 3, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: red, x: 16, y: 4, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: red.opacity(0.92), x: 7, y: 0, width: 3, height: 2, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: red.opacity(0.92), x: 7, y: 7, width: 3, height: 2, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: red.opacity(0.74), x: 6, y: 1, width: 2, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: red.opacity(0.74), x: 6, y: 7, width: 2, pixel: pixel, xInset: xInset, yInset: yInset)

            // Window and one highlight pixel.
            fillPixel(&context, color: Color(red: 0.30, green: 0.72, blue: 0.94), x: 11, y: 3, width: 2, height: 2, pixel: pixel, xInset: xInset, yInset: yInset)
            fillPixel(&context, color: Color.white.opacity(0.72), x: 11, y: 3, pixel: pixel, xInset: xInset, yInset: yInset)
            context.opacity = 1
        }
    }

    private func fillPixel(
        _ context: inout GraphicsContext,
        color: Color,
        x: Int,
        y: Int,
        width: Int = 1,
        height: Int = 1,
        pixel: CGFloat,
        xInset: CGFloat,
        yInset: CGFloat,
        opacity: Double = 1
    ) {
        let rect = CGRect(
            x: xInset + CGFloat(x) * pixel,
            y: yInset + CGFloat(y) * pixel,
            width: CGFloat(width) * pixel,
            height: CGFloat(height) * pixel
        )
        context.opacity = opacity
        context.fill(Path(rect), with: .color(color))
    }
}

// MARK: - Per-theme easter eggs
//
// The rocket is the reference for everything below it: one small thing, rarely,
// briefly, drawn in the pixel idiom, gone again. Each theme gets a visitor that
// belongs to *that* theme rather than the rocket in a different colour, and all
// of them share three rules:
//
// 1. They rest. `EggCycle` returns `nil` for most of every cycle and nothing is
//    drawn at all in that time — not a transparent draw, no draw.
// 2. They stop when the popup is closed. `isVisible` comes down from
//    `MenuBarPopupView`, and a hidden host takes the no-timeline branch, so a
//    closed popup never schedules a redraw. This is the defect fixed once
//    already for the star fields and the rocket; do not reintroduce it.
// 3. Reduce Motion takes the same branch and shows the visitor in a still rest
//    pose. Matching the rocket's parked glyph, so motion-sensitive users get the
//    same easter egg rather than none.

#if MELO_DEV
/// Snapshot-only clock override.
///
/// These eggs appear for a handful of seconds out of every minute or two, so a
/// frame rendered against wall-clock time almost always catches an empty stage.
/// That is correct behaviour and a useless screenshot. Pinning the clock lets a
/// scene capture one mid-appearance **without making the effect commoner**,
/// which is the trade that would actually damage the feature.
///
/// Applies to the rockets as well, so the Space and Galaxy gate is capturable
/// on the same terms.
///
/// **It is sticky.** Nothing clears it between scenes, so a scene that sets it
/// would otherwise freeze an egg into every frame rendered after it. Clear it in
/// the shared `prepare` wrapper in `SnapshotScenes.swift` — the one that already
/// calls `applyAppearance(scheme)` — before each scene's own `prepare` runs.
///
/// `nonisolated(unsafe)` because the timeline closures that read it are not
/// actor-isolated. It is written from the main thread by the snapshot harness
/// and is not compiled into a release build at all.
enum MeloEasterEggClock {
    nonisolated(unsafe) static var forcedTime: TimeInterval?
}
#endif

private func meloEggTime(_ date: Date) -> TimeInterval {
    #if MELO_DEV
    if let forced = MeloEasterEggClock.forcedTime { return forced }
    #endif
    return date.timeIntervalSinceReferenceDate
}

/// A long rest and a short appearance. `nil` means resting.
private struct EggCycle {
    /// Seconds from one appearance to the next.
    let period: Double
    /// Seconds the visitor is on screen. Kept under a tenth of `period`.
    let duration: Double
    /// Staggers the themes against one another, so switching themes doesn't
    /// hand every one of them the same phase.
    let offset: Double

    /// - Returns: the cycle number, so successive appearances can vary, and
    ///   progress through the appearance in `0...1`.
    func appearance(at now: TimeInterval) -> (index: Int, progress: Double)? {
        let shifted = now + offset
        let index = Int(floor(shifted / period))
        let elapsed = shifted - Double(index) * period
        guard elapsed < duration else { return nil }
        return (index, min(max(elapsed / duration, 0), 1))
    }
}

/// The integer hash the star field and rocket already use, as a free function
/// so the eggs below vary per appearance without a fourth copy of it.
private func meloEggUnit(index: Int, salt: Int) -> Double {
    var value = UInt64(truncatingIfNeeded: index &* 1_103_515_245 &+ salt &* 12_345)
    value ^= value >> 16
    value &*= 0x7FEB352D
    value ^= value >> 15
    return Double(value % 10_000) / 10_000
}

private func meloEggEase(_ unit: Double) -> Double {
    let clamped = min(max(unit, 0), 1)
    return clamped * clamped * (3 - 2 * clamped)
}

/// Maps `unit` from `range` onto `0...1`, clamped outside it. Lets one progress
/// value drive several overlapping phases of an appearance.
private func meloEggSegment(_ unit: Double, _ range: ClosedRange<Double>) -> Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return unit >= range.upperBound ? 1 : 0 }
    return min(max((unit - range.lowerBound) / span, 0), 1)
}

private func meloFillPixel(
    _ context: inout GraphicsContext,
    color: Color,
    x: Int,
    y: Int,
    width: Int = 1,
    height: Int = 1,
    pixel: CGFloat,
    xInset: CGFloat,
    yInset: CGFloat,
    opacity: Double = 1
) {
    let rect = CGRect(
        x: xInset + CGFloat(x) * pixel,
        y: yInset + CGFloat(y) * pixel,
        width: CGFloat(width) * pixel,
        height: CGFloat(height) * pixel
    )
    context.opacity = opacity
    context.fill(Path(rect), with: .color(color))
}

// MARK: Mac — the desk Mac

/// The visitor for `.systemAccent`.
///
/// A small pixel-art all-in-one computer rises just past the bottom edge, its
/// screen powers on in the Mac's current accent colour, it sits there for a few
/// seconds, and it sinks back out of frame. This theme's whole identity is "your
/// Mac's accent", so the accent is what the little screen shows.
///
/// It carries a dark outline and a light body on purpose: `.systemAccent` and
/// `.custom` are the two themes that do **not** force dark appearance, so this
/// glyph can land on a white panel. Contrast comes from the outline, never from
/// the accent, which may be graphite.
private struct DeskMacPeek: View {
    let accent: Color
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStatic: Bool { reduceMotion || !isVisible }

    private static let cycle = EggCycle(period: 78, duration: 6.2, offset: 4)
    /// A 12×12 grid at 2.5pt — a third of the rocket's footprint.
    private static let glyphSize = CGSize(width: 30, height: 30)

    var body: some View {
        GeometryReader { geometry in
            if isStatic {
                machine(geometry: geometry, rise: 1, screen: 1, flash: 0)
                    .opacity(0.50)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: isStatic)) { timeline in
                    if let appearance = Self.cycle.appearance(at: meloEggTime(timeline.date)) {
                        let rise = meloEggEase(meloEggSegment(appearance.progress, 0...0.16))
                            * (1 - meloEggEase(meloEggSegment(appearance.progress, 0.80...1)))
                        // The screen comes on a beat after the machine settles,
                        // with one bright frame, the way a CRT strikes.
                        let flash = 1 - meloEggEase(meloEggSegment(appearance.progress, 0.22...0.27))
                        let screen = meloEggEase(meloEggSegment(appearance.progress, 0.21...0.24))
                            * (1 - meloEggEase(meloEggSegment(appearance.progress, 0.82...0.94)))
                        machine(
                            geometry: geometry,
                            rise: rise,
                            screen: screen,
                            flash: appearance.progress > 0.21 ? flash : 0,
                            cycleIndex: appearance.index
                        )
                        .opacity(0.62)
                    }
                }
            }
        }
    }

    private func machine(
        geometry: GeometryProxy,
        rise: Double,
        screen: Double,
        flash: Double,
        cycleIndex: Int = 0
    ) -> some View {
        // Left of centre, and never under the right edge where the scroll
        // indicator and the row disclosure controls sit.
        let unit = meloEggUnit(index: cycleIndex, salt: 419)
        let x = geometry.size.width * CGFloat(0.10 + unit * 0.32)
        let hidden = geometry.size.height + Self.glyphSize.height * 0.7
        let peeked = geometry.size.height - Self.glyphSize.height * 0.5 + 3
        let y = hidden + (peeked - hidden) * CGFloat(rise)

        return DeskMacGlyph(accent: accent, screenLevel: screen, flash: flash)
            .frame(width: Self.glyphSize.width, height: Self.glyphSize.height)
            .position(x: x, y: y)
    }
}

/// Drawn on a 12×12 logical pixel grid.
private struct DeskMacGlyph: View {
    let accent: Color
    let screenLevel: Double
    let flash: Double

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let pixel = min(size.width / 12, size.height / 12)
            let xInset = (size.width - pixel * 12) / 2
            let yInset = (size.height - pixel * 12) / 2

            context.addFilter(.shadow(color: .black.opacity(0.32), radius: 2, x: 0, y: 1))

            let outline = Color(red: 0.16, green: 0.15, blue: 0.14)
            let shell = Color(red: 0.90, green: 0.87, blue: 0.81)
            let shellShade = Color(red: 0.76, green: 0.73, blue: 0.68)

            // Case: one dark rectangle with the shell inset inside it, so the
            // outline is a real 1-pixel border rather than eight edge fills.
            meloFillPixel(&context, color: outline, x: 1, y: 0, width: 10, height: 10, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: shell, x: 2, y: 1, width: 8, height: 8, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: shellShade, x: 2, y: 8, width: 8, pixel: pixel, xInset: xInset, yInset: yInset)

            // Screen well, dark whether or not it is lit.
            meloFillPixel(&context, color: outline.opacity(0.86), x: 3, y: 2, width: 6, height: 4, pixel: pixel, xInset: xInset, yInset: yInset)
            if screenLevel > 0.01 {
                meloFillPixel(&context, color: accent, x: 4, y: 3, width: 4, height: 2, pixel: pixel, xInset: xInset, yInset: yInset, opacity: 0.55 + screenLevel * 0.45)
                meloFillPixel(&context, color: .white, x: 4, y: 3, pixel: pixel, xInset: xInset, yInset: yInset, opacity: min(0.9, screenLevel * 0.45 + flash * 0.85))
            }

            // Drive slot and the stand it rests on.
            meloFillPixel(&context, color: outline.opacity(0.7), x: 4, y: 7, width: 4, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: shellShade, x: 4, y: 10, width: 4, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: outline, x: 2, y: 11, width: 8, pixel: pixel, xInset: xInset, yInset: yInset)
            context.opacity = 1
        }
    }
}

// MARK: Aurora — the cabin

/// The visitor for `.aurora`.
///
/// Once in a while a single warm window lights up on the far ridge, holds with a
/// lamp's small unsteadiness, and goes dark again. Aurora is the only theme with
/// ground drawn under its sky, so its egg is that someone lives out there and is
/// also watching. Nothing new is drawn except the light itself — the mountain it
/// sits on is already there.
///
/// It beat a shooting star, which would have been the star field's own
/// vocabulary sped up, and the rocket's gesture wearing a different costume.
private struct CabinWindowLight: View {
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStatic: Bool { reduceMotion || !isVisible }

    private static let cycle = EggCycle(period: 74, duration: 7.4, offset: 21)

    /// Points that sit below `NightMountainSilhouette`'s far ridge and above its
    /// near one, so the lamp always reads as standing on the distant slope
    /// rather than floating in the sky or on the black foreground mass.
    private static let spots: [CGPoint] = [
        CGPoint(x: 0.33, y: 0.80),
        CGPoint(x: 0.60, y: 0.78),
        CGPoint(x: 0.22, y: 0.75)
    ]

    var body: some View {
        GeometryReader { geometry in
            if isStatic {
                lamp(geometry: geometry, spot: Self.spots[0], level: 0.55)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: isStatic)) { timeline in
                    let now = meloEggTime(timeline.date)
                    if let appearance = Self.cycle.appearance(at: now) {
                        let rise = meloEggEase(meloEggSegment(appearance.progress, 0...0.19))
                        let fall = 1 - meloEggEase(meloEggSegment(appearance.progress, 0.78...1))
                        // A few percent of unsteadiness. A lamp, not a beacon.
                        let unsteady = 0.94 + (sin(now * 2.6) + 1) * 0.03
                        lamp(
                            geometry: geometry,
                            spot: Self.spots[abs(appearance.index) % Self.spots.count],
                            level: rise * fall * unsteady
                        )
                    }
                }
            }
        }
    }

    private func lamp(geometry: GeometryProxy, spot: CGPoint, level: Double) -> some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            guard level > 0.01 else { return }
            let warm = Color(red: 1.0, green: 0.80, blue: 0.46)
            let center = CGPoint(x: size.width * spot.x, y: size.height * spot.y)

            let halo = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
            context.opacity = level * 0.32
            context.fill(
                Path(ellipseIn: halo),
                with: .radialGradient(
                    Gradient(colors: [warm.opacity(0.85), .clear]),
                    center: center,
                    startRadius: 0,
                    endRadius: 9
                )
            )

            context.opacity = level * 0.86
            context.fill(
                Path(CGRect(x: center.x - 1.6, y: center.y - 1.3, width: 3.2, height: 2.6)),
                with: .color(warm)
            )
            context.opacity = 1
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
}

// MARK: Custom — the brush

/// The visitor for `.custom`.
///
/// A small pixel paintbrush leans in low on the left, sweeps right leaving a
/// short stroke in the user's own colour, lifts away, and the stroke dries off.
///
/// `.custom` is the one theme whose colour is unknown at build time — it can be
/// white, black, or anything between — so **the character is shape-based and the
/// colour is only what it paints.** The brush's legibility comes from its dark
/// outline and the same drop-shadow filter the rocket uses, never from the hue;
/// the accent appears in the bristles and the stroke, where being pale or dark
/// is the point rather than a contrast failure. An accent-tinted glow, or the
/// rocket recoloured, would both have disappeared at the ends of the range.
private struct PaintBrushStroke: View {
    let accent: Color
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStatic: Bool { reduceMotion || !isVisible }

    private static let cycle = EggCycle(period: 68, duration: 5.6, offset: 47)
    private static let glyphSize = CGSize(width: 28, height: 16)

    var body: some View {
        GeometryReader { geometry in
            let y = min(geometry.size.height * 0.855, geometry.size.height - 26)
            let startX = geometry.size.width * 0.08

            if isStatic {
                let endX = startX + geometry.size.width * 0.28
                ZStack {
                    stroke(from: startX, to: endX, y: y, opacity: 0.42, size: geometry.size)
                    brush(at: endX, y: y, lift: 0, opacity: 0.45)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: isStatic)) { timeline in
                    if let appearance = Self.cycle.appearance(at: meloEggTime(timeline.date)) {
                        let unit = meloEggUnit(index: appearance.index, salt: 617)
                        let span = geometry.size.width * CGFloat(0.22 + unit * 0.12)
                        let sweep = meloEggEase(meloEggSegment(appearance.progress, 0.09...0.48))
                        let lift = meloEggEase(meloEggSegment(appearance.progress, 0.48...0.60))
                        let enter = meloEggEase(meloEggSegment(appearance.progress, 0...0.09))
                        let tipX = startX + span * CGFloat(sweep)
                        // The stroke outlives the brush by a couple of seconds,
                        // then dries off; the panel is left exactly as it was.
                        let strokeFade = 1 - meloEggEase(meloEggSegment(appearance.progress, 0.62...1))

                        ZStack {
                            stroke(from: startX, to: tipX, y: y, opacity: 0.58 * strokeFade, size: geometry.size)
                            brush(at: tipX, y: y, lift: lift, opacity: 0.72 * enter * (1 - lift))
                        }
                    }
                }
            }
        }
    }

    private func stroke(from startX: CGFloat, to endX: CGFloat, y: CGFloat, opacity: Double, size: CGSize) -> some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
            guard endX - startX > 1, opacity > 0.01 else { return }
            context.addFilter(.shadow(color: .black.opacity(0.26), radius: 1.5, x: 0, y: 1))

            var path = Path()
            path.move(to: CGPoint(x: startX, y: y))
            let segments = 8
            for segment in 1...segments {
                let unit = CGFloat(segment) / CGFloat(segments)
                // A hand's waver, under a point of it, so the stroke doesn't
                // read as a divider rule drawn across the panel.
                let waver = sin(Double(unit) * .pi * 2.1) * 0.8
                path.addLine(to: CGPoint(x: startX + (endX - startX) * unit, y: y + CGFloat(waver)))
            }

            context.opacity = opacity
            context.stroke(
                path,
                with: .color(accent),
                style: StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round)
            )
            context.opacity = 1
        }
        .frame(width: size.width, height: size.height)
    }

    private func brush(at tipX: CGFloat, y: CGFloat, lift: Double, opacity: Double) -> some View {
        PaintBrushGlyph(accent: accent)
            .frame(width: Self.glyphSize.width, height: Self.glyphSize.height)
            // Handle up, bristles down onto the line — a clockwise tilt is what
            // puts the tip on the stroke instead of hovering above it. Lifting
            // rolls the brush back toward flat as it rises.
            .rotationEffect(.degrees(20 - lift * 16))
            .position(
                x: tipX - Self.glyphSize.width * 0.36,
                y: y - Self.glyphSize.height * 0.34 - CGFloat(lift) * 11
            )
            .opacity(opacity)
    }
}

/// Drawn on a 14×8 logical pixel grid, bristles leading, so the paint appears
/// behind the tip rather than in front of it.
private struct PaintBrushGlyph: View {
    let accent: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let pixel = min(size.width / 14, size.height / 8)
            let xInset = (size.width - pixel * 14) / 2
            let yInset = (size.height - pixel * 8) / 2

            context.addFilter(.shadow(color: .black.opacity(0.32), radius: 2, x: 0, y: 1))

            let outline = Color(red: 0.14, green: 0.13, blue: 0.13)
            let handle = Color(red: 0.87, green: 0.74, blue: 0.51)
            let ferrule = Color(red: 0.78, green: 0.80, blue: 0.83)

            // Dark silhouette first, light inset second: the outline is what
            // keeps this readable on a white panel and on a black one.
            meloFillPixel(&context, color: outline, x: 0, y: 2, width: 10, height: 4, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: outline, x: 9, y: 1, width: 5, height: 6, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: handle, x: 0, y: 3, width: 7, height: 2, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: ferrule, x: 7, y: 3, width: 3, height: 2, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: accent, x: 10, y: 2, width: 4, height: 4, pixel: pixel, xInset: xInset, yInset: yInset)
            meloFillPixel(&context, color: .white, x: 10, y: 2, width: 2, pixel: pixel, xInset: xInset, yInset: yInset, opacity: 0.28)
            context.opacity = 1
        }
    }
}

// MARK: - Aurora

private struct AuroraNightBackdrop: View {
    var isVisible: Bool = true

    var body: some View {
        ZStack {
            // The night sky was fully opaque, so the `.popover` material below
            // it was rendered and then discarded. Held at or below 0.70.
            LinearGradient(
                colors: [
                    Color(red: 0.005, green: 0.025, blue: 0.085).opacity(0.70),
                    Color(red: 0.015, green: 0.055, blue: 0.13).opacity(0.66),
                    Color(red: 0.012, green: 0.025, blue: 0.055).opacity(0.68),
                    .black.opacity(0.66)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            AnimatedStarField(
                tint: Color(red: 0.62, green: 0.90, blue: 1),
                density: 18,
                sparkleStrength: 0.18,
                isVisible: isVisible
            )
            AuroraRibbons(isVisible: isVisible)
            NightMountainSilhouette()
            CabinWindowLight(isVisible: isVisible)
        }
    }
}

private struct AuroraRibbons: View {
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStatic: Bool { reduceMotion || !isVisible }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: isStatic)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let time = isStatic ? 0 : timeline.date.timeIntervalSinceReferenceDate
                context.blendMode = .screen
                context.addFilter(.blur(radius: max(13, min(size.width, size.height) * 0.035)))

                let colors: [Color] = [
                    Color(red: 0.26, green: 1.0, blue: 0.68),
                    Color(red: 0.18, green: 0.78, blue: 0.92),
                    Color(red: 0.55, green: 0.35, blue: 1.0),
                    Color(red: 0.32, green: 0.96, blue: 0.78)
                ]

                for band in 0..<4 {
                    var path = Path()
                    let bandValue = Double(band)
                    let baseY = size.height * CGFloat(0.18 + bandValue * 0.055)
                    let amplitude = size.height * CGFloat(0.075 + bandValue * 0.012)
                    let phase = time * (0.10 + bandValue * 0.018) + bandValue * 1.7
                    path.move(to: CGPoint(x: -20, y: baseY))

                    let segments = 14
                    for segment in 1...segments {
                        let unit = Double(segment) / Double(segments)
                        let x = size.width * CGFloat(unit)
                        let firstWave = CGFloat(sin(unit * .pi * (2.0 + bandValue * 0.22) + phase))
                        let secondWave = CGFloat(cos(unit * .pi * 5.0 - phase * 0.6))
                        let y = baseY
                            + firstWave * amplitude
                            + secondWave * amplitude * 0.24
                        path.addLine(to: CGPoint(x: x, y: y))
                    }

                    context.opacity = 0.19 - bandValue * 0.018
                    context.stroke(
                        path,
                        with: .color(colors[band]),
                        style: StrokeStyle(
                            lineWidth: max(34, size.height * CGFloat(0.09 - bandValue * 0.008)),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
                context.opacity = 1
            }
        }
    }
}

private struct NightMountainSilhouette: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                var far = Path()
                far.move(to: CGPoint(x: 0, y: size.height))
                far.addLine(to: CGPoint(x: 0, y: size.height * 0.80))
                far.addLine(to: CGPoint(x: size.width * 0.16, y: size.height * 0.67))
                far.addLine(to: CGPoint(x: size.width * 0.30, y: size.height * 0.80))
                far.addLine(to: CGPoint(x: size.width * 0.48, y: size.height * 0.61))
                far.addLine(to: CGPoint(x: size.width * 0.66, y: size.height * 0.79))
                far.addLine(to: CGPoint(x: size.width * 0.84, y: size.height * 0.65))
                far.addLine(to: CGPoint(x: size.width, y: size.height * 0.78))
                far.addLine(to: CGPoint(x: size.width, y: size.height))
                far.closeSubpath()
                context.fill(far, with: .color(Color(red: 0.015, green: 0.035, blue: 0.065).opacity(0.60)))

                var near = Path()
                near.move(to: CGPoint(x: 0, y: size.height))
                near.addLine(to: CGPoint(x: 0, y: size.height * 0.90))
                near.addLine(to: CGPoint(x: size.width * 0.22, y: size.height * 0.77))
                near.addLine(to: CGPoint(x: size.width * 0.42, y: size.height * 0.91))
                near.addLine(to: CGPoint(x: size.width * 0.72, y: size.height * 0.75))
                near.addLine(to: CGPoint(x: size.width, y: size.height * 0.89))
                near.addLine(to: CGPoint(x: size.width, y: size.height))
                near.closeSubpath()
                // The silhouettes cover the bottom third of the popup, so they
                // were the other half of the occlusion problem; still dark
                // enough to read as a ridgeline against the sky.
                context.fill(near, with: .color(.black.opacity(0.66)))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

// MARK: - AI-generated data-only themes

/// Keeps a pasted or generated theme legible.
///
/// `GeneratedMeloTheme.normalized` validates hex strings for *format* only —
/// six hex digits and nothing else. Nothing checks what those digits mean. But
/// `.aiGenerated` also reports `prefersDarkAppearance`, which forces the whole
/// popup into dark aqua and makes every label white. A theme whose background
/// hexes happen to be light therefore renders white text on a near-white panel,
/// including the Settings screen the user would need in order to undo it.
///
/// The clamps are applied where the theme is *rendered* rather than where it is
/// parsed, so an existing stored theme is fixed on next launch without
/// rewriting anyone's saved data.
///
/// Thresholds use WCAG 2.1 relative luminance:
///
/// - **Background ceiling 0.18.** White text needs a 4.5:1 contrast ratio for
///   body copy: (1.0 + 0.05) / (L + 0.05) ≥ 4.5 solves to L ≤ 0.183. Backdrops
///   also draw at ≤ 0.70 alpha over a dark material, so the effective surface
///   is darker still — 0.18 is the conservative end of the range.
/// - **Foreground floor 0.25.** Accent and secondary are used for glyphs,
///   sparkles and ribbons, which are non-text UI needing 3:1 against a near
///   black surface (L ≈ 0.05): (L + 0.05) / 0.10 ≥ 3 solves to L ≥ 0.25.
private enum ThemeContrast {
    static let backgroundLuminanceCeiling = 0.18
    static let foregroundLuminanceFloor = 0.25

    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double
    }

    static func background(_ hex: String, fallback: Color) -> Color {
        guard var rgb = components(hex) else { return fallback }
        // Geometric steps rather than a solve: luminance is monotonic under a
        // uniform scale, and 0.94^96 reaches black, so the loop always exits.
        var steps = 0
        while luminance(rgb) > backgroundLuminanceCeiling && steps < 96 {
            rgb = RGB(red: rgb.red * 0.94, green: rgb.green * 0.94, blue: rgb.blue * 0.94)
            steps += 1
        }
        return color(rgb)
    }

    static func foreground(_ hex: String, fallback: Color) -> Color {
        guard var rgb = components(hex) else { return fallback }
        var steps = 0
        while luminance(rgb) < foregroundLuminanceFloor && steps < 96 {
            rgb = RGB(
                red: rgb.red + (1 - rgb.red) * 0.08,
                green: rgb.green + (1 - rgb.green) * 0.08,
                blue: rgb.blue + (1 - rgb.blue) * 0.08
            )
            steps += 1
        }
        return color(rgb)
    }

    private static func components(_ hex: String) -> RGB? {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let packed = UInt64(value, radix: 16) else { return nil }
        return RGB(
            red: Double((packed >> 16) & 0xFF) / 255,
            green: Double((packed >> 8) & 0xFF) / 255,
            blue: Double(packed & 0xFF) / 255
        )
    }

    private static func color(_ rgb: RGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func luminance(_ rgb: RGB) -> Double {
        0.2126 * linearized(rgb.red)
            + 0.7152 * linearized(rgb.green)
            + 0.0722 * linearized(rgb.blue)
    }

    /// sRGB companding, per WCAG 2.1.
    private static func linearized(_ channel: Double) -> Double {
        channel <= 0.03928
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }
}

private struct GeneratedThemeBackdrop: View {
    let theme: GeneratedMeloTheme
    var isVisible: Bool = true

    private var top: Color { ThemeContrast.background(theme.topHex, fallback: Color(red: 0.03, green: 0.06, blue: 0.16)) }
    private var middle: Color { ThemeContrast.background(theme.middleHex, fallback: Color(red: 0.08, green: 0.03, blue: 0.18)) }
    private var bottom: Color { ThemeContrast.background(theme.bottomHex, fallback: .black) }
    private var accent: Color { ThemeContrast.foreground(theme.accentHex, fallback: .cyan) }
    private var secondary: Color { ThemeContrast.foreground(theme.secondaryHex, fallback: .purple) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [top.opacity(0.70), middle.opacity(0.64), bottom.opacity(0.70)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            switch theme.style {
            case .stars:
                AnimatedStarField(
                    tint: accent,
                    density: theme.starDensity,
                    sparkleStrength: theme.sparkleStrength,
                    isVisible: isVisible
                )
            case .aurora:
                AnimatedStarField(
                    tint: accent,
                    density: max(theme.starDensity / 2, 8),
                    sparkleStrength: min(theme.sparkleStrength, 0.14),
                    isVisible: isVisible
                )
                GeneratedAuroraRibbons(primary: accent, secondary: secondary, isVisible: isVisible)
                NightMountainSilhouette()
            case .nebula:
                RadialGradient(
                    colors: [secondary.opacity(0.34), accent.opacity(0.10), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 430
                )
                RadialGradient(
                    colors: [accent.opacity(0.22), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: 330
                )
                AnimatedStarField(
                    tint: secondary,
                    density: theme.starDensity,
                    sparkleStrength: theme.sparkleStrength,
                    isVisible: isVisible
                )
            case .gradient:
                RadialGradient(
                    colors: [accent.opacity(0.15), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 360
                )
            }

            if theme.showsRocket {
                RocketFlight(isVisible: isVisible)
            }
        }
    }
}

private struct GeneratedAuroraRibbons: View {
    let primary: Color
    let secondary: Color
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStatic: Bool { reduceMotion || !isVisible }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: isStatic)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let time = isStatic ? 0 : timeline.date.timeIntervalSinceReferenceDate
                context.blendMode = .screen
                context.addFilter(.blur(radius: max(14, min(size.width, size.height) * 0.04)))

                for band in 0..<3 {
                    var path = Path()
                    let bandValue = Double(band)
                    let baseY = size.height * CGFloat(0.18 + bandValue * 0.07)
                    let amplitude = size.height * CGFloat(0.07 + bandValue * 0.014)
                    path.move(to: CGPoint(x: -20, y: baseY))
                    for segment in 1...14 {
                        let unit = Double(segment) / 14
                        let x = size.width * CGFloat(unit)
                        let wave = CGFloat(sin(unit * .pi * 2.4 + time * 0.11 + bandValue))
                        let y = baseY + wave * amplitude
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    context.opacity = 0.19 - bandValue * 0.025
                    context.stroke(
                        path,
                        with: .color(band.isMultiple(of: 2) ? primary : secondary),
                        style: StrokeStyle(lineWidth: max(36, size.height * 0.085), lineCap: .round)
                    )
                }
                context.opacity = 1
            }
        }
    }
}

extension View {
    /// - Parameter isVisible: Pass the host surface's visibility so the animated
    ///   themes stop their timelines while it is off screen. Defaults to `true`.
    func meloThemeBackground(
        theme: MeloVisualTheme,
        customAccentHex: String,
        generatedTheme: GeneratedMeloTheme? = nil,
        isVisible: Bool = true
    ) -> some View {
        background(
            MeloThemeBackdrop(
                theme: theme,
                customAccentHex: customAccentHex,
                generatedTheme: generatedTheme,
                isVisible: isVisible
            )
        )
    }
}
