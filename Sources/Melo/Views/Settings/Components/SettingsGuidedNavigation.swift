// Melo/Views/Settings/Components/SettingsGuidedNavigation.swift
import SwiftUI

/// The choreography of the journey from a search result to the setting it named.
///
/// Four movements, in this order: the page travels sideways, the arrived-at page
/// starts at its own top, it scrolls down to the section, and the section stays
/// marked long enough to be seen.
///
/// The durations live here rather than in `DesignTokens.Animation` because they
/// are not independent tokens — `scrollDelay` is chosen *against* `travel` so the
/// downward movement begins as the page lands rather than after it has stopped,
/// and a later edit that changed one without the other would produce a visible
/// stall that no test would catch. A token scale cannot express "these two must
/// stay in step".
enum SettingsGuidedNavigation {
    /// How long a page takes to slide in from the side.
    static let travel: TimeInterval = 0.30

    /// How long the arrived-at page waits at its top before travelling down.
    /// Slightly shorter than `travel`, so the two movements overlap by a frame
    /// or two and read as one gesture instead of two.
    ///
    /// Spent inside the animation, as `.delay(_:)`, and **not** as a
    /// `Task.sleep` before issuing it. Measured: a `Task.sleep(0.22)` scheduled
    /// from `onChange` had still not resumed by the time the render harness
    /// captured its frame nearly a second later, so `settings-audio-guide-*`
    /// came back parked at the top of the Audio tab — the descent silently did
    /// not happen, and the transition still passed its `mustDiffer` floor on the
    /// 40pt the parking alone moved. A delay inside the animation leaves the
    /// bound scroll position at its destination from the first update, so the
    /// page ends up where it was asked to go whether or not anything animates.
    static let scrollDelay: TimeInterval = 0.22

    /// How long the downward scroll takes. Deliberately a fixed duration rather
    /// than a spring: a spring settles asymptotically, and this movement has to
    /// be finished — not nearly finished — before anything looks at the result.
    static let scrollDuration: TimeInterval = 0.38

    /// How long the arrived-at section stays marked at full strength.
    ///
    /// Long, and constant rather than pulsing. A pulse spends most of its life
    /// away from its peak, so a reader glancing up mid-cycle sees a section that
    /// is only faintly marked, and a single captured frame of it proves nothing
    /// about whether the mark exists at all.
    static let highlightHold: TimeInterval = 2.6

    /// How long the mark takes to fade once its hold has expired.
    static let highlightFade: TimeInterval = 0.6

    /// How long the mark takes to appear. Complete well before the scroll
    /// arrives, so the section is already marked as it comes into view.
    static let highlightRise: TimeInterval = 0.22

    static var pageTravelAnimation: SwiftUI.Animation {
        .easeInOut(duration: travel)
    }

    static var scrollAnimation: SwiftUI.Animation {
        .easeInOut(duration: scrollDuration).delay(scrollDelay)
    }
}

// MARK: - Scrolling to the section

extension View {
    /// Owns a Settings tab's scroll position and performs the guided descent.
    ///
    /// Replaces the four hand-copied `@State scrolledSection` /
    /// `.scrollPosition` / `.onChange` blocks that each tab carried. They had
    /// already drifted apart once in spelling; a fifth tab would have copied
    /// whichever one it was next to.
    func guidedSectionScroll(target: SettingsSectionTarget?) -> some View {
        modifier(GuidedSectionScroll(target: target))
    }
}

@MainActor
private struct GuidedSectionScroll: ViewModifier {
    let target: SettingsSectionTarget?

