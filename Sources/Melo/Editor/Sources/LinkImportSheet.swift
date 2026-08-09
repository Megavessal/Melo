// Melo/Editor/Sources/LinkImportSheet.swift
import AppKit
import SwiftUI

// MARK: - The sheet

/// Pasting a link.
///
/// The clipboard is read on open, because someone who reaches this sheet has just
/// copied a link — the field is never empty when it could be full. What was found is
/// shown before anything is downloaded, so the user confirms they got the right thing
/// rather than finding out after a minute of progress bar.
@MainActor
struct LinkImportSheet: View {
    @ObservedObject var store: CuttingRoomStore
    @Binding var isPresented: Bool

    @StateObject private var model: LinkImportModel

    init(store: CuttingRoomStore, isPresented: Binding<Bool>) {
        self.init(store: store, isPresented: isPresented, seed: nil)
    }

    /// Renders one fixed state and runs nothing: no clipboard read, no `yt-dlp`
    /// lookup, no process. Five of the six phases are otherwise unreachable from a
    /// harness, and the failure sentences are exactly the part of this sheet whose
    /// wrapping and truncation only a frame can check.
    init(store: CuttingRoomStore, isPresented: Binding<Bool>, seed: LinkImportSeed) {
        self.init(store: store, isPresented: isPresented, seed: .some(seed))
    }

