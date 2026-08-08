import Foundation

enum SettingsGuideCategory: String, CaseIterable, Identifiable, Sendable {
    case gettingStarted = "Getting Started"
    case everyday = "Everyday"
    case general = "General"
    case volume = "Volume & Calls"
    case apps = "Apps"
    case devices = "Devices"
    case sound = "Sound"
    case shortcuts = "Shortcuts"
    case privacy = "Privacy & Data"

    var id: String { rawValue }
}

/// The Settings tab a guide entry can send the reader to.
///
/// Deliberately *not* `SettingsRootView.Section`: this model is `Sendable` and
/// lives outside the view layer, while `Section` is nested inside a `@MainActor`
/// view. The raw values are kept identical so `SettingsRootView` can translate
/// with `Section(rawValue:)` and the two lists cannot silently drift apart —
/// a missing case shows up as a button that does nothing, not a build error, so
/// the shared spelling is the safeguard.
enum SettingsDestination: String, Hashable, CaseIterable, Sendable {
    case everyday, general, audio, effects, shortcuts, guide, updates, about

    /// The label printed on the tab, so a button can name where it is about to
    /// go. "Show me" without a destination is a leap of faith.
    var tabTitle: String {
        switch self {
        case .everyday: return "Everyday"
        case .general: return "General"
        case .audio: return "Audio"
        case .effects: return "Effects"
        case .shortcuts: return "Shortcuts"
        case .guide: return "Guide"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }
}

/// One request to put a named section of a Settings tab on screen.
///
/// `serial` is what makes a second press work. Two requests for the same
/// section are otherwise equal, so nothing observing the value changes, and the
/// button reads as dead every time after the first — which is the exact shape
/// of failure this whole path exists to end.
struct SettingsSectionTarget: Hashable, Sendable {
    let section: String
    let serial: Int
}

extension Notification.Name {
    /// Posted by the Guide when the reader asks to be shown a control that lives
    /// in the menu bar popup. `OnboardingWindowController` serves it — it is the
    /// only object holding both the popup controller and the tour coordinator.
    static let meloShowControlInPopup = Notification.Name("io.github.megavessal.Melo.showControlInPopup")
}

/// One spotlight the Guide has asked for. Carries the copy with it so the popup
/// shows the words the reader was just looking at rather than a second, drifting
/// description of the same control.
struct GuideSpotlightRequest {
    let id: String
    let title: String
    let message: String
    let target: GuidedTourTarget?
}

struct SettingsGuideEntry: Identifiable, Sendable {
    let id: String
    let category: SettingsGuideCategory
    let title: String
    let summary: String
    let details: String
    let keywords: [String]
    /// Where the control physically is, in the words of the interface: "Melo
    /// popup › Apps", "Settings › Audio › Calls". Most of Melo's controls live
    /// in the menu bar popup and therefore have no tab to jump to, so without
    /// this line those entries describe a control the reader still cannot find.
    let location: String?
    /// Where this setting actually lives. `nil` means the entry explains a
    /// concept or a control that lives in the menu bar popup rather than in a
    /// Settings tab — sending someone to a tab that does not contain what they
    /// just read about is worse than offering no button at all.
    let destination: SettingsDestination?
    /// Set when the control is in the menu bar popup. "Show me" then opens the
    /// popup and spotlights it, which is the only way most of Melo's controls
    /// can be shown at all: two thirds of this catalog describes the popup, and
    /// a Settings window cannot scroll to something that is not in it.
    let showsInPopup: Bool
    /// The region the spotlight cuts out. `nil` still opens the popup and shows
    /// the card, which is right for the few things — the status dot, Quit — that
    /// the overlay has no anchor for. A wrong cutout is worse than no cutout.
    let popupTarget: GuidedTourTarget?

    init(
        _ id: String,
        category: SettingsGuideCategory,
        title: String,
        summary: String,
        details: String = "",
        keywords: [String] = [],
        location: String? = nil,
        destination: SettingsDestination? = nil,
        showsInPopup: Bool = false,
        popupTarget: GuidedTourTarget? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.details = details
        self.keywords = keywords
        self.location = location
        self.destination = destination
        self.showsInPopup = showsInPopup
        self.popupTarget = popupTarget
    }

    /// The spotlight this entry asks for. The message is the summary the reader
    /// has just read, trimmed of the detail paragraph — the card is small.
    var spotlightRequest: GuideSpotlightRequest {
        GuideSpotlightRequest(id: id, title: title, message: summary, target: popupTarget)
    }

    /// The heading inside a Settings tab that a location line names, or `nil`
    /// when it names none: "Settings › Audio › Calls" → "Calls", and
    /// "Settings › Everyday › Audio Help › Show Details" → "Audio Help".
    ///
    /// Read out of `location` rather than stored in a field of its own. The
    /// location line is already the entry's statement of which part of which
    /// tab it is about, and the tabs anchor their sections by exactly the
    /// heading they print — a second field would be a second spelling of the
    /// same fact, free to drift from the first without anything noticing.
    ///
    /// A location that names no section, or one that points into the menu bar
    /// popup, returns `nil` and leaves the tab where it opens. Guessing a
    /// section is worse than not scrolling: it moves the reader away from the
    /// thing they asked for.
    ///
    /// Which makes a two-level location — "Settings › General" — a defect in the
    /// entry rather than a shorthand. It produces no target, so the tab opens at
    /// its top with nothing marked, and every link downstream of here behaves
    /// exactly as it does when the search is working. Nine entries were written
    /// that way and that is what the owner reported as "clicking a result does
    /// not highlight the setting". `verify-2.8.3-refinement.py` now fails on any
    /// entry whose destination tab can be marked and whose location does not say
    /// where.
    static func sectionTitle(inLocation location: String?) -> String? {
        guard let location else { return nil }
        let parts = location.split(separator: "›").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 3, parts[0] == "Settings" else { return nil }
        return parts[2]
    }

    func searchScore(_ query: String) -> Int {
        // Weighted rather than flat: `keywords` are the words a person reaches
        // for, `summary`/`details` are prose that mentions half the vocabulary
        // in the app and must not outrank a title or an alias.
        IntentSearch.score(
            query: query,
            title: title,
            keywords: keywords,
            body: [summary, details, category.rawValue]
        )
    }

    func matches(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchScore(query) > 0
    }

