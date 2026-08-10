// Melo/Views/DesignSystem/DesignTokens.swift
import SwiftUI
import AppKit

/// Design System tokens for Melo UI
/// Centralized values for colors, typography, spacing, dimensions, and animations
enum DesignTokens {

    // MARK: - Internal helpers

    /// Builds a SwiftUI Color that resolves to `light` or `dark` based on the
    /// effective NSAppearance at draw time. SwiftUI re-resolves automatically
    /// when the appearance changes (system toggle or override change) because
    /// `Color(nsColor:)` preserves the underlying NSColor's adaptability.
    ///
    /// `name` is NSColor's caching key. Pass a unique name per token; two
    /// dynamic colors sharing a name silently resolve to the same instance.
    /// `DesignTokensDynamicResolutionTests` enforces uniqueness by asserting
    /// per-token RGBA values.
    static func dynamicColor(name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Colors

    enum Colors {
        // MARK: Text (Vibrancy-aware)

        /// Primary text - automatically adapts for vibrancy on materials
        static let textPrimary: Color = .primary

        /// Secondary text - slightly muted, still vibrant
        static let textSecondary: Color = .secondary

        /// Tertiary text - for less important content
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)

        /// Quaternary text - very subtle
        static let textQuaternary = Color(nsColor: .quaternaryLabelColor)

        // MARK: Interactive

        /// Default interactive element color
        static let interactiveDefault: Color = .primary.opacity(0.7)

        /// Hovered interactive element color
        static let interactiveHover: Color = .primary.opacity(0.9)

        /// Active/pressed interactive element color
        static let interactiveActive: Color = .primary

        /// System accent color for selections and primary actions
        static let accentPrimary: Color = .accentColor

        /// Mute button active (muted state) - red for visibility
        static let mutedIndicator = Color(nsColor: .systemRed).opacity(0.85)

        /// Default device indicator - uses accent color
        static let defaultDevice: Color = .accentColor

        // MARK: Separators & Borders

        /// System separator color - adapts to appearance
        static let separator = Color(nsColor: .separatorColor)

        /// Subtle border for glass elements
        static let glassBorder = Color(nsColor: .separatorColor).opacity(0.3)

        /// Hover-state border
        static let glassBorderHover = Color(nsColor: .separatorColor).opacity(0.5)

        // MARK: Slider

        /// Slider track background (unfilled) - visible on glass
        static let sliderTrack: Color = .primary.opacity(0.15)

        /// Slider filled track - uses accent color
        static let sliderFill: Color = .accentColor

        /// Slider thumb
        static let sliderThumb: Color = .white

        /// Unity marker on slider
        static let unityMarker: Color = .primary.opacity(0.5)

        // MARK: Control Elements

        /// EQ/slider thumb background
        static let thumbBackground: Color = .white

        /// EQ/slider thumb center dot
        static let thumbDot: Color = .black.opacity(0.7)

        // MARK: Glass Effects

        /// Popup background overlay. Sits over NSVisualEffectView's `.popover`
        /// material. Light bumped from 0.10 → 0.50 so the popup reads as
        /// crisp white-tilted glass over arbitrary wallpapers (Control Center
        /// sweet spot) instead of muddy gray. The earlier 0.55 wash killed
        /// vibrancy entirely; 0.50 keeps a hint of desktop tint.
        static let popupOverlay = dynamicColor(
            name: "popupOverlay",
            light: NSColor.white.withAlphaComponent(0.50),
            dark: NSColor.black.withAlphaComponent(0.4)
        )

        /// Recessed panel background (EQ panel). Light mode is nearly flush
        /// with the surrounding glass; opaque cards do the floating instead.
        static let recessedBackground = dynamicColor(
            name: "recessedBackground",
            light: NSColor.black.withAlphaComponent(0.04),
            dark: NSColor.black.withAlphaComponent(0.3)
        )

        // MARK: Menu/Picker

        /// Menu button background
        static let menuBackground: Color = .clear

        /// Menu button border. Light bumped for visible edge on glass surface.
        static let menuBorder = dynamicColor(
            name: "menuBorder",
            light: NSColor.black.withAlphaComponent(0.18),
            dark: NSColor.white.withAlphaComponent(0.12)
        )

        /// Menu button border on hover. Strong contrast in light mode so the
        /// hover state reads at a glance.
        static let menuBorderHover = dynamicColor(
            name: "menuBorderHover",
            light: NSColor.black.withAlphaComponent(0.32),
            dark: NSColor.white.withAlphaComponent(0.25)
        )

        /// Picker background
        static let pickerBackground: Color = .primary.opacity(0.08)

        /// Picker hover
        static let pickerHover: Color = .primary.opacity(0.12)

        // MARK: Hover & Glass Surface

        /// Hover background for tappable rows. With flat-row design (no
        /// resting fill or border), this is the primary "this row is active"
        /// affordance, so it needs to read clearly without being heavy.
        /// Light bumped from 0.08 → 0.115 to remain unambiguous on the
        /// new whiter glass without competing with the selected-row
        /// indicator. Matches the macOS-native System Settings pattern.
        static let hoverSurface = dynamicColor(
            name: "hoverSurface",
            light: NSColor.black.withAlphaComponent(0.115),
            dark: NSColor.white.withAlphaComponent(0.07)
        )

        /// Default row fill. Transparent — rows blend with the popup
        /// material at rest, like System Settings / Notification Center.
        /// Hover reveals `hoverSurface` as the meaningful interaction signal.
        static let glassFill = dynamicColor(
            name: "glassFill",
            light: NSColor.clear,
            dark: NSColor.clear
        )

        /// Stronger glass-card fill for emphasised badges and sheet inserts
        /// (DEFAULT pill, AutoEQ search panel, device-detail sheet). Not used
        /// for default row backgrounds.
        static let glassFillStrong = dynamicColor(
            name: "glassFillStrong",
            light: NSColor.white.withAlphaComponent(0.85),
            dark: NSColor.white.withAlphaComponent(0.1)
        )

        /// Default row border. Transparent — flat rows have no resting edge.
        static let glassRowBorder = dynamicColor(
            name: "glassRowBorder",
            light: NSColor.clear,
            dark: NSColor.clear
        )

        /// Hovered row edge — soft hairline visible only when the row is
        /// being interacted with. Pairs with `hoverSurface` to define the
        /// active row.
        static let glassRowBorderHover = dynamicColor(
            name: "glassRowBorderHover",
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.15)
        )

