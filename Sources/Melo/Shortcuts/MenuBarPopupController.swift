// Melo/Shortcuts/MenuBarPopupController.swift
import AppKit
import os

/// Toggles the Melo menu-bar popup from outside the SwiftUI scene chain
/// (e.g. when a global hotkey fires).
///
/// Locates the underlying `NSStatusItem` via `NSApp.windows` + KVC introspection
/// of the private `NSStatusBarWindow.statusItem` key. This is the same technique
/// used by `orchetect/MenuBarExtraAccess` for Apple's `MenuBarExtra` and works
/// equally well for `FluidMenuBarExtra` because both ultimately call
/// `NSStatusBar.system.statusItem(...)` and rely on the standard menu-bar window
/// machinery. The technique is package-agnostic and avoids needing any callback
/// wiring (no `onStatusItemReady`, no Scene-reference capture).
///
/// Once the status item is located, we toggle the popup by posting a synthetic
/// `.leftMouseDown` event aimed at the button's window. `FluidMenuBarExtra`
/// installs a `LocalEventMonitor` that filters events on the status button's
/// window — the synthetic event satisfies that filter and re-uses the package's
/// existing visible→dismiss / hidden→show toggle logic, including the
/// screen-edge framing math.
@MainActor
protocol MenuBarPopupControlling: AnyObject {
    func toggle()
}

@MainActor
final class MenuBarPopupController: MenuBarPopupControlling {
    private static let logger = Logger(
        subsystem: "io.github.megavessal.Melo",
        category: "MenuBarPopupController"
    )

    /// Accessibility title used to identify Melo's status item among any
    /// other status items in the same process. `FluidMenuBarExtra` sets this on
    /// the button via `setAccessibilityTitle(title)` where `title` is the first
    /// argument we pass to `FluidMenuBarExtra(...)` in `MeloApp`.
    private let accessibilityTitle: String

    init(accessibilityTitle: String = "Melo") {
        self.accessibilityTitle = accessibilityTitle
    }

    func toggle() {
        // Public view traversal is the primary path and survives private status-item class
        // renames. Keep the KVC-based status-item lookup as a compatibility fallback.
        guard let button = findStatusBarButton() ?? findStatusItem()?.button,
              let window = button.window else {
            Self.logger.debug("toggle: status item found but button/window missing; ignoring")
            return
        }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        let location = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            Self.logger.error("toggle: failed to construct synthetic mouse-down event")
            return
        }

        NSApp.postEvent(event, atStart: false)
    }

    // MARK: - NSApp.windows + KVC introspection

    private func findStatusBarButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let button = findStatusBarButton(in: contentView) { return button }
        }
        return nil
    }

    private func findStatusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton,
           button.accessibilityTitle() == accessibilityTitle {
            return button
        }
        for subview in view.subviews {
            if let match = findStatusBarButton(in: subview) { return match }
        }
        return nil
    }

    /// Exposed `internal` so tests can verify discovery without depending on
    /// `NSApp.postEvent` delivery, which is flaky in a unit-test process.
    func findStatusItem() -> NSStatusItem? {
        return NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap(Self.extractStatusItem(from:))
            // Multi-display setups with "Displays have separate Spaces" enabled produce
            // one NSStatusBarWindow per display; the inactive ones return an
            // `NSStatusItemReplicant`. Skip those by role instead of requiring one private
            // concrete class name: Apple has renamed the canonical implementation more than
            // once, including again after macOS 26.
            .filter { !$0.className.localizedCaseInsensitiveContains("replicant") }
            .first { $0.button?.accessibilityTitle() == accessibilityTitle }
    }

    /// Pulls the `statusItem` private key off an `NSStatusBarWindow`.
    /// KVC is the primary path; `Mirror` is a defensive fallback in case Apple
    /// changes how the property is exposed in a future macOS release.
    private static func extractStatusItem(from window: NSWindow) -> NSStatusItem? {
        if let item = window.value(forKey: "statusItem") as? NSStatusItem {
            return item
        }
        return Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem
    }
}

/// FluidMenuBarExtra normally performs this placement itself. Re-applying the
/// status-item geometry after the panel becomes key protects against a macOS
/// activation-policy transition or tutorial relaunch leaving the panel centered
/// like a conventional window.
@MainActor
enum MenuBarPopupPositioner {
    static func anchor(window: NSWindow, statusItemTitle: String) {
        guard let button = findStatusBarButton(title: statusItemTitle),
              let buttonWindow = button.window else { return }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let screen = buttonWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(buttonRectOnScreen) })
            ?? NSScreen.main
        guard let screen else { return }

        let popupSize = window.frame.size
        guard popupSize.width > 0, popupSize.height > 0 else { return }

        let horizontalInset: CGFloat = 8
        let verticalGap: CGFloat = 5
        let screenBounds = screen.frame
        let visibleBounds = screen.visibleFrame

        var origin = NSPoint(
            x: buttonRectOnScreen.midX - popupSize.width / 2,
            y: buttonRectOnScreen.minY - popupSize.height - verticalGap
        )
        origin.x = min(
            screenBounds.maxX - popupSize.width - horizontalInset,
            max(screenBounds.minX + horizontalInset, origin.x)
        )
        origin.y = max(visibleBounds.minY + horizontalInset, origin.y)

        let distance = hypot(window.frame.origin.x - origin.x, window.frame.origin.y - origin.y)
        guard distance > 1 else { return }
        window.setFrameOrigin(origin)
    }

    private static func findStatusBarButton(title: String) -> NSStatusBarButton? {
        for window in NSApp.windows {
            guard let contentView = window.contentView,
                  let button = findStatusBarButton(in: contentView, title: title) else {
                continue
            }
            return button
        }
        return nil
    }

    private static func findStatusBarButton(in view: NSView, title: String) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton,
           button.accessibilityTitle() == title {
            return button
        }
        for subview in view.subviews {
            if let match = findStatusBarButton(in: subview, title: title) {
                return match
            }
        }
        return nil
    }
}