    /// Add each future setting here beside the tab where it appears. Keeping one
    /// flat searchable catalog avoids hiding help text inside individual views.
    ///
    /// The catalog is assembled from per-area arrays rather than written as one
    /// large literal: a single literal that size is exactly the shape that has
    /// previously blown the release-mode type checker in this project.
    static let all: [SettingsGuideEntry] =
        gettingStarted + everyday + general + volumeAndCalls + apps + devices + sound + shortcuts + privacy

    // MARK: - Getting Started

    private static let gettingStarted: [SettingsGuideEntry] = [
        .init(
            "first-adjustment",
            category: .gettingStarted,
            title: "Change One App’s Volume",
            summary: "Start something playing, click the Melo mark in the menu bar, then click that app’s row to open its slider. Nothing else on your Mac changes.",
            details: "Melo only lists apps that have made a sound since it started. An app that has been silent for a while moves down into Quiet & Remembered.",
            keywords: ["try it out", "first time", "change one app's volume", "get started", "how do i start"],
            location: "Melo popup › Apps",
            showsInPopup: true,
            popupTarget: .appRow
        ),
        .init(
            "app-controls",
            category: .gettingStarted,
            title: "Open an App’s Full Controls",
            summary: "Rows start collapsed showing only a level meter and a percentage. Clicking one reveals mute, the volume slider, Boost, the output device, EQ, and stereo balance.",
            keywords: ["where are the controls", "the row does nothing", "expand an app", "more options", "chevron"],
            location: "Melo popup › Apps",
            showsInPopup: true,
            popupTarget: .appControls
        ),
        .init(
            "popup-status",
            category: .gettingStarted,
            title: "What the Status Dot Means",
            summary: "Beside Melo’s name: Audio active means it is processing sound now, Ready for audio means nothing is playing, and Access needed means macOS has not granted system-audio access yet.",
            details: "While it reads Access needed, device volume and routing still work — only per-app volume, EQ, and Boost are unavailable.",
            keywords: ["access needed", "audio unavailable", "the dot at the top", "melo says ready", "status"],
            location: "Melo popup › header",
            showsInPopup: true
        ),
        .init(
            "permission",
            category: .gettingStarted,
            title: "Allow Access for Volume Keys",
            summary: "Your Mac’s F10–F12 keys only reach Melo once Accessibility is granted in System Settings. Without it Melo still works; the keys just move the system volume instead.",
            details: "Accessibility is what lets Melo see the key press. It is not used to read your screen or your documents.",
            keywords: ["accessibility permission", "volume keys not working", "let melo control volume", "grant access"],
            location: "Settings › Shortcuts › Media Keys",
            destination: .shortcuts
        ),
        .init(
            "settings-search",
            category: .gettingStarted,
            title: "Search Every Setting",
            summary: "The field above these tabs takes a problem as well as a name — “calls are too loud” finds the ducking switch — and Return jumps to the tab that holds it.",
            keywords: ["find a setting", "search settings", "where is that option", "i cannot find it"],
            location: "Top of the Settings window"
        ),
        .init(
            "replay-tutorial",
            category: .gettingStarted,
            title: "Replay Setup",
            summary: "Reopens the six-page setup window — what Melo does, the three permissions, the privacy question, and the try-it slider — ending with the offer of the guided tour.",
            details: "It writes nothing. Permissions you have already granted show as granted, and no setting is changed unless you press something.",
            keywords: ["show tutorial", "help me learn", "onboarding", "walkthrough", "do it again", "replay the tour"],
            location: "Settings › General › Getting Started",
            destination: .general
        )
    ]

    // MARK: - Everyday

    private static let everyday: [SettingsGuideEntry] = [
        .init(
            "scene",
            category: .everyday,
            title: "Scenes",
            summary: "Captures every app volume, every output choice, and your sound settings under one name, then puts all of it back in a click.",
            details: "A Scene stores the setup, not the apps. Applying one to a Mac where an app is closed simply skips that app.",
            keywords: ["save my setup", "sound profile", "restore my settings", "one click setup"],
            location: "Settings › Everyday › Scenes",
            destination: .everyday
        ),
        .init(
            "scene-update",
            category: .everyday,
            title: "Update a Scene",
            summary: "Overwrites a saved Scene with whatever you have set right now, so you can adjust first and commit afterwards.",
            keywords: ["overwrite a scene", "save over", "update my setup"],
            location: "Settings › Everyday › Scenes › the ⋯ menu on a Scene",
            destination: .everyday
        ),
        .init(
            "scene-share",
            category: .everyday,
            title: "Share or Import a Scene",
            summary: "Writes a Scene to a file you can send, and Import reads one back — the way to carry a setup to a second Mac.",
            keywords: ["export a scene", "import a scene", "send my setup to another mac"],
            location: "Settings › Everyday › Scenes",
            destination: .everyday
        ),
        .init(
            "scene-compare",
            category: .everyday,
            title: "Compare Two Scenes",
            summary: "Plays A then B on demand so you can hear the difference. Neither Scene is modified and nothing is saved over.",
            keywords: ["a b compare", "try two setups", "which sounds better"],
            location: "Settings › Everyday › Compare",
            destination: .everyday
        ),
        .init(
            "automation",
            category: .everyday,
            title: "Automations",
            summary: "Applies a Scene by itself on one of three triggers: an app opening, a device connecting, or a time of day arriving.",
            details: "Each automation has its own switch, so you can leave one in place and turn it off for a week.",
            keywords: ["do it automatically", "when an app opens", "run on a schedule", "trigger"],
            location: "Settings › Everyday › Automations",
            destination: .everyday
        ),
        .init(
            "focus",
            category: .everyday,
            title: "Use Melo with a Focus",
            summary: "macOS does not let apps watch Focus directly. Set Up walks you through the one Shortcuts automation that pairs a Focus with Melo’s Use Scene action.",
            keywords: ["focus mode", "do not disturb", "work mode"],
            location: "Settings › Everyday › Focus & Shortcuts",
            destination: .everyday
        ),
        .init(
            "sleep",
            category: .everyday,
            title: "Sleep Timer",
            summary: "Fades the current output down over the last stretch and then mutes it, at 15, 30, 45, or 60 minutes.",
            details: "It mutes the output rather than pausing the app, so nothing loses its place.",
            keywords: ["turn off after a while", "fade out at bedtime", "stop audio later", "bedtime"],
            location: "Settings › Everyday › Sleep Timer",
            destination: .everyday
        ),
        .init(
            "undo",
            category: .everyday,
            title: "Undo a Change",
            summary: "Reverses the last volume, routing, Scene, or sound change — including one an automation made without you.",
            details: "The last five changes are listed, so you can see what actually happened before undoing it. Undo is in the popup as well.",
            keywords: ["undo", "go back", "i changed something by mistake", "revert"],
            location: "Settings › Everyday › Recent Changes",
            destination: .everyday
        ),
        .init(
            "repair",
            category: .everyday,
            title: "Fix Audio",
            summary: "Tears down and rebuilds Melo’s live audio connections. Your volumes, Scenes, and device choices survive it.",
            details: "Worth trying after waking from sleep, after unplugging an interface, or if one app has gone silent while others still play.",
            keywords: ["no sound", "audio stopped working", "sound is broken", "restart audio"],
            location: "Settings › Everyday › Audio Help",
            destination: .everyday
        ),
        .init(
            "diagnostics",
            category: .privacy,
            title: "Copy Audio Details",
            summary: "Puts a plain-text summary of the current audio setup on the clipboard — sample rate, device, format — for pasting into a support message.",
            keywords: ["technical details", "sample rate", "troubleshooting info", "copy audio info"],
            location: "Settings › Everyday › Audio Help › Show Details",
            destination: .everyday
        )
    ]

