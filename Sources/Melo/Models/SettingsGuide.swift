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

struct SettingsGuideEntry: Identifiable, Sendable {
    let id: String
    let category: SettingsGuideCategory
    let title: String
    let summary: String
    let details: String
    let keywords: [String]
    /// Where this setting actually lives. `nil` means the entry explains a
    /// concept or a control that lives in the menu bar popup rather than in a
    /// Settings tab — sending someone to a tab that does not contain what they
    /// just read about is worse than offering no button at all.
    let destination: SettingsDestination?

    init(
        _ id: String,
        category: SettingsGuideCategory,
        title: String,
        summary: String,
        details: String = "",
        keywords: [String] = [],
        destination: SettingsDestination? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.details = details
        self.keywords = keywords
        self.destination = destination
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
    /// 78-element literal: a single literal that large is exactly the shape that
    /// has previously blown the release-mode type checker in this project.
    static let all: [SettingsGuideEntry] =
        gettingStarted + everyday + general + volumeAndCalls + apps + devices + sound + shortcuts + privacy

    // MARK: - Getting Started

    private static let gettingStarted: [SettingsGuideEntry] = [
        .init(
            "permission",
            category: .gettingStarted,
            title: "Allow Access",
            summary: "Lets your Mac's volume keys control Melo.",
            details: "Melo uses Accessibility for media keys and optional playback controls. It does not use this permission to read your documents.",
            keywords: ["accessibility permission", "volume keys not working", "let melo control volume", "grant access"],
            destination: .shortcuts
        ),
        .init(
            "first-adjustment",
            category: .gettingStarted,
            title: "Change One App",
            summary: "Play sound in an app, open Melo, and move that app's slider.",
            keywords: ["try it out", "first time", "change one app's volume", "get started"]
        ),
        .init(
            "replay-tutorial",
            category: .gettingStarted,
            title: "Replay Tutorial",
            summary: "Walk through Melo’s main controls again without changing your settings.",
            keywords: ["show tutorial", "help me learn", "onboarding", "walkthrough"],
            destination: .general
        )
    ]

    // MARK: - Everyday

    private static let everyday: [SettingsGuideEntry] = [
        .init(
            "scene",
            category: .everyday,
            title: "Scenes",
            summary: "Save your whole sound setup and bring it back in one click.",
            keywords: ["save my setup", "sound profile", "restore my settings", "one click setup"],
            destination: .everyday
        ),
        .init(
            "scene-update",
            category: .everyday,
            title: "Update a Scene",
            summary: "Replace a saved Scene with the setup you are using now.",
            keywords: ["overwrite a scene", "save over", "update my setup"],
            destination: .everyday
        ),
        .init(
            "scene-share",
            category: .everyday,
            title: "Share a Scene",
            summary: "Save a Scene to a file or import one from another Mac.",
            keywords: ["export a scene", "import a scene", "send my setup to another mac"],
            destination: .everyday
        ),
        .init(
            "scene-compare",
            category: .everyday,
            title: "Compare Scenes",
            summary: "Switch between two saved setups without changing either one.",
            keywords: ["a b compare", "try two setups", "which sounds better"],
            destination: .everyday
        ),
        .init(
            "automation",
            category: .everyday,
            title: "Automations",
            summary: "Use a Scene when an app opens, a device connects, or a time arrives.",
            keywords: ["do it automatically", "when an app opens", "run on a schedule", "trigger"],
            destination: .everyday
        ),
        .init(
            "focus",
            category: .everyday,
            title: "Use Melo with Focus",
            summary: "In Shortcuts, pair a Focus automation with Melo's Use Scene action.",
            keywords: ["focus mode", "do not disturb", "work mode"],
            destination: .everyday
        ),
        .init(
            "sleep",
            category: .everyday,
            title: "Sleep Timer",
            summary: "Fade the current output down, then mute it after a chosen time.",
            keywords: ["turn off after a while", "fade out at bedtime", "stop audio later", "bedtime"],
            destination: .everyday
        ),
        .init(
            "undo",
            category: .everyday,
            title: "Recent Changes",
            summary: "Undo the latest volume, routing, Scene, or sound adjustment.",
            keywords: ["undo", "go back", "i changed something by mistake", "revert"],
            destination: .everyday
        ),
        .init(
            "repair",
            category: .everyday,
            title: "Fix Audio",
            summary: "Safely rebuild Melo's live audio connections without deleting settings.",
            keywords: ["no sound", "audio stopped working", "sound is broken", "restart audio"],
            destination: .everyday
        ),
        .init(
            "diagnostics",
            category: .privacy,
            title: "Audio Details",
            summary: "Copy a plain-text summary when troubleshooting. Technical information stays out of the main controls.",
            keywords: ["technical details", "sample rate", "troubleshooting info", "copy audio info"],
            destination: .everyday
        )
    ]

    // MARK: - General

    private static let general: [SettingsGuideEntry] = [
        .init(
            "launch",
            category: .general,
            title: "Launch at Login",
            summary: "Start Melo automatically when you sign in.",
            keywords: ["open at startup", "start automatically", "run on login"],
            destination: .general
        ),
        .init(
            "dock",
            category: .general,
            title: "Show Melo in Dock",
            summary: "Keep Melo visible like a regular Mac app and make it easier to force quit.",
            keywords: ["force quit", "dock icon", "regular app", "show in dock"],
            destination: .general
        ),
        .init(
            "appearance",
            category: .general,
            title: "Appearance",
            summary: "Follow macOS or keep Melo in Light or Dark mode.",
            keywords: ["light mode", "dark mode", "follow system appearance"],
            destination: .general
        ),
        .init(
            "theme",
            category: .general,
            title: "Melo Theme",
            summary: "Choose Mac, Space, Galaxy, Aurora, Custom, or a Theme Studio design.",
            keywords: ["change how melo looks", "skin", "visual style", "background"],
            destination: .general
        ),
        .init(
            "aurora-theme",
            category: .general,
            title: "Aurora Theme",
            summary: "Use a dark northern-night background lit by slow aurora ribbons and restrained stars.",
            keywords: ["northern lights", "borealis", "night theme"],
            destination: .general
        ),
        .init(
            "theme-studio",
            category: .general,
            title: "Theme Studio",
            summary: "Generate a constrained theme through the OpenAI API or use the no-key ChatGPT browser bridge.",
            details: "Melo accepts only validated colors and bounded motion values. It does not accept executable code, URLs, images, or layout changes.",
            keywords: ["ChatGPT theme", "OpenAI theme", "AI theme", "make a theme", "generated theme"],
            destination: .general
        ),
        .init(
            "theme-color",
            category: .general,
            title: "Theme Color",
            summary: "Choose a custom Melo accent when Custom Theme is selected.",
            keywords: ["accent color", "highlight color", "pick a color"],
            destination: .general
        ),
        .init(
            "disconnect-alert",
            category: .general,
            title: "Device Disconnect Alerts",
            summary: "Show a notification when an audio device disappears.",
            keywords: ["notify when a device is unplugged", "headphones disconnected warning", "tell me when something drops"],
            destination: .general
        ),
        .init(
            "quiet-move",
            category: .general,
            title: "Move Quiet Apps",
            summary: "Choose how long a silent app stays in the main list before moving to Inactive.",
            keywords: ["apps disappear from the list", "silent apps", "inactive list", "an app vanished"],
            destination: .general
        ),
        .init(
            "menu-icon",
            category: .general,
            title: "Menu Bar Icon",
            summary: "Choose the symbol Melo shows in the menu bar.",
            keywords: ["change the menu bar symbol", "top bar icon", "icon style"],
            destination: .general
        ),
        .init(
            "menu-info",
            category: .general,
            title: "Show Beside Icon",
            summary: "Optionally show volume, device name, or a small live level.",
            keywords: ["show volume in the menu bar", "device name in the menu bar", "text next to the icon"],
            destination: .general
        ),
        .init(
            "popup-size",
            category: .general,
            title: "Popup Size",
            summary: "Choose a compact layout or give controls more breathing room.",
            keywords: ["window is too big", "compact layout", "make melo smaller"],
            destination: .general
        ),
        .init(
            "updates",
            category: .general,
            title: "Updates",
            summary: "Check for a newer version of Melo.",
            keywords: ["new version", "check for updates", "upgrade melo"],
            destination: .updates
        )
    ]

    // MARK: - Volume & Calls

    private static let volumeAndCalls: [SettingsGuideEntry] = [
        .init(
            "default-volume",
            category: .volume,
            title: "Default Volume",
            summary: "Sets the starting volume for apps Melo has not seen before.",
            keywords: ["starting volume", "volume for new apps", "what apps open at"],
            destination: .audio
        ),
        .init(
            "similar-volume",
            category: .volume,
            title: "Balanced Volume and Fuller Sound",
            summary: "Keeps apps closer in volume and preserves fullness when listening quietly.",
            keywords: ["even out the volume", "apps are too different in loudness", "level everything"],
            destination: .audio
        ),
        .init(
            "low-volume-fullness",
            category: .volume,
            title: "Fuller Sound at Low Volume",
            summary: "Adds back some bass and detail when listening quietly.",
            keywords: ["sounds thin when quiet", "listening at night", "quiet listening", "loudness"],
            destination: .audio
        ),
        .init(
            "adaptive",
            category: .volume,
            title: "Smart Sound",
            summary: "Gently balances tone and catches sudden loud moments.",
            keywords: ["automatic sound", "smart audio", "let melo handle it"],
            destination: .audio
        ),
        .init(
            "strength",
            category: .volume,
            title: "Smart Sound Strength",
            summary: "Choose how gently or strongly Melo reacts.",
            keywords: ["how strong", "intensity", "gentle or strong"],
            destination: .audio
        ),
        .init(
            "content-aware",
            category: .volume,
            title: "Balance Sound Automatically",
            summary: "Makes small tone adjustments based on what is playing.",
            keywords: ["adjust to what is playing", "automatic tone", "match the content"],
            destination: .audio
        ),
        .init(
            "normalization",
            category: .volume,
            title: "Keep Volume Steady",
            summary: "Catches spikes after silence while preserving expected movie impact.",
            keywords: ["sudden loud parts", "adverts are too loud", "even loudness", "no surprises"],
            destination: .audio
        ),
        .init(
            "dialogue",
            category: .volume,
            title: "Clearer Voices",
            summary: "Bring speech forward in movies, calls, and videos.",
            keywords: ["i cannot hear the speech", "mumbling", "hard to understand dialogue", "boost voices"],
            destination: .audio
        ),
        .init(
            "duck",
            category: .volume,
            title: "Lower Other Apps During Calls",
            summary: "Drops other apps to 20% while a call app is making sound, then restores them.",
            keywords: ["quieter calls", "lower music during meetings", "duck other apps", "music is too loud on zoom"],
            destination: .audio
        ),
        .init(
            "call-apps",
            category: .volume,
            title: "Choose Call Apps",
            summary: "Add a browser or another communication app Melo should treat as a call.",
            keywords: ["which apps count as calls", "add zoom", "browser calls", "meeting apps"],
            destination: .audio
        ),
        .init(
            "mono",
            category: .volume,
            title: "Same Sound in Both Ears",
            summary: "Combines left and right audio so both sides play the same content.",
            keywords: ["one ear", "mono audio", "i hear better on one side", "combine channels"],
            destination: .audio
        )
    ]

    // MARK: - Apps

    private static let apps: [SettingsGuideEntry] = [
        .init(
            "always-show",
            category: .apps,
            title: "Always Show",
            summary: "Keep an app's row visible even when the app is closed.",
            details: "This only keeps the control visible. Melo still releases unneeded audio access.",
            // The app's own search placeholder is "keep Spotify visible", so
            // "keep" and "visible" both have to be first-class aliases here or
            // the example Melo suggests returns the wrong entry.
            keywords: ["keep an app visible", "keep it in the list", "stay visible when closed", "pin an app"]
        ),
        .init(
            "ignore",
            category: .apps,
            title: "Ignore an App",
            summary: "Hide an app from Melo's main list.",
            keywords: ["hide an app", "remove an app from the list", "stop showing an app"]
        ),
        .init(
            "app-volume",
            category: .apps,
            title: "App Volume",
            summary: "Change one app without changing every other app.",
            keywords: ["change one app's volume", "per app volume", "make just this app louder"]
        ),
        .init(
            "app-mute",
            category: .apps,
            title: "Mute an App",
            summary: "Silence only that app.",
            keywords: ["silence one app", "mute", "turn off the sound for one app"]
        ),
        .init(
            "boost",
            category: .apps,
            title: "Boost",
            summary: "Raise a quiet app above its normal maximum. Start low to avoid distortion.",
            keywords: ["this app is too quiet", "louder than maximum", "amplify", "over 100%"]
        ),
        .init(
            "routing",
            category: .apps,
            title: "Where an App Plays",
            summary: "Send an app to one device or several devices.",
            keywords: ["send an app to headphones", "play this app on the speakers", "split audio", "a different output per app"]
        ),
        .init(
            "balance",
            category: .apps,
            title: "Left and Right Balance",
            summary: "Move one app toward the left or right speaker.",
            keywords: ["left right", "one side is louder", "pan"]
        ),
        .init(
            "meter",
            category: .apps,
            title: "Live Level",
            summary: "Shows when an app is producing sound.",
            keywords: ["what is playing", "sound bars", "activity indicator"]
        )
    ]

    // MARK: - Devices

    private static let devices: [SettingsGuideEntry] = [
        .init(
            "default-device",
            category: .devices,
            title: "Default Output",
            summary: "Choose the speakers or headphones your Mac normally uses.",
            keywords: ["change the output", "switch to headphones", "where sound plays"]
        ),
        .init(
            "priority",
            category: .devices,
            title: "Device Priority",
            summary: "Decide which connected device Melo should prefer.",
            keywords: ["preferred device order", "which device wins", "switch devices automatically"]
        ),
        .init(
            "input-lock",
            category: .devices,
            title: "Keep My Microphone",
            summary: "Stops macOS from changing the selected input when another device connects.",
            keywords: ["microphone keeps changing", "stop switching the input", "my mic changes by itself"],
            destination: .audio
        ),
        .init(
            "preferred-input",
            category: .devices,
            title: "Preferred Microphone",
            summary: "Choose the microphone Melo should return to when it reconnects.",
            keywords: ["mic", "choose my microphone", "which mic melo uses", "usb microphone"],
            destination: .audio
        ),
        .init(
            "hide-device",
            category: .devices,
            title: "Hide a Device",
            summary: "Remove a device from Melo's main list without disconnecting it.",
            keywords: ["remove a device from the list", "too many devices", "tidy up the device list"]
        ),
        .init(
            "device-icon",
            category: .devices,
            title: "Device Icon",
            summary: "Choose a familiar symbol for a speaker, headset, display, or other device.",
            keywords: ["change a device symbol", "the wrong picture", "a picture for my speaker"]
        ),
        .init(
            "device-control",
            category: .devices,
            title: "Device Volume Control",
            summary: "Let Melo choose how to control a device, or change the method when automatic control is wrong.",
            keywords: ["the slider does nothing", "device volume will not change", "control method"]
        ),
        .init(
            "system-sounds",
            category: .devices,
            title: "System Sounds",
            summary: "Choose where alerts and interface sounds play.",
            keywords: ["alert sounds", "notification sounds", "where beeps play"],
            destination: .audio
        ),
        .init(
            "alert-volume",
            category: .devices,
            title: "Alert Volume",
            summary: "Change notifications without changing music or video volume.",
            keywords: ["notifications are too loud", "quieter alerts", "beep volume"],
            destination: .audio
        ),
        .init(
            "monitor-volume",
            category: .devices,
            title: "Monitor Volume",
            summary: "Melo automatically chooses the safest available way to control a display's speakers.",
            keywords: ["display speakers", "monitor speakers", "hdmi volume", "tv volume"]
        ),
        .init(
            "bluetooth",
            category: .devices,
            title: "Connect Bluetooth Audio",
            summary: "Connect a paired headset or speaker from Melo.",
            keywords: ["airpods", "connect headphones", "pair a speaker", "wireless headset"]
        ),
        .init(
            "headphone-pause",
            category: .devices,
            title: "Pause When Headphones Disconnect",
            summary: "Sends a pause command when the current headphones unexpectedly disconnect.",
            keywords: ["pause when i take them off", "unplugging pauses music", "automatic pause"],
            destination: .audio
        )
    ]

    // MARK: - Sound

    private static let sound: [SettingsGuideEntry] = [
        .init(
            "device-autoeq",
            category: .sound,
            title: "Headphone Sound Profile",
            summary: "Apply a correction made for your headphone model.",
            keywords: ["headphone correction", "make my headphones sound right", "harman target", "autoeq"]
        ),
        .init(
            "autoeq-preamp",
            category: .sound,
            title: "Prevent Profile Clipping",
            summary: "Leaves safe headroom when a headphone profile boosts some frequencies.",
            keywords: ["distortion with a profile", "crackling", "headroom", "too loud after a profile"]
        ),
        .init(
            "app-eq",
            category: .sound,
            title: "App Sound Controls",
            summary: "Shape bass, mids, and treble for one app.",
            keywords: ["eq", "equalizer", "bass and treble", "adjust the tone", "more bass"]
        ),
        .init(
            "eq-preset",
            category: .sound,
            title: "Sound Presets",
            summary: "Save and reuse your sound-control settings.",
            keywords: ["save my tone settings", "reuse a curve", "eq presets"]
        ),
        .init(
            "effects",
            category: .sound,
            title: "Audio Effects",
            summary: "Use installed effects for one app or everything Melo controls.",
            details: "This area is optional and intended for people who already use Audio Unit effects.",
            keywords: ["audio unit", "plugin", "add an effect", "reverb"],
            destination: .effects
        ),
        .init(
            "effect-bypass",
            category: .sound,
            title: "Temporarily Turn Off an Effect",
            summary: "Compare the sound without removing the effect.",
            keywords: ["turn an effect off for a moment", "compare with and without", "bypass"],
            destination: .effects
        ),
        .init(
            "effect-order",
            category: .sound,
            title: "Effect Order",
            summary: "Drag effects to choose which one changes the sound first.",
            keywords: ["reorder effects", "chain order", "which effect comes first"],
            destination: .effects
        ),
        .init(
            "effect-window",
            category: .sound,
            title: "Open Effect Controls",
            summary: "Open an effect's own control window when it provides one.",
            keywords: ["open the plugin window", "effect settings", "its own controls"],
            destination: .effects
        )
    ]

    // MARK: - Shortcuts

    private static let shortcuts: [SettingsGuideEntry] = [
        .init(
            "media-keys",
            category: .shortcuts,
            title: "Volume Keys",
            summary: "Use F10, F11, and F12 with Melo's selected output.",
            keywords: ["f11 and f12", "the keys on my keyboard", "volume keys do nothing"],
            destination: .shortcuts
        ),
        .init(
            "hud",
            category: .shortcuts,
            title: "Volume Display",
            summary: "Choose how Melo shows volume changes on screen.",
            keywords: ["hud", "on screen volume", "the volume popup", "volume overlay"],
            destination: .shortcuts
        ),
        .init(
            "key-step",
            category: .shortcuts,
            title: "Volume Key Step",
            summary: "Choose how much each key press changes the volume.",
            keywords: ["the volume jumps too much", "smaller steps", "finer volume control"],
            destination: .shortcuts
        ),
        .init(
            "global-shortcuts",
            category: .shortcuts,
            title: "Keyboard Shortcuts",
            summary: "Assign keys for opening Melo and controlling apps quickly.",
            keywords: ["hotkey", "assign keys", "a shortcut for mute"],
            destination: .shortcuts
        ),
        .init(
            "command-search",
            category: .shortcuts,
            title: "Find an Action",
            summary: "Press Command-K while Melo is open to search common actions, Scenes, and devices.",
            keywords: ["command k", "search for an action", "quick search", "spotlight for melo"]
        ),
        .init(
            "shortcuts-app",
            category: .shortcuts,
            title: "Apple Shortcuts",
            summary: "Use Melo actions inside the Shortcuts app for personal automations.",
            keywords: ["the shortcuts app", "automate with shortcuts", "siri"],
            destination: .everyday
        )
    ]

    // MARK: - Privacy & Data

    private static let privacy: [SettingsGuideEntry] = [
        .init(
            "privacy",
            category: .privacy,
            title: "Process Only When Needed",
            summary: "Leaves untouched apps on their normal audio path and releases unneeded access.",
            keywords: ["does melo touch every app", "cpu use", "leave my apps alone"],
            destination: .audio
        ),
        .init(
            "battery",
            category: .privacy,
            title: "Use Less Processing on Battery",
            summary: "Pauses automatic sound enhancements while unplugged. App volume and routing keep working.",
            keywords: ["save battery", "on battery power", "unplugged"],
            destination: .audio
        ),
        .init(
            "backup",
            category: .privacy,
            title: "Save a Settings Backup",
            summary: "Export Melo settings to a file you can store or move.",
            keywords: ["export my settings", "save settings to a file", "back up melo"],
            destination: .general
        ),
        .init(
            "restore",
            category: .privacy,
            title: "Restore a Settings Backup",
            summary: "Replace current settings with a previously saved Melo backup.",
            keywords: ["import my settings", "load a backup", "bring my settings back"],
            destination: .general
        ),
        .init(
            "reset",
            category: .privacy,
            title: "Reset All Settings",
            summary: "Return Melo to its defaults and clear saved app and device choices.",
            keywords: ["start over", "back to defaults", "clear my settings"],
            destination: .general
        ),
        .init(
            "erase",
            category: .privacy,
            title: "Erase All Melo Data",
            summary: "Remove every Melo setting and reopen as a new installation.",
            details: "macOS privacy permissions are managed separately and are not removed.",
            keywords: ["fresh start", "factory reset", "delete everything", "remove all data"],
            destination: .general
        ),
        .init(
            "problem-report",
            category: .privacy,
            title: "Report a Problem",
            summary: "Create an AI-readable ZIP with logs, crash details, and a private settings summary.",
            details: "No audio is recorded. App names and file contents are excluded by default.",
            keywords: ["diagnostics", "error report", "crash log", "support"],
            destination: .general
        )
    ]
}
