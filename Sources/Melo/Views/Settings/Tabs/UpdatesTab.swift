import SwiftUI

@MainActor
struct UpdatesTab: View {
    @ObservedObject var sparkle: SparkleUpdateController
    @ObservedObject var developerUpdates: DeveloperUpdateManager

    @State private var showsFailureDetail = false
    @State private var showsCurrentReleaseNotes: Bool

    init(
        sparkle: SparkleUpdateController,
        developerUpdates: DeveloperUpdateManager,
        releaseNotesExpanded: Bool = false
    ) {
        self.sparkle = sparkle
        self.developerUpdates = developerUpdates
        // Only the snapshot harness passes this. The notes are a disclosure, so
        // the state that has the actual content in it is unreachable from a
        // frame otherwise.
        _showsCurrentReleaseNotes = State(initialValue: releaseNotesExpanded)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// The notes for the version actually running, not the newest ones written.
    /// A user who has not updated yet must not be shown someone else's changes.
    private var currentReleaseNote: MeloReleaseNote? {
        MeloReleaseNotes.all.first { $0.version == version }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusSection
                whatsNewSection
                automaticUpdatesSection
                #if MELO_DEV
                developerUpdatesSection
                developerStatusSection
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A settings tab has no content of its own to sit on. Without this the
        // scroll view paints the system text background, which is opaque white
        // in a dark window.
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
    }

    // MARK: - Status

    private var statusSection: some View {
        SettingsSection("Melo Updates") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    statusIcon
                        .frame(width: 22, height: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(DesignTokens.Typography.Scale.body(.semibold))
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                        Text(statusDetail)
                            .font(DesignTokens.Typography.Scale.footnote())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let lastChecked {
                            Text(lastChecked)
                                .font(DesignTokens.Typography.Scale.caption())
                                .foregroundStyle(DesignTokens.Colors.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let problem = sparkle.configurationProblem {
                    // Name what is missing rather than implying the updater is
                    // broken. Everything else is wired; Sparkle starts by itself
                    // the moment both values are present.
                    VStack(alignment: .leading, spacing: 4) {
                        Label(problem.summary, systemImage: "wrench.and.screwdriver")
                            .font(DesignTokens.Typography.Scale.footnote(.medium))
                        Text(problem.guidance)
                            .font(DesignTokens.Typography.Scale.footnote())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if case .failed(let failure) = sparkle.activity {
                    failureDetail(failure)
                }

                if let update = inFlightUpdate {
                    availableUpdateDetail(update)
                }

                HStack(spacing: 8) {
                    primaryButton
                    if case .failed = sparkle.activity {
                        Button("Dismiss") { sparkle.dismissFailure() }
                            .buttonStyle(.bordered)
                    }
                    // Deferring and refusing were previously reachable only
                    // from the menu bar, so the one screen entirely about
                    // updates could not answer the question it was asking.
                    if offersRemindLater {
                        Button("Remind Me Later") { sparkle.remindLater() }
                            .buttonStyle(.bordered)
                    }
                    if offersSkip {
                        Button("Skip This Version") { sparkle.skipPendingUpdate() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// The update this card is about, in whatever phase it is in. Carrying it
    /// through download and install is the difference between "something is
    /// downloading" and "Melo 2.9.5, 14.7 MB, here is what changed".
    private var inFlightUpdate: SparkleUpdateController.PendingUpdate? {
        switch sparkle.activity {
        case .available(let update), .readyToInstall(let update), .deferred(let update):
            return update
        case .skipped:
            // Deliberately nothing: size, date and a "what's new" link under a
            // version the user has just refused reads as an offer.
            return nil
        case .downloading(let update), .extracting(let update), .installing(let update):
            return update
        default:
            return sparkle.pendingUpdate
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch sparkle.activity {
        case .checking, .downloading, .extracting, .installing:
            ProgressView()
                .controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, Color.green)
                .symbolRenderingMode(.palette)
        case .available, .readyToInstall:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, Color.accentColor)
                .symbolRenderingMode(.palette)
        case .skipped:
            Image(systemName: "xmark.circle")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        case .deferred:
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch sparkle.activity {
        case .idle:
            return sparkle.isConfigured ? "Melo \(version)" : "Updates aren’t set up in this build"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Melo \(version) is up to date"
        case .available(let update):
            return "\(update.displayName) is available"
        case .downloading(let update):
            return "Downloading \(update?.displayName ?? "the update")…"
        case .extracting(let update):
            return "Verifying \(update?.displayName ?? "the update")…"
        case .installing(let update):
            return "Installing \(update?.displayName ?? "the update")…"
        case .readyToInstall(let update):
            return "\(update.displayName) is ready to install"
        case .skipped(let update):
            return "You skipped \(update.displayName)"
        case .deferred(let update):
            return "\(update.displayName) is still waiting"
        case .failed(let failure):
            return failure.summary
        }
    }

    private var statusDetail: String {
        switch sparkle.activity {
        case .idle:
            guard sparkle.isConfigured else {
                return "Melo hasn’t been told where to look for new versions."
            }
            return sparkle.automaticallyChecksForUpdates
                ? "Build \(build). Melo checks \(sparkle.automaticCheckCadence) and will tell you when there’s a new version."
                : "Build \(build). Automatic checking is off, so this is the only place a new version will turn up."
        case .checking:
            return "Melo is asking its update server what the newest version is."
        case .upToDate:
            return "Build \(build). Nothing newer is published for this Mac."
        case .available(let update):
            // Says that a download happens, because it does: an update that has
            // only been announced has nothing on this Mac yet, so Update Now
            // needs the network even though the version is already named here.
            let mechanics = "Update Now downloads it, checks its signature, then quits and reopens Melo on the new version."
            return update.isCritical
                ? "This is an important update. \(mechanics)"
                : "You’re on \(version). \(mechanics)"
        case .downloading(let update):
            let size = update.map { ByteCountFormatter.string(fromByteCount: $0.downloadBytes, countStyle: .file) }
            let amount = size.map { "\($0) " } ?? ""
            // Sparkle reports phase changes to this app but not bytes, so the
            // exact figure lives in its own progress window. Saying where it is
            // beats a bar that would have to be invented.
            let where_ = sparkle.canRevealUpdateWindow
                ? "Show Progress opens the exact figure and a way to stop."
                : "Melo will say so here when it is downloaded and ready to install."
            return "Melo is fetching \(amount)in the background. Nothing on this Mac has changed yet, and you can keep using Melo. \(where_)"
        case .extracting:
            return "Melo is checking the download’s signature before it goes anywhere near your installed copy."
        case .installing:
            return "Melo will quit and reopen on the new version."
        case .readyToInstall:
            return "It’s downloaded and verified. Melo would install it the next time it quits — but a menu-bar app rarely quits, so you can finish it now."
        case .skipped(let update):
            // Says the version still exists, and names the way back. Check for
            // Updates clears the skip, and nothing used to tell anyone that.
            // Not "is still published": this state now survives a relaunch and
            // a scheduled check, and by then Melo has not asked the server
            // anything about that version. What it does know is that it is
            // suppressing it, and how to stop.
            return "You’re still on \(version). Melo \(update.version) won’t badge the menu bar or turn up here again while it’s skipped. Check for Updates clears the skip and offers it again if it’s still published."
        case .deferred(let update):
            return "You’re still on \(version). The menu bar badge and the popup banner are off for about 8 hours, then Melo \(update.version) will ask again. You can install it any time before that."
        case .failed(let failure):
            return failure.recovery
        }
    }

    private var lastChecked: String? {
        guard let date = sparkle.lastCheckDate else { return nil }
        switch sparkle.activity {
        case .checking, .downloading, .extracting, .installing:
            return nil
        default:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
    }

    private var offersRemindLater: Bool {
        if case .available = sparkle.activity { return true }
        return false
    }

    /// Deliberately not offered in `.readyToInstall`. Once Sparkle has staged
    /// the update on disk there is no public way to unstage it — its own
    /// delegate header states "in either case Sparkle will always attempt to
    /// install the update when the app terminates", and `SUSkippedVersion` only
    /// filters a future appcast fetch. A Skip button there refused nothing: it
    /// left the card unchanged, left Install live, and the staged installer ran
    /// at the next quit anyway.
    private var offersSkip: Bool {
        switch sparkle.activity {
        case .available, .deferred: return true
        default: return false
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch sparkle.activity {
        case .available:
            // Not "Show Update…". macOS Software Update puts *Update Now* on
            // the pane and gets on with it; sending the user to a second window
            // to press a second button was one step of ceremony for no answer.
            Button("Update Now") { sparkle.installPendingUpdate() }
                .buttonStyle(.borderedProminent)
                .disabled(!sparkle.isConfigured)
        case .deferred:
            Button("Update Now") { sparkle.installPendingUpdate() }
                .buttonStyle(.borderedProminent)
                .disabled(!sparkle.isConfigured)
        case .skipped:
            // The recovery path, as the primary action, because it is the only
            // one: checking clears Sparkle's skip list and offers the version
            // again.
            Button("Check for Updates…") { sparkle.checkNow() }
                .buttonStyle(.borderedProminent)
                .disabled(!sparkle.isConfigured || !sparkle.canCheckForUpdates)
        case .readyToInstall:
            Button("Install and Relaunch") { sparkle.installDownloadedUpdateNow() }
                .buttonStyle(.borderedProminent)
        case .checking, .downloading, .extracting, .installing:
            // A spinner with no control beside it is something the user cannot
            // stop, and the card visibly shrank and grew as states changed.
            // Sparkle's own window carries the exact progress and Cancel.
            //
            // Only when that window exists. With Download-and-Install-
            // Automatically on, Sparkle runs the whole download through
            // `SPUAutomaticUpdateDriver`, whose `showingUpdate` returns `NO`
            // and which never opens anything — and `checkForUpdates()` returns
            // immediately while a session is in progress. The button raised
            // Melo and then did nothing at all. A button that is absent is
            // honest; a button that is present and inert is not.
            if sparkle.canRevealUpdateWindow {
                Button("Show Progress…") { sparkle.showPendingUpdate() }
                    .buttonStyle(.bordered)
                    .disabled(!sparkle.isConfigured)
            }
        case .failed:
            Button("Try Again") { sparkle.checkNow() }
                .buttonStyle(.borderedProminent)
                .disabled(!sparkle.isConfigured || !sparkle.canCheckForUpdates)
        default:
            Button("Check for Updates…") { sparkle.checkNow() }
                .buttonStyle(.borderedProminent)
                .disabled(!sparkle.isConfigured || !sparkle.canCheckForUpdates)
        }
    }

    @ViewBuilder
    private func availableUpdateDetail(_ update: SparkleUpdateController.PendingUpdate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(releaseSummary(update))
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            // Feeds usually carry HTML, and raw markup in a settings pane is
            // worse than a link. Plain-text notes are shown where they are.
            if let notes = update.notes, !notes.isEmpty, !update.notesAreHTML {
                Text(notes)
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notesURL = update.notesURL {
                Link("What’s new in \(update.displayName)", destination: notesURL)
                    .font(DesignTokens.Typography.Scale.footnote())
            }
        }
    }

    private func releaseSummary(_ update: SparkleUpdateController.PendingUpdate) -> String {
        var parts: [String] = ["Version \(update.version)"]
        if update.downloadBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: update.downloadBytes, countStyle: .file))
        }
        if let published = update.published {
            parts.append(published.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private func failureDetail(_ failure: SparkleUpdateController.Failure) -> some View {
        if let detail = failure.detail {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    showsFailureDetail.toggle()
                } label: {
                    Label(
                        showsFailureDetail ? "Hide technical detail" : "Show technical detail",
                        systemImage: showsFailureDetail ? "chevron.down" : "chevron.right"
                    )
                    .font(DesignTokens.Typography.Scale.caption())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showsFailureDetail {
                    Text(detail)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Release notes

    @ViewBuilder
    private var whatsNewSection: some View {
        if let note = currentReleaseNote {
            SettingsSection("Release Notes") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("You’re running Melo \(note.version)")
                            .font(DesignTokens.Typography.Scale.footnote(.semibold))
                        Text("\(note.headline). \(note.items.count) change\(note.items.count == 1 ? "" : "s") in this version.")
                            .font(DesignTokens.Typography.Scale.caption())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if showsCurrentReleaseNotes {
                        releaseNoteItems(note)

                        // Everything before this version, so "what changed"
                        // does not stop at the one release the user happens to
                        // be on. Older entries collapse by default; the list is
                        // the whole history Melo ships with.
                        ForEach(olderReleaseNotes) { older in
                            VStack(alignment: .leading, spacing: 6) {
                                Divider()
                                Text("Melo \(older.version) — \(older.headline)")
                                    .font(DesignTokens.Typography.Scale.caption(.semibold))
                                    .foregroundStyle(.secondary)
                                releaseNoteItems(older)
                            }
                        }
                    }

                    Button(showsCurrentReleaseNotes ? "Hide Release Notes" : "Show Release Notes") {
                        withAnimation(DesignTokens.Animation.panel) {
                            showsCurrentReleaseNotes.toggle()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var olderReleaseNotes: [MeloReleaseNote] {
        guard let current = currentReleaseNote else { return [] }
        return MeloReleaseNotes.all.filter { $0.build < current.build }
    }

    private func releaseNoteItems(_ note: MeloReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(note.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(DesignTokens.Typography.Scale.footnote(.medium))
                    Text(item.detail)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Automatic updates

    private var automaticUpdatesSection: some View {
        SettingsSection("Automatic Updates") {
            SettingsRow(
                "Check Automatically",
                description: sparkle.automaticallyChecksForUpdates
                    ? "Melo looks for a new version \(sparkle.automaticCheckCadence) and notifies you when it finds one."
                    : "Off. Melo will never look on its own — a new version only appears when you check here."
            ) {
                Toggle("", isOn: $sparkle.automaticallyChecksForUpdates)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!sparkle.isConfigured)
            }

            SettingsRowDivider()

            SettingsRow(
                "Download and Install Automatically",
                description: sparkle.automaticallyDownloadsAndInstalls
                    ? "Melo downloads verified updates on its own and installs them when it next quits. You can finish one early from above."
                    : "Off. Melo asks before it downloads or installs anything."
            ) {
                Toggle("", isOn: $sparkle.automaticallyDownloadsAndInstalls)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!sparkle.isConfigured || !sparkle.automaticallyChecksForUpdates)
            }

            SettingsRowDivider()

            Text("Melo only accepts updates signed with its own key. A download that doesn’t match is thrown away and the copy you’re running is left alone.")
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    #if MELO_DEV
    private var developerUpdatesSection: some View {
        SettingsSection("Developer Updates") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Build a trusted Melo update on this Mac")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Developer updates build code from a file on this Mac. Only use packages you produced yourself.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Choose Update File…") {
                        developerUpdates.chooseUpdateFile()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Choose Folder to Check…") {
                        developerUpdates.chooseFolderToCheck()
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                rememberedFolderControls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var rememberedFolderControls: some View {
        if let folderName = developerUpdates.watchedFolderName {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remembered Folder")
                            .font(.system(size: 11, weight: .medium))
                        Text(folderName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") {
                        developerUpdates.checkRememberedFolder()
                    }
                    .buttonStyle(.bordered)
                    Button("Forget") {
                        developerUpdates.forgetFolder()
                    }
                    .buttonStyle(.bordered)
                }

                Toggle("Check this folder when Melo starts", isOn: $developerUpdates.automaticallyChecksFolder)
                    .font(.system(size: 11))
            }
        } else {
            Text("Choose a folder once and Melo can search it for the highest valid build later.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var developerStatusSection: some View {
        SettingsSection("Developer Update Status") {
            developerStatusContent
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var developerStatusContent: some View {
        switch developerUpdates.status {
        case .idle:
            statusMessage(
                title: "Ready",
                message: "Choose an update file or a remembered folder to inspect a build."
            )

        case .inspecting(let name):
            progressMessage(title: "Checking \(name)…", message: "Melo is reading the update manifest.")

        case .noNewerUpdate(let detail):
            statusMessage(
                title: "No newer build in that folder",
                message: detail.isEmpty
                    ? "Nothing in the remembered folder is newer than the build you are running."
                    : detail
            )

        case .ready(let candidate):
            VStack(alignment: .leading, spacing: 10) {
                statusMessage(
                    title: "Melo \(candidate.manifest.version) is ready",
                    message: readyDescription(candidate)
                )
                if let notes = candidate.manifest.releaseNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(candidate.manifest.packageType == .source ? "Build and Install" : "Install and Relaunch") {
                    developerUpdates.buildAndInstallReadyUpdate()
                }
                .buttonStyle(.borderedProminent)
            }

        case .building(let candidate):
            progressMessage(
                title: "Building Melo \(candidate.manifest.version)…",
                message: "Xcode is compiling the update in a separate process. Melo remains responsive."
            )

        case .installing(let candidate):
            progressMessage(
                title: "Installing Melo \(candidate.manifest.version)…",
                message: "Melo checks that the new build launches, then closes, replaces itself, and reopens. If the new build does not start, the current version comes back automatically."
            )

        case .rolledBack(let version, let installBuild, let reason):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    statusMessage(
                        title: "Melo \(version) (build \(installBuild)) was rolled back",
                        message: "\(reason) You are running build \(build) — the one you had before."
                    )
                }
                HStack(spacing: 8) {
                    if developerUpdates.lastBuildLogURL != nil {
                        Button("Show Install Log") {
                            developerUpdates.revealLastBuildLog()
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Clear") {
                        developerUpdates.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                statusMessage(title: "The update couldn't be installed.", message: message)
                HStack(spacing: 8) {
                    if developerUpdates.lastBuildLogURL != nil {
                        Button("Show Build Log") {
                            developerUpdates.revealLastBuildLog()
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Clear") {
                        developerUpdates.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func readyDescription(_ candidate: DeveloperUpdateCandidate) -> String {
        let kind = candidate.manifest.packageType == .source ? "source update" : "built app update"
        return "Build \(candidate.manifest.build) • \(kind). Melo verifies the finished app and test-launches it before replacing the current version."
    }

    private func progressMessage(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            statusMessage(title: title, message: message)
        }
    }

    private func statusMessage(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}
