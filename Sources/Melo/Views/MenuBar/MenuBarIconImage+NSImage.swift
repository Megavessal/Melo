// Melo/Views/MenuBar/MenuBarIconImage+NSImage.swift
// AppKit bridge for MenuBarIconImage — kept separate so the value types
// file (MenuBarIconState.swift) stays AppKit-free and the Equatable
// conformances remain nonisolated under Swift 6 strict concurrency.

import AppKit

@MainActor
extension MenuBarIconImage {
    /// The status item is variable-length: icons of differing sizes resize it and shift every neighboring menu bar item.
    static let canvasSize = NSSize(width: 22, height: 18)

    func nsImage(accessibilityDescription: String = "Melo", motionOffsetCells: Int = 0) -> NSImage? {
        if self == .meloMark {
            return Self.makePixelMeloMark(
                accessibilityDescription: accessibilityDescription,
                offsetCells: motionOffsetCells
            )
        }
        if self == .meloMarkSmooth {
            return Self.makeMeloMark(accessibilityDescription: accessibilityDescription)
        }

        let source: NSImage?
        switch self {
        case .meloMark, .meloMarkSmooth:
            source = nil
        case .systemSymbol(let name):
            source = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
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

    /// The pixel-art mark, matching the app icon.
    ///
    /// The rows below are the same waveform silhouette that the app icon uses,
    /// sampled onto a 20×11 grid. It is drawn as filled cells rather than
    /// scaled from a bitmap so each cell lands exactly on a device pixel at 1x
    /// and 2x — a shrunk PNG would blur, which is the one thing pixel art
    /// cannot survive.
    static let pixelMarkRows: [String] = [
        "00000011100000000000",
        "00000111110001100000",
        "00000111110011110000",
        "00000111110011110000",
        "01100111110011110010",
        "11111111110011111111",
        "11111100111111011111",
        "11111000111111001110",
        "00111000111111000000",
        "00000000111111000000",
        "00000000011110000000"
    ]

    private static func makePixelMeloMark(accessibilityDescription: String, offsetCells: Int = 0) -> NSImage {
        let rows = pixelMarkRows
        let columns = rows[0].count
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            // One cell per point keeps the grid aligned to the pixel grid at
            // every backing scale factor.
            // Floored to a whole point, because the comment above is the intent
            // and the division alone did not achieve it: 22/20 and 18/11 give
            // 1.1pt, so cell edges landed at 1.1, 2.2, 3.3 … — 2.2 and 4.4
            // device pixels at 2x. The mark rasterised with columns alternating
            // two and three pixels wide, which is precisely the artefact drawing
            // it as pixel art exists to avoid.
            let cell = min(
                canvasSize.width / CGFloat(columns),
                canvasSize.height / CGFloat(rows.count)
            ).rounded(.down)
            let originX = ((canvasSize.width - cell * CGFloat(columns)) / 2).rounded()
            // Whole cells only. A sub-cell offset would put the artwork between
            // device pixels and undo the point of drawing it as pixel art.
            let originY = ((canvasSize.height - cell * CGFloat(rows.count)) / 2).rounded()
                + CGFloat(offsetCells) * cell
            NSColor.black.setFill()
            for (rowIndex, row) in rows.enumerated() {
                // NSImage draws bottom-up; the rows above read top-down.
                let y = originY + CGFloat(rows.count - 1 - rowIndex) * cell
                for (columnIndex, character) in row.enumerated() where character == "1" {
                    NSRect(x: originX + CGFloat(columnIndex) * cell, y: y, width: cell, height: cell).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// The original smooth mark, kept as an option for anyone who prefers it.
    /// Geometry rather than a shrunk icon, so it stays a true template image
    /// that follows light and dark menu bars.
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
