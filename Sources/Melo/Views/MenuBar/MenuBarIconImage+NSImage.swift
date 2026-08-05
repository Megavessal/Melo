// Melo/Views/MenuBar/MenuBarIconImage+NSImage.swift
// AppKit bridge for MenuBarIconImage — kept separate so the value types
// file (MenuBarIconState.swift) stays AppKit-free and the Equatable
// conformances remain nonisolated under Swift 6 strict concurrency.

import AppKit

@MainActor
extension MenuBarIconImage {
    /// The status item is variable-length: icons of differing sizes resize it and shift every neighboring menu bar item.
    static let canvasSize = NSSize(width: 22, height: 18)

    func nsImage(accessibilityDescription: String = "Melo") -> NSImage? {
        if self == .meloMark {
            return Self.makeMeloMark(accessibilityDescription: accessibilityDescription)
        }

        let source: NSImage?
        switch self {
        case .meloMark:
            source = nil
        case .systemSymbol(let name):
            source = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        case .asset(let name):
            source = NSImage(named: name)
        }
        guard let source else { return nil }

        let canvas = Self.canvasSize
        let scale = min(1, canvas.width / source.size.width, canvas.height / source.size.height)
        let drawRect = NSRect(
            x: (canvas.width - source.size.width * scale) / 2,
            y: (canvas.height - source.size.height * scale) / 2,
            width: source.size.width * scale,
            height: source.size.height * scale
        )
        let image = NSImage(size: canvas, flipped: false) { _ in
            source.draw(in: drawRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// A menu-bar-sized rendering of the signature mark from Melo's app icon.
    /// Keeping this as geometry (instead of shrinking the full-colour icon)
    /// gives macOS a true template image that follows light/dark menu bars.
    private static func makeMeloMark(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 1.1, y: 9.0))
            path.curve(
                to: NSPoint(x: 5.1, y: 8.6),
                controlPoint1: NSPoint(x: 2.4, y: 9.0),
                controlPoint2: NSPoint(x: 2.7, y: 5.3)
            )
            path.curve(
                to: NSPoint(x: 8.0, y: 14.2),
                controlPoint1: NSPoint(x: 7.5, y: 8.3),
                controlPoint2: NSPoint(x: 5.6, y: 14.2)
            )
            path.curve(
                to: NSPoint(x: 11.0, y: 4.0),
                controlPoint1: NSPoint(x: 10.5, y: 14.2),
                controlPoint2: NSPoint(x: 8.6, y: 4.0)
            )
            path.curve(
                to: NSPoint(x: 14.0, y: 13.1),
                controlPoint1: NSPoint(x: 13.5, y: 4.0),
                controlPoint2: NSPoint(x: 11.6, y: 13.1)
            )
            path.curve(
                to: NSPoint(x: 16.9, y: 8.6),
                controlPoint1: NSPoint(x: 16.4, y: 13.1),
                controlPoint2: NSPoint(x: 14.5, y: 8.6)
            )
            path.curve(
                to: NSPoint(x: 20.9, y: 9.0),
                controlPoint1: NSPoint(x: 19.3, y: 8.3),
                controlPoint2: NSPoint(x: 19.6, y: 9.0)
            )
            path.lineWidth = 2.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