        // MARK: Melo Edit's docked panels

        /// The header strip of a docked panel in Melo Edit's right-hand pane.
        ///
        /// **A resting fill, and it is not the pattern `CLAUDE.md` forbids.**
        /// That decision — `glassFill` and `glassRowBorder` resolving to
        /// `.clear` — is about rows in the menu-bar popup, which sit on a
        /// material and use `hoverSurface` as the only interaction signal.
        /// These are not rows. They are chrome: the whole header is the button
        /// that opens and closes the panel, and a header that is invisible until
        /// hovered is a button nobody can see is a button. Same exception the
        /// clip body took in the timeline for the same reason.
        ///
        /// Quiet on purpose — 5% either way. The header has to separate from the
        /// panel body underneath it and from the window's themed backdrop
        /// behind it, and nothing more; VEGAS's grey-on-grey chrome is what the
        /// frame says explicitly not to copy.
        static let panelHeaderFill = dynamicColor(
            name: "panelHeaderFill",
            light: NSColor.black.withAlphaComponent(0.05),
            dark: NSColor.white.withAlphaComponent(0.05)
        )

        /// The same header while its panel is open.
        ///
        /// Stronger than `panelHeaderFill` because open and shut have to be
        /// readable from the header alone — with several panels open at once,
        /// "which of these am I looking at" is answered by the strip, not by
        /// what is underneath it, and the panel at the bottom of the pane may
        /// have no visible body at all when the two above it are full.
        static let panelHeaderFillOpen = dynamicColor(
            name: "panelHeaderFillOpen",
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.10)
        )

        /// The hairline where two docked panels meet.
        ///
        /// Heavier than `glassBorder`'s 30% of the system separator: these
        /// panels butt edge to edge with no gap between them, so the line is
        /// the only thing saying where one ends. A separator that reads as
        /// absent turns a dense pane into an undifferentiated column.
        static let panelSeparator = Color(nsColor: .separatorColor).opacity(0.65)

        // MARK: Melo Edit's tracks and meters

        /// The colour band down the left edge of one track header.
        ///
        /// **The cheapest thing in the VEGAS screenshot**, and the frame says
        /// to take it: a band of colour says which strip belongs to which lane
        /// without a word, a border or a box. Six, cycled by position, so the
        /// third and the ninth track share a colour — which is fine, because
        /// the job is telling *adjacent* lanes apart, and a palette long enough
        /// to never repeat is a palette whose later entries are indistinguishable
        /// from each other anyway.
        ///
        /// **Not the accent, and not derived from it.** The accent is already
        /// spoken for twice on this row — it is the selected-track bar and the
        /// non-zero gain readout — so a lane colour drawn from it would make
        /// "this track is selected" and "this track is the second one" the same
        /// signal. These are fixed hues chosen to hold their separation on both
        /// grounds; the theme's accent stays the accent.
        ///
        /// *Rejected:* hashing the track's UUID to a hue. It survives reordering,
        /// which sounds like the point, and it means two adjacent lanes can come
        /// out the same colour by luck and stay that way — the one failure the
        /// band exists to prevent. Position repeats predictably instead.
        static func trackStripe(at index: Int) -> Color {
            let palette = trackStripePalette
            return palette[((index % palette.count) + palette.count) % palette.count]
        }

        /// How many colours before the band repeats. Read by anything that has
        /// to say "these two lanes will collide".
        static var trackStripeCount: Int { trackStripePalette.count }

        private static let trackStripePalette: [Color] = [
            dynamicColor(
                name: "trackStripe0",
                light: NSColor(srgbRed: 0.20, green: 0.48, blue: 0.86, alpha: 1),
                dark: NSColor(srgbRed: 0.40, green: 0.66, blue: 1.00, alpha: 1)
            ),
            dynamicColor(
                name: "trackStripe1",
                light: NSColor(srgbRed: 0.13, green: 0.58, blue: 0.44, alpha: 1),
                dark: NSColor(srgbRed: 0.32, green: 0.82, blue: 0.62, alpha: 1)
            ),
            dynamicColor(
                name: "trackStripe2",
                light: NSColor(srgbRed: 0.74, green: 0.44, blue: 0.08, alpha: 1),
                dark: NSColor(srgbRed: 0.98, green: 0.70, blue: 0.30, alpha: 1)
            ),
            dynamicColor(
                name: "trackStripe3",
                light: NSColor(srgbRed: 0.58, green: 0.28, blue: 0.68, alpha: 1),
                dark: NSColor(srgbRed: 0.80, green: 0.55, blue: 0.94, alpha: 1)
            ),
            dynamicColor(
                name: "trackStripe4",
                light: NSColor(srgbRed: 0.76, green: 0.26, blue: 0.34, alpha: 1),
                dark: NSColor(srgbRed: 0.98, green: 0.50, blue: 0.55, alpha: 1)
            ),
            dynamicColor(
                name: "trackStripe5",
                light: NSColor(srgbRed: 0.16, green: 0.50, blue: 0.60, alpha: 1),
                dark: NSColor(srgbRed: 0.42, green: 0.78, blue: 0.88, alpha: 1)
            )
        ]

        /// The unlit part of a level meter. Dark enough on both grounds that an
        /// empty meter reads as a trough rather than as a missing control —
        /// a meter whose ground is invisible looks like a bar chart with one bar.
        static let meterTrough = dynamicColor(
            name: "meterTrough",
            light: NSColor.black.withAlphaComponent(0.12),
            dark: NSColor.black.withAlphaComponent(0.38)
        )

        /// The lit part below −6 dBFS. The ordinary case, and therefore the
        /// quiet one.
        static let meterBody = dynamicColor(
            name: "meterBody",
            light: NSColor(srgbRed: 0.13, green: 0.56, blue: 0.42, alpha: 0.95),
            dark: NSColor(srgbRed: 0.36, green: 0.84, blue: 0.62, alpha: 0.95)
        )

        /// −6 to −1 dBFS. Not a warning — this is where a mastered podcast
        /// lives — so it is warm rather than alarming.
        static let meterWarm = dynamicColor(
            name: "meterWarm",
            light: NSColor(srgbRed: 0.78, green: 0.56, blue: 0.10, alpha: 0.95),
            dark: NSColor(srgbRed: 1.00, green: 0.80, blue: 0.34, alpha: 0.95)
        )

        /// Above −1 dBFS, where a peak is about to become a clip. The one part
        /// of a meter that is allowed to shout.
        static let meterHot = mutedIndicator

        /// Ticks and numerals on the meter's decibel ladder. Full mode only —
        /// see `EditorMode.Extra.meterScale`.
        static let meterScale = Color(nsColor: .tertiaryLabelColor)

        /// HUD panel hairline border (Tahoe + Classic).
        static let hudBorder = dynamicColor(
            name: "hudBorder",
            light: NSColor.black.withAlphaComponent(0.15),
            dark: NSColor.white.withAlphaComponent(0.08)
        )

        // MARK: Cards & Badges

        /// Lifted-card fill used by the EQ panel and Settings sections.
        /// Light reads as a white card on the popup glass; dark reads as
        /// a subtle translucent surface on the dark glass. Pairs with
        /// `eqCardBorder` for the hairline edge.
        static let eqCardBackground = dynamicColor(
            name: "eqCardBackground",
            light: NSColor.white.withAlphaComponent(0.78),
            dark: NSColor.white.withAlphaComponent(0.07)
        )

        /// Hairline border for the lifted card. Visible enough to define
        /// the edge, quiet enough to read as part of the glass family.
        static let eqCardBorder = dynamicColor(
            name: "eqCardBorder",
            light: NSColor.black.withAlphaComponent(0.06),
            dark: NSColor.white.withAlphaComponent(0.10)
        )

        /// Monochrome circular badge fill used on non-selected device rows.
        /// The selected state uses a `Color.accentColor` gradient inline in
        /// `DeviceBadge`; that does not need a token.
        static let deviceBadgeMonoFill = dynamicColor(
            name: "deviceBadgeMonoFill",
            light: NSColor.black.withAlphaComponent(0.10),
            dark: NSColor.white.withAlphaComponent(0.10)
        )

        /// Foreground color for the device-badge SF symbol on a non-selected
        /// row. Selected rows use white directly inside `DeviceBadge`.
        static let deviceBadgeMonoForeground = dynamicColor(
            name: "deviceBadgeMonoForeground",
            light: NSColor.black.withAlphaComponent(0.65),
            dark: NSColor.white.withAlphaComponent(0.70)
        )

        /// Section-header text ("APPS", "GENERAL", etc.). The system
        /// `tertiaryLabelColor` is too faint as a section divider in light
        /// mode; this token gives the headers Apple-app-style readability
        /// without changing the dark appearance. Light bumped from 0.55
        /// → 0.65 so headers anchor each section on the whiter glass
        /// without changing tracking or weight.
        static let sectionHeaderText = dynamicColor(
            name: "sectionHeaderText",
            light: NSColor.black.withAlphaComponent(0.65),
            dark: NSColor.white.withAlphaComponent(0.40)
        )

        // MARK: VU Meter (Professional audio standard - NOT themed)

        /// VU meter green segments (bars 0-3, safe levels)
        static let vuGreen = Color(red: 0.20, green: 0.78, blue: 0.40)

        /// VU meter yellow segments (bars 4-5, caution)
        static let vuYellow = Color(red: 0.95, green: 0.75, blue: 0.20)

        /// VU meter orange segment (bar 6, warning)
        static let vuOrange = Color(red: 0.95, green: 0.50, blue: 0.20)

        /// VU meter red segment (bar 7, peak/clip)
        static let vuRed = Color(red: 0.90, green: 0.25, blue: 0.25)

        /// VU meter unlit bar color (matches sliderTrack for visual consistency)
        static let vuUnlit: Color = .primary.opacity(0.15)

        /// VU meter muted state
        static let vuMuted: Color = .primary.opacity(0.35)

        // MARK: AutoEQ

        /// AutoEQ empty-state dashed border. Light bumped so the dashed
        /// outline reads on a translucent panel.
        static let autoEQEmptyBorder = dynamicColor(
            name: "autoEQEmptyBorder",
            light: NSColor.black.withAlphaComponent(0.22),
            dark: NSColor.white.withAlphaComponent(0.1)
        )

        /// AutoEQ empty-state icon color. Light made darker so the icon is
        /// visible on a near-white background.
        static let autoEQEmptyIcon = dynamicColor(
            name: "autoEQEmptyIcon",
            light: NSColor(white: 0.45, alpha: 1.0),
            dark: NSColor(white: 0.267, alpha: 1.0)
        )

        /// AutoEQ toggle label text color (Correction / Preamp labels).
        static let autoEQToggleLabel = dynamicColor(
            name: "autoEQToggleLabel",
            light: NSColor.black.withAlphaComponent(0.65),
            dark: NSColor.white.withAlphaComponent(0.5)
        )

        // MARK: HUD

        /// Active dot in Tahoe HUD tick track
        static let hudDotActive: Color = .primary.opacity(0.85)

        /// Inactive dot in Tahoe HUD tick track
        static let hudDotInactive: Color = .primary.opacity(0.18)

        /// Active tile in Classic HUD segment row
        static let hudTileActive: Color = .primary.opacity(0.7)

        /// Inactive tile in Classic HUD segment row
        static let hudTileInactive: Color = .primary.opacity(0.2)
    }

    // MARK: - Typography

    enum Typography {
        /// Section header text (e.g., "OUTPUT DEVICES") - prominent and bold
        static let sectionHeader = Font.system(size: 12, weight: .bold)

        /// Section header letter spacing (tighter at larger size)
        static let sectionHeaderTracking: CGFloat = 1.2

        /// App/device name in rows
        static let rowName = Font.system(size: 13, weight: .regular)

        /// Bold variant for default device name
        static let rowNameBold = Font.system(size: 13, weight: .semibold)

        /// Volume percentage display.
        ///
        /// Uses SF with *monospaced digits* rather than the monospaced
        /// typeface. `design: .monospaced` swaps in SF Mono, which reads as
        /// a code font sitting inside a consumer UI. `.monospacedDigit()`
        /// keeps SF's proportional letterforms while fixing numeral advance
        /// widths, so "100%" → "99%" doesn't shift the layout and the label
        /// still belongs to the same type family as everything around it.
        static let percentage = Font.system(size: 11, weight: .medium).monospacedDigit()

        /// Numerals in a secondary position (dB readouts, sample rates,
        /// device inspector values). Same non-jitter guarantee.
        static let numeric = Font.system(size: 11, weight: .regular).monospacedDigit()

        /// Small caption text
        static let caption = Font.system(size: 10, weight: .regular)

        /// Device picker text
        static let pickerText = Font.system(size: 11, weight: .regular)

        /// EQ frequency labels. Monospaced digits keep the band labels
        /// optically aligned under their sliders without pulling SF Mono
        /// into the type system.
        static let eqLabel = Font.system(size: 9, weight: .medium).monospacedDigit()

        /// AutoEQ card profile name
        static let cardProfileName = Font.system(size: 12, weight: .semibold)

        /// AutoEQ card source/measuredBy
        static let cardSource = Font.system(size: 9, weight: .regular)

        /// Settings card header (sentence case, 13pt semibold)
        static let cardHeader = Font.system(size: 13, weight: .semibold)

        /// Settings row description (11pt regular, tertiary)
        static let rowDescription = Font.system(size: 11, weight: .regular)

        // MARK: - The scale

        /// Melo's type scale. Seven steps, one for each job.
        ///
        /// Before this existed the app used **21 distinct point sizes** across 260
        /// raw `.system(size:)` calls — 10.5pt and 23pt among them — and adjacent
        /// settings tabs disagreed about whether headers were SF or SF Rounded.
        /// Nothing about a screen reads as "designed" when its type is chosen one
        /// call site at a time. Prefer these everywhere; a raw `.system(size:)`
        /// should survive only where a glyph must match a fixed-size drawing.
        ///
        /// | Token      | Size | Use                                   |
        /// |------------|------|---------------------------------------|
        /// | `caption2` | 9    | EQ band labels, dense metadata        |
        /// | `caption`  | 10   | Secondary captions, tile labels       |
        /// | `footnote` | 11   | Row descriptions, settings body       |
        /// | `body`     | 12   | Default interface text                |
        /// | `headline` | 13   | Row titles, card headers              |
        /// | `title3`   | 15   | Prominent controls, sheet headers     |
        /// | `title2`   | 20   | Window and onboarding titles          |
        enum Scale {
            static func caption2(_ weight: Font.Weight = .regular) -> Font {
                .system(size: 9, weight: weight)
            }
            static func caption(_ weight: Font.Weight = .regular) -> Font {
                .system(size: 10, weight: weight)
            }
            static func footnote(_ weight: Font.Weight = .regular) -> Font {
                .system(size: 11, weight: weight)
            }
            static func body(_ weight: Font.Weight = .regular) -> Font {
                .system(size: 12, weight: weight)
            }
            static func headline(_ weight: Font.Weight = .semibold) -> Font {
                .system(size: 13, weight: weight)
            }
            static func title3(_ weight: Font.Weight = .semibold) -> Font {
                .system(size: 15, weight: weight)
            }
            static func title2(_ weight: Font.Weight = .semibold) -> Font {
                .system(size: 20, weight: weight)
            }
        }
    }

    // MARK: - Spacing (standard 1× multiplier)

    enum Spacing {
        /// 2pt - Extra extra small
        static let xxs: CGFloat = 2

        /// 4pt - Extra small
        static let xs: CGFloat = 4

        /// 6pt — between `xs` and `sm`.
        ///
        /// Added because it was already in use: 6 appeared as a literal 12 times and
        /// 10 appeared 9 times, so the "scale" was really 23 distinct padding values
        /// with a 7-step token set sitting alongside it. Naming the two that were
        /// genuinely load-bearing is what lets the other sixteen be removed.
        static let xs2: CGFloat = 6

        /// 8pt - Small
        static let sm: CGFloat = 8

        /// 10pt — between `sm` and `md`. See `xs2`.
        static let sm2: CGFloat = 10

        /// 12pt - Medium
        static let md: CGFloat = 12

        /// 16pt - Large
        static let lg: CGFloat = 16

        /// 20pt - Extra large
        static let xl: CGFloat = 20

        /// 24pt - Extra extra large
        static let xxl: CGFloat = 24
    }

    // MARK: - Dimensions

    enum Dimensions {
        // MARK: Base Configuration

        /// Main popup width
        static let popupWidth: CGFloat = 510

        /// Content padding
        static var contentPadding: CGFloat { Spacing.lg }

        /// Available content width after padding
        static var contentWidth: CGFloat {
            popupWidth - (contentPadding * 2)
        }

        // MARK: Fixed Dimensions

        /// Max height for scrollable content
        static let maxScrollHeight: CGFloat = 400

        // MARK: Corner Radii

        /// Corner radius for popup
        static let cornerRadius: CGFloat = 12

        /// Corner radius for row cards (glass bars)
        static let rowRadius: CGFloat = 10

        /// Corner radius for buttons/pickers
        static let buttonRadius: CGFloat = 6

        // MARK: Corner shapes — prefer these over the raw radii above

        /// Melo's radius scale, expressed as *shapes* rather than numbers.
        ///
        /// Two problems this solves at once. First, the app had grown **13 distinct
        /// corner radii** across 68 literal call sites for three tokens — 0.5, 5, 7,
        /// 9, 13 and 14 all appear. Second, and more visibly, **100 of 125**
        /// `RoundedRectangle`s used circular corners because `style: .continuous` is
        /// easy to forget; at the 16–22pt radii of the two HUDs, sitting inches from
        /// the system volume HUD, the difference is plain. Handing out finished
        /// shapes makes the correct curve the only thing on offer.
        enum Shape {
            /// 4pt — inner chips, nested indicators
            static let xs = RoundedRectangle(cornerRadius: 4, style: .continuous)
            /// 6pt — buttons, pickers, segmented tiles
            static let sm = RoundedRectangle(cornerRadius: 6, style: .continuous)
            /// 10pt — rows, cards, search fields
            static let md = RoundedRectangle(cornerRadius: 10, style: .continuous)
            /// 14pt — sheets, prominent panels
            static let lg = RoundedRectangle(cornerRadius: 14, style: .continuous)
            /// 12pt — the popup window itself
            static let window = RoundedRectangle(cornerRadius: 12, style: .continuous)

            static func custom(_ radius: CGFloat) -> RoundedRectangle {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
            }
        }

        /// Radius an inset child needs in order to nest concentrically inside a
        /// parent. A child drawn at the parent's radius reads as a sticker laid on
        /// top rather than a part of it.
        static func innerRadius(outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(2, outer - inset)
        }

        /// App/device icon size
        static let iconSize: CGFloat = 22

        /// Small icon size
        static let iconSizeSmall: CGFloat = 14

        // MARK: Slider Dimensions (minimal style)

        /// Slider track height
        static let sliderTrackHeight: CGFloat = 3

        /// Slider thumb width (pill shape)
        static let sliderThumbWidth: CGFloat = 16

        /// Slider thumb height (pill shape)
        static let sliderThumbHeight: CGFloat = 10

        /// Circular thumb size
        static let sliderThumbSize: CGFloat = 12

        /// Minimum hit target for any control the pointer must acquire.
        ///
        /// Was 16pt, which is below the macOS Human Interface Guidelines floor of
        /// 28×28. The mute button and boost chevrons both used it, and the volume
        /// slider's live area was thinner still at 10pt. Keep the *visual* element
        /// whatever size the design wants and expand the hit area to this with
        /// `.contentShape(Rectangle())`.
        static let minTouchTarget: CGFloat = 28

        /// Live drag height for a horizontal slider, independent of how thin the
        /// track is drawn.
        static let sliderHitHeight: CGFloat = 20

        /// Row content height
        static let rowContentHeight: CGFloat = 28

        // MARK: Component Widths

        /// Slider width
        static let sliderWidth: CGFloat = 140

        /// Minimum slider width
        static let sliderMinWidth: CGFloat = 120

        /// Percentage text width (fixed to prevent layout shift)
        /// 44, and the 4 matters.
        ///
        /// Measured with the real font — `Typography.percentage` is
        /// `.system(size: 11, weight: .medium).monospacedDigit()` — "400%" is
        /// **32.2pt**, and `EditablePercentage` puts `Spacing.xs` either side of
        /// it. 32.2 + 8 = 40.2 against a 40pt box, so the readout wrapped: the
        /// digits on one line and the per-cent sign alone underneath, inside a
        /// 28pt row. It was short by two tenths of a point.
        ///
        /// The digits are monospaced, so "100%" measures 32.2 as well and the
        /// device rows were on the same edge — this was never about app rows
        /// reaching 400%. One number serves every caller for the same reason.
        static let percentageWidth: CGFloat = 44

        // MARK: VU Meter

        /// VU meter bar count
        static let vuMeterBarCount: Int = 8

        // MARK: Settings Row

        /// Settings row icon column width
        static let settingsIconWidth: CGFloat = 24

        /// Settings slider width
        static let settingsSliderWidth: CGFloat = 200

        /// Settings percentage text width
        static let settingsPercentageWidth: CGFloat = 44

        /// Settings picker width
        static let settingsPickerWidth: CGFloat = 120

    }

    // MARK: - Elevation

    /// Layered shadow system. Premium macOS surfaces read as physically
    /// stacked because they cast two shadows: a tight contact shadow that
    /// anchors the element to the surface beneath it, and a wider ambient
    /// shadow that gives it height. A single shadow reads as a sticker.
    ///
    /// Apply with `.meloElevation(.card)` — see `ViewModifiers.swift`.
    enum Elevation {
        struct Shadow {
            let contactOpacity: Double
            let contactRadius: CGFloat
            let contactY: CGFloat
            let ambientOpacity: Double
            let ambientRadius: CGFloat
            let ambientY: CGFloat
        }

        /// Hairline lift for hovered rows and badges. Barely perceptible;
        /// its job is to stop hover from reading as a flat color swap.
        static let hover = Shadow(
            contactOpacity: 0.05, contactRadius: 1, contactY: 0.5,
            ambientOpacity: 0.04, ambientRadius: 4, ambientY: 1
        )

        /// Lifted cards — EQ panel, Settings sections, AutoEQ result cards.
        static let card = Shadow(
            contactOpacity: 0.07, contactRadius: 1.5, contactY: 1,
            ambientOpacity: 0.06, ambientRadius: 10, ambientY: 3
        )

        /// Floating surfaces — dropdowns, popovers, device detail sheet.
        static let floating = Shadow(
            contactOpacity: 0.10, contactRadius: 2, contactY: 1,
            ambientOpacity: 0.12, ambientRadius: 24, ambientY: 8
        )

        /// Slider thumb. Tight and dark so the thumb reads as sitting
        /// *on* the track rather than being punched out of it.
        static let thumb = Shadow(
            contactOpacity: 0.18, contactRadius: 1, contactY: 0.5,
            ambientOpacity: 0.12, ambientRadius: 3, ambientY: 1
        )
    }

    // MARK: - Animation (graded motion scale)

    /// Motion is graded by the *mass* of what is moving. Small things settle
    /// fast and near-critically damped; large surfaces take longer and are
    /// allowed a trace of overshoot. Using one curve for everything is the
    /// single most common reason a well-built UI still feels generic.
    ///
    /// ## Reduce Motion
    ///
    /// Every token below is a computed property that collapses to a short
    /// cross-fade when the user has enabled Reduce Motion. This is deliberate:
    /// before this change, six view files each re-implemented the check inline
    /// with a *different* fallback (`nil`, `.linear(0.15)`, a shortened
    /// duration), and the other ~39 ignored the setting entirely. Centralising
    /// it here means a call site cannot forget.
    ///
    /// Apple's guidance is that Reduce Motion should replace *movement* with
    /// *fading* rather than remove feedback outright, so these return a fast
    /// linear curve instead of `nil` — the state change still reads, it just
    /// doesn't travel.
    ///
    /// - Note: `NSWorkspace` is read at access time rather than cached, so a
    ///   change to the setting is picked up on the next view body evaluation.
    ///   SwiftUI is not notified automatically; observe
    ///   `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and
    ///   bump a state value if you need live re-layout without a redraw.
    enum Animation {

        /// Whether the system is currently asking for reduced motion.
        ///
        /// Reading `NSWorkspace` is correct but is not something SwiftUI observes,
        /// so toggling Reduce Motion mid-session left every animation at its old
        /// setting until an unrelated redraw happened to occur. `MotionPreference`
        /// below watches the system notification and republishes, which gives
        /// SwiftUI something to invalidate on.
        @MainActor
        static var isReduced: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// Cross-fade substituted for any travelling animation under
        /// Reduce Motion. Short enough to feel immediate, long enough that
        /// the change is not a jump cut.
        static let reduced = SwiftUI.Animation.linear(duration: 0.10)

        @MainActor
        private static func graded(_ animation: SwiftUI.Animation) -> SwiftUI.Animation {
            isReduced ? reduced : animation
        }

        // MARK: Existing scale (unchanged semantics — call sites depend on these)

        /// Quick spring for small elements
        @MainActor
        static var quick: SwiftUI.Animation {
            graded(.spring(response: 0.2, dampingFraction: 0.85))
        }

        /// Hover transition (brief and precise per HIG)
        @MainActor
        static var hover: SwiftUI.Animation {
            graded(.easeOut(duration: 0.12))
        }

        /// VU meter level change. Not graded — this is a data readout, not
        /// decorative motion, and freezing it would misrepresent audio state.
        static let vuMeterLevel = SwiftUI.Animation.linear(duration: 0.05)

        // MARK: Extended scale

        /// Press-down and release on buttons. Faster and stiffer than
        /// `quick` — a press that springs is a press that feels mushy.
        @MainActor
        static var press: SwiftUI.Animation {
            graded(.spring(response: 0.14, dampingFraction: 0.92))
        }

        /// State flips that carry meaning: mute toggling, a device becoming
        /// default, a preset being applied. Slight overshoot reads as
        /// confirmation.
        @MainActor
        static var toggle: SwiftUI.Animation {
            graded(.spring(response: 0.28, dampingFraction: 0.72))
        }

        /// Value changes the user is directly driving (slider fill, EQ curve).
        /// Must be nearly instant or the control feels laggy under the cursor.
        /// Not graded — this tracks the pointer, and the pointer is already
        /// the user's own motion.
        static let track = SwiftUI.Animation.interactiveSpring(
            response: 0.10, dampingFraction: 1.0
        )

        /// Rows appearing, disappearing, or reordering in a list.
        @MainActor
        static var rowChange: SwiftUI.Animation {
            graded(.spring(response: 0.32, dampingFraction: 0.86))
        }

        /// Panels expanding and collapsing — EQ panel, device details,
        /// hidden-apps list. Heavier mass, longer settle.
        @MainActor
        static var panel: SwiftUI.Animation {
            graded(.spring(response: 0.38, dampingFraction: 0.84))
        }

        /// Dropdowns and popovers presenting. Snappy in, no bounce.
        @MainActor
        static var present: SwiftUI.Animation {
            graded(.spring(response: 0.24, dampingFraction: 0.90))
        }

        /// Scroll-to-row movement driven by keyboard navigation. Slower than
        /// `hover`, which was previously used here and snapped the list so
        /// abruptly that it was hard to track where focus had gone.
        @MainActor
        static var scrollToRow: SwiftUI.Animation {
            graded(.spring(response: 0.30, dampingFraction: 0.90))
        }
    }

    // MARK: - Timing

    enum Timing {
        /// VU meter update interval (30fps)
        static let vuMeterUpdateInterval: TimeInterval = 1.0 / 30.0

        /// VU meter peak hold duration
        static let vuMeterPeakHold: TimeInterval = 0.5
    }

    // MARK: - Links

    enum Links {
        /// Project license on GitHub
        static let license = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    }
}
