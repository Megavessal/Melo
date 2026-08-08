import SwiftUI

extension Notification.Name {
    static let meloOpenGuide = Notification.Name("io.github.megavessal.Melo.openGuide")
}

@MainActor
struct ConsumerCommandPalette: View {
    @Bindable var audioEngine: AudioEngine
    @ObservedObject var sparkleUpdateController: SparkleUpdateController
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private struct Command: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let category: ConsumerCommandCategory
        let aliases: [String]
        let action: () -> Void

        func score(_ query: String) -> Int {
            IntentSearch.score(
                query: query,
                fields: [title, subtitle, category.rawValue],
                aliases: aliases
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Back", systemImage: "chevron.left") { onClose() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.meloHover)
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("Close Find an Action")

                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("What would you like Melo to do?", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($searchFocused)

                if !searchText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { searchText = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(DesignTokens.Colors.glassFillStrong)

            Divider()

            resultsList
        }
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onExitCommand { onClose() }
        .onChange(of: searchText) { _, _ in
            // The best match for the new query is always the top row; leaving the
            // old index in place is how a palette runs the command you were not
            // looking at.
            selectedIndex = 0
        }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.return) { runSelectedCommand() }
    }

    // MARK: - Results

    /// One category's worth of rows. The palette groups visually but navigates
    /// linearly, so the flattened order below has to be derived from exactly the
    /// same grouping the list renders.
    private struct CommandGroup: Identifiable {
        let category: ConsumerCommandCategory
        let commands: [Command]
        var id: ConsumerCommandCategory { category }
    }

    private var commandGroups: [CommandGroup] {
        let commands = filteredCommands
        return ConsumerCommandCategory.allCases.compactMap { category in
            let matching = commands.filter { $0.category == category }
            return matching.isEmpty ? nil : CommandGroup(category: category, commands: matching)
        }
    }

    /// Displayed order, top to bottom. This is what the arrow keys walk.
    private var orderedCommands: [Command] {
        commandGroups.flatMap(\.commands)
    }

    private var resultsList: some View {
        let groups = commandGroups
        let selectedID = selectedCommandID(in: groups.flatMap(\.commands))

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(groups) { group in
                        Text(group.category.rawValue.uppercased())
                            .font(DesignTokens.Typography.Scale.caption2(.bold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, DesignTokens.Spacing.md)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)

                        ForEach(group.commands) { command in
                            commandButton(command, isSelected: command.id == selectedID)
                                .id(command.id)
                        }
                    }

                    if groups.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, DesignTokens.Spacing.md)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(DesignTokens.Animation.scrollToRow) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No close match")
                .font(DesignTokens.Typography.Scale.body(.semibold))
            Text("Try “mute Music,” “Spotify to 200%,” “headphones,” “fix audio,” or “help.”")
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    // MARK: - Keyboard

    private func selectedCommandID(in ordered: [Command]) -> String? {
        guard ordered.indices.contains(selectedIndex) else { return ordered.first?.id }
        return ordered[selectedIndex].id
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        let count = orderedCommands.count
        guard count > 0 else { return .ignored }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
        return .handled
    }

    private func runSelectedCommand() -> KeyPress.Result {
        let ordered = orderedCommands
        // A pressed Return with nothing to run should not silently close the
        // palette, which would read as "it did something".
        guard !ordered.isEmpty else { return .ignored }
        let command = ordered.indices.contains(selectedIndex) ? ordered[selectedIndex] : ordered[0]
        command.action()
        onClose()
        return .handled
    }

    private func commandButton(_ command: Command, isSelected: Bool) -> some View {
        Button {
            command.action()
            onClose()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: command.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.tint.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(command.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "return")
                    .font(DesignTokens.Typography.Scale.caption2())
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keyboard selection is drawn as a ring rather than a fill: the hover
        // fill can be under the pointer on a different row at the same moment,
        // and two rows wearing the same highlight makes Return unpredictable.
        .overlay(
            DesignTokens.Dimensions.Shape.sm
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: 1.5
                )
                .padding(.horizontal, DesignTokens.Spacing.xs2)
        )
        // The title is the whole label: the subtitle is a rationale, not a
        // name, and reading it into the label makes every row take three
        // seconds to hear in a list you are meant to skim.
        .accessibilityLabel(command.title)
        .accessibilityHint(command.subtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var filteredCommands: [Command] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return suggestedCommands }

        var result = commandsForSearch
        result.append(contentsOf: directIntentCommands(query: query))

        var unique: [String: Command] = [:]
        for command in result {
            unique[command.id] = command
        }
        // Sorted by title before ranking because `unique.values` comes out of a
        // dictionary in arbitrary order and the score sort is not stable —
        // equally-scoring rows would otherwise shuffle on every keystroke.
        let candidates = unique.values.sorted { $0.title < $1.title }
        // Ranked rather than merely sorted: with every app contributing three
        // commands, a bare score sort listed dozens of near-misses below the
        // answer and buried it in its own results.
        return IntentSearch.rank(candidates, limit: 12) { $0.score(query) }
    }

    /// What the palette offers before anything is typed.
    ///
    /// The per-app commands used to be absent from this list entirely — they
    /// only existed once a query had been typed — so a palette opened in an app
    /// whose whole purpose is per-app volume suggested scenes, devices and
    /// Settings, and never a single app. The first app's three commands are
    /// included for the same reason four scenes and three devices are: they are
    /// what someone opening this is most likely to have come for.
    ///
    /// `prefix(3)` is one app, not three: `appCommands` emits mute / raise /
    /// lower per app, and every app contributing three rows is what buried the
    /// answer in its own results when this list was longer.
    private var suggestedCommands: [Command] {
        var result: [Command] = []
        result.append(contentsOf: appCommands.prefix(3))
        result.append(contentsOf: sceneCommands.prefix(4))
        result.append(contentsOf: deviceCommands.prefix(3))
        result.append(contentsOf: generalCommands)
        return result
    }

    private var commandsForSearch: [Command] {
        sceneCommands + deviceCommands + appCommands + generalCommands
    }

    private var sceneCommands: [Command] {
        audioEngine.settingsManager.consumerScenes.map { scene in
            Command(
                id: "scene-\(scene.id.uuidString)",
                title: "Use \(scene.name)",
                subtitle: "Restore its volumes, devices, sound, and effects",
                symbol: scene.symbolName,
                category: .scenes,
                aliases: ["load setup", "switch setup", "preset", "remembered sound"],
                action: { audioEngine.applyConsumerScene(scene) }
            )
        }
    }

    private var deviceCommands: [Command] {
        audioEngine.outputDevices.map { device in
            Command(
                id: "device-\(device.uid)",
                title: "Play through \(device.name)",
                subtitle: "Make this the main output",
                symbol: "speaker.wave.2.fill",
                category: .devices,
                aliases: ["switch speaker", "headphones", "output", "send sound"],
                action: { _ = audioEngine.setDefaultOutputDevice(device.id) }
            )
        }
    }

    // MARK: - What a percent means here

    // One definition, shared with the app row's readout, the row's slider and
    // editable field, and the "Set App Volume in Melo" shortcut: a percent is
    // **effective gain × 100, in 0...400** — the app's base volume multiplied by
    // its boost. Reading `getVolume(for:)` on its own reported an app boosted to
    // 2× as "100%" while its row said "200%", and clamping to a gain of 1.0 made
    // "Raise Music" do nothing for every boosted app.

    /// Loudest gain Melo will apply to one app, as a percent. Matches
    /// `EditablePercentage(range: 0...400)` in `AppRowControls` and the 0–400
    /// range `SetMeloAppVolumeIntent` documents.
    private static let maximumPercent = 400

    private func effectivePercent(for app: AudioApp) -> Int {
        let gain = audioEngine.getVolume(for: app) * audioEngine.getBoost(for: app).rawValue
        return Int((Double(max(0, min(4, gain))) * 100).rounded())
    }

    /// Writes a percent back through Melo's persisted base-volume + boost pair,
    /// using the same decomposition the slider uses so the two cannot drift.
    private func setEffectivePercent(_ percent: Int, for app: AudioApp) {
        let clamped = max(0, min(Self.maximumPercent, percent))
        let components = VolumeMapping.components(forEffectiveGain: Float(clamped) / 100)
        audioEngine.setBoost(for: app, to: components.boost)
        audioEngine.setVolume(for: app, to: components.volume)
    }

    private var appCommands: [Command] {
        audioEngine.apps.flatMap { app in
            let currentPercent = effectivePercent(for: app)
            let raisedPercent = min(Self.maximumPercent, currentPercent + 10)
            let loweredPercent = max(0, currentPercent - 10)
            let muted = audioEngine.getMute(for: app)
            return [
                Command(
                    id: "app-mute-\(app.id)",
                    title: muted ? "Unmute \(app.name)" : "Mute \(app.name)",
                    subtitle: muted ? "Bring this app back" : "Silence only this app",
                    symbol: muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    category: .controls,
                    aliases: ["silence \(app.name)", "turn off \(app.name)", "sound on \(app.name)"],
                    action: { audioEngine.setMute(for: app, to: !muted) }
                ),
                Command(
                    id: "app-up-\(app.id)",
                    title: "Raise \(app.name)",
                    // The row it will change shows a number; so does this, and
                    // the number it promises is the number the action writes.
                    subtitle: raisedPercent == currentPercent
                        ? "Already at \(currentPercent)%, as loud as Melo goes"
                        : "Now \(currentPercent)% — this makes it \(raisedPercent)%",
                    symbol: "speaker.plus.fill",
                    category: .controls,
                    aliases: ["louder", "turn up", "increase"],
                    action: { setEffectivePercent(raisedPercent, for: app) }
                ),
                Command(
                    id: "app-down-\(app.id)",
                    title: "Lower \(app.name)",
                    subtitle: loweredPercent == currentPercent
                        ? "Already at 0%"
                        : "Now \(currentPercent)% — this makes it \(loweredPercent)%",
                    symbol: "speaker.minus.fill",
                    category: .controls,
                    aliases: ["quieter", "turn down", "decrease"],
                    action: { setEffectivePercent(loweredPercent, for: app) }
                ),
            ]
        }
    }

    private var generalCommands: [Command] {
        let smartSoundEnabled = audioEngine.settingsManager.appSettings.adaptiveAudio.enabled
        return [
            Command(
                id: "undo",
                title: "Undo Last Change",
                subtitle: audioEngine.consumerUndoManager.latest?.label ?? "Nothing recent to undo",
                symbol: "arrow.uturn.backward",
                category: .controls,
                aliases: ["go back", "reverse", "restore"],
                action: { audioEngine.undoLastConsumerChange() }
            ),
            Command(
                id: "smart-sound",
                title: smartSoundEnabled ? "Turn Off Smart Sound" : "Turn On Smart Sound",
                subtitle: "Keep sudden changes comfortable and speech clear",
                symbol: "ear.badge.waveform",
                category: .controls,
                aliases: ["automatic sound", "steady volume", "clear voices"],
                action: {
                    var adaptive = audioEngine.settingsManager.appSettings.adaptiveAudio
                    adaptive.enabled.toggle()
                    audioEngine.setAdaptiveAudioSettings(adaptive)
                }
            ),
            Command(
                id: "repair",
                title: "Fix Audio",
                subtitle: "Refresh Melo’s audio connections without erasing settings",
                symbol: "wrench.and.screwdriver.fill",
                category: .help,
                aliases: ["broken", "not working", "reset sound", "repair"],
                action: { audioEngine.repairConsumerAudio() }
            ),
            Command(
                id: "guide",
                title: "Open the Melo Guide",
                subtitle: "Find a setting or describe what you want to do",
                symbol: "questionmark.circle.fill",
                category: .help,
                aliases: ["help", "how do i", "instructions", "tutorial"],
                action: {
                    onOpenSettings()
                    Task { @MainActor in
                        await Task.yield()
                        NotificationCenter.default.post(name: .meloOpenGuide, object: nil)
                    }
                }
            ),
            Command(
                id: "updates",
                title: "Check for Updates",
                subtitle: "Look for a newer version of Melo",
                symbol: "arrow.triangle.2.circlepath",
                category: .help,
                aliases: ["upgrade", "new version", "download update"],
                action: { sparkleUpdateController.checkNow() }
            ),
            Command(
                id: "settings",
                title: "Open Melo Settings",
                subtitle: "Scenes, appearance, audio, and shortcuts",
                symbol: "gearshape.fill",
                category: .help,
                aliases: ["preferences", "options", "configure"],
                action: onOpenSettings
            ),
        ]
    }

    private func directIntentCommands(query: String) -> [Command] {
        guard let app = bestMatchingApp(in: query) else { return [] }
        var result: [Command] = []

        if let percent = IntentSearch.percentage(in: query) {
            result.append(Command(
                id: "direct-volume-\(app.id)-\(percent)",
                title: "Set \(app.name) to \(percent)%",
                subtitle: percent > 100
                    ? "Louder than this app can go on its own"
                    : "Change only this app",
                symbol: "slider.horizontal.3",
                category: .controls,
                aliases: [query],
                action: { setEffectivePercent(percent, for: app) }
            ))
        }

        if IntentSearch.containsIntent(query, any: ["mute", "silence"]) {
            result.append(Command(
                id: "direct-mute-\(app.id)",
                title: "Mute \(app.name)",
                subtitle: "Silence only this app",
                symbol: "speaker.slash.fill",
                category: .controls,
                aliases: [query],
                action: { audioEngine.setMute(for: app, to: true) }
            ))
        } else if IntentSearch.containsIntent(query, any: ["unmute", "sound on"]) {
            result.append(Command(
                id: "direct-unmute-\(app.id)",
                title: "Unmute \(app.name)",
                subtitle: "Bring this app back",
                symbol: "speaker.wave.2.fill",
                category: .controls,
                aliases: [query],
                action: { audioEngine.setMute(for: app, to: false) }
            ))
        }

        return result
    }

    private func bestMatchingApp(in query: String) -> AudioApp? {
        audioEngine.apps.max { lhs, rhs in
            IntentSearch.score(query: query, fields: [lhs.name, lhs.bundleID ?? ""])
                < IntentSearch.score(query: query, fields: [rhs.name, rhs.bundleID ?? ""])
        }.flatMap { app in
            IntentSearch.score(query: query, fields: [app.name, app.bundleID ?? ""]) > 0 ? app : nil
        }
    }
}