    // MARK: - General

    private static let general: [SettingsGuideEntry] = [
        .init(
            "launch",
            category: .general,
            title: "Launch at Login",
            summary: "Melo starts with your Mac. Without it, per-app volumes are not applied until you open Melo yourself.",
            keywords: ["open at startup", "start automatically", "run on login"],
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "dock",
            category: .general,
            title: "Show Melo in the Dock",
            summary: "Gives Melo a Dock icon and an app menu, which is what makes Force Quit and ⌘Q behave the way they do for other apps.",
            keywords: ["force quit", "dock icon", "regular app", "show in dock"],
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "quit",
            category: .general,
            title: "Quit Melo",
            summary: "Quit sits at the bottom of the popup, and ⌘Q works while the popup is open. Quitting returns every app to its normal volume.",
            details: "With no Dock icon there is nothing to right-click, which is why the popup carries the button.",
            keywords: ["how do i quit", "close melo", "turn melo off", "exit"],
            location: "Melo popup › footer",
            showsInPopup: true
        ),
        .init(
            "appearance",
            category: .general,
            title: "Light or Dark",
            summary: "Melo follows macOS by default. Pinning it to Light or Dark affects Melo alone, not the rest of your Mac.",
            keywords: ["light mode", "dark mode", "follow system appearance"],
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "theme",
            category: .general,
            title: "Melo Theme",
            summary: "Changes the popup’s background and accent: Mac keeps the system look, Space, Galaxy, and Aurora add a quiet animated backdrop, Custom takes your own color.",
            details: "Themes are decoration only. None of them changes what a control does or where it sits.",
            keywords: ["change how melo looks", "skin", "visual style", "background", "aurora", "galaxy", "space", "northern lights"],
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "theme-studio",
            category: .general,
            title: "Theme Studio",
            summary: "Describe a look and have a theme generated for it, through your OpenAI key or by pasting a reply back from ChatGPT in a browser.",
            details: "Melo accepts only validated colors and bounded motion values from the result. It does not accept executable code, URLs, images, or layout changes.",
            keywords: ["ChatGPT theme", "OpenAI theme", "AI theme", "make a theme", "generated theme"],
            // Theme Studio is a row inside the General section, not a section of
            // its own. Naming it here would send the tab looking for a heading
            // that does not exist and land the reader nowhere in particular.
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "theme-color",
            category: .general,
            title: "Theme Color",
            summary: "Sets Melo’s accent — sliders, selection, the active dot. The picker only appears once the Custom theme is chosen.",
            keywords: ["accent color", "highlight color", "pick a color", "the color picker is missing"],
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "disconnect-alert",
            category: .general,
            title: "Device Disconnect Alerts",
            summary: "Posts a notification when the device you were listening on disappears, so silence is explained rather than mysterious.",
            details: "This is the only feature that asks for notification permission, and it is asked for at the end of setup rather than at launch.",
            keywords: ["notify when a device is unplugged", "headphones disconnected warning", "tell me when something drops"],
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "bluetooth-features",
            category: .general,
            title: "Bluetooth Features",
            // No battery reading. Melo has never read one — a paired device
            // carries a name and an icon — and the two battery keywords brought
            // people here expecting one.
            summary: "Adds the headsets and speakers you have paired but are not connected to, with a Connect button. Off until you turn it on.",
            details: "Turning it on, or saying yes on setup's Bluetooth page, is what makes macOS ask for Bluetooth access. Nothing is scanned before that, and turning it back off stops the scanning.",
            keywords: ["bluetooth", "paired devices", "airpods", "reconnect headphones", "connect from melo"],
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "menu-icon",
            category: .general,
            title: "Menu Bar Icon",
            summary: "Swaps the mark Melo shows in the menu bar for one that reads better against your wallpaper.",
            keywords: ["change the menu bar symbol", "top bar icon", "icon style"],
            location: "Settings › General › Menu Bar",
            destination: .general
        ),
        .init(
            "menu-icon-motion",
            category: .general,
            title: "React to Audio",
            summary: "Lets the menu bar mark move slightly, now and then, while audio plays. Off by default, and it stays still whenever nothing is playing.",
            keywords: ["menu bar icon moves", "animated icon", "stop the icon moving", "bouncing icon"],
            location: "Settings › General › Menu Bar",
            destination: .general
        ),
        .init(
            "menu-info",
            category: .general,
            title: "Show Beside the Icon",
            summary: "Puts the current volume, the output device’s name, or a small live level meter next to the mark, at the cost of menu bar width.",
            keywords: ["show volume in the menu bar", "device name in the menu bar", "text next to the icon"],
            location: "Settings › General › Menu Bar",
            destination: .general
        ),
        .init(
            "popup-size",
            category: .general,
            title: "Popup Size",
            summary: "Compact fits more rows on a small display; the roomier size gives sliders more travel and so finer control.",
            keywords: ["window is too big", "compact layout", "make melo smaller", "too small"],
            location: "Settings › General › Menu Bar",
            destination: .general
        ),
        .init(
            "quiet-move",
            category: .general,
            title: "Move Quiet Apps",
            summary: "How long an app that has stopped making sound stays in the main list before it drops into Quiet & Remembered.",
            details: "It never disappears — Quiet & Remembered is an expandable group directly below the list, and the app’s volume is kept.",
            keywords: ["apps disappear from the list", "silent apps", "inactive list", "an app vanished"],
            location: "Settings › General › General",
            destination: .general
        ),
        .init(
            "updates",
            category: .general,
            title: "Check for Updates",
            summary: "Melo is not from the App Store, so it updates itself. Check for Updates asks the release feed now and shows you the notes before anything installs.",
            keywords: ["new version", "check for updates", "upgrade melo"],
            location: "Settings › Updates › Melo Updates",
            destination: .updates
        ),
        .init(
            "auto-update",
            category: .general,
            title: "Automatic Updates",
            summary: "Two separate switches: the first looks for new versions in the background, the second also downloads and installs them without asking.",
            details: "With only the first on, Melo tells you a version is ready and waits. Leaving both off means nothing checks for security fixes but you.",
            keywords: ["update automatically", "install updates for me", "stop asking about updates", "background updates"],
            location: "Settings › Updates › Automatic Updates",
            destination: .updates
        ),
        .init(
            "whats-new",
            category: .general,
            title: "What’s New in Melo",
            summary: "The release notes for the version you are running, with a Show Me button that opens the popup and points at each new control.",
            keywords: ["release notes", "what changed", "new features", "changelog"],
            location: "Settings › About › About Melo",
            destination: .about
        ),
        .init(
            "applications-folder",
            category: .general,
            title: "Keep Melo in Applications",
            summary: "Melo replaces itself in place when it updates, which only works from a permanent folder. Run from a disk image or Downloads, updates fail.",
            details: "Melo offers to move itself the first time it notices. If you declined, quit Melo, drag it to Applications, and open it again.",
            keywords: ["move to applications", "update failed", "read only location", "translocated", "running from downloads"]
        )
    ]

