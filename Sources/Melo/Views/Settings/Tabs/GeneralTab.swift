import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var appSupport: AppSupportCoordinator
    let audioEngine: AudioEngine
    let onResetAll: () -> Void
    let onSettingsRestored: () -> Void
    /// The section the Guide sent the reader here to see. No default: dropping
    /// it at the call site is then a build error rather than a tab that quietly
    /// opens at the top again.
    let sectionTarget: SettingsSectionTarget?

    @State private var showResetConfirmation = false
    @State private var showEraseConfirmation = false
    @State private var showThemeStudio = false
    @State private var pendingRestoreURL: URL?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                gettingStartedSection
                generalSection
                menuBarSection
                supportSection
                privacySection
                dataSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .guidedSectionScroll(target: sectionTarget)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { onResetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears Melo’s controls and preferences but keeps the app installed.")
        }
        .confirmationDialog(
            "Erase all Melo data?",
            isPresented: $showEraseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Erase and Restart", role: .destructive) {
                appSupport.eraseAllDataAndRestart()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Melo will remove its settings, app controls, scenes, presets, update history, and tutorial progress, then reopen like a new installation. macOS privacy permissions are managed separately and will remain unchanged.")
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { pendingRestoreURL != nil },
                set: { if !$0 { pendingRestoreURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) { restorePendingBackup() }
            Button("Cancel", role: .cancel) { pendingRestoreURL = nil }
        } message: {
            Text("Your current Melo settings will be replaced. The backup file will not be changed.")
        }
        .alert("Melo couldn’t finish that", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showThemeStudio) {
            AIThemeStudioView(settings: settings)
        }
    }

    private var gettingStartedSection: some View {
        SettingsSection("Getting Started") {
            SettingsRow(
                "Replay Tutorial",
                description: "Walk through Melo again without changing your settings"
            ) {
                Button("Replay…") { appSupport.replayTutorial() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .settingsSectionAnchor("Getting Started", target: sectionTarget)
    }

    private var generalSection: some View {
        SettingsSection("General") {
            SettingsRow("Launch at Login", description: "Start Melo when you log in") {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Show Melo in Dock",
                description: "Keep Melo visible like a regular Mac app and make it easier to force quit"
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { settings.appSettings.showInDock },
                        set: { appSupport.setDockVisible($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow("Move Quiet Apps", description: settings.appSettings.quietMoveDelay.explanation) {
                Picker("Move Quiet Apps", selection: $settings.appSettings.quietMoveDelay) {
                    ForEach(QuietMoveDelayOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            SettingsRowDivider()
            SettingsRow("Appearance", description: "Match macOS, or lock to Light or Dark") {
                ThemeTilePicker(selection: $settings.appSettings.appearance)
            }
            SettingsRowDivider()
            SettingsRow("Melo Theme", description: "Mac accent, animated space, galaxy, aurora, or a Studio theme") {
                MeloVisualThemePicker(selection: $settings.appSettings.visualTheme)
            }
            SettingsRowDivider()
            SettingsRow(
                "Theme Studio",
                description: settings.appSettings.generatedTheme.map { "Current AI theme: \($0.name)" }
                    ?? "Create a constrained Melo theme with OpenAI or ChatGPT"
            ) {
                Button("Create…") { showThemeStudio = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if settings.appSettings.visualTheme == .custom {
                SettingsRowDivider()
                SettingsRow("Theme Color", description: "Choose the accent used throughout Melo") {
                    ColorPicker(
                        "Theme Color",
                        selection: Binding(
                            get: {
                                Color(meloHex: settings.appSettings.customAccentHex)
                                    ?? Color(nsColor: .controlAccentColor)
                            },
                            set: { color in
                                guard let hex = color.meloHexRGB else { return }
                                settings.appSettings.customAccentHex = hex
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
            }
            SettingsRowDivider()
            SettingsRow("Device Disconnect Alerts", description: "Show a notification when an audio device disconnects") {
                Toggle("", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .onChange(of: settings.appSettings.showDeviceDisconnectAlerts) { _, isOn in
                        // Ask at the moment the user opts in, so the system prompt
                        // arrives with obvious context.
                        if isOn { NotificationAuthorization.requestIfNeeded() }
                    }
            }
            SettingsRowDivider()
            SettingsRow(
                "Bluetooth Features",
                // Not "and their battery level". Melo has never read a Bluetooth
                // battery — `PairedBluetoothDevice` carries a name and an icon —
                // so that half of the sentence described a feature the switch
                // does not turn on.
                description: "Show paired audio devices, with a button to connect them"
            ) {
                Toggle("", isOn: $settings.appSettings.bluetoothFeaturesEnabled)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .onChange(of: settings.appSettings.bluetoothFeaturesEnabled) { _, isOn in
                        // Start discovery on the spot so the system Bluetooth
                        // prompt arrives while the user is looking at the switch
                        // they just flipped, rather than after a relaunch.
                        if isOn { audioEngine.startBluetoothMonitoringIfEnabled() }
                    }
            }
        }
        .settingsSectionAnchor("General", target: sectionTarget)
    }

    private var menuBarSection: some View {
        SettingsSection("Menu Bar") {
            SettingsRow("Icon Style", description: "How Melo appears in your menu bar") {
                IconStyleSegmentedControl(selection: $settings.appSettings.menuBarIconStyle)
            }
            SettingsRowDivider()
            SettingsRow(
                "React to Audio",
                description: "Let the menu bar mark move a little now and then while audio plays"
            ) {
                Toggle("", isOn: $settings.appSettings.menuBarIconMotion)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow("Show Beside Icon", description: "Optionally show volume, device, or a small live level") {
                Picker("Show Beside Icon", selection: $settings.appSettings.menuBarInfoStyle) {
                    ForEach(MenuBarInfoStyle.allCases) { style in
                        Text(style.description).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            SettingsRowDivider()
            SettingsRow("Popup Size", description: "Smaller fits more on screen; larger leaves more breathing room.") {
                PopupSizeTilePicker(selection: $settings.appSettings.popupSize)
            }
        }
        .settingsSectionAnchor("Menu Bar", target: sectionTarget)
    }

    private var supportSection: some View {
        SettingsSection("Help and Diagnostics") {
            SettingsRow(
                "Report a Problem",
                description: "Includes logs, crash details, and a private settings summary"
            ) {
                Button(appSupport.isCreatingReport ? "Preparing…" : "Create Report…") {
                    appSupport.createDiagnosticReport()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appSupport.isCreatingReport)
            }
            if let message = appSupport.reportStatusMessage {
                SettingsRowDivider()
                HStack(spacing: 6) {
                    Image(systemName: message == "Report saved" ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(message == "Report saved" ? Color.green : Color.gray)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .settingsSectionAnchor("Help and Diagnostics", target: sectionTarget)
    }

    /// The switch reads `.granted` as on and both `.denied` and `.unasked` as
    /// off, but writing never produces `.unasked` again: once this control has
    /// been touched the question has definitively been answered, and the
    /// one-time launch prompt must not come back afterwards.
    private var analyticsSharingBinding: Binding<Bool> {
        Binding(
            get: { settings.appSettings.analyticsConsent == .granted },
            set: { isOn in
                var appSettings = settings.appSettings
                appSettings.analyticsConsent = isOn ? .granted : .denied
                settings.appSettings = appSettings
                TelemetryService.shared.refreshConsent()
            }
        )
    }

    private var privacySection: some View {
        SettingsSection("Privacy") {
            SettingsRow(
                "Share Anonymous Usage",
                description: "Help decide what to improve next. Off unless you turn it on."
            ) {
                Toggle("", isOn: analyticsSharingBinding)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            SettingsRowDivider()
            // Spelled out rather than linked to a privacy policy: the promise
            // that matters here is that app and device names never leave the
            // machine, and it should be readable at the switch that controls it.
            SettingsRow(
                "What Melo Collects",
                description: "Melo’s version, your macOS version, roughly which Mac chip you have, your language, and which features were used. Never the names of your apps, your audio devices, or your Mac, and never what you listen to."
            ) {
                EmptyView()
            }
        }
        .settingsSectionAnchor("Privacy", target: sectionTarget)
    }

    private var dataSection: some View {
        SettingsSection("Data") {
            SettingsRow("Settings Backup", description: "Save a copy you can restore or move to another Mac") {
                HStack(spacing: 8) {
                    Button("Save…") { saveBackup() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Restore…") { chooseBackupToRestore() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if let statusMessage {
                SettingsRowDivider()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(statusMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            SettingsRowDivider()
            SettingsRow("Reset All Settings", description: "Clear all volumes, sound controls, and device choices") {
                Button(role: .destructive) { showResetConfirmation = true } label: { Text("Reset") }
                    .buttonStyle(.bordered).tint(.red).controlSize(.small)
            }
            SettingsRowDivider()
            SettingsRow(
                "Erase All Melo Data",
                description: "Remove every Melo setting and reopen as a new installation"
            ) {
                Button(role: .destructive) { showEraseConfirmation = true } label: { Text("Erase…") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
            }
        }
        .settingsSectionAnchor("Data", target: sectionTarget)
    }

    private func saveBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Melo Settings Backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportSettings(to: url)
            statusMessage = "Backup saved"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseBackupToRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
    }

    private func restorePendingBackup() {
        guard let url = pendingRestoreURL else { return }
        pendingRestoreURL = nil
        do {
            try settings.importSettings(from: url)
            onSettingsRestored()
            statusMessage = "Backup restored"
        } catch {
            errorMessage = "This file isn’t a Melo settings backup.\n\n\(error.localizedDescription)"
        }
    }
}

// MARK: - Theme Studio

/// AI customization is intentionally data-only. ChatGPT can choose a palette,
/// restrained motion style, star density, sparkle strength, and whether Melo's
/// existing small white-and-red pixel rocket appears. It cannot inject Swift, scripts,
/// network endpoints, images, controls, or layout changes.
@MainActor
private struct AIThemeStudioView: View {
    @Bindable var settings: SettingsManager

    @Environment(\.dismiss) private var dismiss

    @State private var idea = "A refined night theme with rich depth, restrained light, and excellent readability."
    @State private var importedJSON = ""
    @State private var draftTheme: GeneratedMeloTheme?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    descriptionSection
                    browserSection
                    previewSection
                    safetyNote
                }
                .padding(22)
            }
            .scrollIndicators(.never)

            Divider()
            footer
        }
        .frame(width: 740, height: 690)
        .onAppear {
            draftTheme = settings.appSettings.generatedTheme ?? .fallback
            importedJSON = encodedTheme(draftTheme ?? .fallback)
        }
        .alert("Theme Studio", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(0.35), .purple.opacity(0.38), .pink.opacity(0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 24, weight: .semibold))
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Melo Theme Studio")
                    .font(.title2.weight(.semibold))
                Text("Create a theme inside Melo’s existing menu-panel and Settings frames.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    private var descriptionSection: some View {
        GroupBox("Describe the theme") {
            TextEditor(text: $idea)
                .font(.system(size: 12))
                .frame(minHeight: 72, maxHeight: 92)
                .scrollContentBackground(.hidden)
                .padding(7)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 5)
        }
    }

    private var browserSection: some View {
        GroupBox("ChatGPT Theme Bridge") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use ChatGPT in your browser as a guest or with your own account. Melo copies a strict theme prompt, then validates the returned JSON. No API key, ChatGPT password, or conversation data is stored by Melo.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        copyPromptAndOpenChatGPT()
                    } label: {
                        Label("Copy Prompt & Open ChatGPT", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Paste Clipboard") { pasteFromClipboard() }
                        .buttonStyle(.bordered)

                    Button("Import JSON…") { importThemeFile() }
                        .buttonStyle(.bordered)

                    Button("Export Current…") { exportThemeFile() }
                        .buttonStyle(.bordered)
                }

                TextEditor(text: $importedJSON)
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(minHeight: 150, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button("Preview Pasted Theme") { previewImportedJSON() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.top, 5)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let draftTheme {
            GroupBox("Preview — \(draftTheme.name)") {
                ZStack {
                    MeloThemeBackdrop(
                        theme: .aiGenerated,
                        customAccentHex: settings.appSettings.customAccentHex,
                        generatedTheme: draftTheme
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "speaker.wave.2.fill")
                            Text("Melo")
                                .font(.headline)
                            Spacer()
                            Text("72%")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }

                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.10))
                            .frame(height: 46)
                            .overlay(alignment: .leading) {
                                HStack {
                                    Image(systemName: "headphones")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Headphones")
                                            .font(.system(size: 12, weight: .medium))
                                        Text("Theme remains behind Melo’s controls")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                            }
                    }
                    .padding(16)
                }
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.13), lineWidth: 0.5)
                }
                .padding(.top, 5)
            }
        }
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.secondary)
            Text("Imported themes can change only bounded colors, one of four background styles, star density, subtle sparkle, and the existing rocket. They cannot add code, images, network requests, controls, or new layouts.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset Example") {
                draftTheme = .fallback
                importedJSON = encodedTheme(.fallback)
                statusMessage = "Example restored."
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Apply Theme") { applyDraftTheme() }
                .buttonStyle(.borderedProminent)
                .disabled(draftTheme == nil)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func copyPromptAndOpenChatGPT() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(guestPrompt, forType: .string)
        statusMessage = "Prompt copied. Paste it into ChatGPT."
        guard let url = URL(string: "https://chatgpt.com/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func pasteFromClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            errorMessage = "The clipboard does not contain text."
            return
        }
        importedJSON = value
        previewImportedJSON()
    }

    private func previewImportedJSON() {
        do {
            let theme = try decodeTheme(from: importedJSON).normalized
            draftTheme = theme
            importedJSON = encodedTheme(theme)
            statusMessage = "Theme validated and ready to apply."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importThemeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importedJSON = try String(contentsOf: url, encoding: .utf8)
            previewImportedJSON()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportThemeFile() {
        let theme = (draftTheme ?? settings.appSettings.generatedTheme ?? .fallback).normalized
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(safeFilename(theme.name)).melo-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try encodedTheme(theme).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Theme exported."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDraftTheme() {
        guard let draftTheme else { return }
        var appSettings = settings.appSettings
        appSettings.generatedTheme = draftTheme.normalized
        appSettings.visualTheme = .aiGenerated
        settings.appSettings = appSettings
        statusMessage = "Theme applied throughout Melo."
    }

    private func decodeTheme(from raw: String) throws -> GeneratedMeloTheme {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let first = trimmed.firstIndex(of: "{"),
           let last = trimmed.lastIndex(of: "}"),
           first <= last {
            json = String(trimmed[first...last])
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8) else {
            throw ThemeStudioError.invalidJSON
        }
        do {
            return try JSONDecoder().decode(GeneratedMeloTheme.self, from: data)
        } catch {
            throw ThemeStudioError.couldNotDecode(error.localizedDescription)
        }
    }

    private func encodedTheme(_ theme: GeneratedMeloTheme) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(theme.normalized),
              let value = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return value
    }

    private func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = value.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Melo Theme" : result
    }

    private var guestPrompt: String {
        let request = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Create one restrained visual theme for the Melo macOS audio application.

        USER IDEA
        \(request.isEmpty ? "A refined dark theme with restrained motion." : request)

        MELO FRAME RULES
        - This is a decorative background behind native translucent glass.
        - It must work in a 470–560 pt menu-bar panel and an 860 × 650 pt Settings window.
        - Do not alter layout, controls, typography, spacing, window size, or audio behavior.
        - Keep the palette dark enough for white primary text and gray secondary text.
        - Avoid flashing, high brightness, full-screen saturated red, or rapid motion.
        - The optional rocket is Melo's existing small white-and-red pixel rocket; do not describe a new asset.
        - Return JSON only, without Markdown fences or commentary.

        REQUIRED JSON
        {
          "name": "32 characters maximum",
          "style": "stars | aurora | nebula | gradient",
          "accentHex": "#RRGGBB",
          "topHex": "#RRGGBB dark",
          "middleHex": "#RRGGBB dark",
          "bottomHex": "#RRGGBB darkest",
          "secondaryHex": "#RRGGBB",
          "starDensity": 24,
          "sparkleStrength": 0.14,
          "showsRocket": true
        }

        LIMITS
        - starDensity: integer 0–48.
        - sparkleStrength: 0.04–0.28; prefer 0.08–0.18.
        - Use exactly these keys. No URLs, code, file paths, image prompts, or extra fields.
        """
    }

    private enum ThemeStudioError: LocalizedError {
        case invalidJSON
        case couldNotDecode(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "The pasted text could not be read as JSON."
            case .couldNotDecode(let message):
                return "The theme JSON does not match Melo’s theme format. \(message)"
            }
        }
    }
}
