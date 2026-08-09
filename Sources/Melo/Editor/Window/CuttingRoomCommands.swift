import AppKit
import SwiftUI

/// The Cutting Room's key equivalents, as a value that can be tested without a
/// window.
///
/// Separated from the monitor that delivers them on purpose. A check that
/// asserts "⌘⇧Z is redo" against a pure function proves the *rule*; only a check
/// that watches `perform` fire proves the rule is connected. Both are cheap, and
/// this project's anchor records a run where four wiring points were severed at
/// once and every rule-only assertion still passed.
enum CuttingRoomShortcut: String, CaseIterable, Sendable {
    case playPause
    case export
    case undo
    case redo
    case openFile
    case pasteLink
    case recordSystem
    case deleteMove
    case zoomToFit
    case zoomIn
    case zoomOut
    /// Held, not pressed. The only shortcut with a meaningful key-up.
    case bypassHold

    /// Whether a shortcut is a press or a hold.
    ///
    /// Every other shortcut is an event; this one is a *state*, and a state
    /// needs both edges. Modelling it as a phase on the existing match rather
    /// than as a second monitor is deliberate — two monitors on one window is
    /// two places for the first-responder guard to drift apart, and the guard is
    /// the whole reason this file exists.
    enum Phase: Sendable {
        case down
        case up
    }

    /// Whether holding the key down should keep firing.
    ///
    /// Almost nothing should. A held Space would toggle playback at the key
    /// repeat rate, which is a hundred play/pause flips a second rather than one
    /// pause; a held ⌘Z would unwind the whole stack past the point anyone
    /// wanted. Zoom is the exception people actually expect to repeat, and
    /// `bypassHold` handles its own repeats by ignoring them.
    var repeatsAreMeaningful: Bool {
        switch self {
        case .zoomIn, .zoomOut: return true
        default: return false
        }
    }

    /// - Parameters:
    ///   - characters: `NSEvent.charactersIgnoringModifiers`. Ignoring modifiers
    ///     is what makes ⌘⇧= arrive as `"="` rather than `"+"`, so the shifted
    ///     and unshifted spellings of zoom-in are one case instead of a layout
    ///     guess.
    ///   - modifiers: `NSEvent.modifierFlags`, unfiltered; this function does its
    ///     own masking.
    ///   - phase: `.up` matches `bypassHold` and nothing else. A key-up for any
    ///     other shortcut is not a second chance to fire it.
    static func match(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        phase: Phase
    ) -> CuttingRoomShortcut? {
        let flags = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let key = characters.lowercased()

        // B, unmodified, held.
        //
        // The control this drives is the one that lets someone hear their own
        // file against what Melo did to it, which means it has to be findable
        // without looking away from the waveform — so no modifier, and a letter
        // the hand can reach from where it already is. `b` for bypass is the
        // mnemonic, and it collides with nothing else bound here.
        //
        // *Rejected:* holding Option, which is the gesture some plugins use and
        // which arrives as `flagsChanged` rather than a key event — a third
        // event type, on a key macOS itself claims for a dozen things. And `\`,
        // which some DAWs use for A/B: no mnemonic, and it is not the same
        // physical key on an ISO keyboard as on ANSI.
        if flags.isEmpty, key == "b" {
            return .bypassHold
        }
        guard phase == .down else { return nil }

        if flags.isEmpty {
            switch key {
            case " ":
                return .playPause
            // Backspace, forward delete, and the character the Delete key
            // actually sends on a Mac keyboard, which is none of the two people
            // expect.
            case "\u{8}", "\u{7F}", "\u{F728}":
                return .deleteMove
            default:
                return nil
            }
        }

        guard flags.contains(.command) else { return nil }
        let extra = flags.subtracting(.command)
        guard extra.isEmpty || extra == .shift else { return nil }
        let shifted = extra == .shift

        switch key {
        case "e": return shifted ? nil : .export
        case "z": return shifted ? .redo : .undo
        case "o": return shifted ? nil : .openFile
        // The other two ways a sound gets in. They sat behind the empty state,
        // which stops existing the moment a document opens, so before these they
        // were reachable once per launch. Neither collides: nothing in this
        // window binds ⌘L or ⌘R, and this app has no menu bar to lose them to.
        case "l": return shifted ? nil : .pasteLink
        case "r": return shifted ? nil : .recordSystem
        case "0": return shifted ? nil : .zoomToFit
        // ⌘+ is ⌘⇧= on most layouts and plain ⌘= on none of them, so both
        // spellings mean zoom in. The same courtesy for ⌘_ costs one case.
        case "=", "+": return .zoomIn
        case "-", "_": return .zoomOut
        default: return nil
        }
    }
}