    // MARK: - Volume & Calls

    private static let volumeAndCalls: [SettingsGuideEntry] = [
        .init(
            "default-volume",
            category: .volume,
            title: "Default Volume",
            summary: "The level Melo gives an app the first time it sees it. Apps you have already adjusted keep their own setting.",
            keywords: ["starting volume", "volume for new apps", "what apps open at"],
            location: "Settings › Audio › Volume",
            destination: .audio
        ),
        .init(
            "similar-volume",
            category: .volume,
            title: "Balanced Volume and Fuller Sound",
            summary: "One switch doing two jobs: it pulls apps closer together in loudness, and restores some bass and detail that the ear loses when you listen quietly.",
            details: "It works on level and tone, not on content, so it does not flatten the difference between a whisper and a shout inside one track.",
            keywords: ["even out the volume", "apps are too different in loudness", "level everything", "sounds thin when quiet", "listening at night", "quiet listening", "loudness"],
            location: "Settings › Audio › Volume",
            destination: .audio
        ),
        .init(
            "adaptive",
            category: .volume,
            title: "Smart Sound",
            summary: "The umbrella switch for Melo’s automatic listening help. With it off, the three settings beneath it do nothing.",
            keywords: ["automatic sound", "smart audio", "let melo handle it"],
            location: "Settings › Audio › Smart Sound",
            destination: .audio
        ),
        .init(
            "strength",
            category: .volume,
            title: "Smart Sound Strength",
            summary: "How far Smart Sound is allowed to move things. Low is a nudge you stop noticing; High is audible and better suited to podcasts than to music.",
            keywords: ["how strong", "intensity", "gentle or strong", "too much processing"],
            location: "Settings › Audio › Smart Sound",
            destination: .audio
        ),
        .init(
            "content-aware",
            category: .volume,
            title: "Balance Sound Automatically",
            summary: "Makes small tone corrections based on what is playing, so a lecture and an album do not need the same EQ.",
            keywords: ["adjust to what is playing", "automatic tone", "match the content"],
            location: "Settings › Audio › Smart Sound",
            destination: .audio
        ),
        .init(
            "normalization",
            category: .volume,
            title: "Keep Volume Steady",
            summary: "Catches the jump when something loud starts after a quiet stretch — an advert, an autoplaying video — while leaving deliberate film dynamics alone.",
            keywords: ["sudden loud parts", "adverts are too loud", "even loudness", "no surprises"],
            location: "Settings › Audio › Smart Sound",
            destination: .audio
        ),
        .init(
            "dialogue",
            category: .volume,
            title: "Clearer Voices",
            summary: "Lifts the frequency range speech sits in, so dialogue stands out from music and effects without raising the whole mix.",
            keywords: ["i cannot hear the speech", "mumbling", "hard to understand dialogue", "boost voices"],
            location: "Settings › Audio › Listening",
            destination: .audio
        ),
        .init(
            "duck",
            category: .volume,
            title: "Lower Other Apps During Calls",
            summary: "While a call app is making sound, everything else drops to 20% and goes back up when the call stops.",
            keywords: ["quieter calls", "lower music during meetings", "duck other apps", "music is too loud on zoom"],
            location: "Settings › Audio › Calls",
            destination: .audio
        ),
        .init(
            "call-apps",
            category: .volume,
            title: "Choose Call Apps",
            summary: "Melo knows the common meeting apps. Add a browser here if your calls happen in a tab, or clear one that keeps ducking your music by mistake.",
            keywords: ["which apps count as calls", "add zoom", "browser calls", "meeting apps", "it ducks the wrong app"],
            location: "Settings › Audio › Calls",
            destination: .audio
        ),
        .init(
            "mono",
            category: .volume,
            title: "Same Sound in Both Ears",
            summary: "Sums left and right into one signal sent to both sides, so nothing is lost if you hear better on one side or use a single earbud.",
            keywords: ["one ear", "mono audio", "i hear better on one side", "combine channels"],
            location: "Settings › Audio › Listening",
            destination: .audio
        )
    ]

    // MARK: - Apps

