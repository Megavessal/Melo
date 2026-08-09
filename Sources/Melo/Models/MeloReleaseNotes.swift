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
            id: "3.1.2",
            version: "3.1.2",
            build: 312,
            headline: "MP3 and Opus just work now",
            items: [
                MeloReleaseNote.Item(
                    id: "3.1.2-bundled-ffmpeg",
                    title: "Melo brings its own encoder",
                    // Says what changed for the reader, not how. "ffmpeg" is
                    // named because 3.1.0 and 3.1.1 both told people to go and
                    // install it, so the word is the link between the old
                    // instruction and it no longer applying.
                    detail: "MP3 and Opus needed an ffmpeg you installed yourself. Melo now ships one — 1.7 MB, audio only — so both formats export straight away.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.1.2-links-unchanged",
                    title: "Links still need yt-dlp",
                    // Kept because the note above invites the reasonable
                    // assumption that the other tool came too. Saying why is
                    // cheaper than the support question, and the reason is real
                    // rather than an excuse.
                    detail: "That one keeps up with sites that change every week, so a copy frozen into Melo would be broken by the time you updated. Melo finds yours and says so when there isn't one.",
                    target: nil
                )
            ]
        ),
        MeloReleaseNote(
            id: "3.1.1",
            version: "3.1.1",
            build: 311,
            headline: "The editor has a plainer name",
            items: [
                MeloReleaseNote.Item(
                    id: "3.1.1-rename",
                    title: "The Cutting Room is now Melo Edit",
                    // The only item in this release, and it is here rather than
                    // silent because 3.1.0 shipped a week's worth of copy under
                    // the old name — a reader who saw it and cannot find it
                    // again deserves the sentence. "Cutting room" is kept as a
                    // search alias for the same reason.
                    detail: "Same window, same everything inside it. Searching for the old name still finds it.",
                    target: nil
                )
            ]
        ),
        MeloReleaseNote(
            id: "3.1.0",
            version: "3.1.0",
            build: 310,
            // The prose below deliberately says "Melo Edit" rather than the
            // name this release actually shipped under. What's New is read as
            // in-app history, so naming a thing the reader can no longer find
            // is worse than a small inaccuracy about what it was called at the
            // time. The 3.1.1 note above carries the rename itself.
            headline: "Melo can edit a sound now",
            items: [
                MeloReleaseNote.Item(
                    id: "3.1.0-cutting-room",
                    title: "Melo Edit",
                    // First because everything else in this release is inside
                    // it. Names the three ways in that an existing install can
                    // use today, which is what turns the notes below from news
                    // into somewhere the reader can go.
                    detail: "A window for one sound. Trim it, level it, shape it, and save it in another format. It is in the menu bar, in ⌘K, and you can drop a file on Melo.",
                    // There is no popup control this sentence is about. The
                    // scissors button opens a separate window, and
                    // `GuidedTourTarget` anchors are only collected inside the
                    // popup, so a step here would draw a card pointing at
                    // nothing.
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.1.0-destinations",
                    title: "Say where the sound is going",
                    // The feature. If a reader takes one thing from this
                    // release it is that Melo measures *their* file rather
                    // than applying a preset — hence "your file" and the
                    // promise that the numbers are editable.
                    detail: "Pick Podcast, Music, Video, Ringtone or Voice memo. Melo measures your file and proposes the moves that get it there, each one explained, every number yours to change.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.1.0-link-and-record",
                    title: "Audio off a link, or straight off your Mac",
                    detail: "Paste a link and Melo pulls the sound out with yt-dlp, or record what this Mac is playing — everything, or one app.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.1.0-theme-remix",
                    title: "Melo's theme is yours to cut up",
                    detail: "Four one-tap starting points on the app's own track. Your version can become the one setup plays.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.1.0-eq-preset",
                    title: "An editor curve can become a Melo preset",
                    // The one thing here no other audio editor can do, and the
                    // reason the equalizer is Melo's rather than a generic one.
                    detail: "Save what you build in Melo Edit's equalizer and use it on live apps.",
                    target: .equalizer
                ),
                MeloReleaseNote.Item(
                    id: "3.1.0-capture-wording",
                    title: "Melo's audio permission now says it can record",
                    // Kept deliberately. Every other item here is something
                    // that grew; this is the only one where a promise Melo made
                    // to the user changed, and a release that quietly reworded
                    // a privacy string would be the kind of thing this file
                    // exists to prevent.
                    detail: "Same permission as before and nothing leaves your Mac — but the old wording promised Melo never records, and that stopped being true.",
                    target: nil
                )
            ]
        ),
        MeloReleaseNote(
            id: "3.0.0",
            version: "3.0.0",
            build: 300,
            headline: "Melo has a sound of its own",
            items: [
                MeloReleaseNote.Item(
                    id: "3.0.0-theme",
                    title: "A Melo theme, written for Melo",
                    // First because it is the only item in this release that an
                    // existing install can act on today, and it is the item that
                    // carries the route. `MeloExperienceVersion.onboarding` is
                    // held at 3 again this release, so setup does not replay and
                    // nobody who already has Melo meets the theme, the tutorial
                    // or the playground by simply updating. Naming Replay
                    // Tutorial here is what turns the next two notes from news
                    // about somebody else's first run into something the reader
                    // can go and hear. Same shape as 2.9.4's Bluetooth note.
                    detail: "Ninety seconds of funky boom-bap, written for the app. Setup plays it while you try things, and its opening bar is what Melo plays when it first asks macOS for audio access.",
                    // A piece of music playing during setup. There is no control
                    // in the popup that is the thing this sentence is about.
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-setup-playground",
                    title: "Setup ends on a real equalizer",
                    // Second because it is the payoff of the note above — the
                    // music is what the bands are dragged against — and because
                    // it is the one item here whose subject really is in the
                    // popup, so it claims the walkthrough's equalizer step.
                    // `tourSteps` hands a control to the first note that asks for
                    // it, so this has to sit above anything else that might want
                    // the panel.
                    detail: "The same ten-band panel from an app’s row is now on setup’s last page. Drag the bands against the music.",
                    // The panel on that page is the popup's equalizer, so the
                    // spotlight points at the thing the sentence is about rather
                    // than at somewhere it is configured.
                    target: .equalizer
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-setup-dock-icon",
                    title: "Setup cannot get lost behind other apps",
                    detail: "Melo keeps a Dock icon while setup and the guided tour are running, so the window cannot get lost behind other apps. It asks at the end whether to keep it — the default is no.",
                    // A Dock tile, and a question asked at the end of setup.
                    // Neither is in the popup. The Show Melo in Dock switch in
                    // Settings › General is where it is configured afterwards,
                    // which is not the same as it being what this sentence is
                    // about — that reasoning is what had the walkthrough
                    // spotlighting the gear four times running.
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-setup-slider-drag",
                    title: "Fixed: the slider in setup can be dragged again",
                    detail: "It moved the whole window instead. The slider takes the drag now, and the window moves from its title bar.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-windows-take-clicks",
                    title: "Setup's windows answer the mouse again",
                    detail: "The welcome and What’s New windows could open behind whatever you were doing, visible but with dead buttons. They take clicks now.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-search-highlights",
                    title: "Search marks what it found",
                    detail: "Opening a search result scrolls to that setting and highlights it. Results with no home of their own open the Guide on that topic.",
                    target: .settings
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-palette-coverage",
                    title: "The command palette knows far more of Melo",
                    detail: "Apps you have not played anything in yet, per-app device routing, microphone choice, device volume and mute, and about a hundred settings by name. “Set Spotify to 200%” works as well as “Spotify to 200%”.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-settings-travel",
                    title: "Settings goes to the setting you asked for",
                    detail: "“Show me” in the Guide travels to the page and descends to the named section, marking it briefly, instead of printing directions.",
                    target: .settings
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-theme-visitors",
                    title: "Three new visitors in the themes",
                    detail: "A desk Mac whose screen lights in your accent colour, a cabin window on Aurora’s far ridge, and a paintbrush that leaves a stroke in your own colour. Rockets stay in Space and Galaxy now, and the sky is emptier.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-reduce-motion-eggs",
                    title: "Reduce Motion gets the visitors too",
                    detail: "With Reduce Motion on they used to sit on screen permanently. Now they turn up about as often as everyone else’s, and never move.",
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "3.0.0-quieter-launch",
                    title: "Quicker to start, and quieter during calls",
                    detail: "A pause at launch is gone, and call ducking no longer drops your music for a notification chime — it waits for a real call.",
                    target: nil
                ),
            ]
        ),
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
                    detail: "Melo now has the identifier it keeps for good, so macOS asks once more — system audio, the volume keys, Bluetooth — each one when the feature needs it. Your volumes, EQ curves, devices and shortcuts are untouched.",
                    // Three system prompts arriving over the next few minutes.
                    // There is no control in the popup that is the thing this
                    // sentence is about.
                    target: nil
                ),
                MeloReleaseNote.Item(
                    id: "2.9.4-analytics-choice",
                    title: "You decide whether Melo shares anything",
                    detail: "Anonymous notes about which features get used, off until you say yes, asked once. Your app names, your devices and your Mac never leave the machine. Settings › General.",
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
                    detail: "It used to arrive the moment Melo launched, before anything explained why. Setup now has a page for it, and the request waits until you ask — there or in Settings › General.",
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
                    detail: "It points out the menu bar mark, asks for system audio access while a sound is playing, offers to hook up your volume keys, and ends on a real app row for you to try.",
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
