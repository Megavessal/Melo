import AppKit
import Combine
import Foundation
import Sparkle
import UserNotifications
import os

@MainActor
final class SparkleUpdateController: ObservableObject {
    /// What is stopping Sparkle from running, in the order it needs fixing.
    ///
    /// Sparkle will not start without both a secure feed and a public key, and an
    /// updater that silently does nothing is indistinguishable from one that found
    /// no updates. Naming the missing piece is the difference between a feature
    /// that looks broken and one that is visibly not set up yet.
    enum ConfigurationProblem: Equatable {
        case feedMissing
        case feedNotSecure
        case signingKeyMissing

        var summary: String {
            switch self {
            case .feedMissing:
                return "No update feed is set yet."
            case .feedNotSecure:
                return "The update feed must be an https address."
            case .signingKeyMissing:
                return "No update signing key is set yet."
            }
        }

        var guidance: String {
            switch self {
            case .feedMissing, .feedNotSecure:
                return "Add the address of your appcast.xml to SUFeedURL in Config/Info.plist."
            case .signingKeyMissing:
                return "Run scripts/sparkle-setup.sh once to create a signing key, then paste the public half into SUPublicEDKey in Config/Info.plist."
            }
        }
    }

    /// One update Sparkle has told us about, reduced to what a person needs to
    /// decide with. Kept as a value so the UI can render a state that is no
    /// longer live — a finished session's "ready to install" still has to say
    /// *which* version is waiting.
    struct PendingUpdate: Equatable, Codable {
        let version: String
        let build: String
        let notes: String?
        let notesAreHTML: Bool
        let notesURL: URL?
        let downloadBytes: Int64
        let published: Date?
        let isCritical: Bool
        /// `SUAppcastItem.minimumAutoupdateVersion`, carried raw — Sparkle's
        /// skip filter reads the attribute itself, not only the case where the
        /// host fails it. Optional so a record written by an earlier build
        /// still decodes; `nil` means the appcast declared none, which is what
        /// every old record was treated as anyway.
        let minimumAutoupdateVersion: String?
        /// `SUAppcastItem.ignoreSkippedUpgradesBelowVersion`. Sparkle uses it to
        /// let a later release override an earlier major skip; without it Melo
        /// would keep suppressing a version Sparkle has decided to offer again.
        let ignoreSkippedUpgradesBelowVersion: String?

        /// Spelled out rather than left to the memberwise default so the two
        /// skip fields can be omitted. Almost every construction of this type —
        /// every snapshot fixture, every future test — describes an ordinary
        /// release, and `nil` for both is exactly what an ordinary release
        /// means: not a major upgrade, no override.
        init(
            version: String,
            build: String,
            notes: String?,
            notesAreHTML: Bool,
            notesURL: URL?,
            downloadBytes: Int64,
            published: Date?,
            isCritical: Bool,
            minimumAutoupdateVersion: String? = nil,
            ignoreSkippedUpgradesBelowVersion: String? = nil
        ) {
            self.version = version
            self.build = build
            self.notes = notes
            self.notesAreHTML = notesAreHTML
            self.notesURL = notesURL
            self.downloadBytes = downloadBytes
            self.published = published
            self.isCritical = isCritical
            self.minimumAutoupdateVersion = minimumAutoupdateVersion
            self.ignoreSkippedUpgradesBelowVersion = ignoreSkippedUpgradesBelowVersion
        }

        var displayName: String { "Melo \(version)" }

        /// Derived, not stored, and deliberately so: a record restored from
        /// disk has to answer this question too, and `SUAppcastItem.majorUpgrade`
        /// is gone by then. This is Sparkle's own definition —
        /// `SPUAppcastItemStateResolver`: "An update is a major upgrade if the
        /// application's bundle version doesn't meet the
        /// `minimumAutoupdateVersion` requirement" — evaluated with the same
        /// comparator, because Melo supplies no `versionComparatorForUpdater:`
        /// and Sparkle therefore uses the standard one too.
        var isMajorUpgrade: Bool {
            guard let minimumAutoupdateVersion, !minimumAutoupdateVersion.isEmpty else { return false }
            return SparkleUpdateController.versionComparator
                .compareVersion(SparkleUpdateController.hostBuild, toVersion: minimumAutoupdateVersion)
                == .orderedAscending
        }

        /// `build` is Sparkle's `versionString`, which for Melo is
        /// `CFBundleVersion`. Compared numerically so a restored record can be
        /// thrown away once the running app has caught up or passed it.
        var buildNumber: Int { Int(build) ?? 0 }
    }

    /// A failure the user has to be able to act on. `summary` says what went
    /// wrong in their terms, `recovery` says what to do about it, and `detail`
    /// carries the underlying text for a support report. Sparkle's own errors
    /// are written for developers; none of them survive to the UI untranslated.
    struct Failure: Equatable {
        let summary: String
        let recovery: String
        let detail: String?
    }

