// Melo/Views/Components/BoostChevrons.swift
import SwiftUI

/// Stacked chevron boost indicator — 3 SF Symbol chevrons that light up based on boost level.
/// Click to jump the unified volume slider between 1x → 2x → 3x → 4x → 1x.
struct BoostChevrons: View {
    let level: BoostLevel
    /// Takes the level to move to rather than "advance one". Clicking still
    /// cycles, but VoiceOver's increment and decrement have a direction and
    /// need to name a destination, and a cycling callback cannot express
    /// "one lower".
    let onSelect: (BoostLevel) -> Void

    @State private var isHovered = false

    /// Adjacent level, **clamped at both ends** rather than wrapping the way a
    /// click does. Wrapping an increment at 4x would drop the app from 400% to
    /// 100% — a sudden four-fold cut — in response to a gesture that means
    /// "louder". At the top, increment does nothing and says so by leaving the
    /// value where it is.
    private func stepped(_ delta: Int) -> BoostLevel? {
        let all = BoostLevel.allCases
        guard let index = all.firstIndex(of: level) else { return nil }
        let target = index + delta
        guard all.indices.contains(target) else { return nil }
        return all[target]
    }

    /// Number of lit chevrons for each boost level
    private var litCount: Int {
        switch level {
        case .x1: 0
        case .x2: 1
        case .x3: 2
        case .x4: 3
        }
    }

    /// Color for each chevron position (bottom=0, top=2)
    private func chevronColor(at index: Int) -> Color {
        if index < litCount {
            return DesignTokens.Colors.accentPrimary
        } else {
            return isHovered
                ? .primary.opacity(0.25)
                : .primary.opacity(0.15)
        }
    }

    var body: some View {
        Button {
            // Discrete jump between gain ranges — the same class of change as
            // an arrow-key step, so it gets the same level-change tick.
            Haptics.step()
            onSelect(level.next)
        } label: {
            VStack(spacing: -2) {
                ForEach((0..<3).reversed(), id: \.self) { index in
                    Image(systemName: "chevron.compact.up")
                        .font(DesignTokens.Typography.Scale.body(.heavy))
                        .foregroundStyle(chevronColor(at: index))
                }
            }
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .onHover { isHovered = $0 }
        .help("Gain range: \(level.label). Click to jump to \(level.next.label)")
        // Name in the label, setting in the value, and a way to change it —
        // rather than one string that read out both the current level and the
        // next one and still left no way to reach either.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gain range")
        .accessibilityValue(level.label)
        .accessibilityAdjustableAction { direction in
            let target: BoostLevel?
            switch direction {
            case .increment: target = stepped(1)
            case .decrement: target = stepped(-1)
            @unknown default: target = nil
            }
            guard let target else { return }
            Haptics.step()
            onSelect(target)
        }
        .animation(DesignTokens.Animation.present, value: level)
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}

// MARK: - Previews

#Preview("Boost Chevrons") {
    ComponentPreviewContainer {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack {
                BoostChevrons(level: .x1) { _ in }
                Text("1x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x2) { _ in }
                Text("2x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x3) { _ in }
                Text("3x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x4) { _ in }
                Text("4x").font(.caption)
            }
        }
    }
}