    private init(store: CuttingRoomStore, isPresented: Binding<Bool>, seed: LinkImportSeed?) {
        self.store = store
        self._isPresented = isPresented
        self._model = StateObject(wrappedValue: LinkImportModel(seed: seed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            header

            if model.phase == .needsTool {
                missingTool
            } else {
                linkField
                findings
                termsNote
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(DesignTokens.Spacing.xl)
        // Sized to content with a floor. The fixed 380 was a guess and left the
        // failure states with about 180pt of void under the sentence.
        .frame(width: 460)
        .frame(minHeight: 300, alignment: .top)
        .task { await model.prepare() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Audio from a link")
                .font(DesignTokens.Typography.Scale.title3())
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            Text("Melo hands the page to yt-dlp and keeps the sound.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Link field

    private var linkField: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "link")
                .font(DesignTokens.Typography.Scale.footnote(.semibold))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)

            TextField("Paste a link", text: $model.linkText)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.Scale.body())
                .onSubmit { model.look() }
                .accessibilityLabel("Page address")

            if model.phase == .looking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Looking up the link")
            } else if !model.linkText.isEmpty {
                Button {
                    model.look()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(DesignTokens.Typography.Scale.caption(.semibold))
                }
                .buttonStyle(.plain)
                .frame(width: DesignTokens.Dimensions.minTouchTarget,
                       height: DesignTokens.Dimensions.minTouchTarget)
                .contentShape(Rectangle())
                .help("Look this up again")
                .accessibilityLabel("Look this up again")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background {
            DesignTokens.Dimensions.Shape.md
                .fill(DesignTokens.Colors.recessedBackground)
        }
    }

    // MARK: Findings

    @ViewBuilder
    private var findings: some View {
        switch model.phase {
        case .found(let preview):
            previewCard(preview)
        case .working(let fraction, let stage, let detail):
            workingRow(fraction: fraction, stage: stage, detail: detail)
        case .failed(let message):
            noticeRow(symbol: "exclamationmark.triangle.fill", text: message, isProblem: true)
        case .idle:
            noticeRow(
                symbol: "sparkles",
                text: "Paste a page address and Melo will see what's on it.",
                isProblem: false
            )
        case .looking, .needsTool:
            noticeRow(symbol: "sparkles", text: "Having a look…", isProblem: false)
        }
    }

    private func previewCard(_ preview: LinkPreview) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            thumbnail

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(preview.title)
                    .font(DesignTokens.Typography.Scale.body(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.subtitle(for: preview))
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .monospacedDigit()

                if preview.isLive {
                    Text("This one is live. Melo will take whatever has aired so far.")
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            DesignTokens.Dimensions.Shape.md
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Found: \(preview.title). \(model.subtitle(for: preview))")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = model.thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 54)
                .clipShape(DesignTokens.Dimensions.Shape.sm)
                .accessibilityHidden(true)
        } else {
            DesignTokens.Dimensions.Shape.sm
                .fill(DesignTokens.Colors.hoverSurface)
                .frame(width: 96, height: 54)
                .overlay {
                    Image(systemName: "waveform")
                        .font(DesignTokens.Typography.Scale.title3())
                        .foregroundStyle(DesignTokens.Colors.textQuaternary)
                }
                .accessibilityHidden(true)
        }
    }

    private func workingRow(fraction: Double?, stage: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(stage)
                    .font(DesignTokens.Typography.Scale.body(.medium))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .monospacedDigit()
                }
            }
            ProgressView(value: fraction ?? 0, total: 1)
                .progressViewStyle(.linear)
                .opacity(fraction == nil ? 0.45 : 1)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            DesignTokens.Dimensions.Shape.md
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage). \(detail ?? "")")
    }

    private func noticeRow(symbol: String, text: String, isProblem: Bool) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: symbol)
                .font(DesignTokens.Typography.Scale.footnote(.semibold))
                .foregroundStyle(isProblem
                    ? DesignTokens.Colors.mutedIndicator
                    : DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: The one line of judgement

    /// Melo hands the user a tool. It does not decide for them what a site permits,
    /// and it does not pretend the question is not there.
    private var termsNote: some View {
        Text("Sites set their own terms about downloading. Melo runs the tool — the call is yours.")
            .font(DesignTokens.Typography.Scale.caption())
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Missing tool

    /// The honest state. Not a dead button, and not a dialog that says "an error
    /// occurred": what the tool is, why Melo does not ship it, and the one command.
    private var missingTool: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "shippingbox")
                    .font(DesignTokens.Typography.Scale.title3())
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .accessibilityHidden(true)
                Text("Melo needs yt-dlp for this.")
                    .font(DesignTokens.Typography.Scale.body(.semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
            }

            Text("It's the tool that pulls audio off a page. Melo doesn't ship it, because a copy that stopped being updated looks installed and isn't.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            installCommandRow

            Button("Check again") {
                Task { await model.prepare() }
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Looks for yt-dlp again after you install it")
        }
    }

    private var installCommandRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(ExternalTool.ytdlp.installHint)
                .font(DesignTokens.Typography.Scale.body())
                .textSelection(.enabled)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer(minLength: 0)

            Button {
                model.copyInstallCommand()
            } label: {
                Image(systemName: model.didCopyInstallCommand ? "checkmark" : "doc.on.doc")
                    .font(DesignTokens.Typography.Scale.caption(.semibold))
            }
            .buttonStyle(.plain)
            .frame(width: DesignTokens.Dimensions.minTouchTarget,
                   height: DesignTokens.Dimensions.minTouchTarget)
            .contentShape(Rectangle())
            .help("Copy the install command")
            .accessibilityLabel("Copy the install command")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background {
            DesignTokens.Dimensions.Shape.md
                .fill(DesignTokens.Colors.recessedBackground)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let version = model.toolVersion {
                Text("yt-dlp \(version)")
                    .font(DesignTokens.Typography.Scale.caption2())
                    .foregroundStyle(DesignTokens.Colors.textQuaternary)
                    .monospacedDigit()
                    .accessibilityLabel("Using yt-dlp version \(version)")
            }

            Spacer(minLength: 0)

            if model.isWorking {
                Button("Stop") { model.cancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Close") { isPresented = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }

            Button("Get the audio") {
                model.download(into: store) { isPresented = false }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canDownload)
        }
    }
}

// MARK: - Seeding

/// One fixed state for `LinkImportSheet`, so any of its six phases can be rendered.
///
/// Not `#if MELO_DEV`: a state that only exists in a dev build is a state the release
/// build's layout was never checked against, and the point of this seam is checking
/// the layout. It costs one unused initialiser in a release build.
@MainActor
struct LinkImportSeed {
    var phase: LinkImportModel.Phase
    var linkText: String
    var toolVersion: String?
    /// Not fetched — handed in. The placeholder renders when this is nil.
    var thumbnail: NSImage?

    init(
        phase: LinkImportModel.Phase,
        linkText: String = "",
        toolVersion: String? = "2026.07.31",
        thumbnail: NSImage? = nil
    ) {
        self.phase = phase
        self.linkText = linkText
        self.toolVersion = toolVersion
        self.thumbnail = thumbnail
    }

    /// A page title long enough to prove the found state wraps rather than pushing
    /// the card open. Real titles run this long routinely.
    static let longTitle = "Morning Show Ep 41 — the one where we finally answer every question you sent in about microphones, room treatment and why your podcast sounds thin"
}

// MARK: - The flow

/// Owns the extraction so it survives the sheet being dismissed: the task is held by
/// the `EditorJob` in the store, and the job is what the progress strip renders.
@MainActor
final class LinkImportModel: ObservableObject {
    enum Phase: Equatable {
        case needsTool
        case idle
        case looking
        case found(LinkPreview)
        case working(fraction: Double?, stage: String, detail: String?)
        case failed(String)
    }

    @Published var linkText: String = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var toolVersion: String?
    @Published private(set) var didCopyInstallCommand = false

    /// Set by `URLHandler.handleCuttingRoom(queryItems:)` when a
    /// `melo://cutting-room?url=…` route arrives, and consumed here ahead of the
    /// clipboard.
    static var pendingLink: URL?

    /// Non-nil means every side effect is off: `prepare()` returns immediately and
    /// nothing looks anything up.
    private let seed: LinkImportSeed?

    init(seed: LinkImportSeed? = nil) {
        self.seed = seed
        guard let seed else { return }
        linkText = seed.linkText
        phase = seed.phase
        toolVersion = seed.toolVersion
        thumbnail = seed.thumbnail
    }

    private let extractor = LinkExtractor()
    private var lookupTask: Task<Void, Never>?
    /// The extraction in flight. Held so "Stop" cancels this job and nothing else —
    /// an export running in the same window is not the user's business here.
    private var activeJob: EditorJob?

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    var canDownload: Bool {
        guard phase != .needsTool, !isWorking else { return false }
        return LinkExtractor.webLink(fromPastedText: linkText) != nil
    }

    // MARK: Opening

    /// Runs on open and on "Check again". Reading the clipboard here is the whole
    /// point of the sheet: someone who is opening it has just copied a link.
    func prepare() async {
        guard seed == nil else { return }

        guard ExternalToolLocator.locate(.ytdlp) != nil else {
            phase = .needsTool
            toolVersion = nil
            return
        }

        if phase == .needsTool { phase = .idle }

        if linkText.isEmpty, let routed = Self.pendingLink {
            Self.pendingLink = nil
            linkText = routed.absoluteString
            look()
        } else if linkText.isEmpty,
                  let pasted = NSPasteboard.general.string(forType: .string),
                  let link = LinkExtractor.webLink(fromPastedText: pasted) {
            linkText = link.absoluteString
            look()
        }

        toolVersion = await ExternalToolLocator.version(of: .ytdlp)
    }

    // MARK: Looking

    func look() {
        guard let url = LinkExtractor.webLink(fromPastedText: linkText) else {
            phase = .failed(LinkExtractionFailure.notAWebLink.errorDescription ?? "")
            return
        }
        lookupTask?.cancel()
        thumbnail = nil
        phase = .looking

        lookupTask = Task { @MainActor [extractor] in
            do {
                let preview = try await extractor.preview(url)
                guard !Task.isCancelled else { return }
                phase = .found(preview)
                if let imageURL = preview.thumbnailFileURL {
                    thumbnail = await Task.detached { NSImage(contentsOf: imageURL) }.value
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.sentence(for: error))
            }
        }
    }

    // MARK: Downloading

    func download(into store: CuttingRoomStore, onFinished: @escaping () -> Void) {
        guard let url = LinkExtractor.webLink(fromPastedText: linkText) else { return }
        lookupTask?.cancel()

        let job = store.makeJob(stage: "Finding it", isCancellable: true)
        activeJob = job
        phase = .working(fraction: nil, stage: "Finding it", detail: nil)

        let task = Task { @MainActor [extractor] in
            do {
                let audio = try await extractor.extractAudio(from: url) { update in
                    Task { @MainActor in
                        job.setStage(update.stage, detail: update.detail)
                        job.setFraction(update.fraction)
                        self.phase = .working(
                            fraction: update.fraction,
                            stage: update.stage,
                            detail: update.detail
                        )
                    }
                }
                job.finish()
                store.retire(job)
                self.activeJob = nil
                await store.openSource(
                    at: audio.fileURL,
                    origin: .extractedFromLink(pageURL: audio.pageURL, siteName: audio.siteName),
                    displayName: audio.displayName
                )
                onFinished()
            } catch {
                self.activeJob = nil
                if (error as? LinkExtractionFailure) == .cancelled {
                    store.retire(job)
                    self.phase = .idle
                } else {
                    let sentence = Self.sentence(for: error)
                    job.fail(sentence)
                    store.retire(job)
                    self.phase = .failed(sentence)
                }
            }
        }
        job.attach(task)
    }

    /// Cancelling the job cancels the task it holds, which trips the runner's
    /// cancellation handler, which terminates yt-dlp. One path, no second flag.
    func cancel() {
        lookupTask?.cancel()
        activeJob?.cancel()
        activeJob = nil
        phase = .idle
    }

    // MARK: Copy

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ExternalTool.ytdlp.installHint, forType: .string)
        didCopyInstallCommand = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            didCopyInstallCommand = false
        }
    }

    // MARK: Copy helpers

    func subtitle(for preview: LinkPreview) -> String {
        var pieces: [String] = []
        if let uploader = preview.uploader { pieces.append(uploader) }
        if let duration = preview.duration { pieces.append(EditorFormat.timecode(duration)) }
        pieces.append(preview.siteName)
        return pieces.joined(separator: " · ")
    }

    private static func sentence(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
