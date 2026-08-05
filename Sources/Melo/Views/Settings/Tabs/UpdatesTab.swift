import SwiftUI

@MainActor
struct UpdatesTab: View {
    @ObservedObject var sparkle: SparkleUpdateController
    @ObservedObject var developerUpdates: DeveloperUpdateManager

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                regularUpdatesSection
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
        .scrollIndicators(.never)
    }

    private var regularUpdatesSection: some View {
        SettingsSection("Melo Updates") {
            SettingsRow("Melo \(version)", description: "Build \(build)") {
                if sparkle.isConfigured {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsRowDivider()

            VStack(alignment: .leading, spacing: 10) {
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
                } else {
                    Text("Melo checks your update feed securely and verifies each update's signature before installing it.")
                        .font(DesignTokens.Typography.Scale.footnote())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Check for Updates…") {
                    sparkle.checkNow()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!sparkle.isConfigured || !sparkle.canCheckForUpdates)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var automaticUpdatesSection: some View {
        SettingsSection("Automatic Updates") {
            SettingsRow(
                "Check Automatically",
                description: "Look for published Melo updates in the background"
            ) {
                Toggle("", isOn: $sparkle.automaticallyChecksForUpdates)
                    .labelsHidden()
                    .disabled(!sparkle.isConfigured)
            }

            SettingsRowDivider()

            SettingsRow(
                "Download and Install Automatically",
                description: "Let verified updates install when Melo can safely relaunch"
            ) {
                Toggle("", isOn: $sparkle.automaticallyDownloadsAndInstalls)
                    .labelsHidden()
                    .disabled(!sparkle.isConfigured || !sparkle.automaticallyChecksForUpdates)
            }
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
