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

    @State private var searchText: String
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    /// `initialQuery` exists for the same reason `SettingsGuideView` has one:
    /// without it nothing outside this struct can put a query in the box, so no
    /// frame can show a single row this palette produces. `searchText` is
    /// `@State private` and every step from a query to rows —
    /// `filteredCommands`, `directIntentCommands`, `guideCommands` — is
    /// `private`, which left the whole search half of this view unrenderable and
    /// therefore unchecked: "Set Music to 200%" has never been seen as a row by
    /// anyone. Seeded, the palette renders its results on appear and a snapshot
    /// scene can read them.
    init(
        audioEngine: AudioEngine,
        sparkleUpdateController: SparkleUpdateController,
        onOpenSettings: @escaping () -> Void,
        onClose: @escaping () -> Void,
        initialQuery: String = ""
    ) {
        self.audioEngine = audioEngine
        self.sparkleUpdateController = sparkleUpdateController
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        _searchText = State(initialValue: initialQuery)
    }

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
            Text("Try “mute Music,” “set Spotify to 200%,” “send Music to my headphones,” “microphone,” “fix audio,” or “launch at login.”")
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
        result.append(contentsOf: guideCommands(query: query))

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
    /// Three commands for one app, not one command for three apps:
    /// `commands(for:)` emits mute / raise / lower, and every app contributing
    /// three rows is what buried the answer in its own results when this list
    /// was longer.
    ///
    /// The app chosen is the first one that is actually making sound, falling
    /// back to the first row of the popup. `displayableApps` sorts pinned apps
    /// first, so taking its head would offer to mute an app that is closed —
    /// true, persisted, and not what anyone opened this to do.
    /// The app the pre-typing list features: the first one making sound, and
    /// failing that the first row of the popup.
    ///
    /// A rule of its own rather than a line inside `suggestedCommands`, because
    /// the state that decides whether this list is any good — a Mac with nothing
    /// playing — is the one state the render harness cannot stage:
    /// `audioEngine.apps` is `processMonitor.activeApps` behind `private(set)`,
    /// and the harness receives an engine already built. `verify-volume-and-eq`
    /// executes this function against that state instead.
    ///
    /// The `??` is the whole point. Without it a quiet Mac gets no per-app rows
    /// at all — which is exactly what the `audioEngine.apps` version this
    /// replaced shipped, and what the check that was supposed to forbid it
    /// stayed green through.
    nonisolated static func featuredApp<App>(
        in apps: [App],
        isActive: (App) -> Bool
    ) -> App? {
        apps.first(where: isActive) ?? apps.first
    }

    private var suggestedCommands: [Command] {
        let apps = audioEngine.displayableApps
        let featured = Self.featuredApp(in: apps, isActive: \.isActive)

        var result: [Command] = []
        if let featured { result.append(contentsOf: commands(for: featured)) }
        result.append(contentsOf: sceneCommands.prefix(4))
        result.append(contentsOf: deviceCommands.prefix(3))
        result.append(contentsOf: generalCommands)
        return result
    }

    private var commandsForSearch: [Command] {
        sceneCommands
            + deviceCommands
            + inputDeviceCommands
            + appCommands
            + hiddenAppCommands
            + generalCommands
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

    /// Output devices in the order and the membership the popup shows them:
    /// user priority order, minus the ones the user hid. Listing raw
    /// `outputDevices` offered a device the user had deliberately taken out of
    /// the popup, and put `suggestedCommands`' `prefix(3)` on an arbitrary
    /// three rather than the three at the top of their own list. The current
    /// output stays listed even when hidden, matching `updateSortedDevices`.
    private var visibleOutputDevices: [AudioDevice] {
        let currentUID = audioEngine.deviceVolumeMonitor.defaultDeviceUID
        let filtered = audioEngine.prioritySortedOutputDevices.filter {
            $0.uid == currentUID || !audioEngine.settingsManager.isOutputDeviceHidden($0.uid)
        }
        return filtered.isEmpty ? audioEngine.prioritySortedOutputDevices : filtered
    }

    private var visibleInputDevices: [AudioDevice] {
        let currentUID = audioEngine.deviceVolumeMonitor.defaultInputDeviceUID
        let filtered = audioEngine.prioritySortedInputDevices.filter {
            $0.uid == currentUID || !audioEngine.settingsManager.isInputDeviceHidden($0.uid)
        }
        return filtered.isEmpty ? audioEngine.prioritySortedInputDevices : filtered
    }

    private var deviceCommands: [Command] {
        visibleOutputDevices.map { device in
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

    /// The popup has an Input tab and Melo can lock a microphone; the palette
    /// could not reach either, so "microphone" and every mic's own name found
    /// nothing. Search-only rather than suggested: choosing a microphone is a
    /// deliberate act, and adding one row per input to the pre-typing list would
    /// push scenes and Settings off the first screen for everyone.
    private var inputDeviceCommands: [Command] {
        visibleInputDevices.map { device in
            Command(
                id: "input-\(device.uid)",
                title: "Use \(device.name) as the microphone",
                subtitle: "Melo keeps this input selected",
                symbol: "mic.fill",
                category: .devices,
                aliases: ["microphone", "mic", "input", "record", "switch microphone"],
                action: { audioEngine.setLockedInputDevice(device) }
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

    private func effectivePercent(for identifier: String) -> Int {
        let gain = audioEngine.getVolumeForInactive(identifier: identifier)
            * audioEngine.getBoostForInactive(identifier: identifier).rawValue
        return Int((Double(max(0, min(4, gain))) * 100).rounded())
    }

    /// Writes a percent back through Melo's persisted base-volume + boost pair,
    /// using the same decomposition the slider uses so the two cannot drift.
    private func setEffectivePercent(_ percent: Int, for identifier: String) {
        let clamped = max(0, min(Self.maximumPercent, percent))
        let components = VolumeMapping.components(forEffectiveGain: Float(clamped) / 100)
        audioEngine.setBoostForInactive(identifier: identifier, to: components.boost)
        audioEngine.setVolumeForInactive(identifier: identifier, to: components.volume)
    }

    // MARK: - Apps
    //
    // Every app the popup lists, addressed the way the popup addresses it.
    //
    // This iterated `audioEngine.apps` — Core Audio's *currently capturable*
    // processes. The popup lists `displayableApps`: those, plus apps that are
    // open but silent, plus apps the user pinned so their controls stay put. So
    // an app sitting in plain sight in the popup, not making a sound, had no
    // palette commands at all, and "Mute Music" was unreachable from ⌘K exactly
    // when Music was quiet — which is most of the time, and is what the owner
    // reported as the palette not finding what it can do.
    //
    // A pinned app has no live `AudioApp` to hand to `setMute(for:)`, so the
    // commands are keyed on the persistence identifier and go through the
    // `…ForInactive` family instead. That is not a fallback for the quiet case:
    // every one of those methods starts at `AudioEngine.retainedTapApp(for:)`
    // and routes to the live tap when there is one, so a single call is correct
    // for a playing app, a silent-but-open app, and a closed pinned app alike.
    // Rejected: branching on `DisplayableApp`'s case and keeping the `AudioApp`
    // calls for `.active` — two paths for one action, where only one of them can
    // be exercised by any given test, and the engine has already made the choice
    // correctly one layer down. Also rejected: keying on the settings identifier
    // but writing through `settingsManager` directly, which skips the undo
    // record that makes "Undo Last Change" able to reach these.
    private var appCommands: [Command] {
        audioEngine.displayableApps.flatMap(commands(for:))
    }

    private func commands(for app: DisplayableApp) -> [Command] {
        let identifier = app.id
        let name = app.displayName
        let currentPercent = effectivePercent(for: identifier)
        let raisedPercent = min(Self.maximumPercent, currentPercent + 10)
        let loweredPercent = max(0, currentPercent - 10)
        let muted = audioEngine.getMuteForInactive(identifier: identifier)
        // Silencing something that is already silent needs to say what it did,
        // or the palette reads as having done nothing.
        let takesEffectLater = !app.isActive

        return [
            Command(
                id: "app-mute-\(identifier)",
                title: muted ? "Unmute \(name)" : "Mute \(name)",
                subtitle: takesEffectLater
                    ? (muted ? "Lets it be heard next time it plays" : "Stays silent whenever it plays")
                    : (muted ? "Bring this app back" : "Silence only this app"),
                symbol: muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                category: .controls,
                aliases: ["silence \(name)", "turn off \(name)", "sound on \(name)"],
                action: { audioEngine.setMuteForInactive(identifier: identifier, to: !muted) }
            ),
            Command(
                id: "app-up-\(identifier)",
                title: "Raise \(name)",
                // The row it will change shows a number; so does this, and
                // the number it promises is the number the action writes.
                subtitle: raisedPercent == currentPercent
                    ? "Already at \(currentPercent)%, as loud as Melo goes"
                    : "Now \(currentPercent)% — this makes it \(raisedPercent)%",
                symbol: "speaker.plus.fill",
                category: .controls,
                aliases: ["louder", "turn up", "increase"],
                action: { setEffectivePercent(raisedPercent, for: identifier) }
            ),
            Command(
                id: "app-down-\(identifier)",
                title: "Lower \(name)",
                subtitle: loweredPercent == currentPercent
                    ? "Already at 0%"
                    : "Now \(currentPercent)% — this makes it \(loweredPercent)%",
                symbol: "speaker.minus.fill",
                category: .controls,
                aliases: ["quieter", "turn down", "decrease"],
                action: { setEffectivePercent(loweredPercent, for: identifier) }
            ),
        ]
    }

    /// A hidden app is absent from `displayableApps` by design, so nothing in
    /// the palette could name one and the only way back was the Hidden Apps
    /// disclosure in the popup — which the person searching for the app by name
    /// has, by definition, not found.
    private var hiddenAppCommands: [Command] {
        audioEngine.settingsManager.getIgnoredAppInfo().map { info in
            Command(
                id: "app-unhide-\(info.persistenceIdentifier)",
                title: "Show \(info.displayName) again",
                subtitle: "Put it back in Melo’s list",
                symbol: "eye.fill",
                category: .controls,
                aliases: ["unhide \(info.displayName)", "hidden", "bring back", "restore app"],
                action: { audioEngine.unignoreApp(info.persistenceIdentifier) }
            )
        }
    }

    /// Everything Melo can be *set to* that has no command of its own — roughly
    /// a hundred catalogued settings, none of which the palette could reach.
    /// "launch at login", "dark mode", "sleep timer", "share a scene" and
    /// "battery" all returned "No close match" from a search box that had just
    /// asked what you would like Melo to do, while the Guide answered every one
    /// of them.
    ///
    /// Selected with the Guide's own weighting so the two agree about what a
    /// query means, then capped hard: these are directions to a setting, not the
    /// setting itself, and a palette that answers "mute music" with three help
    /// topics has made itself worse. `IntentSearch.rank`'s floor drops them
    /// outright whenever a real action scores well.
    private func guideCommands(query: String) -> [Command] {
        IntentSearch.rank(SettingsGuideEntry.all, limit: 3) { $0.searchScore(query) }
            .map { entry in
                Command(
                    id: "guide-\(entry.id)",
                    title: entry.title,
                    // The location line is the useful half: it names where the
                    // control is, which is the thing the searcher lacked.
                    subtitle: entry.location ?? entry.summary,
                    symbol: "book.fill",
                    category: .help,
                    aliases: entry.keywords,
                    action: {
                        onOpenSettings()
                        Task { @MainActor in
                            await Task.yield()
                            // The Guide's search box takes an `initialQuery`;
                            // `SettingsRootView`'s observer currently discards
                            // this object and opens the Guide unsearched, so
                            // until it reads it the row lands the reader on the
                            // Guide rather than on the entry.
                            NotificationCenter.default.post(
                                name: .meloOpenGuide,
                                object: entry.title
                            )
                        }
                    }
                )
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
        var result: [Command] = []
        let app = bestMatchingApp(in: query)
        // Resolved once: this runs on every keystroke and the answer is used by
        // both the routing command and the device commands below.
        let namedDevice = bestMatchingOutputDevice(in: query)
        let percent = IntentSearch.percentage(in: query)
        let wantsMute = IntentSearch.containsIntent(query, any: ["mute", "silence"])
        let wantsUnmute = IntentSearch.containsIntent(query, any: ["unmute", "sound on"])

        if let app {
            let identifier = app.id
            let name = app.displayName

            if let percent {
                result.append(Command(
                    id: "direct-volume-\(identifier)-\(percent)",
                    title: "Set \(name) to \(percent)%",
                    subtitle: percent > 100
                        ? "Louder than this app can go on its own"
                        : "Change only this app",
                    symbol: "slider.horizontal.3",
                    category: .controls,
                    aliases: [query],
                    action: { setEffectivePercent(percent, for: identifier) }
                ))
            }

            // Guarded on the current state, like the device rows below: a
            // "Mute Music" row offered for an already-muted Music runs, closes
            // the palette, and changes nothing, which is the dead-button
            // signature. The `commands(for:)` row alongside it already flips to
            // "Unmute Music", so the useful command is never the one withheld.
            let isMuted = audioEngine.getMuteForInactive(identifier: identifier)

            if wantsMute && !isMuted {
                result.append(Command(
                    id: "direct-mute-\(identifier)",
                    title: "Mute \(name)",
                    subtitle: "Silence only this app",
                    symbol: "speaker.slash.fill",
                    category: .controls,
                    aliases: [query],
                    action: { audioEngine.setMuteForInactive(identifier: identifier, to: true) }
                ))
            } else if wantsUnmute && isMuted {
                result.append(Command(
                    id: "direct-unmute-\(identifier)",
                    title: "Unmute \(name)",
                    subtitle: "Bring this app back",
                    symbol: "speaker.wave.2.fill",
                    category: .controls,
                    aliases: [query],
                    action: { audioEngine.setMuteForInactive(identifier: identifier, to: false) }
                ))
            }

            // Per-app routing is in the popup and in Shortcuts
            // (`SendMeloAppToDeviceIntent`) and was in the palette nowhere, so
            // "send Spotify to my headphones" — one of the few things Melo does
            // that nothing else on the Mac does — found nothing. Offered only
            // when the query names both, because naming both is the request.
            if let device = namedDevice {
                result.append(Command(
                    id: "direct-route-\(identifier)-\(device.uid)",
                    title: "Send \(name) to \(device.name)",
                    subtitle: "Everything else keeps playing where it is",
                    symbol: "arrow.turn.down.right",
                    category: .controls,
                    aliases: [query],
                    action: {
                        audioEngine.setDeviceRoutingForInactive(
                            identifier: identifier,
                            deviceUID: device.uid
                        )
                    }
                ))
            }

            // The only way to undo a per-app route, and it had no words of its
            // own anywhere outside the popup's device picker.
            if !audioEngine.isFollowingDefaultForInactive(identifier: identifier),
               IntentSearch.containsIntent(query, any: ["follow", "default", "system", "everything"]) {
                result.append(Command(
                    id: "direct-follow-\(identifier)",
                    title: "Let \(name) follow the main output",
                    subtitle: "Stops pinning it to one set of speakers",
                    symbol: "arrow.uturn.backward.circle",
                    category: .controls,
                    aliases: [query],
                    action: {
                        audioEngine.setDeviceRoutingForInactive(
                            identifier: identifier,
                            deviceUID: nil
                        )
                    }
                ))
            }
        }

        // Devices had exactly one command — switch to it. Their volume and mute
        // are in the popup and behind the arrow keys, and "turn down the
        // speakers" found nothing. A device's own volume is a 0–100% scalar, not
        // Melo's 0–400% per-app gain, so a typed 200 is answered for the app and
        // declined for the speakers rather than quietly clamped.
        if let device = namedDevice {
            let isMuted = audioEngine.deviceVolumeMonitor.muteStates[device.id] ?? false

            if let percent, percent <= 100 {
                result.append(Command(
                    id: "direct-device-volume-\(device.uid)-\(percent)",
                    title: "Set \(device.name) to \(percent)%",
                    subtitle: "Changes this output for everything",
                    symbol: "slider.horizontal.3",
                    category: .devices,
                    aliases: [query],
                    action: {
                        audioEngine.setOutputDeviceVolume(
                            for: device.id,
                            to: Float(percent) / 100
                        )
                    }
                ))
            }

            if wantsMute && !isMuted {
                result.append(Command(
                    id: "direct-device-mute-\(device.uid)",
                    title: "Mute \(device.name)",
                    subtitle: "Silences everything playing there",
                    symbol: "speaker.slash.fill",
                    category: .devices,
                    aliases: [query],
                    action: { audioEngine.setOutputDeviceMute(for: device.id, to: true) }
                ))
            } else if wantsUnmute && isMuted {
                result.append(Command(
                    id: "direct-device-unmute-\(device.uid)",
                    title: "Unmute \(device.name)",
                    subtitle: "Sound comes back here",
                    symbol: "speaker.wave.2.fill",
                    category: .devices,
                    aliases: [query],
                    action: { audioEngine.setOutputDeviceMute(for: device.id, to: false) }
                ))
            }
        }

        return result
    }

    // MARK: - Naming a thing in a sentence

    // `IntentSearch.mention` rather than `IntentSearch.score`: score answers
    // "how good a result is this for that query" and gates on the result
    // accounting for half of it, which an app name in a four-word sentence never
    // does. Measured before the change: "set spotify to 200%" scored Spotify at
    // 0 and produced no command, while "spotify to 200%" worked — the same
    // request, one filler word apart.

    private func bestMatchingApp(in query: String) -> DisplayableApp? {
        audioEngine.displayableApps
            .map { (app: $0, score: mentionScore(of: $0, in: query)) }
            .filter { $0.score > 0 }
            .max { $0.score < $1.score }?
            .app
    }

    /// The persistence identifier is matched as well as the name because it
    /// carries the bundle ID, which is how someone typing "vscode" reaches an
    /// app whose display name is "Code".
    private func mentionScore(of app: DisplayableApp, in query: String) -> Int {
        max(
            IntentSearch.mention(of: app.displayName, in: query),
            IntentSearch.mention(of: app.id, in: query)
        )
    }

    private func bestMatchingOutputDevice(in query: String) -> AudioDevice? {
        visibleOutputDevices
            .map { (device: $0, score: IntentSearch.mention(of: $0.name, in: query)) }
            .filter { $0.score > 0 }
            .max { $0.score < $1.score }?
            .device
    }
}