    private static let apps: [SettingsGuideEntry] = [
        .init(
            "app-volume",
            category: .apps,
            title: "App Volume",
            summary: "Each app has its own slider. Moving one changes that app alone — the system volume and every other app stay where they are.",
            keywords: ["change one app's volume", "per app volume", "make just this app louder"],
            location: "Melo popup › Apps › open a row",
            showsInPopup: true,
            popupTarget: .appControls
        ),
        .init(
            "app-mute",
            category: .apps,
            title: "Mute an App",
            summary: "Silences one app while everything else keeps playing, and remembers the level it was at so unmuting returns to it.",
            details: "Also on the right-click menu of any app row, without opening the row.",
            keywords: ["silence one app", "mute", "turn off the sound for one app"],
            location: "Melo popup › Apps",
            showsInPopup: true,
            popupTarget: .appRow
        ),
        .init(
            "boost",
            category: .apps,
            title: "Boost",
            summary: "Takes an app past 100% — up to four times normal — for sources recorded far too quietly. It amplifies distortion along with everything else.",
            details: "Work up from 2x rather than starting at 4x, and drop back a step the moment it sounds harsh.",
            keywords: ["this app is too quiet", "louder than maximum", "amplify", "over 100%", "400%"],
            location: "Melo popup › Apps › open a row",
            showsInPopup: true,
            popupTarget: .appControls
        ),
        .init(
            "routing",
            category: .apps,
            title: "Where an App Plays",
            summary: "Sends one app to a device of its own — a film to the TV while messages stay on the Mac — or, in Multi mode, to several devices at once.",
            details: "Follows macOS default is the starting state: the app goes wherever your Mac's output goes.",
            keywords: ["send an app to headphones", "play this app on the speakers", "split audio", "a different output per app", "multi output"],
            location: "Melo popup › Apps › open a row",
            showsInPopup: true,
            popupTarget: .appControls
        ),
        .init(
            "balance",
            category: .apps,
            title: "Stereo Field and Balance",
            summary: "Moves one app toward the left or right side, with a Center button to put it back exactly.",
            keywords: ["left right", "one side is louder", "pan", "stereo balance"],
            location: "Melo popup › Apps › open a row",
            showsInPopup: true,
            popupTarget: .appControls
        ),
        .init(
            "meter",
            category: .apps,
            title: "The Level Meter",
            summary: "The moving bar at the left of a row is the sound that app is producing right now — the quickest way to find which app is making a noise.",
            details: "A row with a flat meter is an app Melo is holding a control for but that is currently silent.",
            keywords: ["what is playing", "sound bars", "activity indicator", "which app is making noise"],
            location: "Melo popup › Apps",
            showsInPopup: true,
            popupTarget: .appRow
        ),
        .init(
            "always-show",
            category: .apps,
            title: "Always Show",
            summary: "Pins a row so it stays put even when the app is closed, which is what you want for the app whose volume you set every day.",
            details: "This only keeps the control visible. Melo still releases unneeded audio access.",
            // The app's own search placeholder is "keep Spotify visible", so
            // "keep" and "visible" both have to be first-class aliases here or
            // the example Melo suggests returns the wrong entry.
            keywords: ["keep an app visible", "keep it in the list", "stay visible when closed", "pin an app"],
            location: "Melo popup › Apps › Reorder",
            showsInPopup: true,
            popupTarget: .apps
        ),
        .init(
            "ignore",
            category: .apps,
            title: "Hide an App",
            summary: "Takes an app off the list for good — useful for the one that beeps once an hour and pushes everything else down.",
            details: "Hidden apps keep playing at their current volume; Melo simply stops showing a control for them.",
            keywords: ["hide an app", "remove an app from the list", "stop showing an app"],
            location: "Melo popup › Apps, or right-click a row",
            showsInPopup: true,
            popupTarget: .apps
        ),
        .init(
            "hidden-apps",
            category: .apps,
            title: "Bring a Hidden App Back",
            summary: "Every app you have hidden is listed behind the Hidden Apps button above the list. Clicking its chip restores the row.",
            keywords: ["unhide an app", "i hid an app by mistake", "restore an app", "where did the app go"],
            location: "Melo popup › Apps › Hidden Apps",
            showsInPopup: true,
            popupTarget: .apps
        ),
        .init(
            "quiet-apps",
            category: .apps,
            title: "Quiet & Remembered",
            summary: "Apps that have gone silent collect here instead of vanishing. Expand it to reach an app that has stopped playing but whose volume you still want to set.",
            keywords: ["quiet apps", "n quiet", "an app left the list", "remembered apps"],
            location: "Melo popup › Apps header",
            showsInPopup: true,
            popupTarget: .apps
        )
    ]

    // MARK: - Devices

