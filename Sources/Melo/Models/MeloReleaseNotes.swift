import Foundation

/// What changed in one release, written for the person reading it rather than
/// for the person who wrote it: no build numbers in the prose, no internal
/// names, one line per thing they can actually notice.
///
/// `build` is the number this note belongs to, and it is what the What's New
/// flow compares against — version strings are for display only, because they
/// do not sort reliably ("2.9.10" is newer than "2.9.9" but sorts before it).
struct MeloReleaseNote: Identifiable, Sendable {
    let id: String
    let version: String
    let build: Int
    let headline: String
    let items: [Item]

    /// `target` decides whether this item can be part of the optional spotlight
    /// walkthrough. Something with no control to point at — an icon, a change in
    /// what Melo asks for at launch — leaves it nil and is simply listed.
    ///
    /// Set it only when the popup holds the thing the sentence is about.
    /// "It is configured somewhere behind this gear" is not that: every note
    /// here once claimed `.settings` on those grounds, and the walkthrough
    /// spotlighted one button four times running. `tourSteps` now gives a
    /// control to the first note that claims it, so a hopeful target is
    /// silently dropped rather than repeated.
    struct Item: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        let target: GuidedTourTarget?
    }
}

enum MeloReleaseNotes {
    /// Newest first. `scripts/verify-whats-new.py` fails the build if the version
    /// in Info.plist has no entry here, if its build number disagrees, or if any
    /// entry ships with no items — so a release cannot go out silent.
    static let all: [MeloReleaseNote] = [
        MeloReleaseNote(
            id: "2.9.4",
            version: "2.9.4",
            build: 299,
            headline: "Your call on what Melo shares",
            items: [
                MeloReleaseNote.Item(
                    id: "2.9.4-identifier-permissions",
                    title: "macOS asks for its permissions one more time",
                    // The note `MeloExperienceVersion.onboarding` is held at 3 on
                    // the strength of. Every existing install has its macOS
                    // grants revoked by the identifier change and will never see
                    // the setup page that explains why, because setup does not
                    // replay — so this is the only notice that cohort gets, and
                    // it has to arrive first for that reason. First also because
                    // it is what happens to them within seconds of this launch.
                    detail: "Melo now has the identifier it will keep for good. macOS ties every permission to that identifier, so it treats this version as an app it has not met before and asks again — once for system audio access, once for the volume keys, and once for Bluetooth. Each request still waits until the feature that needs it comes up, with Melo's reason on screen first. Your app volumes, EQ curves, devices and shortcuts are all still here.",
                    // Three system prompts arriving over the next few minutes.
                    // There is no control in the popup that is the thing this
                    // sentence is about.
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.4-analytics-choice",
                    title: "You decide whether Melo shares anything",
                    detail: "Melo can send anonymous notes about which features get used, so the next version improves the parts you actually reach for. It stays off until you say yes, Melo only asks once, and the names of your apps, your audio devices, and your Mac never leave your machine. The switch is in Settings › General.",
                    target: .settings
                ),
                MeloReleaseNote.Item(
                    id: "2.9.4-bluetooth-order",
                    title: "The Bluetooth request waits its turn",
                    // The cohort this line is written for will never see the page
                    // it describes: `MeloExperienceVersion.onboarding` stays at 3
                    // on purpose, so setup does not replay. This note is the only
                    // way an existing install learns the page exists, which is why
                    // it names the Settings switch as well.
                    detail: "macOS used to ask about Bluetooth the moment Melo launched, before anything had explained why. Now setup has a page that says what the permission buys — seeing headphones you have paired but are not connected to, and connecting them from Melo — and the request only appears when you ask for it there, or from the Bluetooth switch in Settings › General.",
                    target: nil
                )
            ]
        ),
        MeloReleaseNote(
            id: "2.9.3",
            version: "2.9.3",
            build: 298,
            headline: "A new look, and Melo asks for less",
            items: [
                MeloReleaseNote.Item(
                    id: "2.9.3-app-icon",
                    title: "A hand-drawn app icon",
                    detail: "Melo has a new pixel icon, with separate light and dark artwork so it sits properly in the Dock whichever appearance you use.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.3-menu-bar-mark",
                    title: "The menu bar mark matches it",
                    detail: "The icon in your menu bar was redrawn to match. If you want it to, it can now react gently to what is playing — that motion is off unless you turn it on.",
                    // The menu bar is not inside the popup, so a walkthrough
                    // that shares the popup's overlay has nothing honest to
                    // point at. It used to point at the Settings gear while the
                    // card talked about the menu bar.
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.3-bluetooth",
                    title: "Bluetooth is your choice now",
                    detail: "Melo used to ask macOS for your Bluetooth devices as soon as it started, which made the system prompt appear out of nowhere. Now it only asks once you switch Bluetooth features on.",
                    // A change in when a system prompt appears. Nothing on
                    // screen is the thing that changed.
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.3-setup",
                    title: "Setup you can try, not just read",
                    // Kept in step with FirstRunOnboardingView by hand. It used
                    // to promise pages on Bluetooth, the menu bar icon and
                    // update handling; all three were deleted and this sentence
                    // went on describing them in What's New and in Settings →
                    // Updates for two releases. Bluetooth's page has since
                    // returned — that belongs to 2.9.4's note above, not here,
                    // because this one describes the flow 2.9.3 shipped and is
                    // still accurate about it. If a page named here is renamed
                    // or removed, this line is the thing that goes stale.
                    detail: "The welcome flow points out Melo's mark up in the menu bar, explains the system audio access Melo needs and asks macOS for it while a sound is playing, offers to hook up your volume keys, and finishes on a real app row — same icon, same slider, same percentage — for you to try.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.3-whats-new",
                    title: "This screen",
                    detail: "After an update Melo shows you what changed, version by version, and can point out the new things in place. You can reopen it any time from Settings › About.",
                    target: nil
                )
            ]
        ),
        MeloReleaseNote(
            id: "2.9.2",
            version: "2.9.2",
            build: 297,
            headline: "Pixel polish",
            items: [
                MeloReleaseNote.Item(
                    id: "2.9.2-app-icon",
                    title: "The pixel app icon arrives",
                    detail: "Melo's icon was redrawn as pixel art rather than a scaled-down illustration.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.2-rockets",
                    title: "Calmer rockets in the themes",
                    detail: "The rockets that drift across the Space, Galaxy and Aurora themes are smaller, so they read as scenery instead of competing with your sliders.",
                    target: nil
                )
            ]
        ),
        MeloReleaseNote(
            id: "2.9.0",
            version: "2.9.0",
            build: 294,
            headline: "Updates that arrive on their own, and a search that understands you",
            items: [
                MeloReleaseNote.Item(
                    id: "2.9.0-updates",
                    title: "Melo updates itself",
                    detail: "New versions are published openly and Melo can check for them, download them and install them for you. You decide how much of that happens automatically.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.0-applications",
                    title: "An offer to move to Applications",
                    detail: "Run Melo from your Downloads folder and it will offer to move itself somewhere it can actually keep itself up to date.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.0-search",
                    title: "Search was rebuilt",
                    detail: "Press ⌘K and describe what you want in your own words — “quiet apps”, “headphones”, “volume keys” — instead of guessing the name of a setting.",
                    target: .search
                )
            ]
        )
    ]

    /// Everything released after `build`, up to and including the running build.
    /// Notes for a build newer than the one running are skipped: they describe a
    /// release this copy of Melo is not.
    static func notes(after build: Int, upTo currentBuild: Int) -> [MeloReleaseNote] {
        all.filter { $0.build > build && $0.build <= currentBuild }
    }

    static func note(forVersion version: String) -> MeloReleaseNote? {
        all.first { $0.version == version }
    }
}
