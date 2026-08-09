// Melo/Editor/Analysis/EQCurveView.swift
import SwiftUI

// MARK: - The drawing

/// The response, its grid, and a handle per band.
///
/// A `Canvas` rather than a stack of `Path`s: the curve is 240 points that move
/// under a drag, and one draw call is the difference between a control that
/// tracks the pointer and one that lags it.
@MainActor
struct EQCurveView: View {
    let bands: [AutoEQFilter]
    let preampDB: Double
    /// Drawn only at the parametric depth. At the graphic depth the sliders are
    /// the handles, and a second set of grabbable dots on top of them is two
    /// controls for one value.
    let showsHandles: Bool
    /// Which band the pointer is on, so the list below can highlight the same one.
    var highlighted: Int?
    /// `(index, frequency, gainDB)` while a handle is dragged.
    var onDragBand: ((Int, Double, Double) -> Void)?

    @State private var draggingIndex: Int?
    /// The size the canvas last drew at. A gesture reports points in the same
    /// space, so normalising by this is what keeps hit testing and the picture
    /// from drifting apart.
    @State private var canvasSize: CGSize = CGSize(width: 1, height: Self.height)

    private static let height: CGFloat = 108
    private static let gridDecibels: [Double] = [-12, -6, 0, 6, 12]
    /// Labelled decades. The ten band centres get a hairline; these get a number.
    private static let gridFrequencies: [Double] = [100, 1000, 10000]

    var body: some View {
        Canvas { context, size in
            drawGrid(in: &context, size: size)
            drawCurve(in: &context, size: size)
            if showsHandles { drawHandles(in: &context, size: size) }
        }
        .frame(height: Self.height)
        .background {
            DesignTokens.Dimensions.Shape.sm
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .gesture(dragGesture)
        .accessibilityElement()
        .accessibilityLabel("Equalizer response")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard !bands.isEmpty else { return "Flat" }
        let moved = bands.filter { abs($0.gainDB) >= 0.05 }
        guard !moved.isEmpty else { return "Flat" }
        return moved
            .map { "\(EditorFormat.hertz($0.frequency)) \(EditorFormat.decibels(Double($0.gainDB)))" }
            .joined(separator: ", ")
    }

    // MARK: Drawing

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        for value in Self.gridDecibels {
            let y = EQResponseCurve.verticalPosition(ofDB: value) * size.height
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                line,
                with: .color(value == 0 ? Color.primary.opacity(0.22) : Color.primary.opacity(0.07)),
                lineWidth: value == 0 ? 1 : 0.5
            )
        }

        // A hairline at each of Melo's ten band centres, so the two depths are
        // visibly the same instrument.
        for frequency in EQSettings.frequencies {
            let x = EQResponseCurve.position(ofFrequency: frequency) * size.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Color.primary.opacity(0.05)), lineWidth: 0.5)
        }

        for frequency in Self.gridFrequencies {
            let x = EQResponseCurve.position(ofFrequency: frequency) * size.width
            let text = Text(EditorFormat.hertz(frequency))
                .font(DesignTokens.Typography.Scale.caption2())
                .foregroundStyle(DesignTokens.Colors.textQuaternary)
            context.draw(text, at: CGPoint(x: x, y: size.height - 7), anchor: .center)
        }
    }

    private func drawCurve(in context: inout GraphicsContext, size: CGSize) {
        let points = EQResponseCurve.curve(bands: bands, preampDB: preampDB)
        guard points.count > 1 else { return }

        var stroke = Path()
        for (index, value) in points.enumerated() {
            let x = size.width * Double(index) / Double(points.count - 1)
            let y = EQResponseCurve.verticalPosition(ofDB: value) * size.height
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                stroke.move(to: point)
            } else {
                stroke.addLine(to: point)
            }
        }

        // The area between the curve and unity, which is what the curve is
        // actually doing. Faint enough to stay a hint rather than a chart.
        var fill = stroke
        let zero = EQResponseCurve.verticalPosition(ofDB: 0) * size.height
        fill.addLine(to: CGPoint(x: size.width, y: zero))
        fill.addLine(to: CGPoint(x: 0, y: zero))
        fill.closeSubpath()
        context.fill(fill, with: .color(Color.accentColor.opacity(0.13)))

        context.stroke(
            stroke,
            with: .color(Color.accentColor),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawHandles(in context: inout GraphicsContext, size: CGSize) {
        for (index, band) in bands.enumerated() {
            let x = EQResponseCurve.position(ofFrequency: band.frequency) * size.width
            let y = EQResponseCurve.verticalPosition(ofDB: Double(band.gainDB)) * size.height
            let isActive = highlighted == index || draggingIndex == index
            let radius: CGFloat = isActive ? 5 : 3.5
            let circle = Path(ellipseIn: CGRect(
                x: x - radius, y: y - radius, width: radius * 2, height: radius * 2
            ))
            context.fill(circle, with: .color(DesignTokens.Colors.thumbBackground))
            context.stroke(circle, with: .color(Color.accentColor), lineWidth: isActive ? 2 : 1.5)
        }
    }

    // MARK: Dragging

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard showsHandles, let onDragBand else { return }
                guard let index = draggingIndex ?? nearestBand(to: value.startLocation) else {
                    return
                }
                draggingIndex = index
                onDragBand(index, draggedFrequency(value.location), draggedGain(value.location))
            }
            .onEnded { _ in draggingIndex = nil }
    }

    /// Hit testing runs through the same axis functions the handles are drawn
    /// with, so it cannot drift from the picture. Nearest in x is enough: two
    /// bands at the same frequency and different gains is not a curve anyone is
    /// trying to edit by pointing at it.
    private func nearestBand(to point: CGPoint) -> Int? {
        guard !bands.isEmpty else { return nil }
        return bands.indices.min { left, right in
            abs(handleX(bands[left]) - Double(point.x))
                < abs(handleX(bands[right]) - Double(point.x))
        }
    }

    private func handleX(_ band: AutoEQFilter) -> Double {
        EQResponseCurve.position(ofFrequency: band.frequency) * Double(canvasSize.width)
    }

    private func draggedFrequency(_ point: CGPoint) -> Double {
        let position = Double(point.x) / max(Double(canvasSize.width), 1)
        return (EQResponseCurve.frequency(atPosition: position)).rounded()
    }

    private func draggedGain(_ point: CGPoint) -> Double {
        let fraction = Double(point.y) / max(Double(canvasSize.height), 1)
        return (EQResponseCurve.decibels(atVerticalPosition: fraction) * 10).rounded() / 10
    }
}
