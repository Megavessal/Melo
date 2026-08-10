// Melo/Editor/Views/Chain/MoveInspectorControls.swift
import SwiftUI
import AppKit

// The primitives every move inspector is built from: four rows
// (`MoveNumberRow`, `MoveTimeRow`, `MoveChoiceRow`, `MoveFactRow`), the
// `MoveNumberField` the numeric rows share, and the `MoveInspectorBody` that
// holds them. A gain in dB, a fade in seconds and a gate release in
// milliseconds are the same control wearing different units — the Chain is one
// object the user learns once, not fifteen little panels each with its own
// habits.

// MARK: - A number with a unit

/// One editable number: a name, a slider, and a click-to-type readout carrying
/// the unit.
///
/// The slider is `LiquidGlassSlider` — the app's only slider — and its output is
/// snapped to `step` before it is stored, so the number shown is the number
/// held. A readout that rounds a value it did not change is how a UI ends up
/// claiming 4.0 dB while rendering 4.037.
///
/// The numeral comes from `EditorFormat.number`, which is Melo Edit's
/// only number formatter, at a **fixed** number of places. An inspector value
/// that gains and loses a decimal under a moving slider is unreadable, and a
/// readout whose unit changes with magnitude — "1000 ms" becoming "1 s" — can
/// no longer be typed back into itself.
@MainActor
struct MoveNumberRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var places: Int = 1
    /// Draws the centre detent. Only true for ranges whose midpoint means
    /// "no change" — gain, tilt — never for a range like 20…500 Hz where the
    /// middle is not a landmark.
    var showsUnityMarker: Bool = false

    init(
        label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        unit: String,
        places: Int = 1,
        showsUnityMarker: Bool = false
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.places = places
        self.showsUnityMarker = showsUnityMarker
    }

    private var snapped: Binding<Double> {
        Binding(
            get: { value },
            set: { value = MoveNumberField.snap($0, to: step, in: range) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(label)
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(.secondary)

                Spacer(minLength: DesignTokens.Spacing.xs)

                MoveNumberField(
                    value: snapped,
                    range: range,
                    step: step,
                    label: label,
                    format: { MoveNumberField.text($0, unit: unit, places: places) },
                    parse: { MoveNumberField.number(from: $0) }
                )
            }

            LiquidGlassSlider(
                value: snapped,
                in: range,
                showUnityMarker: showsUnityMarker,
                accessibilityTitle: label,
                valueDescription: { MoveNumberField.text($0, unit: unit, places: places) }
            )
        }
    }
}

/// A number that is a position or a length in the sound. Same control, but the
/// readout speaks minutes and seconds, because "1:47.20" is where the user is
/// and "107.2 s" is arithmetic they have to do.
@MainActor
struct MoveTimeRow: View {
    let label: String
    @Binding var value: TimeInterval
    let range: ClosedRange<TimeInterval>
    var step: TimeInterval = 0.01

    init(
        label: String,
        value: Binding<TimeInterval>,
        in range: ClosedRange<TimeInterval>,
        step: TimeInterval = 0.01
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
    }

    private var snapped: Binding<Double> {
        Binding(
            get: { value },
            set: { value = MoveNumberField.snap($0, to: step, in: range) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(label)
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(.secondary)

                Spacer(minLength: DesignTokens.Spacing.xs)

                MoveNumberField(
                    value: snapped,
                    range: range,
                    step: step,
                    label: label,
                    format: { EditorFormat.timecode($0, decimals: 2) },
                    parse: { MoveNumberField.seconds(from: $0) }
                )
            }

            LiquidGlassSlider(
                value: snapped,
                in: range,
                accessibilityTitle: label,
                // Spoken, not read: "1:23" out loud is a street address.
                valueDescription: { EditorFormat.spokenTime($0) }
            )
        }
    }
}

// MARK: - The readout

