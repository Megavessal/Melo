// Melo/Editor/Export/ExportSheet.swift
//
// Choosing a format and where it goes.
//
// Six formats macOS writes natively, and two — MP3 and Opus — that need an
// `ffmpeg` most people do not have. Those two are in the list with an honest
// state rather than hidden, because a user who cannot find MP3 concludes Melo
// cannot do it.

import AppKit
import SwiftUI

// MARK: - The sheet

@MainActor
struct ExportSheet: View {

    @ObservedObject private var store: EditorStore
    @Binding private var isPresented: Bool
    private let initialFormat: AudioFormatKind?

    init(store: EditorStore, isPresented: Binding<Bool>) {
        self.init(store: store, isPresented: isPresented, initialFormat: nil)
    }

    private init(
        store: EditorStore,
        isPresented: Binding<Bool>,
        initialFormat: AudioFormatKind?
    ) {
        _store = ObservedObject(wrappedValue: store)
        _isPresented = isPresented
        self.initialFormat = initialFormat
    }

    var body: some View {
        if let document = store.document {
            ExportSheetContent(
                document: document,
                store: store,
                isPresented: $isPresented,
                initialFormat: initialFormat
            )
        } else {
            VStack(spacing: DesignTokens.Spacing.md) {
                Text("Nothing to save yet.")
                    .font(DesignTokens.Typography.Scale.title3())
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DesignTokens.Spacing.xxl)
            .frame(width: 320)
        }
    }

    #if MELO_DEV
    /// Snapshot seam: starts the sheet on a chosen format, so the frame that
    /// has to show the missing-`ffmpeg` state can be rendered without a click.
    init(store: EditorStore, isPresented: Binding<Bool>, format: AudioFormatKind) {
        self.init(store: store, isPresented: isPresented, initialFormat: format)
    }
    #endif
}

// MARK: - Content

@MainActor
private struct ExportSheetContent: View {

    let document: EditorDocument
    @ObservedObject var store: EditorStore
    @Binding var isPresented: Bool

    @State private var format: AudioFormatKind
    @State private var sampleRate: Double?
    @State private var bitRateKbps: Int?
    @State private var channels: ChannelMode
    @State private var fileName: String
    @State private var toolLocations: [ExternalTool: URL] = [:]
    @State private var didLocateTools = false

    /// Remembered between exports, because "the same folder as last time" is
    /// what a second export nearly always wants.
    @AppStorage("melo.editor.export.folder") private var storedFolderPath = ""
    @AppStorage("melo.editor.export.reveal") private var revealWhenDone = true

    private static let sheetWidth: CGFloat = 540
    private static let formatColumns = [
        GridItem(.flexible(), spacing: DesignTokens.Spacing.sm),
        GridItem(.flexible(), spacing: DesignTokens.Spacing.sm)
    ]

    init(
        document: EditorDocument,
        store: EditorStore,
        isPresented: Binding<Bool>,
        initialFormat: AudioFormatKind?
    ) {
        self.document = document
        _store = ObservedObject(wrappedValue: store)
        _isPresented = isPresented

        // Default to the source's own format: "same as it came in" is what
        // most people want, and having to choose is friction.
        let preset = ExportPresets.sameAsSource(document.source)
        let chosen = initialFormat ?? preset.format
        _format = State(initialValue: chosen)
        _sampleRate = State(initialValue: preset.sampleRate)
        _bitRateKbps = State(initialValue: chosen.exportFacts.defaultBitRateKbps)
        _channels = State(initialValue: preset.channels)
        _fileName = State(initialValue: document.source.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            // What to make scrolls. What you are about to get does not.
            //
            // The first rendered frame of this sheet had the file name, the
            // folder and the size estimate all below the fold, which is the
            // one thing the brief says has to be visible: "show what the user
            // is actually about to get". Pinning them under the scroll view
            // costs a shorter format list and buys a sheet where pressing
            // Export is never a guess.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    presets
                    formats
                    options
                    themeAdoption
                }
                .padding(DesignTokens.Spacing.lg)
            }
            .scrollIndicators(.automatic)
            .frame(minHeight: 220, maxHeight: 372)

            Divider()

