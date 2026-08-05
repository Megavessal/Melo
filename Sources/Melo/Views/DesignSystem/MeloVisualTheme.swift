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
                AuroraNightBackdrop(isVisible: isVisible)
                RocketFlight(isVisible: isVisible)

            case .custom:
                LinearGradient(
                    colors: [accent.opacity(0.24), .clear, accent.opacity(0.11)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

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

/// A small pixel-art rocket. Flights alternate direction so the next pass
/// enters from the edge where the previous pass disappeared. Each cycle picks
/// a new vertical lane, while the straight flight angle is clamped to ±15°.
private struct RocketFlight: View {
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStatic: Bool { reduceMotion || !isVisible }

    var body: some View {
        GeometryReader { geometry in
            if isStatic {
                PixelRocketGlyph(flamePhase: 0)
                    .frame(width: 50, height: 24)
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
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let flightDuration = 10.8
                    let restDuration = 8.2
                    let cycleDuration = flightDuration + restDuration
                    let cycleIndex = Int(floor(now / cycleDuration))
                    let elapsed = now - Double(cycleIndex) * cycleDuration
                    let isFlying = elapsed < flightDuration
                    let rawProgress = min(max(elapsed / flightDuration, 0), 1)
                    let progress = rawProgress * rawProgress * (3 - 2 * rawProgress)
                    let travelsRight = cycleIndex.isMultiple(of: 2)

                    let margin: CGFloat = 62
                    let travelDistance = geometry.size.width + margin * 2
                    let startLane = edgeLane(index: cycleIndex - 1, height: geometry.size.height)
                    let proposedEndLane = edgeLane(index: cycleIndex, height: geometry.size.height)
                    let maxVerticalChange = CGFloat(tan(Double.pi / 12)) * travelDistance
                    let endLane = min(
                        max(proposedEndLane, startLane - maxVerticalChange),
                        startLane + maxVerticalChange
                    )
                    let y = startLane + (endLane - startLane) * CGFloat(progress)
                    let startX = travelsRight ? -margin : geometry.size.width + margin
                    let endX = travelsRight ? geometry.size.width + margin : -margin
                    let x = startX + (endX - startX) * CGFloat(progress)
                    let pathAngle = atan2(Double(endLane - startLane), Double(travelDistance)) * 180 / .pi
                    let visualAngle = travelsRight ? pathAngle : -pathAngle

                    PixelRocketGlyph(flamePhase: now)
                        .frame(width: 54, height: 26)
                        .scaleEffect(x: travelsRight ? 1 : -1, y: 1)
                        .rotationEffect(.degrees(max(-15, min(15, visualAngle))))
                        .position(x: x, y: y)
                        .opacity(isFlying ? 0.70 : 0)
                }
            }
        }
    }

    private func edgeLane(index: Int, height: CGFloat) -> CGFloat {
        let usableMin = max(28, height * 0.16)
        let usableMax = max(usableMin + 1, min(height - 30, height * 0.66))
        let unit = deterministicUnit(index: index, salt: 811)
        return usableMin + (usableMax - usableMin) * CGFloat(unit)
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
