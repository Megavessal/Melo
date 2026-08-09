// Melo/Editor/Analysis/EditorEQPanel.swift
import SwiftUI

/// The equalizer, at two depths, over one array.
///
/// Melo's runtime EQ is a fixed ten-band graphic: gain only, `Q = 1.4`, always
/// peaking. The editor's EQ is **the same filters with frequency and Q
/// unlocked** — not a second equalizer. So:
///
/// - **Ten bands** is `EQPanelView`, the panel that already ships in the popup
///   and in setup. It is not redrawn here. Its ten sliders write
///   `[AutoEQFilter]`s at Melo's own frequencies through the `EQSettings`
///   bridge, and its preset picker brings all twenty built-ins and every saved
///   user preset with it.
/// - **Parametric** is the same array with every field exposed.
///
/// Both draw through `EQResponseCurve`, which evaluates `BiquadMath`'s own
/// coefficients, so the picture cannot disagree with the sound.
///
/// ## Switching depths does not lose the curve
///
/// The array is the truth and neither depth owns it. Ten bands → parametric is
/// exact, because the ten bands already *are* parametric bands. Parametric →
/// ten bands is only exact when the array is still on Melo's grid; when it is
/// not, the panel says so and offers to fit it rather than quietly discarding
/// the shelves. Switching back and forth without pressing that button changes
/// nothing.
///
/// ## The preamp is not a control
///
/// It is derived from the bands by the rule in `EQSettings.preampDB`: cut by the
/// largest positive gain, so a boosting curve keeps its shape instead of
/// arriving at the limiter hot. `EQResponseCurve.automaticPreampDB` generalises
/// that to shelves. Two headroom concepts in one app is one too many.
@MainActor
struct EditorEQPanel: View {

    /// Which set of controls is showing. The array underneath is the same either
    /// way, which is the whole point.
    enum Depth: String, Hashable, CaseIterable {
        case graphic, parametric
        var title: String {
            switch self {
            case .graphic: "Ten bands"
            case .parametric: "Parametric"
            }
        }
    }

    /// Needed only by the "Save to Melo" button and by the user-preset list. Nil
    /// is a supported state: both degrade to absent rather than to broken, which
    /// is also what makes this panel renderable with nothing behind it.
    private let settings: SettingsManager?
    private let onChange: ([AutoEQFilter], Double) -> Void

    @State private var bands: [AutoEQFilter]
    @State private var depth: Depth
    /// `EQPanelView` has an on/off switch and it has to mean something here.
    ///
    /// Off emits an **empty** band array, so the stored move genuinely does
    /// nothing and its own summary says "0 bands" rather than claiming ten bands
    /// that are secretly bypassed. The curve stays in this view's state, so
    /// switching back restores it. Two things this deliberately is not: a toggle
    /// that snaps back (a dead control), and a set of zeroed gains (which would
    /// read as ten real bands doing nothing and lose the curve anyway).
    ///
    /// The cost, stated plainly: the document's truth is the empty array, so if
    /// SwiftUI ever rebuilds this view while the EQ is off, the curve is gone and
    /// the panel comes back off and flat. Consistent with what is stored, which
    /// is the property worth keeping.
    @State private var isActive: Bool
    @State private var highlighted: Int?
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var savedName: String?
    @FocusState private var nameFieldFocused: Bool

    /// The pinned initialiser. `settings` is defaulted and sits ahead of
    /// `onChange`, so `EditorEQPanel(bands:preampDB:) { … }` still resolves.
    init(
        bands: [AutoEQFilter],
        preampDB: Double,
        settings: SettingsManager? = nil,
        onChange: @escaping ([AutoEQFilter], Double) -> Void
    ) {
        self.init(bands: bands, preampDB: preampDB, settings: settings,
                  depth: .graphic, onChange: onChange)
    }

    /// The depth is view state, not document state, so the store's snapshot
    /// seeding cannot reach it. This is how a scene renders the parametric side.
    ///
    /// `preampDB` is accepted and not stored. The preamp is derived from the
    /// bands — see the note on this type — so honouring an incoming value would
    /// give the panel two sources of truth for one number, and the one the user
    /// can see would be the one that loses.
    init(
        bands: [AutoEQFilter],
        preampDB: Double,
        settings: SettingsManager?,
        depth: Depth,
        onChange: @escaping ([AutoEQFilter], Double) -> Void
    ) {
        self.settings = settings
        self.onChange = onChange
        // `AddMoveMenu` already hands a new equalizer move Melo's ten flat bands,
        // so an empty array here means the panel was switched off — the curve is
        // gone and flat is the only honest thing to show.
        _bands = State(initialValue: bands.isEmpty
            ? EQResponseCurve.flatGraphicBands
            : bands)
        // An empty array is what "off" stores, so an empty array is what "off"
        // reads back as. Seeding this `true` would show an active panel over a
        // move that is doing nothing.
        _isActive = State(initialValue: !bands.isEmpty)
        _depth = State(initialValue: depth)
    }

