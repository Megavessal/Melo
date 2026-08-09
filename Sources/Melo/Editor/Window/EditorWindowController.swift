import AppKit
import SwiftUI

/// Closing Melo Edit gives back the Dock tile it borrowed. In the window
/// delegate rather than in whatever code called `close()`, for the same reason
/// `OnboardingWindowCloseObserver` is: the title-bar close button is a way out
/// that no call site sees, and a claim released only by the other ways out is a
/// Dock tile that stays up for the rest of the session.
@MainActor
private final class EditorWindowCloseObserver: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// Melo Edit's window.
///
/// ## Why this is a plain `NSWindow` and not `UnpromptedWindowPanel`
///
/// Melo's other standalone windows all go through `UnpromptedWindowPanel`, and
/// that class exists for a measured reason: an `LSUIElement` app that opens a
/// plain `NSWindow` while another app is frontmost gets a window that draws and
/// can be dragged and whose controls do nothing. Copying it here was the
/// starting assumption, and it is the wrong one.
///
/// `UnpromptedWindowPanel` forces `.nonactivatingPanel`, whose entire definition
/// is *a window that takes key status without its application becoming active*.
/// That is exactly right for the four things it serves — a consent question, a
/// release-notes card, first-run setup, the move-to-Applications offer — all of
/// which appear unasked, are answered in seconds, and are gone. It is wrong for
/// a window someone leaves open for twenty minutes and keeps switching back to:
/// clicking a non-activating panel does not activate Melo, so the user would be
/// typing into a Melo window while Safari still owns the menu bar. Every ⌘-key
/// they press goes somewhere they cannot see, and the window looks broken in a
/// way that is very hard to describe.
///
/// Two further objections to the panel turned out not to hold, and are recorded
/// so nobody re-raises them:
///
/// - **It does not float.** Measured on this machine: a freshly constructed
///   `NSPanel` reports `isFloatingPanel == false` and `level == 0`, the same
///   level as an ordinary window. (Its `hidesOnDeactivate` also came back
///   `false`, not the `true` that `UnpromptedWindowPanel`'s own comment claims —
///   harmless, because that class sets the value explicitly, but the comment is
///   stale.)
/// - **It would not block `DockPresence`.** `windowThatWouldLoseKey()` matches
///   panels only, so a key Melo Edit panel looks like a deferral blocker. It
///   is not one: this window holds a Dock claim for its whole life, so any other
///   claim being released still leaves `wanted == true`, and `evaluate` returns
///   at its `guard NSApp.activationPolicy() != policy` before it ever asks what
///   is key. By the time this window's own claim is released it is closing, and
///   `windowThatWouldLoseKey()` requires `isVisible`.
///
/// ## What replaces the panel's guarantee
///
/// The activation refusal is real and the plain window has to answer it. Three
/// things do, and they are why this is a different case from the four windows
/// that needed the panel:
///
/// 1. **The Dock claim is taken first**, so the app is already `.regular` — an
///    app with a Dock tile, not an accessory — before the window is shown.
/// 2. **This window only ever opens because someone asked for it**, from the
///    popup, the command palette, Settings, or a `melo://` URL. The four panel
///    windows all open by themselves inside the launch block, which is the
///    moment macOS is least willing to hand over activation.
/// 3. **Key status is re-asserted once on the next turn** if the first attempt
///    did not take. Same shape, and the same reasoning, as the deferred second
///    `reassertKey()` in `DockPresence.apply()`: the grant can land after
///    `makeKeyAndOrderFront` returns, so one synchronous check is not enough and
///    one deferred check is not a retry loop.
///
/// **Unverified.** Nothing above about activation policy, key status, or the
/// Dock tile can be rendered or measured by this project's harness. The
/// `isFloatingPanel` and `hidesOnDeactivate` values are measured; the claim that
/// this window comes up key on the first try is not.
@MainActor
final class EditorWindowController {
    static let shared = EditorWindowController()

    /// Kept alive across a close so the window's frame, and the cost of building
    /// its content, survive being dismissed and reopened. The document does not
    /// live here — `EditorStore` is the state — so a reopened window is the
    /// same window showing the same work.
    private var window: NSWindow?
    private var closeObserver: EditorWindowCloseObserver?