extension View {
    /// Installs the Cutting Room's key equivalents for as long as this view is
    /// in a window.
    ///
    /// - Parameters:
    ///   - store: everything a shortcut changes goes through here, including the
    ///     ones belonging to panes this piece does not own. A shortcut that
    ///     reached into `EditorWaveformView` to zoom it would be a second way to
    ///     drive a pane, and the second way is always the one that rots.
    ///   - onExport: presenting `ExportSheet` is the window's own state, not the
    ///     store's, so ⌘E comes back out rather than going in.
    ///   - onOpenFile: likewise — the file picker is a window affordance.
    func cuttingRoomKeyCommands(
        store: CuttingRoomStore,
        onExport: @escaping () -> Void,
        onOpenFile: @escaping () -> Void,
        onPasteLink: @escaping () -> Void,
        onRecord: @escaping () -> Void
    ) -> some View {
        background(
            CuttingRoomKeyCommands(
                store: store,
                onExport: onExport,
                onOpenFile: onOpenFile,
                onPasteLink: onPasteLink,
                onRecord: onRecord
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }
}

/// ## Why a local event monitor rather than hidden `Button`s
///
/// Melo's popup reaches for `.keyboardShortcut` on a real button, and for ⌘K on
/// a control that is visibly there, that is the right answer. It is the wrong
/// one here for two reasons that both come from this window having text in it.
///
/// Space and Delete carry no modifier. A `.keyboardShortcut(.space, modifiers:
/// [])` fires while a `TextField` has the insertion point, so typing a filename
/// into the export sheet or a frequency into a move would start and stop
/// playback a word at a time. `MenuBarPopupView.handleKeyPress` already answers
/// this exact question the same way — `if NSApp.keyWindow?.firstResponder is
/// NSTextView { return .ignored }` — and that guard is what this needs, which
/// means it needs the event rather than a shortcut.
///
/// ⌘Z is the second reason, and it is subtler: inside a text field ⌘Z means undo
/// what I just typed, and taking it away to undo a *move* is the kind of thing
/// that loses someone a sentence. The same first-responder guard hands it back.
///
/// One mechanism for all of them, uniformly guarded, is also why every shortcut
/// goes through here rather than splitting the modified ones off into buttons.
private struct CuttingRoomKeyCommands: NSViewRepresentable {
    let store: CuttingRoomStore
    let onExport: () -> Void
    let onOpenFile: () -> Void
    let onPasteLink: () -> Void
    let onRecord: () -> Void

    func makeNSView(context: Context) -> CuttingRoomKeyCommandView {
        CuttingRoomKeyCommandView()
    }

    func updateNSView(_ nsView: CuttingRoomKeyCommandView, context: Context) {
        nsView.perform = { shortcut, phase in
            switch shortcut {
            case .bypassHold:
                store.setBypassHeld(phase == .down)
            case .playPause:
                store.togglePlayback()
            case .export:
                onExport()
            case .undo:
                store.undo()
            case .redo:
                store.redo()
            case .openFile:
                onOpenFile()
            case .pasteLink:
                onPasteLink()
            case .recordSystem:
                onRecord()
            case .deleteMove:
                guard let selected = store.selectedMoveID else { return }
                store.remove(selected)
            case .zoomToFit:
                store.zoomToFit()
            case .zoomIn:
                store.zoomIn()
            case .zoomOut:
                store.zoomOut()
            }
        }
    }
}

/// Holds the monitor and tears it down when the view leaves its window, the same
/// shape `WindowAppearanceTrackerView` uses to hang behaviour off a window a
/// SwiftUI view cannot otherwise see.
final class CuttingRoomKeyCommandView: NSView {
    var perform: ((CuttingRoomShortcut, CuttingRoomShortcut.Phase) -> Void)?

    /// Tracked so the hold can be broken by something other than the key coming
    /// back up. See `releaseBypassIfHeld()`.
    private var isBypassHeld = false

    /// Both tokens are `nonisolated(unsafe)` for the same reason as
    /// `OnboardingWindowController.guideRequestObserver`: `deinit` is
    /// nonisolated under Swift 6 and cannot read a `@MainActor` property, and
    /// both have to be unregistered there. Safe in fact — each is written only
    /// from the main actor in the methods below, and `deinit` cannot run
    /// concurrently with any of them.
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            releaseBypassIfHeld()
            removeMonitor()
        } else {
            installMonitor()
            observeResign()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        // No `MainActor.assumeIsolated` here, unlike `ClickOutsideCoordinator`:
        // this handler is already main-actor isolated by the SDK, and wrapping it
        // would push `NSEvent` — which is explicitly non-`Sendable` — out through
        // the closure's return type.
        //
        // `keyUp` as well as `keyDown`, for `bypassHold` and nothing else.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// The failure this exists for: hold B, ⌘-Tab away, let go. The key-up lands
    /// in the other app, this window never hears it, and Melo is left bypassed
    /// with no key held and nothing on screen explaining why the sound is wrong.
    /// A hold has to be released by *losing the hold*, which quitting the window
    /// is a way of doing.
    private func observeResign() {
        guard resignObserver == nil, let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseBypassIfHeld()
            }
        }
    }

    private func releaseBypassIfHeld() {
        guard isBypassHeld else { return }
        isBypassHeld = false
        perform?(.bypassHold, .up)
    }

    /// - Returns: `nil` to swallow the event, or the event to pass it along.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // The monitor is application-wide, so the window check is what keeps
        // Space from pausing the Cutting Room while someone is in Settings. It
        // also covers sheets for free: an attached sheet is its own window, so
        // the export sheet's own keys never reach here.
        guard let window, event.window === window else { return event }
        // The field editor wins every key it can use. See the type comment.
        // Releasing first: someone holding B who clicks into a text field has
        // stopped comparing, and the alternative is a bypass nothing can clear.
        if window.firstResponder is NSTextView {
            releaseBypassIfHeld()
            return event
        }

        let phase: CuttingRoomShortcut.Phase = event.type == .keyUp ? .up : .down

        guard
            let characters = event.charactersIgnoringModifiers,
            let shortcut = CuttingRoomShortcut.match(
                characters: characters,
                modifiers: event.modifierFlags,
                phase: phase
            )
        else {
            return event
        }

        if shortcut == .bypassHold {
            // A held key repeats, and the second keyDown is not a second press.
            let held = phase == .down
            guard held != isBypassHeld else { return nil }
            isBypassHeld = held
        } else if event.isARepeat, !shortcut.repeatsAreMeaningful {
            // Swallowed rather than passed along: this key *is* bound here, and
            // handing the repeat to the responder chain would beep.
            return nil
        }

        perform?(shortcut, phase)
        return nil
    }
}
