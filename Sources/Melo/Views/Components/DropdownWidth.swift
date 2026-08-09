// Melo/Views/Components/DropdownWidth.swift
import AppKit
import CoreGraphics

/// How wide a dropdown popover has to be to show the words that are in it.
///
/// Every picker in the popup used to carry a hand-picked constant —
/// `DevicePicker`'s 210, `EQPresetPicker`'s 170 — chosen against whatever
/// device and preset names the author happened to have. A constant cannot know
/// that this Mac calls an output "MacBook Pro Microphone" (134.6pt at 11pt
/// system, measured 2026-08-09) where the author's said "Built-in Output"
/// (76.9pt), so the number is right on one Mac and clips on the next.
///
/// Split into a measuring half and an arithmetic half on purpose. The
/// arithmetic is pure and can be executed by a verify script; the measurement
/// is AppKit's, and is only as good as the point sizes the caller passes —
/// which is why those are parameters and not constants here. A fit computed
/// against a font the row does not draw in is a fit that clips.
///
/// **Why this is a function and not a layout.** A popover is a separate
/// `NSPanel` created by `PopoverHost`, so no frame the render harness produces
/// can ever contain one: `cacheDisplay` captures the popup window's own hosting
/// view and `ImageRenderer` re-draws a SwiftUI tree, and the panel is neither.
/// That is why a clipped dropdown shipped past eighty-odd rendered frames.
/// Nothing here can be checked by looking; it has to be checked by running.
///
/// Sizing cannot simply be handed to SwiftUI either. `PopoverHost` sizes its
/// panel from `NSHostingView.fittingSize`, which is the content's *ideal*
/// width — for a `Text` at `lineLimit(1)` that is the whole untruncated string,
/// with no ceiling. Fitting to content therefore has to mean fitting to content
/// *and stopping*, which is what `width(forWidestText:chrome:minimum:maximum:)`
/// does.
nonisolated enum DropdownWidth {
    /// Widest any of Melo's dropdowns may become.
    ///
    /// The popup is 510pt wide (`DesignTokens.Dimensions.popupWidth`) and
    /// `PopoverHost.showPanel` places a panel at its trigger's x with no
    /// screen-edge clamping, so an unbounded menu hung off a right-hand control
    /// walks off the display. 300 carries roughly 34 characters of an 11pt
    /// device name past the row chrome and still sits inside the window it
    /// belongs to. Past it, names truncate — see `truncationMode(.tail)` on the
    /// rows that draw them.
    static let ceiling: CGFloat = 300

    /// Width of one line of interface text, in points.
    ///
    /// `NSFont.systemFont(ofSize:weight:)` is what SwiftUI's
    /// `.system(size:weight:)` resolves to, so the two agree as long as the
    /// caller passes the size and weight the row actually uses.
    static func textWidth(
        _ text: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: pointSize, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The policy, with the measuring already done: text plus chrome, floored
    /// at what the picker used to be and capped at what the window can hold.
    ///
    /// `minimum` wins over `maximum` when a caller sets them the wrong way
    /// round. A picker being wider than intended is a cosmetic complaint; one
    /// silently narrower than the constant it replaced is the bug this exists
    /// to remove, and it would arrive looking like a fix.
    static func width(
        forWidestText widestText: CGFloat,
        chrome: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat = ceiling
    ) -> CGFloat {
        let cap = Swift.max(minimum, maximum)
        let ideal = (widestText + chrome).rounded(.up)
        return Swift.min(Swift.max(ideal, minimum), cap)
    }

    /// Measure a menu's rows and apply the policy in one call.
    ///
    /// `subtitles` are measured at their own point size and against the same
    /// chrome, because a two-line row is as wide as its widest line. Pass every
    /// subtitle the menu *can* show, not only the one showing now: a popover
    /// that changes width when a toggle inside it flips reads as a glitch.
    ///
    /// **No `maximum` here on purpose.** The ceiling is a property of the window
    /// the panel hangs off, not a per-picker preference, and a caller able to
    /// pass its own is a caller able to pass `maximum: 210` — which restores the
    /// original defect exactly while every executed check on the policy stays
    /// green. Measured: that mutation passed the first version of
    /// `scripts/verify-app-search.py`. Removing the parameter makes it a
    /// compile error instead, which is the only kind of check that cannot be
    /// argued with.
    static func fit(
        titles: [String],
        titlePointSize: CGFloat,
        titleWeight: NSFont.Weight = .regular,
        subtitles: [String] = [],
        subtitlePointSize: CGFloat = 10,
        chrome: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        var widest: CGFloat = 0
        for title in titles {
            widest = Swift.max(
                widest,
                textWidth(title, pointSize: titlePointSize, weight: titleWeight)
            )
        }
        for subtitle in subtitles {
            widest = Swift.max(widest, textWidth(subtitle, pointSize: subtitlePointSize))
        }
        return width(forWidestText: widest, chrome: chrome, minimum: minimum)
    }
}