    private var preampDB: Double { EQResponseCurve.automaticPreampDB(for: bands) }
    private var isGraphicShaped: Bool { EQResponseCurve.isGraphicShaped(bands) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            EQCurveView(
                bands: bands,
                preampDB: isActive ? preampDB : 0,
                showsHandles: depth == .parametric,
                highlighted: highlighted,
                onDragBand: { index, frequency, gain in
                    setBand(at: index, frequency: frequency, gainDB: gain)
                }
            )
            .opacity(isActive ? 1 : 0.35)

            MoveChoiceRow(
                label: "Equalizer",
                selection: $depth,
                options: Depth.allCases.map { (value: $0, title: $0.title) }
            )

            switch depth {
            case .graphic: graphicDepth
            case .parametric: parametricDepth
            }

            saveRow
        }
        .animation(DesignTokens.Animation.panel, value: depth)
    }

    // MARK: - Ten bands

    @ViewBuilder
    private var graphicDepth: some View {
        if isGraphicShaped {
            // Melo's own EQ panel, unchanged. Twenty built-in presets and every
            // saved user preset arrive with it.
            EQPanelView(
                settings: graphicSettings,
                userPresets: settings?.getUserPresets() ?? [],
                onPresetSelected: { preset in
                    apply(EQSettings(bandGains: preset.settings.bandGains))
                },
                onUserPresetSelected: { preset in
                    apply(EQSettings(bandGains: preset.settings.bandGains))
                },
                // The binding above has already stored whatever changed; this
                // callback would be a second write of the same value.
                onSettingsChanged: { _ in },
                onSavePreset: { name, value in
                    save(named: name, settings: value)
                },
                onDeleteUserPreset: { identifier in
                    settings?.deleteUserPreset(id: identifier)
                },
                onRenameUserPreset: { identifier, name in
                    settings?.updateUserPreset(id: identifier, name: name)
                }
            )
        } else {
            offGridNotice
        }
    }

    /// The ten-band view of the array, and the write back into it.
    private var graphicSettings: Binding<EQSettings> {
        Binding(
            get: { EQSettings(autoEQFilters: bands, isEnabled: isActive) },
            set: { updated in
                isActive = updated.isEnabled
                bands = updated.autoEQFilters
                emit()
            }
        )
    }

    /// Shown when the array has been shaped past what ten fixed bands can hold.
    /// The alternative — silently projecting it — would make switching depth a
    /// destructive edit, and the user would find out by looking at a curve that
    /// had changed while they were not editing it.
    private var offGridNotice: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs2) {
            Text("This curve isn't on Melo's ten bands.")
                .font(DesignTokens.Typography.Scale.footnote(.medium))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text("Fitting it measures the curve at each of the ten frequencies. "
                 + "Close, not identical.")
                .font(DesignTokens.Typography.Scale.caption())
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Fit it to ten bands") {
                bands = EQResponseCurve.flattenedToGraphicBands(bands: bands, preampDB: 0)
                emit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .background {
            DesignTokens.Dimensions.Shape.sm
                .fill(DesignTokens.Colors.recessedBackground)
        }
    }

    // MARK: - Parametric

    private var parametricDepth: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Shape").frame(width: 58, alignment: .leading)
                Text("Centre").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Gain").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Q").frame(width: 38, alignment: .trailing)
                Color.clear.frame(width: 16)
            }
            .font(DesignTokens.Typography.Scale.caption2())
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .accessibilityHidden(true)

            ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                bandRow(index: index, band: band)
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    addBand()
                } label: {
                    Label("Add a band", systemImage: "plus")
                        .font(DesignTokens.Typography.Scale.caption())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // Ten is `AutoEQProfile.maxFilters`, the ceiling Melo's own
                // correction profiles already run at.
                .disabled(bands.count >= AutoEQProfile.maxFilters)
                .accessibilityLabel("Add an equalizer band")

                Spacer(minLength: DesignTokens.Spacing.xs)

                if preampDB < 0 {
                    Text("Headroom \(EditorFormat.decibels(preampDB))")
                        .font(DesignTokens.Typography.Scale.caption2())
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .help("This curve boosts, so Melo lowers the level first. "
                              + "The shape is unchanged; only its loudness is.")
                        .accessibilityLabel("Headroom \(EditorFormat.decibels(preampDB))")
                }
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("Preset")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                // The same picker the popup uses. The frozen decision rejected a
                // genre list as the *novice entry point*; it did not ban Melo's
                // twenty presets, and hiding them from the deep view would be
                // reinventing rather than restraint.
                EQPresetPicker(
                    selectedItem: matchingPickerItem,
                    userPresets: settings?.getUserPresets() ?? [],
                    onBuiltInSelected: { preset in
                        apply(EQSettings(bandGains: preset.settings.bandGains))
                    },
                    onUserPresetSelected: { preset in
                        apply(EQSettings(bandGains: preset.settings.bandGains))
                    },
                    onDeleteUserPreset: { identifier in
                        settings?.deleteUserPreset(id: identifier)
                    },
                    onRenameUserPreset: { identifier, name in
                        settings?.updateUserPreset(id: identifier, name: name)
                    }
                )

                Spacer(minLength: 0)
            }
            .zIndex(1)
        }
        .padding(DesignTokens.Spacing.sm)
        .background {
            DesignTokens.Dimensions.Shape.sm
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .opacity(isActive ? 1 : 0.35)
        .allowsHitTesting(isActive)
    }

    @ViewBuilder
    private func bandRow(index: Int, band: AutoEQFilter) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            DropdownMenu(
                items: EQFilterShape.all,
                selectedItem: EQFilterShape.all.first { $0.type == band.type },
                maxVisibleItems: nil,
                width: 58,
                popoverWidth: 110,
                onSelect: { shape in setBand(at: index, type: shape.type) },
                label: { Text($0?.short ?? "Peak") },
                itemContent: { shape, isSelected in
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(shape.full).lineLimit(1)
                        Spacer(minLength: DesignTokens.Spacing.xs)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(DesignTokens.Typography.Scale.caption(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            )
            .accessibilityLabel("Band \(index + 1) shape")

            Spacer(minLength: 0)

            MoveNumberField(
                value: Binding(
                    get: { band.frequency },
                    set: { setBand(at: index, frequency: $0) }
                ),
                range: EQResponseCurve.minimumFrequency...EQResponseCurve.maximumFrequency,
                step: 1,
                label: "Band \(index + 1) centre frequency",
                format: { EditorFormat.hertz($0) },
                parse: { MoveNumberField.number(from: $0) }
            )

            Spacer(minLength: 0)

            MoveNumberField(
                value: Binding(
                    get: { Double(band.gainDB) },
                    set: { setBand(at: index, gainDB: $0) }
                ),
                // The same ±12 dB `EQSettings` allows. The editor unlocks
                // frequency and Q; it does not raise Melo's gain ceiling.
                range: Double(EQSettings.minGainDB)...Double(EQSettings.maxGainDB),
                step: 0.1,
                label: "Band \(index + 1) gain",
                format: { MoveNumberField.text($0, unit: "dB", places: 1) },
                parse: { MoveNumberField.number(from: $0) }
            )

            MoveNumberField(
                value: Binding(
                    get: { band.q },
                    set: { setBand(at: index, q: $0) }
                ),
                range: 0.2...12,
                step: 0.05,
                label: "Band \(index + 1) Q",
                format: { EditorFormat.number($0, places: 2) },
                parse: { MoveNumberField.number(from: $0) }
            )
            .frame(width: 38, alignment: .trailing)

            Button {
                removeBand(at: index)
            } label: {
                Image(systemName: "minus.circle")
                    .font(DesignTokens.Typography.Scale.footnote())
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DesignTokens.Colors.interactiveDefault)
            }
            .buttonStyle(.meloHover)
            .disabled(bands.count <= 1)
            .frame(width: 16)
            .accessibilityLabel("Remove band \(index + 1)")
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .whenHovered { hovering in highlighted = hovering ? index : nil }
    }

    // MARK: - Save to Melo

    /// The one thing no other audio editor can do: the curve you just built for
    /// this file becomes a Melo preset, usable on Spotify and everything else on
    /// this Mac the moment it is saved. It saves the ten-band projection,
    /// because that is what a `UserEQPreset` is.
    @ViewBuilder
    private var saveRow: some View {
        if let manager = settings {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if isNamingPreset {
                    TextField("Name it", text: $presetName)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.Scale.footnote(.medium))
                        .focused($nameFieldFocused)
                        .onSubmit { commitSave(manager) }
                        .onExitCommand { isNamingPreset = false }
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                        .background {
                            DesignTokens.Dimensions.Shape.sm
                                .fill(DesignTokens.Colors.recessedBackground)
                        }

                    Button("Save") { commitSave(manager) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                } else if let savedName {
                    Label("Saved as “\(savedName)”", systemImage: "checkmark.circle")
                        .font(DesignTokens.Typography.Scale.caption())
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .accessibilityLabel("Saved as \(savedName)")
                } else {
                    Button {
                        presetName = "My curve"
                        isNamingPreset = true
                        Task { @MainActor in nameFieldFocused = true }
                    } label: {
                        Label("Save to Melo", systemImage: "square.and.arrow.down")
                            .font(DesignTokens.Typography.Scale.caption())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Saves this curve as a Melo preset you can use on any app")

                    Text("Then it's available on every app on this Mac.")
                        .font(DesignTokens.Typography.Scale.caption2())
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 0)
            }
            .animation(DesignTokens.Animation.quick, value: isNamingPreset)
            .animation(DesignTokens.Animation.quick, value: savedName)
        }
    }

    private func commitSave(_ manager: SettingsManager) {
        let trimmed = presetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let preset = save(named: trimmed, settings: graphicProjection, using: manager)
        isNamingPreset = false
        // The manager renames duplicates Finder-style, so the confirmation shows
        // the name it actually got rather than the one that was typed.
        savedName = preset?.name
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            savedName = nil
        }
    }

    @discardableResult
    private func save(
        named name: String,
        settings value: EQSettings,
        using manager: SettingsManager? = nil
    ) -> UserEQPreset? {
        guard let manager = manager ?? settings else { return nil }
        // `isEnabled` is per-app state, never preset state — the same rule
        // `EQPanelView.commitSave` follows.
        var stored = value
        stored.isEnabled = true
        return manager.createUserPreset(name: name, settings: stored)
    }

    /// What this curve looks like as a ten-band preset.
    private var graphicProjection: EQSettings {
        isGraphicShaped
            ? EQSettings(autoEQFilters: bands)
            : EQSettings(autoEQFilters: EQResponseCurve.flattenedToGraphicBands(
                bands: bands, preampDB: 0
            ))
    }

    private var matchingPickerItem: EQPickerItem? {
        let gains = graphicProjection.bandGains
        if let builtIn = EQPreset.allCases.first(where: { $0.settings.bandGains == gains }) {
            return EQPickerItem(builtIn: builtIn)
        }
        if let user = settings?.getUserPresets().first(where: { $0.settings.bandGains == gains }) {
            return EQPickerItem(user: user)
        }
        return nil
    }

    // MARK: - Editing the array

    /// `AutoEQFilter`'s properties are `let`, so every edit rebuilds the band.
    /// That is not a workaround: a band is a value, and replacing it is what
    /// makes the array safe to hand across an actor boundary.
    private func setBand(
        at index: Int,
        type: AutoEQFilter.FilterType? = nil,
        frequency: Double? = nil,
        gainDB: Double? = nil,
        q: Double? = nil
    ) {
        guard bands.indices.contains(index) else { return }
        let existing = bands[index]
        bands[index] = AutoEQFilter(
            type: type ?? existing.type,
            frequency: min(max(frequency ?? existing.frequency,
                               EQResponseCurve.minimumFrequency),
                           EQResponseCurve.maximumFrequency),
            gainDB: gainDB.map {
                Float(min(max($0, Double(EQSettings.minGainDB)), Double(EQSettings.maxGainDB)))
            } ?? existing.gainDB,
            q: min(max(q ?? existing.q, 0.2), 12)
        )
        emit()
    }

    private func addBand() {
        guard bands.count < AutoEQProfile.maxFilters else { return }
        // 1 kHz at Melo's own Q, flat. A new band that already does something is
        // a change the user did not ask for.
        bands.append(AutoEQFilter(
            type: .peaking, frequency: 1000, gainDB: 0, q: BiquadMath.graphicEQQ
        ))
        emit()
    }

    private func removeBand(at index: Int) {
        guard bands.count > 1, bands.indices.contains(index) else { return }
        bands.remove(at: index)
        highlighted = nil
        emit()
    }

    /// A ten-band curve arriving from a preset replaces the array outright. That
    /// is the one place a depth switch is not the cause of a shape change, and
    /// it is what picking a preset means.
    private func apply(_ settings: EQSettings) {
        bands = settings.autoEQFilters
        emit()
    }

    private func emit() {
        onChange(isActive ? bands : [], isActive ? preampDB : 0)
    }
}

// MARK: - Filter shapes

/// The three shapes `BiquadMath` can build, named twice: short enough for a
/// 58pt trigger, long enough to be unambiguous in the menu.
private struct EQFilterShape: Identifiable, Hashable {
    let id: String
    let type: AutoEQFilter.FilterType
    let short: String
    let full: String

    static let all: [EQFilterShape] = [
        EQFilterShape(id: "peaking", type: .peaking, short: "Peak", full: "Peak"),
        EQFilterShape(id: "lowShelf", type: .lowShelf, short: "Low", full: "Low shelf"),
        EQFilterShape(id: "highShelf", type: .highShelf, short: "High", full: "High shelf")
    ]
}
