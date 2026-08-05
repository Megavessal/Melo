import AppKit
import CoreGraphics

/// Sends the same system play/pause command as the keyboard media key.
/// Accessibility permission is required for reliable delivery.
@MainActor
enum PlaybackPauseService {
    private static let playPauseKey = 16

    static func sendPlayPause() {
        post(keyState: 0xA) // key down
        post(keyState: 0xB) // key up
    }

    private static func post(keyState: Int) {
        let data1 = (playPauseKey << 16) | (keyState << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