    private static let devices: [SettingsGuideEntry] = [
        .init(
            "default-device",
            category: .devices,
            title: "Choose the Output",
            summary: "Clicking a device row in the Audio section makes it your Mac’s output — the same switch as Control Center, without leaving Melo.",
            keywords: ["change the output", "switch to headphones", "where sound plays"],
            location: "Melo popup › Audio › Output",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "device-volume",
            category: .devices,
            title: "Device Volume and Mute",
            summary: "Each device has its own slider and mute, and its own remembered level, so headphones do not inherit whatever the speakers were at.",
            details: "The percentage is editable — click it and type a number when a slider is too coarse. Scrolling over the slider also steps it.",
            keywords: ["speaker volume", "headphone volume", "mute the output", "type an exact volume", "device slider"],
            location: "Melo popup › Audio › Output",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "input-volume",
            category: .devices,
            title: "Microphone Level and Mute",
            summary: "The Input tab lists your microphones with the same slider and mute, so you can drop your mic without hunting for the app that is using it.",
            keywords: ["mic volume", "mute my microphone", "input level", "microphone is too quiet"],
            location: "Melo popup › Audio › Input",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "preferred-input",
            category: .devices,
            title: "Choose Your Microphone",
            summary: "Clicking a row under Input makes that device your Mac’s microphone for every app that follows the system choice.",
            details: "If macOS keeps overriding it when something connects, Lock Input Device is the setting that stops that.",
            keywords: ["mic", "choose my microphone", "which mic melo uses", "usb microphone"],
            location: "Melo popup › Audio › Input",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "input-lock",
            category: .devices,
            title: "Lock Input Device",
            summary: "Stops macOS from silently switching your microphone when a headset or webcam connects mid-call.",
            keywords: ["microphone keeps changing", "stop switching the input", "my mic changes by itself"],
            location: "Settings › Audio › Devices",
            destination: .audio
        ),
        .init(
            "priority",
            category: .devices,
            title: "Device Priority",
            summary: "Numbers the devices so that when several are connected at once, Melo knows which one you actually meant to listen on.",
            keywords: ["preferred device order", "which device wins", "switch devices automatically", "reorder devices"],
            location: "Melo popup › Audio › Reorder devices",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "hide-device",
            category: .devices,
            title: "Hide a Device",
            summary: "Removes a device from Melo’s list without disconnecting it — for the virtual outputs other software installs and you never choose.",
            keywords: ["remove a device from the list", "too many devices", "tidy up the device list"],
            location: "Melo popup › Audio › Reorder devices",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "device-icon",
            category: .devices,
            title: "Device Icon",
            summary: "Replaces the symbol on a device row, so an interface called “USB Audio CODEC” can look like the headphones it actually is.",
            keywords: ["change a device symbol", "the wrong picture", "a picture for my speaker"],
            location: "Melo popup › Audio › Reorder devices",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "device-control",
            category: .devices,
            title: "How a Device’s Volume Is Controlled",
            summary: "Melo prefers the device’s own hardware volume, falls back to DDC for displays, and uses software gain only when neither exists. The badge names which it chose.",
            details: "Switch to Melo’s software volume when the slider moves but the sound does not — some devices report a volume control they do not implement.",
            keywords: ["the slider does nothing", "device volume will not change", "control method", "hardware or software volume"],
            location: "Melo popup › Audio › Reorder devices › expand a device",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "device-details",
            category: .devices,
            title: "Device Details",
            summary: "Connection, quality, and latency for a device in plain words, with a Technical details section holding transport, format, channels, clock, and the device ID.",
            details: "The sample rate here is a live control, not a readout: changing it changes how the device runs.",
            keywords: ["sample rate", "latency", "device id", "48khz", "what format is my device", "technical details"],
            location: "Melo popup › Audio › Reorder devices › expand a device",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "device-exclusive",
            category: .devices,
            title: "A Device in Exclusive Use",
            summary: "When another app takes exclusive control of a device, macOS locks everyone else out. Melo names the app rather than leaving the controls dead.",
            details: "Quitting the named app, or turning off its exclusive or hog mode, returns the device.",
            keywords: ["controls are grayed out", "controls are greyed out", "cannot change this device", "another app has it", "exclusive use", "hog mode"],
            location: "Melo popup › Audio › Reorder devices › expand a device",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "system-sounds",
            category: .devices,
            title: "System Sounds",
            summary: "Sends alerts and interface beeps to a device of their own, so a notification does not arrive in your headphones during a film.",
            keywords: ["alert sounds", "notification sounds", "where beeps play"],
            location: "Settings › Audio › Devices",
            destination: .audio
        ),
        .init(
            "alert-volume",
            category: .devices,
            title: "Alert Volume",
            summary: "Sets how loud notifications are relative to everything else, so quiet listening does not mean being startled by a beep.",
            keywords: ["notifications are too loud", "quieter alerts", "beep volume"],
            location: "Settings › Audio › Devices",
            destination: .audio
        ),
        .init(
            "monitor-volume",
            category: .devices,
            title: "Display and TV Speakers",
            summary: "Most monitors accept volume over DDC rather than as an audio device. Melo tries that first and drops to software gain when the display refuses.",
            keywords: ["display speakers", "monitor speakers", "hdmi volume", "tv volume"],
            location: "Melo popup › Audio › Output",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "bluetooth",
            category: .devices,
            title: "Connect Bluetooth Audio",
            summary: "Paired headsets appear under Paired with a Connect button, so reconnecting does not mean a trip to System Settings.",
            details: "The Paired list only appears once Bluetooth Features is turned on in General settings.",
            keywords: ["airpods", "connect headphones", "pair a speaker", "wireless headset"],
            location: "Melo popup › Audio › Output › Paired",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "airplay",
            category: .devices,
            title: "AirPlay Speakers",
            summary: "An AirPlay speaker that macOS has already connected appears in Melo's list like any other output, with its own volume and its own icon.",
            details: "Melo cannot start the AirPlay connection — choose the speaker in Control Center first. Headphone profiles are not offered for AirPlay, because a room speaker is not a headphone.",
            keywords: ["airplay", "homepod", "apple tv", "play to my speaker", "wireless speaker"],
            location: "Melo popup › Audio › Output",
            showsInPopup: true,
            popupTarget: .devices
        ),
        .init(
            "headphone-pause",
            category: .devices,
            title: "Pause When Headphones Disconnect",
            summary: "Sends a pause when the headphones you were listening on drop out, so a podcast does not carry on into an empty room.",
            keywords: ["pause when i take them off", "unplugging pauses music", "automatic pause"],
            location: "Settings › Audio › Devices",
            destination: .audio
        )
    ]

    // MARK: - Sound

