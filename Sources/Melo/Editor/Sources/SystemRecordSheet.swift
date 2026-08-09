// Melo/Editor/Sources/SystemRecordSheet.swift
import AppKit
import SwiftUI

// MARK: - Reaching the live engine

/// The recorder needs two things the editor does not own: the list of apps currently
/// making sound, and Melo's one permission model.
///
/// `LinkImportSheet` and `SystemRecordSheet` both take `(store:isPresented:)`, so
/// neither can be handed an `AudioEngine`. The app delegate holds the only
/// instance and is reachable from anywhere on the main actor. This is the one
/// place that changes if it is ever injected instead.
@MainActor
enum EditorAudioEnvironment {
    static var engine: AudioEngine? {
        (NSApp.delegate as? AppDelegate)?.audioEngine
    }

    /// Apps Core Audio has actually made capturable. `AudioProcessMonitor` already
    /// excludes Melo itself, so the editor's own playback never appears as a source.
    static var capturableApps: [AudioApp] {
        (engine?.apps ?? [])
            .filter { !$0.processObjectIDs.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Seeding

/// One fixed state for `SystemRecordSheet`.
///
/// This sheet has the same coverage problem as the link sheet and a worse cause: which
/// branch it renders depends on this Mac's capture grant, and the source list depends
/// on what happens to be making sound at the moment the frame is taken. Both are
/// handed in here instead.
@MainActor
struct SystemRecordSeed {
    var state: SystemAudioRecorder.State
    var level: Float
    var elapsed: TimeInterval
    var droppedFrameCount: Int
    var needsPermission: Bool
    var source: RecordingSource
    /// Replaces the live process list. Empty renders the honest "nothing is playing"
    /// case, which is a state worth a frame in its own right.
    var apps: [AudioApp]

    init(
        state: SystemAudioRecorder.State = .idle,
        level: Float = 0,
        elapsed: TimeInterval = 0,
        droppedFrameCount: Int = 0,
        needsPermission: Bool = false,
        source: RecordingSource = .everything,
        apps: [AudioApp] = []
    ) {
        self.state = state
        self.level = level
        self.elapsed = elapsed
        self.droppedFrameCount = droppedFrameCount
        self.needsPermission = needsPermission
        self.source = source
        self.apps = apps
    }
}

// MARK: - The sheet

/// Arming and running a recording.
///
/// Recording one app is the headline rather than the fallback: Melo already knows
/// which processes are making sound, so "record Safari and nothing else" is one tap
/// here and impossible in every other audio editor on the Mac.
@MainActor
struct SystemRecordSheet: View {
    @ObservedObject var store: EditorStore
    @Binding var isPresented: Bool

    @StateObject private var recorder: SystemAudioRecorder
    @State private var source: RecordingSource
    @State private var startedAt = Date()
    @State private var job: EditorJob?

    /// Non-nil replaces the live engine's app list and switches every action off.
    private let seed: SystemRecordSeed?

    init(store: EditorStore, isPresented: Binding<Bool>) {
        self.init(store: store, isPresented: isPresented, seed: nil)
    }

    /// Renders one fixed state: no tap, no permission call, no process list.
    init(store: EditorStore, isPresented: Binding<Bool>, seed: SystemRecordSeed) {
        self.init(store: store, isPresented: isPresented, seed: .some(seed))
    }

    private init(store: EditorStore, isPresented: Binding<Bool>, seed: SystemRecordSeed?) {
        self.store = store
        self._isPresented = isPresented
        self.seed = seed
        self._recorder = StateObject(wrappedValue: SystemAudioRecorder(seed: seed))
        self._source = State(initialValue: seed?.source ?? .everything)
    }

    /// The live process list, or the seeded one.
    private var sources: [AudioApp] {
        seed?.apps ?? EditorAudioEnvironment.capturableApps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            header

            if recorder.needsPermission {
                permissionBlock
            } else if isRunning {
                meterPanel
            } else {
                sourcePicker
            }

            if case .failed(let message) = recorder.state, !recorder.needsPermission {
                notice(symbol: "exclamationmark.triangle.fill", text: message, isProblem: true)
            }

            indicatorNote
            Spacer(minLength: 0)
            footer
        }
        .padding(DesignTokens.Spacing.xl)
        // Sized to content with a floor rather than pinned at a guessed height. A
        // fixed 400 left roughly 350pt of nothing under the running state.
        .frame(width: 460)
        .frame(minHeight: 320, alignment: .top)
        .interactiveDismissDisabled(recorder.state.isBusy)
        .onDisappear {
            // A sheet dismissed mid-recording must not leave a private aggregate
            // device registered with coreaudiod. This is the only path that can.
            if recorder.state.isBusy { discard() }
        }
    }

    private var isRunning: Bool {
        if case .recording = recorder.state { return true }
        if case .stopping = recorder.state { return true }
        return false
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Record what's playing")
                .font(DesignTokens.Typography.Scale.title3())
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Text("Melo catches the Mac's own output and opens it here.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Source

    /// 44, not the 36 this started at: the "Everything" row carries two lines of text
    /// and at 36 they sat about 5pt from each edge. Measured in a rendered frame.
    private static let sourceRowHeight = DesignTokens.Dimensions.minTouchTarget + DesignTokens.Spacing.lg
    private static let maximumVisibleSourceRows = 5

    private var sourcePicker: some View {
        // Everything, plus one row per app.
        let rowCount = sources.count + 1
        let needsScrolling = rowCount > Self.maximumVisibleSourceRows
        let visibleRows = min(rowCount, Self.maximumVisibleSourceRows)

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SectionHeader(title: "Record")

            Group {
                // Only scroll when there is something to scroll. A fixed-height scroll
                // box around three rows was two-thirds empty, and a `ScrollView`'s
                // content does not appear in an `ImageRenderer` capture at all —
                // measured this session, so the common case now renders everywhere.
                if needsScrolling {
                    ScrollView { sourceRows }
                } else {
                    sourceRows
                }
            }
            .frame(height: CGFloat(visibleRows) * Self.sourceRowHeight)
            .background {
                DesignTokens.Dimensions.Shape.md
                    .fill(DesignTokens.Colors.recessedBackground)
            }

            if sources.isEmpty {
                Text("Nothing else is making sound right now.")
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
    }

    private var sourceRows: some View {
        VStack(spacing: 0) {
            sourceRow(
                .everything,
                title: "Everything",
                subtitle: "Every app, mixed the way you hear it",
                icon: nil
            )

            ForEach(sources) { app in
                sourceRow(
                    .app(pid: app.id, name: app.name),
                    title: app.name,
                    subtitle: nil,
                    icon: app.icon
                )
            }
        }
    }

    private func sourceRow(
        _ candidate: RecordingSource,
        title: String,
        subtitle: String?,
        icon: NSImage?
    ) -> some View {
        let isSelected = source == candidate
        return Button {
            source = candidate
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                RadioButton(isSelected: isSelected) { source = candidate }
                    .accessibilityHidden(true)

                // `iconSize` (22), matching the app rows in the popup. At
                // `iconSizeSmall` a real app icon was a speck beside 12pt text.
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: DesignTokens.Dimensions.iconSize,
                               height: DesignTokens.Dimensions.iconSize)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "speaker.wave.3")
                        .font(DesignTokens.Typography.Scale.body())
                        .frame(width: DesignTokens.Dimensions.iconSize,
                               height: DesignTokens.Dimensions.iconSize)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(DesignTokens.Typography.Scale.body())
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(DesignTokens.Typography.Scale.caption())
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: DesignTokens.Dimensions.minTouchTarget + DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Meter

    private var meterPanel: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(EditorFormat.timecode(recorder.elapsed))
                    .font(DesignTokens.Typography.Scale.title2())
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(source.displayName)
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }

            Spacer(minLength: 0)

            if recorder.droppedFrameCount > 0 {
                Text("Dropped audio")
                    .font(DesignTokens.Typography.Scale.caption(.semibold))
                    .foregroundStyle(DesignTokens.Colors.mutedIndicator)
            }

            VUMeter(level: recorder.level)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            DesignTokens.Dimensions.Shape.md
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording \(source.displayName)")
        .accessibilityValue(EditorFormat.timecode(recorder.elapsed))
    }

    // MARK: Permission

    private var permissionBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("macOS is blocking system audio for Melo.")
                .font(DesignTokens.Typography.Scale.body(.semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Text("It's the same permission Melo already uses to play your audio — turn Melo on under Screen & System Audio Recording, then come back.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") {
                EditorAudioEnvironment.engine?.permission.openSystemAudioSettings()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Notes

    /// Someone who turned on privacy-friendly processing chose to keep that indicator
    /// dark. Seeing it light up during a recording they started should read as
    /// expected, not as a leak.
    private var indicatorNote: some View {
        notice(
            symbol: "record.circle",
            text: "macOS lights its recording indicator while this runs, even with privacy-friendly processing on. The audio goes to a file on your Mac and nowhere else.",
            isProblem: false
        )
    }

    private func notice(symbol: String, text: String, isProblem: Bool) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.Scale.footnote(.semibold))
                .foregroundStyle(isProblem
                    ? DesignTokens.Colors.mutedIndicator
                    : DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Spacer(minLength: 0)

            if isRunning {
                Button("Discard") { discard() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button("Stop and edit") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.state == .stopping)
            } else {
                Button("Close") { isPresented = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button("Start recording") { arm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.state == .arming)
            }
        }
    }

    // MARK: Actions

    private func arm() {
        // A seeded sheet is a picture of a state, not a working control. Nothing here
        // starts a tap, and nothing publishes a job into a store the harness shares.
        guard seed == nil else { return }
        startedAt = Date()
        let recording = store.makeJob(stage: "Recording", detail: EditorFormat.timecode(0))
        job = recording
        Task { @MainActor in
            await recorder.start(source: source, permission: EditorAudioEnvironment.engine?.permission)
            guard case .recording = recorder.state else {
                store.retire(recording)
                job = nil
                return
            }
            while case .recording = recorder.state {
                recording.setDetail(EditorFormat.timecode(recorder.elapsed))
                try? await Task.sleep(for: .seconds(0.25))
            }
        }
    }

    private func finish() {
        guard seed == nil else { return }
        Task { @MainActor in
            let url = await recorder.stop()
            if let job {
                job.finish()
                store.retire(job)
            }
            job = nil

            guard let url else { return }
            recorder.forgetScratchDirectory()
            await store.openSource(
                at: url,
                origin: .systemRecording(startedAt: startedAt),
                displayName: url.deletingPathExtension().lastPathComponent
            )
            isPresented = false
        }
    }

    private func discard() {
        guard seed == nil else { return }
        recorder.cancel()
        if let job {
            store.retire(job)
        }
        job = nil
    }
}