/// Click-to-type numeric readout, following `EditablePercentage`'s manners —
/// quiet at rest, a pill on hover, an accent pill while editing — because that
/// is how a number is typed everywhere else in Melo. It exists separately only
/// because `EditablePercentage` is `Int` and hard-wired to `%`, and dB, Hz, ms
/// and seconds are none of those.
@MainActor
struct MoveNumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let format: (Double) -> String
    let parse: (String) -> Double?

    @State private var isEditing = false
    @State private var isHovered = false
    @State private var input = ""
    @FocusState private var fieldFocused: Bool

    private var textColor: Color {
        if isEditing { return DesignTokens.Colors.accentPrimary }
        return isHovered ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary
    }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.numeric)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.trailing)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { isEditing = false }
                    .frame(minWidth: 52, alignment: .trailing)
            } else {
                Text(format(value))
                    .font(DesignTokens.Typography.numeric)
                    .foregroundStyle(textColor)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.vertical, 1)
        .background {
            if isEditing {
                DesignTokens.Dimensions.Shape.xs
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))
                    .overlay {
                        DesignTokens.Dimensions.Shape.xs
                            .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.4), lineWidth: 1)
                    }
            } else if isHovered {
                DesignTokens.Dimensions.Shape.xs
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { beginEditing() }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // Clicking away is a commit, not a discard: the field is a readout the
        // user typed into, and losing the number they just entered because they
        // reached for the next control is indefensible. Escape still discards.
        .onChange(of: fieldFocused) { _, focused in
            if !focused && isEditing { commit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(by: step)
            case .decrement: nudge(by: -step)
            @unknown default: break
            }
        }
        .animation(DesignTokens.Animation.quick, value: isEditing)
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }

    private func beginEditing() {
        guard !isEditing else { return }
        input = format(value)
        isEditing = true
        Task { @MainActor in fieldFocused = true }
    }

    private func commit() {
        if let parsed = parse(input) {
            value = Self.snap(parsed, to: step, in: range)
        }
        isEditing = false
    }

    private func nudge(by delta: Double) {
        let next = Self.snap(value + delta, to: step, in: range)
        guard next != value else { return }
        value = next
        Haptics.step()
    }

    // MARK: Formatting and parsing
    //
    // `nonisolated` so a `valueDescription` closure handed to the slider can
    // call them without inheriting an isolation it does not need.

    nonisolated static func snap(
        _ candidate: Double,
        to step: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        let clamped = min(max(candidate, range.lowerBound), range.upperBound)
        guard step > 0, clamped.isFinite else { return clamped }
        let stepped = (clamped / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// `EditorFormat.number` is Melo Edit's only numeral, so a dB here
    /// and the same dB in the Chain row above are the same string.
    nonisolated static func text(_ value: Double, unit: String, places: Int) -> String {
        let numeral = EditorFormat.number(value, places: places)
        return unit.isEmpty ? numeral : "\(numeral) \(unit)"
    }

    /// The inverse of `text(_:unit:places:)`, and it has to be exact: whatever
    /// the field shows must type back into the same value.
    ///
    /// Two traps. `EditorFormat` writes a real minus (U+2212), which is not the
    /// hyphen `Double` parses — dropping it silently turns −3 dB into +3 dB.
    /// And a person typing a frequency writes "4.2k" as often as "4200".
    nonisolated static func number(from string: String) -> Double? {
        let normalised = string
            .replacingOccurrences(of: EditorFormat.minusSign, with: "-")
            .replacingOccurrences(of: ",", with: ".")
        let isKilo = normalised.lowercased().contains("k")
        let stripped = normalised.filter { "0123456789.+-".contains($0) }
        guard let value = Double(stripped) else { return nil }
        return isKilo ? value * 1000 : value
    }

    /// Accepts "1:47.2", "1:02:03.5", or a plain number of seconds — all three
    /// are things a person types into a field showing "1:47.20".
    nonisolated static func seconds(from string: String) -> TimeInterval? {
        let trimmed = string
            .replacingOccurrences(of: EditorFormat.minusSign, with: "-")
            .trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]),
                  let secs = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + secs
        case 2:
            guard let minutes = Double(parts[0]), let secs = Double(parts[1]) else { return nil }
            return minutes * 60 + secs
        default:
            return number(from: trimmed)
        }
    }
}

// MARK: - A choice between named options

/// The segmented control, following `ModeToggle`'s treatment. Used where the
/// parameter is a name rather than a number — a fade curve, a channel mode.
@MainActor
struct MoveChoiceRow<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    @State private var hovered: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(label)
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(options, id: \.value) { option in
                    optionButton(option.value, title: option.title)
                }
            }
            .background {
                DesignTokens.Dimensions.Shape.sm
                    .fill(.regularMaterial)
            }
            .overlay {
                DesignTokens.Dimensions.Shape.sm
                    .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func optionButton(_ value: Value, title: String) -> some View {
        let isSelected = selection == value
        let isHovered = hovered == value

        Button {
            guard selection != value else { return }
            Haptics.step()
            withAnimation(DesignTokens.Animation.present) { selection = value }
        } label: {
            Text(title)
                .font(DesignTokens.Typography.Scale.caption(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, DesignTokens.Spacing.xs2)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .frame(maxWidth: .infinity)
                .background {
                    DesignTokens.Dimensions.Shape.custom(
                        DesignTokens.Dimensions.innerRadius(
                            outer: DesignTokens.Dimensions.buttonRadius,
                            inset: 1
                        )
                    )
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.15)
                            : (isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
                    )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
        .whenHovered { hovering in
            withAnimation(DesignTokens.Animation.hover) {
                hovered = hovering ? value : nil
            }
        }
    }
}

// MARK: - A measured fact

/// A number the user cannot set because Melo measured it. Shown, never edited:
/// a field that lets you type over a measurement is a field that lets you make
/// the app lie about the file.
@MainActor
struct MoveFactRow: View {
    let label: String
    let value: String
    /// One short line under the value, when the fact needs a word of context.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(label)
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(.secondary)

                Spacer(minLength: DesignTokens.Spacing.xs)

                Text(value)
                    .font(DesignTokens.Typography.numeric)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            if let note {
                Text(note)
                    .font(DesignTokens.Typography.Scale.caption2())
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The inspector body

/// The recessed panel every inspector sits in. Matches the EQ panel's inset
/// surface, so an opened move reads as the same kind of thing as an opened
/// equalizer rather than as a second design.
@MainActor
struct MoveInspectorBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .background {
            DesignTokens.Dimensions.Shape.sm
                .fill(DesignTokens.Colors.recessedBackground)
        }
    }
}