    private static let sound: [SettingsGuideEntry] = [
        .init(
            "device-autoeq",
            category: .sound,
            title: "Headphone Sound Profile",
            summary: "Applies a measured correction for your exact headphone model, flattening the peaks and dips that model is known to have.",
            details: "Search by model name. The profile attaches to that device, so it follows the headphones rather than the app.",
            keywords: ["headphone correction", "make my headphones sound right", "harman target", "autoeq"],
            location: "Melo popup › Audio › the profile control on a device row",
            showsInPopup: true,
            popupTarget: .autoEQ
        ),
        .init(
            "autoeq-favorites",
            category: .sound,
            title: "Favorite Headphone Profiles",
            summary: "Starring a profile lifts it to the top of the list, which matters because the catalog runs to thousands of models.",
            keywords: ["star a profile", "favorite headphones", "favourite headphones", "top of the list", "my headphones"],
            location: "Melo popup › Audio › headphone profile search",
            showsInPopup: true,
            popupTarget: .autoEQ
        ),
        .init(
            "autoeq-import",
            category: .sound,
            title: "Import an EQ File",
            summary: "Takes an AutoEQ ParametricEQ text file, so a measurement for headphones missing from the catalog — or your own — can be used.",
            keywords: ["parametriceq", "import a correction", "my headphones are not listed", "custom eq file"],
            location: "Melo popup › Audio › headphone profile search",
            showsInPopup: true,
            popupTarget: .autoEQ
        ),
        .init(
            "autoeq-preamp",
            category: .sound,
            title: "Prevent Profile Clipping",
            summary: "A correction that boosts frequencies can push the signal past full scale. This drops the level first, which is why a profile can sound quieter.",
            details: "Turn it off only if a profile cuts more than it boosts and you want the level back. This switch is about imported headphone profiles and nothing else — if an EQ preset started sounding quieter, that is a separate, automatic control with no switch; see “Why a Preset Sounds Quieter”.",
            keywords: ["distortion with a profile", "crackling", "headroom", "too loud after a profile", "quieter after a profile"],
            location: "Melo popup › Audio › headphone profile search",
            showsInPopup: true,
            popupTarget: .autoEQ
        ),
        // Melo has two preamps with different contracts, and the reader has no
        // way to know which one they met. The imported-profile one above is a
        // switch they chose; this one is automatic and has no switch. Without
        // this entry, a search for the symptom the *automatic* one produces —
        // "quieter after a preset" — returns "Prevent Profile Clipping", whose
        // toggle has no effect on what they are hearing, and the Guide has
        // confidently sent them to the wrong control.
        .init(
            "app-eq-headroom",
            category: .sound,
            title: "Why a Preset Sounds Quieter",
            summary: "A preset that lifts bands would push the sound past full scale, so Melo lowers the level by the size of its biggest lift first. Electronic lifts 7 dB, so it plays 7 dB quieter — the tone is what changed, not just the loudness.",
            details: "This is automatic and has no switch: the level it takes back is exactly the level the curve added, so turning it off would only trade tone for distortion. The amount is shown beside the EQ switch as “Headroom −7.0 dB”. It is not the same control as “Prevent Profile Clipping”, which applies to imported headphone profiles; that switch does nothing to a preset. To get loudness back, raise the app's own volume — Melo goes past 100%.",
            keywords: [
                "quieter after a preset", "quieter after an eq preset",
                "preset sounds quieter", "eq made it quieter",
                "electronic sounds quiet", "equalizer lowered the volume",
                "headroom", "eq preamp", "why is my eq quieter",
                "lost volume after choosing a preset"
            ],
            location: "Melo popup › Apps › open a row › EQ",
            showsInPopup: true,
            popupTarget: .equalizer
        ),
        .init(
            "app-eq",
            category: .sound,
            title: "App Equaliser",
            summary: "Ten bands for one app, so a bass lift on a music app does not muddy every voice call you take.",
            keywords: ["eq", "equalizer", "bass and treble", "adjust the tone", "more bass"],
            location: "Melo popup › Apps › open a row › EQ",
            showsInPopup: true,
            popupTarget: .equalizer
        ),
        .init(
            "eq-preset",
            category: .sound,
            title: "Sound Presets",
            summary: "Saves a band setup under a name and reuses it on any app, so a curve you tuned once is not rebuilt by hand.",
            keywords: ["save my tone settings", "reuse a curve", "eq presets"],
            location: "Melo popup › Apps › open a row › EQ",
            showsInPopup: true,
            popupTarget: .equalizer
        ),
        .init(
            "effects",
            category: .sound,
            title: "Audio Unit Effects",
            summary: "Runs installed Audio Units on one app or on everything Melo controls, chosen with the Audio source picker at the top.",
            details: "For people who already use Audio Unit plug-ins. Nothing here is needed for volume, routing, or EQ.",
            keywords: ["audio unit", "plugin", "add an effect", "reverb", "au"],
            location: "Settings › Effects › Audio Unit Effects",
            destination: .effects
        ),
        .init(
            "effect-manage",
            category: .sound,
            title: "Add, Remove, and Rescan Effects",
            summary: "Add Effect opens a searchable browser grouped by manufacturer; the ⋯ menu on a slot removes it. Rescan finds plug-ins installed since Melo started.",
            keywords: ["my plugin is missing", "remove an effect", "rescan audio units", "browse audio units"],
            location: "Settings › Effects › Audio Unit Effects",
            destination: .effects
        ),
        .init(
            "effect-bypass",
            category: .sound,
            title: "Turn an Effect Off Temporarily",
            summary: "Bypass passes the audio straight through while the effect stays loaded and keeps its settings, which is how you A/B it.",
            details: "The slot switch beside it does the same thing more permanently; bypass is the one meant for comparing.",
            keywords: ["turn an effect off for a moment", "compare with and without", "bypass"],
            location: "Settings › Effects › Effect Chain",
            destination: .effects
        ),
        .init(
            "effect-order",
            category: .sound,
            title: "Effect Order",
            summary: "Audio passes through the slots top to bottom, and the order changes the result — a compressor before a reverb sounds unlike one after it.",
            keywords: ["reorder effects", "chain order", "which effect comes first"],
            location: "Settings › Effects › Effect Chain",
            destination: .effects
        ),
        .init(
            "effect-window",
            category: .sound,
            title: "Open an Effect’s Own Controls",
            summary: "Opens the plug-in’s own interface when it ships one; otherwise Melo builds a plain slider list from its parameters.",
            keywords: ["open the plugin window", "effect settings", "its own controls"],
            location: "Settings › Effects › Effect Chain",
            destination: .effects
        )
    ]

    // MARK: - Shortcuts

    private static let shortcuts: [SettingsGuideEntry] = [
        .init(
            "media-keys",
            category: .shortcuts,
            title: "Volume Keys",
            summary: "Points F10, F11, and F12 at whichever device Melo has selected, instead of at whatever macOS thinks the output is.",
            details: "Needs Accessibility. The Grant button beside the switch is the fastest way there.",
            keywords: ["f11 and f12", "the keys on my keyboard", "volume keys do nothing"],
            location: "Settings › Shortcuts › Media Keys",
            destination: .shortcuts
        ),
        .init(
            "media-keys-offline",
            category: .shortcuts,
            title: "Volume Keys Stopped Working",
            summary: "macOS sometimes drops Melo’s key tap after sleep or a permission change. Melo notices and shows a Retry button rather than staying quietly broken.",
            details: "If Retry does not take, remove Melo from System Settings › Privacy & Security › Accessibility and add it again.",
            keywords: ["keys stopped after sleep", "media keys offline", "volume keys broke", "retry media keys"],
            location: "Settings › Shortcuts › Media Keys",
            destination: .shortcuts
        ),
        .init(
            "key-step",
            category: .shortcuts,
            title: "Volume Step",
            summary: "How far one key press moves the volume. A smaller step is what you want on sensitive headphones where the usual jump is the difference between quiet and loud.",
            keywords: ["the volume jumps too much", "smaller steps", "finer volume control"],
            location: "Settings › Shortcuts › Volume",
            destination: .shortcuts
        ),
        .init(
            "hud",
            category: .shortcuts,
            title: "Volume Display",
            summary: "The on-screen readout when volume changes: Melo’s own, the macOS one, or none at all.",
            keywords: ["hud", "on screen volume", "the volume popup", "volume overlay"],
            location: "Settings › Shortcuts › Media Keys",
            destination: .shortcuts
        ),
        .init(
            "global-shortcuts",
            category: .shortcuts,
            title: "Keyboard Shortcuts",
            summary: "Four system-wide keys: open the popup, and raise, lower, or mute whichever app is playing — the one in front if that app is also making sound, otherwise whatever is.",
            details: "With nothing playing at all, the keys fall back to the app you are in front of, so a press is never simply lost.",
            keywords: ["hotkey", "assign keys", "a shortcut for mute", "global shortcut"],
            location: "Settings › Shortcuts › Hotkeys",
            destination: .shortcuts
        ),
        .init(
            "command-search",
            category: .shortcuts,
            title: "Find an Action",
            summary: "⌘K in the popup takes a plain sentence — “Spotify to 40%”, “play through the speakers” — and runs it.",
            details: "It also reaches Scenes, Fix Audio, Smart Sound, and this Guide, so most things can be done without clicking through.",
            keywords: ["command k", "search for an action", "quick search", "spotlight for melo"],
            location: "Melo popup › ⌘K",
            showsInPopup: true,
            popupTarget: .search
        ),
        .init(
            "popup-keyboard",
            category: .shortcuts,
            title: "Use the Popup Without a Mouse",
            summary: "Arrow keys move between rows, typing jumps to an app by name, Return opens the selected row, and Escape steps back out one level at a time.",
            keywords: ["keyboard navigation", "no mouse", "arrow keys", "accessibility keyboard"],
            location: "Melo popup",
            showsInPopup: true
        ),
        .init(
            "shortcuts-app",
            category: .shortcuts,
            title: "Apple Shortcuts",
            summary: "Melo publishes actions to the Shortcuts app — Use Scene among them — which is how it reaches Focus modes, times of day, and the menu bar’s Shortcuts menu.",
            keywords: ["the shortcuts app", "automate with shortcuts", "siri"],
            location: "Settings › Everyday › Focus & Shortcuts",
            destination: .everyday
        )
    ]