    /// Every state the updater can be in, as the user experiences it. The old
    /// controller published none of this: the tab showed a version number and a
    /// button, so "checking", "no network", "downloaded and waiting" and
    /// "nothing to do" were all the same picture.
    enum Activity: Equatable {
        case idle
        case checking
        case upToDate
        case available(PendingUpdate)
        // The update travels with each phase. Dropping it at `.downloading` was
        // the moment the user most needed to know what was being installed.
        case downloading(PendingUpdate?)
        case extracting(PendingUpdate?)
        case installing(PendingUpdate?)
        /// Downloaded, verified, and waiting. Reached when automatic installs
        /// are on: Sparkle would otherwise sit on it until the app quits, which
        /// for a menu-bar app can be weeks.
        case readyToInstall(PendingUpdate)
        /// The user refused this version. A state of its own because the
        /// alternative was `.upToDate`, which renders as "nothing newer is
        /// published" — a flat falsehood about a version the user was just
        /// looking at, and one that hid the only way back.
        case skipped(PendingUpdate)
        /// The user asked to be reminded later. A state of its own for the
        /// opposite reason: without it the tab redrew identically after the
        /// click while the badge and banner vanished, so the two surfaces
        /// disagreed about a decision that had just been made.
        case deferred(PendingUpdate)
        case failed(Failure)
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var configurationProblem: ConfigurationProblem?
    @Published private(set) var activity: Activity = .idle
    /// When a check last *succeeded*. Only ever written by a check that got an
    /// answer, so a failed check can never borrow an older check's credibility.
    @Published private(set) var lastCheckDate: Date?
    /// The durable fact: a version that is waiting, independent of any live
    /// Sparkle session. Restored from disk at launch and read by the menu bar
    /// icon, the popup and the Updates tab, so an update found in the
    /// background survives a quit, a relaunch, and a notification the user
    /// never saw.
    @Published private(set) var pendingUpdate: PendingUpdate? {
        didSet { pendingUpdateChanged(from: oldValue) }
    }
    /// The same update as far as the *ambient* surfaces are concerned — the
    /// badge on Melo's menu bar icon and the banner at the top of the popup.
    /// Nil while the user has answered "Later", which is what makes Later
    /// different from Skip: `pendingUpdate` is untouched the whole time and
    /// Settings → Updates still offers the version.
    @Published private(set) var updateReminder: PendingUpdate?
    /// Whether Sparkle has UI on screen for the session now running — i.e.
    /// whether there is anything for "Show Progress…" to reveal.
    ///
    /// `SPUAutomaticUpdateDriver.showingUpdate` returns `NO` unconditionally
    /// and never calls the standard user driver, so when Download-and-Install-
    /// Automatically is on the download happens with no window at all. Melo
    /// still offered a Show Progress button, which called `showPendingUpdate()`
    /// → `checkForUpdates()` → `if (_sessionInProgress) { return; }`
    /// (`SPUUpdater.m`). It activated the app and then did nothing, under copy
    /// promising "the exact figure and a way to stop". Set only from the
    /// standard user driver's own callbacks, which is precisely the condition
    /// that makes the button true.
    @Published private(set) var canRevealUpdateWindow = false

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard isSynchronizing == false else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            // Sparkle can refuse — an app that cannot write to its own location
            // never gets automatic updates. Read the value back so the switch
            // shows what will actually happen rather than what was asked for.
            syncAutomaticSettings()
        }
    }

    @Published var automaticallyDownloadsAndInstalls: Bool {
        didSet {
            guard isSynchronizing == false else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsAndInstalls
            syncAutomaticSettings()
        }
    }

    let updaterController: SPUStandardUpdaterController

    /// How often Sparkle checks when automatic checks are on, in the words the
    /// tab uses. Read from the updater rather than assumed, because the
    /// interval comes from Info.plist and can change without this file.
    var automaticCheckCadence: String {
        let hours = updater.updateCheckInterval / 3600
        switch hours {
        case ..<2: return "about once an hour"
        case ..<20: return "every \(Int(hours.rounded())) hours"
        case ..<40: return "about once a day"
        default: return "about once a week"
        }
    }

    private enum Keys {
        static let pendingUpdate = "updates.pendingUpdate"
        static let remindAfter = "updates.remindAfter"
        /// Sparkle's own skip list, from its `SUConstants.m`. Melo writes and
        /// reads *these* keys rather than keeping a second list beside them:
        /// two lists disagree, and a version dismissed in Melo's UI would come
        /// straight back as Sparkle's own alert on the next scheduled check.
        /// Sparkle's host defaults for a main bundle with no `SUDefaultsDomain`
        /// are `UserDefaults.standard`, which is the same store this reads.
        /// What was skipped, kept so Melo can *say* so. Emphatically not a
        /// second skip list: the decision lives only in Sparkle's three keys
        /// below, and `restoredSkippedUpdate()` re-checks this record against
        /// them on every read and throws it away the moment they disagree. A
        /// list that could contradict Sparkle is the bug this app already
        /// fixed once; a caption that cannot is what was missing.
        static let skippedUpdate = "updates.skippedUpdate"
        static let sparkleSkippedVersion = "SUSkippedVersion"
        static let sparkleSkippedMajorVersion = "SUSkippedMajorVersion"
        static let sparkleSkippedMajorSubrelease = "SUSkippedMajorSubreleaseVersion"

        /// All three, in the order `SPUSkippedUpdate.clearSkippedUpdateForHost:`
        /// clears them. Melo now writes the major pair too, so a list that
        /// clears only some of them leaves a skip nothing can undo.
        static let sparkleSkipKeys = [
            sparkleSkippedVersion, sparkleSkippedMajorVersion, sparkleSkippedMajorSubrelease
        ]
    }

    /// How long "Later" puts the ambient reminder away for. Long enough to stop
    /// being nagged through one working day, short enough that it cannot become
    /// an accidental "never".
    private static let reminderInterval: TimeInterval = 8 * 3600

    private let logger = Logger(subsystem: "io.github.megavessal.Melo", category: "Updates")
    private let bridge = UpdaterBridge()
    private let defaults: UserDefaults
    private var reminderTimer: Timer?
    /// A restored record is a claim about a server we have not spoken to since
    /// the last launch. While this is true, a failure belongs in the log rather
    /// than in the user's face: nothing they did started this check.
    private var isVerifyingRestoredUpdate = false
    private var cancellables: Set<AnyCancellable> = []
    private var isSynchronizing = true
    /// Sparkle hands this over when an automatically downloaded update is
    /// parked until the next quit. Holding it is what turns "it will install
    /// eventually" into a button the user can press now.
    private var immediateInstallHandler: (() -> Void)?
    /// Whether the check now in flight was asked for. Sparkle does not tell the
    /// updater delegate this on the "found an update" callback, and the two
    /// cases need opposite treatment: one already has the user's attention, the
    /// other has to go and get it.
    private var isUserInitiatedCheck = false

    private var updater: SPUUpdater { updaterController.updater }

    private static let updateNotificationIdentifier = "melo.update.available"

    // MARK: - The update notification's category

    /// A notification with no category has no buttons and no meaningful tap.
    /// Melo shipped exactly that: the body read "Open Melo from the menu bar to
    /// see what's new and install it", and tapping it activated an app with no
    /// Dock tile and no window, so the notification both told the user to do
    /// the work themselves *and* did nothing when they tried. HIG,
    /// *Notifications*: "Avoid sending a notification that tells people to
    /// perform specific tasks within your app. If it makes sense to offer
    /// simple tasks that people can perform without opening your app, you can
    /// provide notification actions. Otherwise, avoid telling people what to do
    /// because it's hard for people to remember such instructions after they
    /// dismiss the notification."
    static let updateNotificationCategoryIdentifier = "melo.update.available.category"
    static let remindLaterActionIdentifier = "melo.update.remindLater"

    /// Exactly one custom action, and it is the deferral.
    ///
    /// HIG allows up to four, but it also says "Avoid providing an action that
    /// merely opens your app. When people tap a notification or its preview,
    /// they expect your app to display related content, so presenting an action
    /// button that does the same thing clutters the detail view and can be
    /// confusing." That rules out the obvious candidate: with
    /// `SUAutomaticallyUpdate` false — Melo's settled default — nothing is on
    /// disk when this notification is posted, so `installPendingUpdate()` falls
    /// through to `showPendingUpdate()`. An "Install Now" button would be
    /// byte-for-byte the same call as the tap, wearing a label that promises
    /// more. "Remind Me Later" is the one answer that genuinely completes
    /// without opening anything: it writes a date and goes quiet.
    ///
    /// Skip is deliberately not here. It is the permanent answer, it lives in
    /// Settings → Updates by the same decision that keeps it out of the popup
    /// banner, and a destructive one-way choice does not belong on a banner
    /// that disappears in a few seconds.
    ///
    /// Worded as the banner, the status-item menu and Settings → Updates word
    /// it. One action must not have four names.
    static var updateNotificationCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: updateNotificationCategoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: remindLaterActionIdentifier,
                    title: "Remind Me Later",
                    options: []
                )
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Registration has to happen before anything is delivered, and it needs no
    /// permission of any kind — unlike posting, this neither prompts nor waits.
    /// It runs from `init`, which is the earliest point at which the category
    /// exists, so a notification that survives in Notification Center from an
    /// earlier launch still resolves its buttons after a relaunch.
    private static func registerNotificationCategories() {
        UNUserNotificationCenter.current()
            .setNotificationCategories([updateNotificationCategory])
    }

    /// What the notification's buttons and its tap do. Called by the
    /// `UNUserNotificationCenterDelegate`, which by macOS's design must be the
    /// app delegate; this keeps the *decisions* here, beside the state they act
    /// on, rather than in the composition root.
    func handleNotificationResponse(actionIdentifier: String, categoryIdentifier: String) {
        // Another category's response is not ours to interpret. Melo registers
        // one today; a second one added later must not silently inherit these.
        guard categoryIdentifier == Self.updateNotificationCategoryIdentifier else { return }
        switch actionIdentifier {
        case Self.remindLaterActionIdentifier:
            // The notification outlives the thing it is about: between posting
            // and pressing, the update can be installed, refused, or pulled
            // from the feed, and `remindLater()` guards on `pendingUpdate` and
            // returns. There is genuinely nothing to defer then — but the
            // banner is still on screen, so take it away rather than let the
            // press appear to do nothing.
            if pendingUpdate == nil {
                logger.notice("Remind Me Later pressed on a notification whose update is no longer waiting")
                clearUpdateNotification()
                return
            }
            remindLater()
        case UNNotificationDefaultActionIdentifier:
            // "People expect your app to display related content." Sparkle's
            // own window is where the version, its notes, its size and the
            // Install button are, and `showPendingUpdate` is the same entry
            // point the popup banner and the status-item menu use.
            showPendingUpdate()
        default:
            // Includes `UNNotificationDismissActionIdentifier`. Dismissing is
            // not deferring: it must not write a reminder date, because the
            // user answered nothing.
            break
        }
    }

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let problem: ConfigurationProblem?
        if feed.isEmpty {
            problem = .feedMissing
        } else if URL(string: feed)?.scheme?.lowercased() != "https" {
            problem = .feedNotSecure
        } else if publicKey.isEmpty {
            problem = .signingKeyMissing
        } else {
            problem = nil
        }
        let configured = problem == nil

        // The delegates have to exist before the controller does, and they need
        // to talk back to this object, so a small bridge holds the weak link
        // rather than forcing this type to be an NSObject with a late-bound
        // updater.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: bridge,
            userDriverDelegate: bridge
        )
        isConfigured = configured
        configurationProblem = problem
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        automaticallyDownloadsAndInstalls = updaterController.updater.automaticallyDownloadsUpdates
        bridge.owner = self

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.canCheckForUpdates = value
                }
            }
            .store(in: &cancellables)

        if configured {
            updaterController.startUpdater()
            lastCheckDate = updater.lastUpdateCheckDate
        }
        isSynchronizing = false

        // Before anything can be posted, and before the delegate that handles a
        // response is even set: a category registered late leaves an already
        // delivered notification with no buttons.
        Self.registerNotificationCategories()

        restorePendingUpdate()
    }

    /// Brings back an update found in an earlier run. Without this the whole
    /// record of a background discovery lived in memory: quit Melo and the
    /// waiting version was gone until the next scheduled check, a day later.
    private func restorePendingUpdate() {
        // Before anything else, and deliberately not inside the guard below:
        // Skip deletes the pending record, so on the next launch this is the
        // *only* thing that knows a decision was ever made. Without it the tab
        // opened at `.idle` and the skip became invisible to the one screen
        // that is entirely about updates.
        if let skipped = restoredSkippedUpdate() {
            activity = .skipped(skipped)
            logger.notice("Restored skipped Melo \(skipped.version, privacy: .public) from a previous launch")
        }

        guard let data = defaults.data(forKey: Keys.pendingUpdate),
              let restored = try? JSONDecoder().decode(PendingUpdate.self, from: data) else { return }

        // The install may have happened since. A record for a build we are now
        // running (or have passed) is a stale prompt to install the past.
        let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        guard restored.buildNumber > currentBuild else {
            defaults.removeObject(forKey: Keys.pendingUpdate)
            return
        }
        // A skipped version's record is dead weight, not something to keep for
        // later: leaving the blob on disk meant it was re-read and re-discarded
        // on every launch forever.
        guard !isSkipped(restored) else {
            defaults.removeObject(forKey: Keys.pendingUpdate)
            defaults.removeObject(forKey: Keys.remindAfter)
            return
        }
        pendingUpdate = restored
        activity = .available(restored)
        logger.notice("Restored pending update Melo \(restored.version, privacy: .public) from a previous launch")
        verifyRestoredUpdate()
    }

    /// A restored record is an assertion about yesterday's feed. A release can
    /// be pulled — for a bug found after publishing, which is exactly when it
    /// matters — and without this Melo would keep advertising and offering it
    /// until the next scheduled check, up to a day later.
    ///
    /// `checkForUpdateInformation` is Sparkle's silent check: it re-runs the
    /// feed and reports through the same delegate callbacks without opening any
    /// window, so a pulled release clears `pendingUpdate` on its own and a
    /// still-published one simply refreshes the record.
    private func verifyRestoredUpdate() {
        guard isConfigured else { return }
        // Deferred off init: this runs at the tail of `init`, and the updater
        // has only just been started. `canCheckForUpdates` is read from the
        // updater rather than the published mirror, which is still at its
        // initial `false` until the first KVO delivery lands.
        Task { @MainActor [weak self] in
            guard let self, self.updater.canCheckForUpdates else { return }
            self.isVerifyingRestoredUpdate = true
            self.updater.checkForUpdateInformation()
        }
    }

    // MARK: - Actions

    /// A user-initiated check. Sparkle's own windows belong to an app that
    /// macOS considers an accessory, so nothing brings them forward on their
    /// own — without this the alert opens behind whatever the user is doing and
    /// the check looks like it did nothing.
    func checkNow() {
        guard isConfigured, canCheckForUpdates else { return }
        isUserInitiatedCheck = true
        activity = .checking
        activateForUpdateUI()
        updater.checkForUpdates()
    }

    /// Brings whatever Sparkle is doing — an update alert, a check, a download
    /// — into focus. Sparkle treats a second `checkForUpdates` during a live
    /// session as "show me that again" rather than starting a new check, and
    /// its own window is where Cancel lives.
    func showPendingUpdate() {
        guard isConfigured else { return }
        // A session Sparkle is running without UI cannot be brought forward:
        // `checkForUpdates()` returns immediately while `sessionInProgress`,
        // and there is no window for `activateForUpdateUI()` to raise. Saying
        // so in the log beats activating the app and appearing to hang.
        if updater.sessionInProgress, !canRevealUpdateWindow {
            logger.notice("Nothing to show: Sparkle is running a session with no window of its own")
            return
        }
        isUserInitiatedCheck = true
        clearUpdateNotification()
        activateForUpdateUI()
        updater.checkForUpdates()
    }

    /// Opens the notes for the version being offered. The icon's menu, the
    /// popup banner and the tab all need this, and none of them should have to
    /// know where the notes live.
    func openPendingReleaseNotes() {
        guard let url = pendingUpdate?.notesURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Drops the waiting update for good, in the same place Sparkle keeps its
    /// own answer to the same question. Writing only Melo's record left the
    /// version unskipped as far as Sparkle was concerned, so the next scheduled
    /// check with Melo frontmost put up Sparkle's alert for the version the
    /// user had just dismissed.
    func skipPendingUpdate() {
        guard let skipped = pendingUpdate else { return }
        recordSkip(skipped)
        defaults.removeObject(forKey: Keys.remindAfter)
        pendingUpdate = nil
        clearUpdateNotification()
        // Unconditional, and never `.upToDate`. The old guard matched only
        // `.available`, so from any other state the card was left advertising
        // the version that had just been refused; and `.upToDate` would have
        // claimed nothing newer is published, which is not what happened.
        activity = .skipped(skipped)
        logger.notice("Skipped Melo \(skipped.version, privacy: .public)")
    }

    /// Puts the badge and the popup banner away without answering the question.
    /// Before this the only thing that cleared the reminder was Skip, so a user
    /// who was simply busy had to choose between being reminded forever and
    /// permanently refusing a version — and Skip was the easier click.
    func remindLater() {
        guard let deferred = pendingUpdate else { return }
        defaults.set(Date().addingTimeInterval(Self.reminderInterval), forKey: Keys.remindAfter)
        clearUpdateNotification()
        // The tab has to move too. Without this the badge and the banner went
        // quiet while the card redrew byte-identically, so the two surfaces
        // disagreed about the decision the user had just made.
        activity = .deferred(deferred)
        refreshReminder()
    }

    /// What the primary button on an available update should do. If the bits
    /// are already downloaded and parked this finishes with no network at all;
    /// otherwise Sparkle re-runs the feed and takes it from there, because an
    /// update that was only ever *announced* has nothing on disk to install.
    func installPendingUpdate() {
        if immediateInstallHandler != nil {
            installDownloadedUpdateNow()
            return
        }
        showPendingUpdate()
    }

    /// Installs an update that was downloaded automatically instead of waiting
    /// for the next quit.
    func installDownloadedUpdateNow() {
        // Both conditions. Guarding on the handler alone meant that once the
        // record was gone — the version refused, or the feed no longer offering
        // it — this button still installed it.
        guard pendingUpdate != nil, let handler = immediateInstallHandler else { return }
        immediateInstallHandler = nil
        activity = .installing(pendingUpdate)
        handler()
    }

    /// Puts the card back to neutral after a failure the user has read.
    ///
    /// Deliberately never `.upToDate`: the check that just failed proved
    /// nothing about being current, and "Melo is up to date" carrying an older
    /// check's timestamp is a false all-clear the user acts on by not looking
    /// again. `.idle` states the version and when the last check that actually
    /// answered was.
    func dismissFailure() {
        guard case .failed = activity else { return }
        activity = restingActivity
    }

    // MARK: - Bridge callbacks

    fileprivate func foundUpdate(_ item: SUAppcastItem) {
        let pending = Self.pending(from: item)
        lastCheckDate = updater.lastUpdateCheckDate ?? Date()
        // A version the user skipped stays skipped through background checks,
        // but asking to check is asking to be shown what is out there.
        if isUserInitiatedCheck {
            // All three keys, matching `SPUSkippedUpdate.clearSkippedUpdateForHost:`.
            // Clearing a subset left `SUSkippedMajorVersion` standing, and that
            // one key is enough for Sparkle to keep filtering the whole major
            // line out of a check the user explicitly asked for.
            clearSkip()
        } else if isSkipped(pending) {
            return
        }
        let isNew = pendingUpdate?.build != pending.build
        pendingUpdate = pending
        activity = .available(pending)
        // A check the user asked for already has their attention. A scheduled
        // one is the case a menu-bar app has to work at — and the notification
        // is the weakest half of that: it needs permission, it vanishes in
        // seconds, and it is posted once. The badge on Melo's own menu bar icon
        // and the banner in its popup are what persist, and neither needs a
        // permission or a second icon in the menu bar to do it.
        if !isUserInitiatedCheck, isNew {
            postUpdateNotification(for: pending)
        }
    }

    fileprivate func foundNoUpdate(_ error: Error?) {
        lastCheckDate = updater.lastUpdateCheckDate ?? Date()
        // The server is the authority: if it no longer offers anything newer,
        // a record left over from a previous check is stale.
        pendingUpdate = nil
        // "Your macOS is too old for the newest Melo" arrives on the same path
        // as "you are current". Reporting it as up to date would be a lie the
        // user then acts on by never looking again.
        if let reason = (error as NSError?)?.userInfo[SPUNoUpdateFoundReasonKey] as? Int,
           let failure = Self.failure(forNoUpdateReason: reason) {
            activity = .failed(failure)
            return
        }
        // "Nothing newer" is Sparkle answering a question it filtered first.
        // `SUAppcastDriver.m` builds the *not-found* appcast with the skip list
        // applied too — "This excludes newer backgrounded updates that fail
        // because they are skipped" — so a skipped version leaves
        // `notFoundPrimaryItem` nil and arrives here as
        // `SPUNoUpdateFoundReasonOnLatestVersion`, indistinguishable from
        // genuinely being current. It is not the same fact, and drawing a green
        // check under "Nothing newer is published for this Mac" about a version
        // Melo is itself suppressing is the exact falsehood `.skipped` was
        // added to prevent.
        if let skipped = restoredSkippedUpdate() {
            activity = .skipped(skipped)
            return
        }
        activity = .upToDate
    }

    fileprivate func downloadStarted(_ item: SUAppcastItem) {
        let pending = Self.pending(from: item)
        pendingUpdate = pending
        activity = .downloading(pending)
    }

    fileprivate func extractionStarted(_ item: SUAppcastItem) {
        activity = .extracting(Self.pending(from: item))
    }

    fileprivate func installationStarted(_ item: SUAppcastItem) {
        immediateInstallHandler = nil
        activity = .installing(Self.pending(from: item))
    }

    fileprivate func parkedUntilQuit(_ item: SUAppcastItem, install: @escaping () -> Void) {
        immediateInstallHandler = install
        let pending = Self.pending(from: item)
        pendingUpdate = pending
        activity = .readyToInstall(pending)
    }

    /// The user's own decision is the authority on whether anything is still
    /// waiting. Skipping or installing clears the record; dismissing leaves it,
    /// because "not now" is not "never".
    fileprivate func userMadeChoice(_ choice: SPUUserUpdateChoice) {
        switch choice {
        case .skip, .install:
            pendingUpdate = nil
            clearUpdateNotification()
        case .dismiss:
            break
        @unknown default:
            break
        }
    }

    fileprivate func aborted(with error: Error) {
        let nsError = error as NSError
        // A cancelled install and "no update found" both arrive here; neither is
        // something to alarm the user with.
        if nsError.domain == SUSparkleErrorDomain, nsError.code == SparkleError.noUpdate {
            // The genuine "you are current" answer, which arrives here rather
            // than at `updaterDidNotFindUpdate` in some flows.
            foundNoUpdate(nsError)
            return
        }
        if nsError.domain == SUSparkleErrorDomain, nsError.code == SparkleError.installationCanceled {
            // The user backed out. Nothing failed, and nothing was proved about
            // being current, so fall back to whatever is still waiting.
            activity = restingActivity
            return
        }
        // The silent re-check of a restored record is Melo's idea, not the
        // user's. Turning its failure into a failure card would mean opening
        // Settings offline and being shown an error for a check nobody asked
        // for, in place of the update that is genuinely still waiting.
        if isVerifyingRestoredUpdate {
            logger.notice("Could not re-verify the restored update: \(nsError.domain) \(nsError.code). Keeping the record.")
            isVerifyingRestoredUpdate = false
            activity = pendingUpdate.map(Activity.available) ?? activity
            return
        }
        logger.error("Update session aborted: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        activity = .failed(Self.failure(for: nsError))
        isUserInitiatedCheck = false
    }

    fileprivate func userSawUpdate() {
        clearUpdateNotification()
    }

    /// Sparkle's standard user driver is about to put something on screen, so
    /// from here until the session ends there is a window to raise.
    fileprivate func updateWindowBecameAvailable() {
        canRevealUpdateWindow = true
    }

    fileprivate func sessionFinished() {
        isUserInitiatedCheck = false
        isVerifyingRestoredUpdate = false
        canRevealUpdateWindow = false
        // Only a check that never resolved needs rescuing here. Anything that
        // produced a real outcome — available, failed, parked until quit — must
        // survive the session ending, or the tab blanks the moment Sparkle's
        // own window closes. A check that ended without an answer is not
        // evidence of being current, so it goes back to neutral, not to
        // "up to date".
        if case .checking = activity {
            activity = restingActivity
        }
    }

    /// Sparkle's status and alert windows belong to an accessory app, so they
    /// open unfocused and can land behind every other window. Activating is
    /// enough to raise them; deliberately *not* switching to `.regular`,
    /// because Melo's Dock icon is a setting the user owns and flipping the
    /// activation policy here would silently contradict it.
    fileprivate func activateForUpdateUI() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - The waiting update

    /// One place where the record, the surfaces that announce it, and disk
    /// agree. Every path that finds, clears, or restores an update goes through
    /// the property this observes, so none of them can update one and forget
    /// another.
    private func pendingUpdateChanged(from oldValue: PendingUpdate?) {
        guard pendingUpdate != oldValue else { return }

        if let pendingUpdate {
            if let data = try? JSONEncoder().encode(pendingUpdate) {
                defaults.set(data, forKey: Keys.pendingUpdate)
            }
            // A deferral answers one version, not every version after it.
            // Deliberately not fired when `oldValue` is nil: that is the launch
            // restore, and clearing there would make "Later" last exactly as
            // long as the app stayed running.
            if let oldValue, pendingUpdate.build != oldValue.build {
                defaults.removeObject(forKey: Keys.remindAfter)
            }
        } else {
            defaults.removeObject(forKey: Keys.pendingUpdate)
            defaults.removeObject(forKey: Keys.remindAfter)
        }
        refreshReminder()
    }

    /// Recomputes what the ambient surfaces show. Called on every change to the
    /// pending update and when a deferral runs out, so the badge and the banner
    /// are a pure function of "something is waiting and the user has not just
    /// asked for quiet".
    private func refreshReminder() {
        reminderTimer?.invalidate()
        reminderTimer = nil

        guard let pendingUpdate else {
            updateReminder = nil
            return
        }

        if let deferredUntil = defaults.object(forKey: Keys.remindAfter) as? Date, deferredUntil > Date() {
            updateReminder = nil
            // The deferral has to end by itself. Melo is a menu-bar app that
            // runs for weeks between launches, so without a timer "Later" would
            // silently be "never" for exactly the people it is meant to help.
            let timer = Timer(fire: deferredUntil, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshReminder() }
            }
            RunLoop.main.add(timer, forMode: .common)
            reminderTimer = timer
            return
        }

        defaults.removeObject(forKey: Keys.remindAfter)
        updateReminder = pendingUpdate
    }

    /// Sparkle's own version comparator, not `==`. Sparkle never compares
    /// version strings for equality; using equality where it uses ordering is
    /// how the two disagree.
    /// `nonisolated`: `PendingUpdate` is a value type with nonisolated
    /// conformances, and it has to be able to answer `isMajorUpgrade` for
    /// itself. Both of these are pure reads of process-wide constants.
    nonisolated private static var versionComparator: SUStandardVersionComparator {
        SUStandardVersionComparator.default
    }

    /// The build Melo is running, in the same form Sparkle's `SUHost.version`
    /// supplies to `filterSupportedAppcast` — `CFBundleVersion`.
    nonisolated private static var hostBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    nonisolated private static var hostBuildNumber: Int { Int(hostBuild) ?? 0 }

    /// Sparkle only consults its skip list inside a live session, so a restored
    /// record has to answer the same question from the same store — otherwise a
    /// skipped version comes back as a badge on the next launch.
    ///
    /// This is a transcription of `SUAppcastDriver`'s
    /// `+item:containsSkippedUpdate:hostPassesSkippedMajorVersion:versionComparator:`
    /// (Sparkle 2.9.5), not an approximation of it. It previously compared with
    /// `==`, which is *narrower* than Sparkle in two ways: Sparkle suppresses
    /// anything at or below the skipped minor version, and it suppresses a
    /// whole major line from `SUSkippedMajorVersion` — a key this never even
    /// read. Two answers to "is this skipped?" that disagree is the same defect
    /// as two skip lists, which is what the key choice above exists to avoid.
    private func isSkipped(_ update: PendingUpdate) -> Bool {
        let comparator = Self.versionComparator

        // The major branch. Sparkle: "If skipped major version is >= than the
        // item's minimumAutoupdateVersion, we can skip the item. But if there
        // is an ignoreSkippedUpgradesBelowVersion, we can only skip the item if
        // the last skipped subrelease version is >= than that version provided
        // by the item."
        if let skippedMajor = defaults.string(forKey: Keys.sparkleSkippedMajorVersion),
           !skippedMajor.isEmpty,
           let minimumAutoupdate = update.minimumAutoupdateVersion, !minimumAutoupdate.isEmpty {
            // `SPUAppcastItemStateResolver.isMinimumAutoupdateVersionOK`: the
            // host has caught up with the skipped major line, so the skip no
            // longer applies to anything.
            let hostPassesSkippedMajor =
                comparator.compareVersion(Self.hostBuild, toVersion: skippedMajor) != .orderedAscending
            let skippedMajorCoversItem =
                comparator.compareVersion(skippedMajor, toVersion: minimumAutoupdate) != .orderedAscending
            let subreleaseClearsOverride: Bool
            if let ignoreBelow = update.ignoreSkippedUpgradesBelowVersion {
                subreleaseClearsOverride = defaults.string(forKey: Keys.sparkleSkippedMajorSubrelease)
                    .map { comparator.compareVersion($0, toVersion: ignoreBelow) != .orderedAscending }
                    ?? false
            } else {
                subreleaseClearsOverride = true
            }
            if !hostPassesSkippedMajor, skippedMajorCoversItem, subreleaseClearsOverride {
                return true
            }
        }

        // The minor branch. Sparkle: "Item is on a less or equal version than a
        // minor version we've skipped, so we skip this item."
        if let skippedMinor = defaults.string(forKey: Keys.sparkleSkippedVersion),
           !skippedMinor.isEmpty,
           comparator.compareVersion(skippedMinor, toVersion: update.build) != .orderedAscending {
            return true
        }

        return false
    }

    /// A transcription of `SPUSkippedUpdate.skipUpdate:host:`.
    ///
    /// This used to write the minor key unconditionally. For a major upgrade
    /// Sparkle writes the *major pair* instead, and the difference is not
    /// cosmetic: skipping Melo 3.0 in Sparkle's own alert means "stop offering
    /// me the 3.x line", while skipping it in Melo's Settings meant "stop
    /// offering me exactly build 500" — so 3.0.1 came straight back with a
    /// badge. Two buttons in one app, both labelled Skip This Version, with
    /// different durable meanings depending on which window the user happened
    /// to be looking at.
    private func recordSkip(_ update: PendingUpdate) {
        if update.isMajorUpgrade, let majorVersion = update.minimumAutoupdateVersion {
            defaults.set(majorVersion, forKey: Keys.sparkleSkippedMajorVersion)
            defaults.set(update.build, forKey: Keys.sparkleSkippedMajorSubrelease)
        } else {
            defaults.set(update.build, forKey: Keys.sparkleSkippedVersion)
        }
        // And what it *was*, so the decision can still be described tomorrow.
        if let data = try? JSONEncoder().encode(update) {
            defaults.set(data, forKey: Keys.skippedUpdate)
        }
    }

    /// The skip, as something Melo can put on screen.
    ///
    /// A skip used to be durable in `UserDefaults` and nowhere else. `activity`
    /// went to `.skipped` in memory, `pendingUpdate` went to nil — which
    /// deletes the disk record — and then the first background check found
    /// nothing, because Sparkle filters the skipped item out of its
    /// *not-found* appcast too (`SUAppcastDriver.m`: "This excludes newer
    /// backgrounded updates that fail because they are skipped"), reported
    /// `SPUNoUpdateFoundReasonOnLatestVersion`, and the tab drew a green check
    /// under "Nothing newer is published for this Mac" — about a version Melo
    /// itself was suppressing. A relaunch got there sooner still, at `.idle`.
    ///
    /// Every branch is a discard, and each is the record failing to be true any
    /// more rather than a policy of its own:
    /// - the running build has caught up, so there is nothing to have skipped;
    /// - Sparkle's keys no longer skip it — a user-initiated check clears them
    ///   (`SPUUIBasedUpdateDriver._clearSkippedUpdatesIfUserInitiated`), which
    ///   is exactly what "Check for Updates brings it back" means.
    private func restoredSkippedUpdate() -> PendingUpdate? {
        guard let data = defaults.data(forKey: Keys.skippedUpdate),
              let record = try? JSONDecoder().decode(PendingUpdate.self, from: data) else { return nil }
        guard record.buildNumber > Self.hostBuildNumber, isSkipped(record) else {
            defaults.removeObject(forKey: Keys.skippedUpdate)
            return nil
        }
        return record
    }

    /// Sparkle's own three keys plus the caption that describes them, cleared
    /// together. Clearing the keys and leaving the caption would leave the tab
    /// naming a version nothing is suppressing.
    private func clearSkip() {
        Keys.sparkleSkipKeys.forEach { defaults.removeObject(forKey: $0) }
        defaults.removeObject(forKey: Keys.skippedUpdate)
    }

    /// What the card shows when nothing is in flight: the update that is
    /// waiting, else the one the user refused, else neutral.
    ///
    /// Never `.upToDate`. Four call sites used to fall back to `.idle` here,
    /// which is not a lie but is silent about a decision the user made and can
    /// still reverse — and `.idle`'s own copy ("Melo checks about once a day
    /// and will tell you when there's a new version") is false while a version
    /// is being suppressed.
    private var restingActivity: Activity {
        if let pendingUpdate { return .available(pendingUpdate) }
        if let skipped = restoredSkippedUpdate() { return .skipped(skipped) }
        return .idle
    }

    // MARK: - Notifications

    /// Posts only once there is an answer about permission.
    ///
    /// The previous version asked and then immediately added the request. On a
    /// Mac that had never been asked, the prompt and the post raced: the system
    /// resolves an `add` against the authorization state *at the time of the
    /// call*, so the one notification that announces a new version was the one
    /// most likely to be dropped. Posting from inside the completion means the
    /// answer exists before anything is sent.
    private func postUpdateNotification(for update: PendingUpdate) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "\(update.displayName) is available"
        // States what is true, and never what to go and do. The instruction the
        // body used to carry ("Open Melo from the menu bar to…") was the exact
        // thing HIG names, and it was also the only thing the notification
        // offered, because tapping it did nothing. The buttons carry the verbs
        // now; see `updateNotificationCategory`.
        content.body = Self.notificationBody(for: update)
        content.categoryIdentifier = Self.updateNotificationCategoryIdentifier
        let request = UNNotificationRequest(
            identifier: Self.updateNotificationIdentifier,
            content: content,
            trigger: nil
        )

        center.getNotificationSettings { [logger] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if let error {
                        logger.error("Could not post the update notification: \(error.localizedDescription)")
                    }
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if let error {
                        logger.error("Notification authorization failed: \(error.localizedDescription)")
                    }
                    guard granted else { return }
                    center.add(request) { error in
                        if let error {
                            logger.error("Could not post the update notification: \(error.localizedDescription)")
                        }
                    }
                }
            case .denied:
                // Nothing to do and nothing to nag about. The badge on Melo's
                // menu bar icon is the channel that does not need permission,
                // and it is already showing.
                logger.notice("Notifications are declined; the update is announced by the menu bar badge instead")
            @unknown default:
                break
            }
        }
    }

    /// Facts, in the order they change a decision: whether it is urgent, how
    /// big it is, and what installing costs. HIG asks for "complete sentences,
    /// sentence case, and proper punctuation" and warns against truncating —
    /// the system does that itself — so this stays to three short sentences at
    /// most. The last one is worded exactly as `PendingUpdateBanner.detail`
    /// words it, so the notification and the banner do not describe the same
    /// install two different ways.
    private static func notificationBody(for update: PendingUpdate) -> String {
        var sentences: [String] = []
        if update.isCritical {
            sentences.append("This is an important update.")
        }
        // Says a download happens, because it does — the version is named in
        // the title but nothing of it is on this Mac yet, so finishing needs
        // the internet. `UpdatesTab` makes the same point for the same reason.
        if update.downloadBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: update.downloadBytes, countStyle: .file)
            sentences.append("Installing downloads \(size) over the internet.")
        } else {
            sentences.append("Installing downloads it over the internet.")
        }
        sentences.append("Melo quits and reopens itself to finish.")
        return sentences.joined(separator: " ")
    }

    private func clearUpdateNotification() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.updateNotificationIdentifier])
    }

    // MARK: - Translation

    private func syncAutomaticSettings() {
        isSynchronizing = true
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsAndInstalls = updater.automaticallyDownloadsUpdates
        isSynchronizing = false
    }

    private static func pending(from item: SUAppcastItem) -> PendingUpdate {
        let format = item.itemDescriptionFormat?.lowercased()
        return PendingUpdate(
            version: item.displayVersionString,
            build: item.versionString,
            notes: item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
            notesAreHTML: format == nil || format == "html",
            notesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL,
            downloadBytes: Int64(item.contentLength),
            published: item.date,
            isCritical: item.isCriticalUpdate,
            minimumAutoupdateVersion: item.minimumAutoupdateVersion,
            ignoreSkippedUpgradesBelowVersion: item.ignoreSkippedUpgradesBelowVersion
        )
    }

    /// Sparkle's error codes, spelled out rather than taken from its imported
    /// Swift enums. The names those enums get depend on how the Objective-C
    /// prefix is stripped, and a mis-spelled case here would be a compile error
    /// while a mis-matched *value* would silently mistranslate a real failure.
    /// Values are from Sparkle's `SUErrors.h`.
    private enum SparkleError {
        static let noUpdate = 1001
        static let appcastParse = 1000
        static let appcast = 1002
        static let runningFromDiskImage = 1003
        static let resumeAppcast = 1004
        static let runningTranslocated = 1005
        static let download = 2001
        static let unarchiving = 3000
        static let signature = 3001
        static let validation = 3002
        static let insecureFeedURL = 3
        static let invalidFeedURL = 4
        static let missingUpdate = 4002
        static let missingInstallerTool = 4003
        static let relaunch = 4004
        static let installation = 4005
        static let installationCanceled = 4007
        static let notValidUpdate = 4009
        static let installationWriteNoPermission = 4012
    }

    /// From `SPUNoUpdateFoundReason` in `SUErrors.h`, declared in that order
    /// starting at zero.
    private enum NoUpdateReason {
        static let systemIsTooOld = 3
        static let hardwareDoesNotSupportARM64 = 5
    }

    /// Sparkle reports "no update" for reasons that are not good news. Only the
    /// ones that genuinely mean "you are current" return nil.
    private static func failure(forNoUpdateReason reason: Int) -> Failure? {
        switch reason {
        case NoUpdateReason.systemIsTooOld:
            return Failure(
                summary: "A newer Melo exists, but it needs a newer macOS.",
                recovery: "Update macOS in System Settings → General → Software Update, then check again.",
                detail: nil
            )
        case NoUpdateReason.hardwareDoesNotSupportARM64:
            return Failure(
                summary: "The newest Melo needs a Mac with Apple silicon.",
                recovery: "This Mac stays on the version you have. It keeps working.",
                detail: nil
            )
        default:
            return nil
        }
    }

    private static func failure(for error: NSError) -> Failure {
        let detail = error.localizedDescription

        if error.domain == NSURLErrorDomain {
            return Failure(
                summary: "Melo couldn’t reach the update server.",
                recovery: "Check your internet connection and try again. Nothing on this Mac was changed.",
                detail: detail
            )
        }

        guard error.domain == SUSparkleErrorDomain else {
            return Failure(
                summary: "The update couldn’t be completed.",
                recovery: "Try again in a moment. The Melo you are running was not changed.",
                detail: detail
            )
        }

        switch error.code {
        case SparkleError.download:
            return Failure(
                summary: "The update download didn’t finish.",
                recovery: "Check your internet connection and try again. Nothing on this Mac was changed.",
                detail: detail
            )
        case SparkleError.appcast, SparkleError.appcastParse, SparkleError.resumeAppcast:
            return Failure(
                summary: "Melo couldn’t read the update list.",
                recovery: "This is a problem at the other end. Try again later — your copy of Melo is fine.",
                detail: detail
            )
        case SparkleError.signature, SparkleError.validation, SparkleError.notValidUpdate:
            return Failure(
                summary: "The download didn’t match its signature, so Melo threw it away.",
                recovery: "Your installed Melo is untouched. This can mean a damaged download or a feed that isn’t genuine; try again, and if it keeps happening, download Melo again from its website.",
                detail: detail
            )
        case SparkleError.unarchiving:
            return Failure(
                summary: "The downloaded update was damaged.",
                recovery: "Melo discarded it and kept the version you are running. Try again.",
                detail: detail
            )
        case SparkleError.runningFromDiskImage:
            return Failure(
                summary: "Melo can’t update itself from a disk image.",
                recovery: "Drag Melo into your Applications folder, open it from there, then check again.",
                detail: detail
            )
        case SparkleError.runningTranslocated:
            return Failure(
                summary: "macOS is running Melo from a temporary copy, which can’t be updated.",
                recovery: "Move Melo to your Applications folder — in Finder, drag it out and back in — then reopen it.",
                detail: detail
            )
        case SparkleError.installationWriteNoPermission:
            return Failure(
                summary: "Melo isn’t allowed to replace itself where it is installed.",
                recovery: "Move Melo to your Applications folder and open it from there, then check again.",
                detail: detail
            )
        case SparkleError.insecureFeedURL, SparkleError.invalidFeedURL:
            return Failure(
                summary: "The update feed address isn’t usable.",
                recovery: "This build is misconfigured; updates can’t run until it is fixed.",
                detail: detail
            )
        case SparkleError.relaunch, SparkleError.installation, SparkleError.missingUpdate,
             SparkleError.missingInstallerTool:
            return Failure(
                summary: "The update was downloaded but couldn’t be installed.",
                recovery: "Melo kept running the version you have. Try again, or download Melo again from its website.",
                detail: detail
            )
        default:
            return Failure(
                summary: "The update couldn’t be completed.",
                recovery: "Try again in a moment. The Melo you are running was not changed.",
                detail: detail
            )
        }
    }

    #if MELO_DEV
    /// Snapshot seam. The update states are the whole point of this tab and all
    /// but one of them need a live server to reach, so the harness sets them
    /// directly instead of nobody ever looking at them.
    func setActivityForSnapshot(_ activity: Activity, lastCheck: Date? = nil) {
        self.activity = activity
        if let lastCheck { lastCheckDate = lastCheck }
    }

    /// Sets the ambient reminder directly, without writing anything to disk.
    /// The popup banner and the icon badge are the two surfaces a real update
    /// reaches first, and neither is reachable from a frame otherwise.
    func setUpdateReminderForSnapshot(_ update: PendingUpdate?) {
        updateReminder = update
    }

    /// The seam that lets the harness press **Skip** and **Remind Me Later**
    /// for real.
    ///
    /// Both guard on `pendingUpdate`, which is `private(set)` and only ever
    /// written by a live Sparkle session — so a frame could show what
    /// `.skipped` and `.deferred` *look* like, via `setActivityForSnapshot`,
    /// while proving nothing about whether the buttons produce them. That is
    /// exactly how a dead Skip button survived ten verify scripts and forty-odd
    /// frames in an earlier run.
    ///
    /// Deliberately assigns the property rather than the storage, so `didSet`
    /// runs and everything downstream — the disk record, the deferral reset,
    /// `refreshReminder()` — behaves as it does for a real find. A seam that
    /// skipped `didSet` would let the buttons pass against a state the app can
    /// never actually be in.
    func setPendingUpdateForSnapshot(_ update: PendingUpdate?) {
        pendingUpdate = update
    }
    #endif
}