            naming
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.md)

            Divider()
            footer
        }
        .frame(width: Self.sheetWidth)
        .task {
            guard !didLocateTools else { return }
            didLocateTools = true
            locateTools()
        }
        // Someone reads "brew install ffmpeg", switches to Terminal, runs it,
        // and comes back. Coming back is the event. `ExternalToolLocator`
        // deliberately does not cache a miss for exactly this flow, so a
        // one-shot lookup at sheet-open would be the only thing left making
        // MP3 look impossible on a Mac that can now do it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            locateTools()
        }
        .onChange(of: format) { _, new in
            let facts = new.exportFacts
            if facts.supportsBitRate {
                if let current = bitRateKbps, facts.bitRateChoicesKbps.contains(current) { return }
                bitRateKbps = facts.defaultBitRateKbps
            } else {
                bitRateKbps = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Save it")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text("\(document.source.displayName) · \(document.source.formatDescription)")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.md)
    }

    // MARK: Presets

    private var presets: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Quick picks")

            ScrollView(.horizontal) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(ExportPresets.all(for: document.source)) { preset in
                        PresetChip(
                            preset: preset,
                            isSelected: matches(preset),
                            isAvailable: isAvailable(preset.format)
                        ) {
                            apply(preset)
                        }
                    }
                }
                .padding(.bottom, DesignTokens.Spacing.xs)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Formats

    private var formats: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Format")

            LazyVGrid(columns: Self.formatColumns, spacing: DesignTokens.Spacing.sm) {
                ForEach(AudioFormatKind.exportOrder, id: \.self) { kind in
                    FormatTile(
                        kind: kind,
                        isSelected: kind == format,
                        isAvailable: isAvailable(kind)
                    ) {
                        format = kind
                    }
                }
            }

            if let note = formatNote {
                FormatNote(note: note)
            }
        }
    }

    /// The one sentence a user needs before they press Export: what is missing
    /// and the command that fixes it, or the thing this format does to the
    /// sound that the others do not.
    private var formatNote: FormatNoteContent? {
        if let tool = format.requiresExternalTool, toolLocations[tool] == nil {
            return FormatNoteContent(
                symbol: "wrench.and.screwdriver",
                message: "\(format.displayName) needs \(tool.executableName), and this Mac doesn't have it.",
                command: tool.installHint
            )
        }
        if let caveat = format.exportFacts.caveat {
            return FormatNoteContent(symbol: "info.circle", message: caveat, command: nil)
        }
        return nil
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Settings")

            HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                LabelledControl(title: "Sample rate") {
                    if let fixed = format.exportFacts.fixedSampleRate {
                        FixedValue(text: EditorFormat.hertz(fixed))
                    } else {
                        ChoiceMenu(
                            title: "Sample rate",
                            choices: sampleRateChoices,
                            selectedID: sampleRate.map { String(Int($0)) } ?? "source",
                            width: 150
                        ) { choice in
                            sampleRate = choice.value
                        }
                    }
                }

                LabelledControl(title: "Channels") {
                    ChoiceMenu(
                        title: "Channels",
                        choices: channelChoices,
                        selectedID: channels.rawValue,
                        width: 150
                    ) { choice in
                        channels = choice.value
                    }
                }

                if format.exportFacts.supportsBitRate {
                    LabelledControl(title: "Bit rate") {
                        ChoiceMenu(
                            title: "Bit rate",
                            choices: bitRateChoices,
                            selectedID: String(bitRateKbps ?? format.exportFacts.defaultBitRateKbps ?? 0),
                            width: 120
                        ) { choice in
                            bitRateKbps = choice.value
                        }
                    }
                } else if let depth = format.exportFacts.depthLabel {
                    LabelledControl(title: "Depth") {
                        FixedValue(text: depth)
                    }
                }
            }
        }
    }

    private var sampleRateChoices: [ExportChoice<Double?>] {
        var list: [ExportChoice<Double?>] = [
            ExportChoice(id: "source", title: "Same as the source", value: nil)
        ]
        for rate in [44_100.0, 48_000.0, 88_200.0, 96_000.0] {
            list.append(ExportChoice(id: String(Int(rate)), title: EditorFormat.hertz(rate), value: rate))
        }
        return list
    }

    private var channelChoices: [ExportChoice<ChannelMode>] {
        ChannelMode.allCases.map {
            ExportChoice(
                id: $0.rawValue,
                title: ExportCopy.channelChoice($0, source: document.source),
                value: $0
            )
        }
    }

    private var bitRateChoices: [ExportChoice<Int?>] {
        format.exportFacts.bitRateChoicesKbps.map {
            ExportChoice(id: String($0), title: "\($0) kbps", value: Int?.some($0))
        }
    }

    // MARK: Naming

    private var naming: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Where it lands")

            HStack(spacing: DesignTokens.Spacing.sm) {
                TextField("Name", text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.Scale.body())
                    .accessibilityLabel("File name")

                Text(".\(format.fileExtension)")
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "folder")
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .accessibilityHidden(true)

                Text(folder.lastPathComponent)
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: DesignTokens.Spacing.sm)

                Button("Choose…", action: chooseFolder)
                    .font(DesignTokens.Typography.Scale.footnote())
                    .accessibilityLabel("Choose a folder")
            }

            if uniqueURL != plannedURL {
                Text("There's already one called that, so this becomes \(uniqueURL.lastPathComponent).")
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            summaryCard
        }
    }

    /// What the user is actually about to get.
    private var summaryCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(ExportCopy.summary(
                    format: format,
                    sampleRate: sampleRate,
                    bitRateKbps: bitRateKbps,
                    channels: channels,
                    source: document.source
                ))
                .font(DesignTokens.Typography.Scale.body(.medium))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("\(EditorFormat.timecode(outputDuration)) long")
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Text("about \(ExportCopy.fileSize(estimatedBytes))")
                .font(DesignTokens.Typography.Scale.body(.medium))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Colors.textPrimary)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .eqCardBackground()
        .accessibilityElement(children: .combine)
    }

    // MARK: The theme

    /// The offer to make a remix the theme Melo plays during setup. Only for
    /// the theme, and only once there is a rendered file to adopt — before
    /// that its button is disabled, and a disabled control with nothing behind
    /// it is worse than no control. The result card in the progress strip is
    /// where this first appears; here it is the way back to it.
    @ViewBuilder
    private var themeAdoption: some View {
        if document.source.origin == .meloTheme,
           let rendered = ExportCoordinator.shared.lastThemeExportURL {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                SectionHeader(title: "Melo's theme")
                MeloThemeAdoptionRow(renderedURL: rendered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .eqCardBackground()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Toggle("Show it in the Finder when it's done", isOn: $revealWhenDone)
                .toggleStyle(.checkbox)
                .font(DesignTokens.Typography.Scale.footnote())

            Spacer(minLength: DesignTokens.Spacing.md)

            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)

            Button("Export", action: export)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isAvailable(format))
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    // MARK: Derived values

    private var folder: URL {
        if !storedFolderPath.isEmpty {
            let url = URL(fileURLWithPath: storedFolderPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return ExportDestination.defaultFolder(for: document.source)
    }

    private var plannedURL: URL {
        folder
            .appendingPathComponent(ExportDestination.sanitise(fileName))
            .appendingPathExtension(format.fileExtension)
    }

    private var uniqueURL: URL {
        ExportDestination.unique(plannedURL)
    }

    private var outputDuration: TimeInterval {
        ExportSizeEstimate.estimatedDuration(source: document.source, moves: document.moves)
    }

    private var estimatedBytes: Int64 {
        ExportSizeEstimate.bytes(
            format: format,
            duration: outputDuration,
            sampleRate: ExportSizeEstimate.sampleRate(sampleRate, format: format, source: document.source),
            channelCount: channels.resolvedChannelCount(from: document.source.channelCount),
            bitRateKbps: bitRateKbps
        )
    }

    /// One filesystem walk, not one per body evaluation.
    private func locateTools() {
        var found: [ExternalTool: URL] = [:]
        for tool in ExternalTool.allCases {
            if let url = ExternalToolLocator.locate(tool) { found[tool] = url }
        }
        toolLocations = found
    }

    private func isAvailable(_ kind: AudioFormatKind) -> Bool {
        guard let tool = kind.requiresExternalTool else { return true }
        return toolLocations[tool] != nil
    }

    private func matches(_ preset: ExportPreset) -> Bool {
        preset.format == format
            && preset.sampleRate == sampleRate
            && preset.channels == channels
            && (!format.exportFacts.supportsBitRate || preset.bitRateKbps == bitRateKbps)
    }

    // MARK: Actions

    private func apply(_ preset: ExportPreset) {
        Haptics.step()
        format = preset.format
        sampleRate = preset.sampleRate
        channels = preset.channels
        // Set after `format`, because changing the format resets the bit rate.
        bitRateKbps = preset.bitRateKbps
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should Melo put it?"
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        storedFolderPath = picked.path
    }

    private func export() {
        guard isAvailable(format) else { return }
        let settings = ExportSettings(
            format: format,
            destinationURL: plannedURL,
            sampleRate: sampleRate,
            bitRateKbps: bitRateKbps,
            channels: channels
        )
        ExportCoordinator.shared.start(
            document: document,
            settings: settings,
            revealWhenDone: revealWhenDone,
            store: store
        )
        isPresented = false
    }
}

// MARK: - Preset chip

@MainActor
private struct PresetChip: View {
    let preset: ExportPreset
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: preset.symbolName)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
                        .accessibilityHidden(true)

                    Text(preset.title)
                        .font(DesignTokens.Typography.Scale.footnote(.medium))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                }

                Text(isAvailable ? preset.summary : "Needs \(preset.format.requiresExternalTool?.executableName ?? "a tool")")
                    .font(DesignTokens.Typography.Scale.caption2())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm2)
            .padding(.vertical, DesignTokens.Spacing.xs2)
            .frame(width: 168, alignment: .leading)
            .frame(minHeight: DesignTokens.Dimensions.minTouchTarget)
            .background {
                DesignTokens.Dimensions.Shape.sm
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .overlay {
                DesignTokens.Dimensions.Shape.sm
                    .strokeBorder(
                        isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.menuBorder,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .opacity(isAvailable ? 1 : 0.55)
        .accessibilityLabel("\(preset.title), \(preset.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Format tile

@MainActor
private struct FormatTile: View {
    let kind: AudioFormatKind
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(kind.displayName)
                        .font(DesignTokens.Typography.Scale.headline(.medium))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)

                    Spacer(minLength: DesignTokens.Spacing.xs)

                    if !isAvailable, let tool = kind.requiresExternalTool {
                        Text("Needs \(tool.executableName)")
                            .font(DesignTokens.Typography.Scale.caption2(.medium))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .padding(.horizontal, DesignTokens.Spacing.xs2)
                            .padding(.vertical, 1)
                            .background { Capsule().fill(DesignTokens.Colors.glassFillStrong) }
                    }
                }

                Text(kind.exportFacts.blurb)
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm2)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            .background {
                DesignTokens.Dimensions.Shape.sm
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .overlay {
                DesignTokens.Dimensions.Shape.sm
                    .strokeBorder(
                        isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.menuBorder,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .accessibilityLabel("\(kind.displayName). \(kind.exportFacts.blurb)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - The one sentence

private struct FormatNoteContent: Equatable {
    var symbol: String
    var message: String
    var command: String?
}

@MainActor
private struct FormatNote: View {
    let note: FormatNoteContent
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: note.symbol)
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(note.message)
                    .font(DesignTokens.Typography.Scale.footnote())
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let command = note.command {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text(command)
                            .font(DesignTokens.Typography.Scale.footnote(.medium))
                            .textSelection(.enabled)
                            .padding(.horizontal, DesignTokens.Spacing.xs2)
                            .padding(.vertical, 2)
                            .background {
                                DesignTokens.Dimensions.Shape.xs
                                    .fill(DesignTokens.Colors.recessedBackground)
                            }

                        Button(didCopy ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            didCopy = true
                            Haptics.commit()
                        }
                        .font(DesignTokens.Typography.Scale.caption())
                        .accessibilityLabel("Copy the install command")
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .eqCardBackground()
    }
}

// MARK: - Small controls

private struct ExportChoice<Value>: Identifiable {
    let id: String
    let title: String
    let value: Value
}

@MainActor
private struct LabelledControl<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            content
        }
    }
}

@MainActor
private struct FixedValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.Typography.Scale.footnote(.medium))
            .monospacedDigit()
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: 24, alignment: .leading)
    }
}

/// A thin wrapper over the app's own `DropdownMenu`, so the three settings
/// pickers are the same control the rest of Melo uses.
@MainActor
private struct ChoiceMenu<Value>: View {
    let title: String
    let choices: [ExportChoice<Value>]
    let selectedID: String
    let width: CGFloat
    let onSelect: (ExportChoice<Value>) -> Void

    var body: some View {
        DropdownMenu(
            items: choices,
            selectedItem: choices.first { $0.id == selectedID },
            maxVisibleItems: 6,
            width: width,
            popoverWidth: nil,
            onSelect: onSelect,
            label: { selected in
                Text(selected?.title ?? "—")
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
            },
            itemContent: { item, isSelected in
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(item.title)
                    if isSelected {
                        Spacer(minLength: DesignTokens.Spacing.xs)
                        Image(systemName: "checkmark")
                            .font(DesignTokens.Typography.Scale.caption2(.bold))
                            .accessibilityHidden(true)
                    }
                }
            }
        )
        .accessibilityLabel(title)
    }
}