    // MARK: - Privacy & Data

    private static let privacy: [SettingsGuideEntry] = [
        .init(
            "analytics",
            category: .privacy,
            title: "Share Anonymous Usage",
            summary: "Off unless you turn it on. It records which features get used, so the next version improves the parts people actually reach for.",
            details: "Melo asks once and keeps your answer. Turning it off stops the collection at the source rather than collecting quietly and not sending.",
            keywords: ["analytics", "telemetry", "usage data", "opt out of tracking", "stop sharing data", "help improve melo"],
            location: "Settings › General › Privacy",
            destination: .general
        ),
        .init(
            "analytics-collected",
            category: .privacy,
            title: "What Melo Collects",
            summary: "Melo’s version, your macOS version, roughly which Mac chip you have, your language, and which features were used.",
            details: "The names of your apps, your audio devices, and your Mac never leave the machine, and neither does anything about what you listen to.",
            keywords: ["what data is collected", "does melo send my app names", "what leaves my mac", "crash reports"],
            location: "Settings › General › Privacy",
            destination: .general
        ),
        .init(
            "privacy",
            category: .privacy,
            title: "Process Only When Needed",
            summary: "Melo taps an app’s audio only while that app has a control you have changed, and hands the audio back untouched otherwise.",
            details: "This is what keeps Melo’s processing cost near zero when you are not using it, and it is on by default.",
            keywords: ["does melo touch every app", "cpu use", "leave my apps alone"],
            location: "Settings › Audio › Privacy",
            destination: .audio
        ),
        .init(
            "battery",
            category: .privacy,
            title: "Use Less Processing on Battery",
            summary: "Suspends Smart Sound and the automatic tone work while unplugged. Per-app volume, mute, and routing keep working exactly as before.",
            keywords: ["save battery", "on battery power", "unplugged"],
            location: "Settings › Audio › Privacy",
            destination: .audio
        ),
        .init(
            "backup",
            category: .privacy,
            title: "Save a Settings Backup",
            summary: "Writes every Melo setting — apps, devices, Scenes, automations — to one file you can keep or carry to another Mac.",
            keywords: ["export my settings", "save settings to a file", "back up melo"],
            location: "Settings › General › Data",
            destination: .general
        ),
        .init(
            "restore",
            category: .privacy,
            title: "Restore a Settings Backup",
            summary: "Replaces what you have now with the contents of a backup file. Melo confirms first, because this is not merged into your current setup.",
            keywords: ["import my settings", "load a backup", "bring my settings back"],
            location: "Settings › General › Data",
            destination: .general
        ),
        .init(
            "reset",
            category: .privacy,
            title: "Reset All Settings",
            summary: "Returns every option to its default and forgets your per-app and per-device choices, while leaving Melo installed and running.",
            keywords: ["start over", "back to defaults", "clear my settings"],
            location: "Settings › General › Data",
            destination: .general
        ),
        .init(
            "erase",
            category: .privacy,
            title: "Erase All Melo Data",
            summary: "Removes everything Melo has stored and restarts it as a brand-new installation, first-run setup included.",
            details: "macOS privacy permissions live outside Melo and are not removed. Take those back in System Settings › Privacy & Security.",
            keywords: ["fresh start", "factory reset", "delete everything", "remove all data"],
            location: "Settings › General › Data",
            destination: .general
        ),
        .init(
            "uninstall",
            category: .privacy,
            title: "Remove Melo from This Mac",
            summary: "Quit Melo from the popup, then drag it out of Applications. Every app returns to its normal volume the moment Melo quits.",
            details: "Run Erase All Melo Data first if you want its stored settings gone as well — dragging the app to the Trash leaves those behind. The Accessibility and audio permissions are removed separately, in System Settings › Privacy & Security.",
            keywords: ["uninstall", "remove melo", "delete melo", "get rid of it", "how do i uninstall"]
        ),
        .init(
            "license",
            category: .privacy,
            title: "License and Source",
            summary: "Melo is GPL-3.0 and builds on the open-source FineTune project. The About tab links to both the license and the upstream source.",
            keywords: ["license", "gpl", "open source", "who made this", "finetune", "copyright"],
            location: "Settings › About › License and Source",
            destination: .about
        ),
        .init(
            "problem-report",
            category: .privacy,
            title: "Report a Problem",
            summary: "Builds a ZIP with logs, any crash details, and a summary of your settings — the thing to attach when something is wrong and hard to describe.",
            details: "No audio is recorded. App names and file contents are excluded by default, and you can open the ZIP and read it before sending it.",
            keywords: ["diagnostics", "error report", "crash log", "support"],
            location: "Settings › General › Help and Diagnostics",
            destination: .general
        )
    ]
}