// MARK: - Sparkle delegates

/// Sparkle's delegates must be Objective-C objects and are handed to the
/// updater at construction time, before `SparkleUpdateController` has finished
/// initialising, so this forwards to it weakly instead.
///
/// Every method carries its Objective-C selector explicitly. These are all
/// optional protocol members: a Swift name that does not map to the selector
/// Sparkle actually sends compiles cleanly and is simply never called, which
/// would turn the whole state machine below into decoration.
@MainActor
private final class UpdaterBridge: NSObject, SPUUpdaterDelegate {
    weak var owner: SparkleUpdateController?

    @objc(updater:didFindValidUpdate:)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        owner?.foundUpdate(item)
    }

    @objc(updaterDidNotFindUpdate:error:)
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        owner?.foundNoUpdate(error)
    }

    @objc(updater:willDownloadUpdate:withRequest:)
    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        owner?.downloadStarted(item)
    }

    @objc(updater:failedToDownloadUpdate:error:)
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        owner?.aborted(with: error)
    }

    @objc(updater:willExtractUpdate:)
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        owner?.extractionStarted(item)
    }

    @objc(updater:willInstallUpdate:)
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        owner?.installationStarted(item)
    }

    /// Returning true keeps the update parked until Melo quits *and* hands over
    /// the block that installs it now. A menu-bar app is almost never quit, so
    /// without holding this an automatically downloaded update can sit finished
    /// and unusable indefinitely, with nothing in the UI able to complete it.
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        owner?.parkedUntilQuit(item, install: immediateInstallHandler)
        return true
    }

    @objc(updater:didAbortWithError:)
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        owner?.aborted(with: error)
    }

    /// Skip and Install are the two answers that mean nothing is waiting any
    /// more. Sparkle knows them; without this the menu-bar mark would outlive
    /// the decision that removed it.
    @objc(updater:userDidMakeChoice:forUpdate:state:)
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        owner?.userMadeChoice(choice)
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        if let error {
            owner?.aborted(with: error)
        } else {
            owner?.sessionFinished()
        }
    }

    /// Melo asks about automatic updates during its own onboarding, in its own
    /// words, next to the other choices a first run makes. Sparkle's separate
    /// permission alert would be a second prompt asking the same question.
    @objc(updaterShouldPromptForPermissionToCheckForUpdates:)
    func updaterShouldPromptForPermission(toCheckForUpdates updater: SPUUpdater) -> Bool {
        false
    }
}

extension UpdaterBridge: SPUStandardUserDriverDelegate {
    @objc nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check must not throw a window in front of whatever the user
    /// is doing. Sparkle's fallback for that is to open its alert *behind*
    /// everything — which in an app with no Dock tile and no windows means it
    /// is never seen at all, and the update silently never happens. So when
    /// Melo is not the active app, Melo handles the reminder itself: a
    /// notification, plus state that stays put in Settings → Updates.
    @objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated { NSApp.isActive }
    }

    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            guard handleShowingUpdate else { return }
            owner?.updateWindowBecameAvailable()
            owner?.activateForUpdateUI()
        }
    }

    @objc(standardUserDriverDidReceiveUserAttentionForUpdate:)
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { owner?.userSawUpdate() }
    }

    /// Sparkle's modal alerts are the one place an accessory app reliably
    /// disappears behind other windows. Raising Melo first is what stops a
    /// "Melo is up to date" sheet from reading as a hang.
    @objc(standardUserDriverWillShowModalAlert)
    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated {
            owner?.updateWindowBecameAvailable()
            owner?.activateForUpdateUI()
        }
    }

    @objc(standardUserDriverWillFinishUpdateSession)
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { owner?.sessionFinished() }
    }
}
