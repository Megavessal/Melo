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
                    target: .settings
                ),
                MeloReleaseNote.Item(
                    id: "2.9.3-bluetooth",
                    title: "Bluetooth is your choice now",
                    detail: "Melo used to ask macOS for your Bluetooth devices as soon as it started, which made the system prompt appear out of nowhere. Now it only asks once you switch Bluetooth features on.",
                    target: .settings
                ),
                MeloReleaseNote.Item(
                    id: "2.9.3-setup",
                    title: "Setup covers more ground",
                    detail: "The welcome flow now walks through Bluetooth, how the menu bar icon looks, and how you would like updates handled.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.3-whats-new",
                    title: "This screen",
                    detail: "After an update Melo shows you what changed, version by version, and can point out the new things in place. You can reopen it any time from Settings → About.",
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
                    target: .settings
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
                    target: .settings
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