    /// Read on every present so the window matches whatever theme and appearance
    /// the user has chosen, including one they changed while it was closed. Held
    /// weakly and configured once at startup, exactly as `DockPresence` does.
    private weak var settings: SettingsManager?

    /// Deliberately still the 3.1.0 spelling. This is a UserDefaults key, and
    /// renaming it would silently forget the window position of every install
    /// that has ever opened the editor.
    private static let frameAutosaveName = "MeloCuttingRoomWindow"

    private init() {}

    /// Call once from `AppSupportCoordinator.init`, alongside
    /// `DockPresence.shared.configure(settings:)`. Without it the window still
    /// opens; it just draws in the system appearance with the system accent
    /// instead of the user's Melo theme.
    func configure(settings: SettingsManager) {
        self.settings = settings
    }

    /// Whether Melo Edit is on screen. Read by
    /// `applicationShouldHandleReopen` so a click on the Dock tile brings this
    /// window forward rather than toggling the menu-bar popup.
    var isOpen: Bool {
        window?.isVisible ?? false
    }

    /// The window itself, for the one thing a SwiftUI view cannot do without it:
    /// hanging an `NSOpenPanel` off it as a sheet instead of as a free-floating
    /// dialog. `nil` before the first `show()` and in the snapshot harness.
    var hostWindow: NSWindow? {
        window
    }

    func show() {
        // Before the window is presented, not after — the same order, and the
        // same reason, as `OnboardingWindowController.show()`. The policy switch
        // is the thing most likely to disturb key status, so doing it first
        // means the present below is the last word on which window is key.
        DockPresence.shared.claim(.editor)

        if let window {
            present(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Melo Edit"
        window.titlebarAppearsTransparent = true
        // Deliberately off, and this is not a preference. With background
        // dragging on, AppKit claims any drag a subview does not consume — which
        // cost first-run setup its only slider once already (see
        // `UnpromptedWindowPanel.init`). This window is mostly waveform: every
        // scrub, every selection edge, every fader is a drag that would be
        // competing with the window moving out from under it.
        window.isMovableByWindowBackground = false
        // Closing must not deallocate the window, because the controller keeps
        // it for the next `show()`.
        window.isReleasedWhenClosed = false
        // Explicit rather than inherited. The default is already `false` on this
        // OS, but an editor that vanished when the user clicked another app
        // would be the single worst behaviour this window could have, and that
        // is not a property to leave to a default.
        window.hidesOnDeactivate = false
        // There is exactly one Melo Edit window, so native tabbing has nothing to
        // group it with — all it can do is offer a "Show Tab Bar" item that does
        // nothing and let Settings merge itself in.
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 820, height: 520)

        // Restore before naming, then name. `setFrameAutosaveName` only arranges
        // for *saving*; `setFrameUsingName` is what reads a stored frame back.
        // Centring is the fallback for a first run, not the default — a window
        // that jumps back to the middle of the screen at every launch is the
        // thing `setFrameAutosaveName` exists to prevent.
        let restoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !restoredFrame {
            window.center()
        }

        window.contentViewController = NSHostingController(
            rootView: EditorRootView(store: .shared, settings: settings)
        )

        let observer = EditorWindowCloseObserver {
            DockPresence.shared.release(.editor)
        }
        window.delegate = observer
        closeObserver = observer

        self.window = window
        present(window)
    }

    /// Apple's documented order — activate, then make key — through the API that
    /// is not deprecated, followed by one deferred check.
    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        // Not a retry loop: one deferred re-assert, for the case where the
        // activation grant lands after this turn and takes key status somewhere
        // else on its way in. `DockPresence.apply()` does the same thing for the
        // same reason. If the window is already key this is a no-op, and if it
        // still is not, `ignoringOtherApps` is the stronger request that
        // `reapplyPreference` already uses when the user has directly asked for
        // Melo to come forward — which, here, they have.
        DispatchQueue.main.async { [weak window] in
            MainActor.assumeIsolated {
                guard let window, window.isVisible, !window.isKeyWindow else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
