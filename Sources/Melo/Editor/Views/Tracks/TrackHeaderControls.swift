// Melo/Editor/Views/Tracks/TrackHeaderControls.swift
//
// The two controls a track header needs that the app did not already have: a
// solo button, and a pan control. Everything else in a header is a component
// Melo already ships — `MuteButton` for mute, `LiquidGlassSlider` for level.

import SwiftUI

// MARK: - Solo

/// Hear only this track.
///
/// Melo has no solo button, so this is the one new button in the header. It is
/// deliberately a twin of `MuteButton`: same 28pt target, same hierarchical
/// glyph, same hover treatment, so the pair reads as one control with two
/// halves rather than as two controls that happen to be adjacent.
///
/// It is not built on `MuteButton`'s shared body because that body is
/// `private` to `MuteButton.swift`, which is not a file this piece owns. The
/// duplication is the chrome, not the behaviour, and it is four lines.
///
/// Headphones rather than an "S". Logic and every DAW after it uses the letter,
/// and the letter is a convention you have to be told; a pair of headphones is
/// a picture of what soloing does, which is the difference between a user who
/// does not know and a user who cannot find out.
@MainActor
struct TrackSoloButton: View {
    let isSoloed: Bool
    /// The track's name, so VoiceOver can tell eight of these apart.
    let subject: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.step()
            action()
        } label: {
            Image(systemName: "headphones")
                // 14pt matches `MuteButton`'s glyph, which is sized to the 28pt
                // target rather than to the type scale.
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    isSoloed
                        ? DesignTokens.Colors.vuYellow
                        : DesignTokens.Colors.interactiveDefault
                )
                .frame(
                    width: DesignTokens.Dimensions.minTouchTarget,
                    height: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.meloHover)
        .help(isSoloed ? "Stop soloing" : "Hear only this track")
        .accessibilityLabel(isSoloed ? "Stop soloing \(subject)" : "Solo \(subject)")
        .accessibilityAddTraits(isSoloed ? .isSelected : [])
    }
}

// MARK: - Pan

/// Where the track sits between the speakers.
///
/// The shape is `StereoFieldControlView`'s, because that is the one thing in
/// Melo that already does this and a second visual language for the same idea
/// would be a bug the user experiences as confusion: `L`, a slider with a
/// centre notch, `R`, and a readout that snaps back to centre when clicked.
///
/// `showUnityMarker: true` is correct here and only here. `LiquidGlassSlider`
/// draws its marker and places its middle detent at the midpoint of the range,
/// and pan's range is −1…+1, whose midpoint *is* centre. The gain fader in the
/// same header cannot use it — see `TrackHeaderRow`.
@MainActor
struct TrackPanControl: View {
    @Binding var pan: Double
    /// The track's name, for VoiceOver.
    let subject: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text("L")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)

            LiquidGlassSlider(
                value: $pan,
                in: -1...1,
                showUnityMarker: true,
                accessibilityTitle: "\(subject) pan",
                valueDescription: { EditorPanFormat.spoken($0) }
            )
            .frame(maxWidth: .infinity)

            Text("R")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)

            // The readout is the way back to centre, exactly as the stereo
            // field control's is. A pan that has been nudged off centre by a
            // stray drag is otherwise very hard to put back by hand, because
            // the one value that matters is a single point on a 124pt slider.
            Button {
                pan = 0
            } label: {
                Text(EditorPanFormat.short(pan))
                    .font(DesignTokens.Typography.Scale.caption2(.medium))
                    .monospacedDigit()
                    .foregroundStyle(
                        pan == 0
                            ? DesignTokens.Colors.textTertiary
                            : DesignTokens.Colors.accentPrimary
                    )
                    .frame(width: 30, height: 16)
                    .background(Capsule().fill(DesignTokens.Colors.pickerBackground))
            }
            .buttonStyle(.meloHover)
            .disabled(pan == 0)
            .help("Center this track")
            .accessibilityLabel("Center \(subject)")
        }
    }
}
