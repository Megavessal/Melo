import AppKit
import SwiftUI

/// Publishes the system's Reduce Motion setting so SwiftUI can react to it.
///
/// `DesignTokens.Animation.isReduced` reads `NSWorkspace` directly, which is
/// accurate but invisible to SwiftUI's dependency tracking: turning Reduce Motion
/// on in System Settings left every already-rendered view animating exactly as
/// before until some unrelated state change forced a redraw. Observing
/// `accessibilityDisplayOptionsDidChangeNotification` and republishing gives the
/// view graph something to invalidate on, so the preference takes effect the
/// moment it is changed — which is the whole point of an accessibility setting.
@MainActor
@Observable
final class MotionPreference {
    static let shared = MotionPreference()

    private(set) var isReduced: Bool
    private var observer: NSObjectProtocol?

    private init() {
        isReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    // No deinit: `shared` is a singleton that lives for the process, so tearing the
    // observer down is unreachable code. It also cannot be written safely here —
    // deinit is nonisolated, so it may not touch this @MainActor property.
}