    /// Where the scroll view is parked. `scrollPosition` reads this during the
    /// scroll view's own layout, which is why the target is copied into it
    /// rather than acted on afterwards: a `ScrollViewProxy.scrollTo` issued
    /// after the tab appears rendered nothing at all, and nothing could see that
    /// it had not.
    @State private var scrolledSection: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scrollPosition(id: $scrolledSection, anchor: .top)
            // `initial: true` because the tab the reader is sent to is usually
            // built *after* the search set the target, so there is no change
            // left to observe by the time this view exists.
            .onChange(of: target, initial: true) { _, target in
                begin(target)
            }
    }

    /// Sets the destination once, now, and lets the animation supply the
    /// journey. Nothing here is deferred: the position this view is bound to is
    /// the section the reader asked for from the moment they asked for it, so a
    /// tab that never animates still ends up showing the right setting.
    ///
    /// The travel down starts from the top because the tab is built fresh when
    /// the page it lives on slides in — the reader is sent to a page that opens
    /// at its own top, and the descent from there is the movement they see. A
    /// request that lands on the tab already showing travels from wherever the
    /// reader had scrolled to instead, which is the honest thing for it to do:
    /// jerking the page up to the top first, only to come back down past what
    /// they were already reading, is motion that describes the feature rather
    /// than performing it.
    private func begin(_ target: SettingsSectionTarget?) {
        guard let target else { return }

        // Reduce Motion: the destination, not the journey. An earlier pass made
        // this path unanimated for everyone; the owner asked for the movement,
        // which overrules that for everyone who has not asked for less of it.
        guard !reduceMotion else {
            scrolledSection = target.section
            return
        }

        withAnimation(SettingsGuidedNavigation.scrollAnimation) {
            scrolledSection = target.section
        }
    }
}

// MARK: - Marking the section on arrival

extension View {
    /// Names a section so the search can scroll to it, and marks it when the
    /// search does.
    ///
    /// Both halves belong to one modifier because they are one promise: an
    /// anchor with no mark lands the reader on a screenful of settings and
    /// leaves them to work out which of them they asked for, and a mark with no
    /// anchor is drawn somewhere off screen.
    func settingsSectionAnchor(_ title: String, target: SettingsSectionTarget?) -> some View {
        modifier(SettingsSectionAnchor(title: title, target: target))
    }
}

@MainActor
private struct SettingsSectionAnchor: ViewModifier {
    let title: String
    let target: SettingsSectionTarget?

    /// The navigation this section is currently marked for. Held as the serial
    /// rather than a `Bool` so a second request for the same section restarts
    /// the hold instead of being swallowed as "already marked".
    @State private var markedSerial: Int?
    /// Ends the hold. A real elapsed wait, so unlike the descent it genuinely
    /// cannot be folded into an animation. Under the render harness's hand-spun
    /// run loop this never resumes and the mark simply stays up, which is the
    /// harmless direction for it to fail in and is why the frames show it.
    @State private var expiry: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // Deliberately *not* `meloGlassSurface`, unlike every other bubble
            // in this journey. Glass is composited by the window server and
            // takes the content of its island with it, so a glass mark around a
            // settings card would delete that card from every rendered frame —
            // including the two that exist to prove this navigation works.
            .background {
                if markedSerial != nil {
                    marker
                }
            }
            .id(title)
            .onChange(of: target, initial: true) { _, target in
                update(for: target)
            }
            .onDisappear {
                expiry?.cancel()
                expiry = nil
            }
    }

    private var marker: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            }
            // Negative padding grows the shape past the card it sits behind
            // without changing the card's own layout, so section positions —
            // and therefore every scroll target — are exactly what they were.
            .padding(-8)
            .transition(.opacity)
    }

    private func update(for target: SettingsSectionTarget?) {
        expiry?.cancel()
        expiry = nil

        guard let target, target.section == title else {
            // Another section was asked for. Two marked sections would be two
            // answers to a question with one.
            markedSerial = nil
            return
        }

        if reduceMotion {
            markedSerial = target.serial
        } else {
            withAnimation(.easeOut(duration: SettingsGuidedNavigation.highlightRise)) {
                markedSerial = target.serial
            }
        }

        expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(SettingsGuidedNavigation.highlightHold))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                markedSerial = nil
            } else {
                withAnimation(.easeIn(duration: SettingsGuidedNavigation.highlightFade)) {
                    markedSerial = nil
                }
            }
        }
    }
}
