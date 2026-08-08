// Melo/Views/Settings/Tabs/AudioUnitsTab.swift
// Audio Unit hosting additions for Melo, based on the GPL-3.0 FineTune codebase.

import AudioToolbox
import AVFAudio
import CoreAudioKit
import SwiftUI

@MainActor
struct AudioUnitsTab: View {
    @Bindable var host: AudioUnitHost
    @Bindable var audioEngine: AudioEngine

    @State private var selectedProfileID = AudioUnitHost.systemProfileID
    @State private var showsBrowser = false
    @State private var editingSlot: AudioUnitSlot?

    private var profiles: [AudioUnitProfile] {
        host.profiles.values.sorted {
            if $0.id == AudioUnitHost.systemProfileID { return true }
            if $1.id == AudioUnitHost.systemProfileID { return false }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var slots: [AudioUnitSlot] { host.slots(for: selectedProfileID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Group {
                if slots.isEmpty {
                    emptyState
                } else {
                    slotList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }

            footer
        }
        .padding(20)
        .onAppear(perform: synchronizeProfiles)
        .onChange(of: audioEngine.displayableApps.map(\.id)) { _, _ in
            synchronizeProfiles()
        }
        .sheet(isPresented: $showsBrowser) {
            AudioUnitBrowserView(host: host, profileID: selectedProfileID)
        }
        .sheet(item: $editingSlot) { slot in
            AudioUnitEditorSheet(host: host, slot: slot, profileID: selectedProfileID)
        }
        .alert(
            "Audio Unit Error",
            isPresented: Binding(
                get: { host.lastError != nil },
                set: { if !$0 { host.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { host.lastError = nil }
        } message: {
            Text(host.lastError ?? "This plug-in couldn’t be loaded.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Audio Unit Effects")
                    .font(.system(size: 18, weight: .semibold))
                Text("Each app has its own ordered plug-in chain.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Audio source", selection: $selectedProfileID) {
                ForEach(profiles) { profile in
                    Text(profile.displayName).tag(profile.id)
                }
            }
            .labelsHidden()
            .frame(width: 190)

            Button {
                showsBrowser = true
            } label: {
                Label("Add Effect", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Audio Units", systemImage: "waveform.badge.plus")
        } description: {
            Text("Add an effect to shape \(host.profiles[selectedProfileID]?.displayName ?? "this audio source").")
        } actions: {
            Button("Browse Audio Units") { showsBrowser = true }
        }
    }

    private var slotList: some View {
        List {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                AudioUnitSlotRow(
                    slot: slot,
                    canMoveUp: index > 0,
                    canMoveDown: index < slots.count - 1,
                    onEnabled: { host.setEnabled($0, slotID: slot.id, in: selectedProfileID) },
                    onBypass: {
                        host.setBypassed(!slot.isBypassed, slotID: slot.id, in: selectedProfileID)
                    },
                    onEdit: { editingSlot = slot },
                    onMoveUp: { host.move(slotID: slot.id, by: -1, in: selectedProfileID) },
                    onMoveDown: { host.move(slotID: slot.id, by: 1, in: selectedProfileID) },
                    onRemove: { host.remove(slotID: slot.id, from: selectedProfileID) }
                )
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.secondary)
            Text("Melo isolates Audio Units in another process when the plug-in supports it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                host.refreshCatalog()
            } label: {
                Label(host.isScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(host.isScanning)
        }
    }

    private func synchronizeProfiles() {
        for app in audioEngine.displayableApps {
            host.ensureProfile(id: app.id, displayName: app.displayName)
        }
        if host.profiles[selectedProfileID] == nil {
            selectedProfileID = AudioUnitHost.systemProfileID
        }
    }
}

@MainActor
private struct AudioUnitSlotRow: View {
    let slot: AudioUnitSlot
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEnabled: (Bool) -> Void
    let onBypass: () -> Void
    let onEdit: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Toggle("", isOn: Binding(get: { slot.isEnabled }, set: { onEnabled($0) }))
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(slot.manufacturerName) · \(slot.component.compactName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onBypass) {
                Image(systemName: slot.isBypassed ? "pause.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(slot.isBypassed ? .orange : .green)
            }
            .buttonStyle(.meloHover)
            .help(slot.isBypassed ? "Enable processing" : "Bypass without removing")
            .disabled(!slot.isEnabled)

            Button(action: onEdit) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Open Audio Unit controls")

            Menu {
                Button("Open Controls…", action: onEdit)
                Divider()
                Button("Move Up", systemImage: "arrow.up", action: onMoveUp)
                    .disabled(!canMoveUp)
                Button("Move Down", systemImage: "arrow.down", action: onMoveDown)
                    .disabled(!canMoveDown)
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 5)
        .opacity(slot.isEnabled ? 1 : 0.55)
    }
}

@MainActor
private struct AudioUnitBrowserView: View {
    @Bindable var host: AudioUnitHost
    @Environment(\.dismiss) private var dismiss
    let profileID: String
    @State private var search = ""

    private var filtered: [AudioUnitCatalogItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return host.catalog }
        return host.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.manufacturerName.localizedCaseInsensitiveContains(query)
                || $0.typeName.localizedCaseInsensitiveContains(query)
                || $0.component.compactName.localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [(String, [AudioUnitCatalogItem])] {
        Dictionary(grouping: filtered, by: \.manufacturerName)
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add an Audio Unit")
                        .font(.title2.weight(.semibold))
                    Text("Effects and music effects installed on this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            if host.catalog.isEmpty && !host.isScanning {
                ContentUnavailableView(
                    "No Audio Units Found",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Install a compatible Audio Unit, then rescan.")
                )
            } else {
                List {
                    ForEach(groups, id: \.0) { manufacturer, items in
                        Section(manufacturer) {
                            ForEach(items) { item in
                                Button {
                                    host.add(item, to: profileID)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: "waveform.path")
                                            .font(.system(size: 17))
                                            .foregroundStyle(.tint)
                                            .frame(width: 26)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .foregroundStyle(.primary)
                                            Text("\(item.typeName) · \(item.component.compactName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.meloHover)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .searchable(text: $search, prompt: "Name or manufacturer")
            }
        }
        .frame(width: 560, height: 520)
    }
}

@MainActor
private struct AudioUnitEditorSheet: View {
    @Bindable var host: AudioUnitHost
    @Environment(\.dismiss) private var dismiss
    let slot: AudioUnitSlot
    let profileID: String

    @State private var audioUnit: AVAudioUnit?
    @State private var customViewController: NSViewController?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.name)
                        .font(.headline)
                    Text(slot.manufacturerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Changes are applied to live audio when you choose Done.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            Group {
                if loading {
                    ProgressView("Loading Audio Unit…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn’t Open Controls",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if let customViewController {
                    AudioUnitViewControllerHost(viewController: customViewController)
                } else if let audioUnit {
                    GenericAudioUnitParameterView(audioUnit: audioUnit.auAudioUnit)
                }
            }
            .frame(minWidth: 620, minHeight: 420)
        }
        .task(id: slot.id) {
            do {
                let unit = try await host.loadEditorUnit(for: slot.id)
                audioUnit = unit
                customViewController = await unit.auAudioUnit.requestViewController()
                loading = false
            } catch {
                errorMessage = error.localizedDescription
                loading = false
            }
        }
        .onDisappear {
            host.captureState(slotID: slot.id, in: profileID)
        }
    }
}

@MainActor
private struct AudioUnitViewControllerHost: NSViewControllerRepresentable {
    let viewController: NSViewController

    func makeNSViewController(context: Context) -> NSViewController { viewController }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

@MainActor
private struct GenericAudioUnitParameterView: View {
    let audioUnit: AUAudioUnit
    @State private var search = ""

    private var parameters: [AUParameter] {
        let all = audioUnit.parameterTree?.allParameters ?? []
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter parameters", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.meloHover)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35))

            if parameters.isEmpty {
                ContentUnavailableView(
                    "No Editable Parameters",
                    systemImage: "slider.horizontal.below.square.filled.and.square"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(parameters, id: \.address) { parameter in
                            AudioUnitParameterRow(parameter: parameter)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct AudioUnitParameterRow: View {
    let parameter: AUParameter
    @State private var value: Double

    init(parameter: AUParameter) {
        self.parameter = parameter
        _value = State(initialValue: Double(parameter.value))
    }

    private var isWritable: Bool {
        parameter.flags.contains(.flag_IsWritable)
    }

    private var formattedValue: String {
        if let values = parameter.valueStrings {
            let index = Int((value - Double(parameter.minValue)).rounded())
            if values.indices.contains(index) { return values[index] }
        }
        let number = value.magnitude >= 100
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
        if let unit = parameter.unitName, !unit.isEmpty { return "\(number) \(unit)" }
        return number
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(parameter.displayName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(formattedValue)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: {
                        value = $0
                        parameter.value = AUValue($0)
                    }
                ),
                in: Double(parameter.minValue)...Double(parameter.maxValue)
            )
            .disabled(!isWritable || parameter.minValue >= parameter.maxValue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
