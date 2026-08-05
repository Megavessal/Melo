import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct EverydayTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var automationManager: ConsumerAutomationManager
    @Bindable var sleepTimer: SleepTimerManager

    @State private var showCreateScene = false
    @State private var showCreateAutomation = false
    @State private var showDiagnostics = false
    @State private var showFocusSetup = false
    @State private var statusMessage: String?
    @State private var compareA: UUID?
    @State private var compareB: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                intro
                scenesSection
                compareSection
                automationsSection
                focusAndShortcutsSection
                sleepTimerSection
                recentChangesSection
                helpSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showCreateScene) {
            CreateConsumerSceneSheet { name, symbol in
                let scene = audioEngine.saveCurrentConsumerScene(name: name, symbolName: symbol)
                compareA = compareA ?? scene.id
                statusMessage = "Saved \(scene.name)"
            }
        }
        .sheet(isPresented: $showCreateAutomation) {
            CreateConsumerAutomationSheet(
                scenes: settings.consumerScenes,
                apps: audioEngine.displayableApps,
                devices: audioEngine.outputDevices
            ) { automation in
                settings.setAutomation(automation)
                automationManager.checkNow()
                statusMessage = "Automation added"
            }
        }
        .sheet(isPresented: $showFocusSetup) {
            FocusSceneSetupView(openShortcuts: openShortcuts)
        }
        .onAppear {
            automationManager.start()
            seedCompareSelection()
        }
        .onChange(of: settings.consumerScenes.map(\.id)) { _, _ in
            seedCompareSelection()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Everyday")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("Save how everything sounds, switch setups in one click, and let Melo handle simple routines for you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            }
        }
    }

    private var scenesSection: some View {
        SettingsSection("Scenes") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save your whole setup")
                            .font(.system(size: 13, weight: .semibold))
                        Text("A Scene remembers app volumes, where sound plays, sound shaping, and effects.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import") { importScene() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Save Current") { showCreateScene = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                if settings.consumerScenes.isEmpty {
                    friendlyEmptyState(
                        symbol: "square.stack.3d.up",
                        title: "No Scenes yet",
                        message: "Set Melo how you like it, then choose Save Current."
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(settings.consumerScenes) { scene in
                            sceneCard(scene)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func sceneCard(_ scene: ConsumerScene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: scene.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(sceneSummary(scene))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Menu {
                    Button("Update with Current Setup", systemImage: "arrow.triangle.2.circlepath") {
                        _ = audioEngine.updateConsumerScene(id: scene.id)
                        statusMessage = "Updated \(scene.name)"
                    }
                    Button("Share Scene…", systemImage: "square.and.arrow.up") {
                        exportScene(scene)
                    }
                    Divider()
                    Button(role: .destructive) {
                        settings.deleteScene(id: scene.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button {
                audioEngine.applyConsumerScene(scene)
                statusMessage = "Applied \(scene.name)"
            } label: {
                Label("Apply", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignTokens.Colors.glassFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var compareSection: some View {
        if settings.consumerScenes.count >= 2 {
            SettingsSection("Compare") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quickly switch between two Scenes to decide which sounds better.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        sceneComparePicker(title: "A", selection: $compareA)
                        sceneComparePicker(title: "B", selection: $compareB)
                    }

                    HStack(spacing: 10) {
                        Button("Listen to A") { applyComparedScene(compareA) }
                            .buttonStyle(.borderedProminent)
                        Button("Listen to B") { applyComparedScene(compareB) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(12)
            }
        }
    }

    private func sceneComparePicker(title: String, selection: Binding<UUID?>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.14)))
            Picker("Scene \(title)", selection: selection) {
                ForEach(settings.consumerScenes) { scene in
                    Text(scene.name).tag(Optional(scene.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(DesignTokens.Colors.recessedBackground))
    }

    private var automationsSection: some View {
        SettingsSection("Automations") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Let Melo switch Scenes for you")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Choose an app, a device, or a time. No scripting required.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Automation") { showCreateAutomation = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(settings.consumerScenes.isEmpty)
                }

                if settings.consumerScenes.isEmpty {
                    Text("Save a Scene before adding an automation.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if settings.consumerAutomations.isEmpty {
                    friendlyEmptyState(
                        symbol: "wand.and.stars",
                        title: "Nothing automatic yet",
                        message: "Example: use Movie Night when your TV connects."
                    )
                } else {
                    ForEach(settings.consumerAutomations) { automation in
                        automationRow(automation)
                    }
                }

                if let lastRun = automationManager.lastRunText {
                    Label(lastRun, systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func automationRow(_ automation: ConsumerAutomation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: automation.trigger.symbolName)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.trigger.title)
                    .font(.system(size: 12, weight: .medium))
                Text("Use \(settings.scene(id: automation.sceneID)?.name ?? "Missing Scene")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { automation.isEnabled },
                set: { enabled in
                    var copy = automation
                    copy.isEnabled = enabled
                    settings.setAutomation(copy)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Button(role: .destructive) {
                settings.deleteAutomation(id: automation.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete automation")
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(DesignTokens.Colors.recessedBackground))
    }

    private var focusAndShortcutsSection: some View {
        SettingsSection("Focus & Shortcuts") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Match a Scene to a Focus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("For example, use your Work Scene when Work Focus turns on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set Up…") { showFocusSetup = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
        }
    }

    private func openShortcuts() {
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.shortcuts")
            ?? URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
        workspace.open(url)
    }

    private var sleepTimerSection: some View {
        SettingsSection("Sleep Timer") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fade Out, Then Mute")
                            .font(.system(size: 13, weight: .semibold))
                        Text(sleepTimer.isActive ? sleepTimer.statusText : "Choose how long you want to keep listening.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if sleepTimer.isActive {
                        Button("Cancel") { sleepTimer.cancel() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in
                        Button("\(minutes) min") {
                            sleepTimer.start(minutes: minutes)
                            statusMessage = "Sleep timer started"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(12)
        }
    }

    private var recentChangesSection: some View {
        SettingsSection("Recent Changes") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent changes")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Melo keeps a short, private history during this session.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Undo Last") {
                        audioEngine.undoLastConsumerChange()
                        statusMessage = "Last change undone"
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!audioEngine.consumerUndoManager.canUndo)
                }

                if audioEngine.consumerUndoManager.entries.isEmpty {
                    Text("No recent changes to undo.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(audioEngine.consumerUndoManager.entries.prefix(5)) { entry in
                        HStack {
                            Image(systemName: "arrow.uturn.backward.circle")
                                .foregroundStyle(.secondary)
                            Text(entry.label)
                                .font(.system(size: 11))
                            Spacer()
                            Text(entry.date, style: .time)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var helpSection: some View {
        SettingsSection("Audio Help") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio isn’t working")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Melo can refresh its audio connections without erasing your settings.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Fix Audio") {
                        audioEngine.repairConsumerAudio()
                        statusMessage = "Audio connections refreshed"
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                DisclosureGroup("Show Details", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(audioEngine.consumerDiagnosticText)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.Colors.recessedBackground))
                        Button("Copy Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(audioEngine.consumerDiagnosticText, forType: .string)
                            statusMessage = "Details copied"
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 11, weight: .medium))
            }
            .padding(12)
        }
    }

    private func friendlyEmptyState(symbol: String, title: String, message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(DesignTokens.Colors.recessedBackground))
    }

    private func sceneSummary(_ scene: ConsumerScene) -> String {
        let appText = scene.appCount == 1 ? "1 app" : "\(scene.appCount) apps"
        let effects = scene.audioUnitProfiles.reduce(0) { $0 + $1.slots.count }
        if effects > 0 {
            return "\(appText) · \(effects) saved effect\(effects == 1 ? "" : "s")"
        }
        return appText
    }

    private func seedCompareSelection() {
        let ids = settings.consumerScenes.map(\.id)
        if compareA == nil || !ids.contains(compareA!) { compareA = ids.first }
        if compareB == nil || !ids.contains(compareB!) { compareB = ids.dropFirst().first }
        if compareA == compareB { compareB = ids.first { $0 != compareA } }
    }

    private func applyComparedScene(_ id: UUID?) {
        guard let id, let scene = settings.scene(id: id) else { return }
        audioEngine.applyConsumerScene(scene)
        statusMessage = "Listening to \(scene.name)"
    }

    private func exportScene(_ scene: ConsumerScene) {
        let panel = NSSavePanel()
        panel.title = "Share Melo Scene"
        panel.nameFieldStringValue = scene.name.replacingOccurrences(of: "/", with: "-") + ".melo-scene.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(scene).write(to: url, options: .atomic)
            statusMessage = "Scene exported"
        } catch {
            statusMessage = "Couldn’t export the Scene"
        }
    }

    private func importScene() {
        let panel = NSOpenPanel()
        panel.title = "Import Melo Scene"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let scene = try decoder.decode(ConsumerScene.self, from: Data(contentsOf: url))
            let imported = settings.importScene(scene)
            statusMessage = "Imported \(imported.name)"
        } catch {
            statusMessage = "That file isn’t a valid Melo Scene"
        }
    }
}

private struct CreateConsumerSceneSheet: View {
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "slider.horizontal.3"

    private let symbols = [
        "slider.horizontal.3", "film.fill", "gamecontroller.fill", "moon.stars.fill",
        "music.note", "person.wave.2.fill", "briefcase.fill", "headphones"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Save a Scene")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Give this setup a familiar name, such as Movie Night or Work.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Scene name", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Choose an icon")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                ForEach(symbols, id: \.self) { item in
                    Button {
                        symbol = item
                    } label: {
                        Image(systemName: item)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(symbol == item ? Color.accentColor.opacity(0.22) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Scene") {
                    onSave(name, symbol)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct CreateConsumerAutomationSheet: View {
    private enum TriggerChoice: String, CaseIterable, Identifiable {
        case app = "App Opens"
        case device = "Device Connects"
        case time = "Time of Day"
        var id: String { rawValue }
    }

    let scenes: [ConsumerScene]
    let apps: [DisplayableApp]
    let devices: [AudioDevice]
    let onSave: (ConsumerAutomation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sceneID: UUID?
    @State private var triggerChoice: TriggerChoice = .app
    @State private var appID: String?
    @State private var deviceUID: String?
    @State private var time = Calendar.current.date(from: DateComponents(hour: 21, minute: 0)) ?? .now

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Automation")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Choose what happens and which Scene Melo should use.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Picker("When", selection: $triggerChoice) {
                ForEach(TriggerChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            triggerEditor

            Picker("Use Scene", selection: $sceneID) {
                ForEach(scenes) { scene in
                    Text(scene.name).tag(Optional(scene.id))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard let sceneID, let trigger = makeTrigger() else { return }
                    onSave(ConsumerAutomation(sceneID: sceneID, trigger: trigger))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(sceneID == nil || makeTrigger() == nil)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            sceneID = sceneID ?? scenes.first?.id
            appID = appID ?? apps.first?.id
            deviceUID = deviceUID ?? devices.first?.uid
        }
    }

    @ViewBuilder
    private var triggerEditor: some View {
        switch triggerChoice {
        case .app:
            Picker("App", selection: $appID) {
                ForEach(apps, id: \.id) { app in
                    Text(app.displayName).tag(Optional(app.id))
                }
            }
        case .device:
            Picker("Speakers or Headphones", selection: $deviceUID) {
                ForEach(devices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
        case .time:
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
        }
    }

    private func makeTrigger() -> ConsumerAutomationTrigger? {
        switch triggerChoice {
        case .app:
            guard let appID, let app = apps.first(where: { $0.id == appID }) else { return nil }
            return .appOpens(identifier: appID, displayName: app.displayName)
        case .device:
            guard let deviceUID, let device = devices.first(where: { $0.uid == deviceUID }) else { return nil }
            return .deviceConnects(uid: deviceUID, displayName: device.name)
        case .time:
            let components = Calendar.current.dateComponents([.hour, .minute], from: time)
            return .daily(hour: components.hour ?? 21, minute: components.minute ?? 0)
        }
    }
}


@MainActor
private struct FocusSceneSetupView: View {
    let openShortcuts: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use Melo with Focus")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Your Mac handles the Focus trigger. Melo supplies the Scene you want to use.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            setupStep(1, "Open Shortcuts and choose Automation.")
            setupStep(2, "Choose the Focus and whether it is turning on or off.")
            setupStep(3, "Add Melo’s Use Scene action, then choose your Scene.")

            Text("This keeps Focus names and schedules private inside macOS. Melo only receives the Scene action when it runs.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not Now") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Open Shortcuts") {
                    openShortcuts()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.tint.opacity(0.14)))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 3)
        }
    }
}
