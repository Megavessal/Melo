import AVFoundation
import AppKit
import SwiftUI

/// The sound behind setup's one interactive control.
///
/// Deliberately `AVAudioPlayer` on Melo's own bundled file rather than the audio
/// engine: it needs no permission, so the slider works identically whether the
/// person allowed system audio or refused it, and it cannot alter anything the
/// person has set. A demo that only works after a grant would teach nobody who
/// said no — and they are exactly the people left wondering what Melo does.
@Observable
@MainActor
final class OnboardingVolumeDemo {
    var volume: Double = 0.7 {
        didSet { player?.volume = Float(volume) }
    }

    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle() {
        if isPlaying {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard let url = Bundle.main.url(forResource: "MeloFirstRunIntro", withExtension: "wav") else { return }
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: url)
            // Looped, because the point is to keep playing while the slider is
            // dragged. A one-shot clip ends before the gesture does.
            player?.numberOfLoops = -1
        }
        player?.volume = Float(volume)
        guard player?.play() == true else { return }
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
    }
}

@MainActor
struct FirstRunOnboardingView: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var audioPrimer: FirstRunAudioPrimer
    let audioEngine: AudioEngine
    /// Snapshot frames need to render a specific page; the real flow always
    /// starts at the beginning.
    var initialPage: Int = 0
    let onClose: (Bool) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var page: Int
    /// Whether the person has been sent to the Accessibility prompt yet. Apple's
    /// pre-alert guidance allows exactly one button before a system alert, so the
    /// "Open System Settings" recovery route only appears once the alert has
    /// already been and gone.
    @State private var didRequestAccessibility = false
    @State private var demo = OnboardingVolumeDemo()

    init(
        settings: SettingsManager,
        accessibility: AccessibilityPermissionService,
        audioPrimer: FirstRunAudioPrimer,
        audioEngine: AudioEngine,
        initialPage: Int = 0,
        onClose: @escaping (Bool) -> Void
    ) {
        self.settings = settings
        self.accessibility = accessibility
        self.audioPrimer = audioPrimer
        self.audioEngine = audioEngine
        self.initialPage = initialPage
        self.onClose = onClose
        _page = State(initialValue: initialPage)
    }

    // Five pages: two permission asks, one consent question, and the two
    // bookends. The Bluetooth, menu bar motion, and update-policy pages that
    // used to sit here were configuration, not setup — Apple's onboarding
    // guidance is to ship reasonable defaults and postpone that, and each of
    // those settings has a home in Settings and an entry in the Guide.
    //
    // `MeloExperienceVersion.onboarding` is deliberately NOT bumped: this flow
    // asks strictly less than the old one, so replaying it at people who
    // finished the longer version would be a nag with nothing to gain.
    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { complete(startTour: false, skipped: true) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(18)
            }

            // Fixed-height pages clipped at large accessibility text sizes, and
            // the `.unavailable` branch injects an arbitrary-length system
            // message with no ceiling on it.
            ScrollView(.vertical) {
                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: audioAccessPage
                    case 2: accessibilityPage
                    case 3: analyticsPage
                    default: finishPage
                    }
                }
                .id(page)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == page ? 22 : 7, height: 7)
                        .animation(DesignTokens.Animation.quick, value: page)
                }
            }
            .padding(.bottom, 12)
            .accessibilityElement()
            .accessibilityLabel("Step \(page + 1) of \(pageCount)")

            HStack {
                if page > 0 {
                    Button("Back") { move(to: page - 1) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if page < pageCount - 1 {
                    Button("Continue") { move(to: page + 1) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Show Me Around") { complete(startTour: true, skipped: false) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        // SwiftUI has no frame(width:minHeight:) overload — a fixed width has to be
        // expressed as equal min and max in the flexible-frame form.
        // 470 put the system-audio page's own action button below the fold, which
        // is the one page where the primary control must be visible on arrival.
        .frame(minWidth: 590, maxWidth: 590, minHeight: 560, maxHeight: .infinity)
        .background(.regularMaterial)
        .onDisappear {
            audioPrimer.cancel()
            demo.stop()
        }
    }

    // MARK: - Welcome

    /// Welcome and "here is the menu bar mark" were two pages saying one thing.
    /// Showing the actual mark in a menu-bar strip teaches where Melo lives in
    /// less space than the sentence that used to describe it.
    private var welcomePage: some View {
        onboardingPage(
            customIcon: AnyView(
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 94, height: 94)
                    .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
            ),
            title: "Melo",
            message: "Set the volume of one app without touching the others, and send each one to whichever speakers or headphones you want.",
            detail: "Melo has no window and no Dock icon. It lives in the menu bar."
        ) {
            menuBarMarkStrip
        }
    }

    private var menuBarMarkStrip: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "wifi")
                    .foregroundStyle(.tertiary)
                Image(systemName: "battery.75")
                    .foregroundStyle(.tertiary)
                Image(nsImage: MenuBarIconImage.meloMark.nsImage() ?? NSImage())
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 17)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                    .padding(.vertical, 3)
                    .background(
                        DesignTokens.Dimensions.Shape.sm.fill(.tint.opacity(0.18))
                    )
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(DesignTokens.Dimensions.Shape.md.fill(DesignTokens.Colors.glassFillStrong))
            .overlay(
                DesignTokens.Dimensions.Shape.md
                    .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
            )

            Text("Click this mark, up at the top of your screen.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Melo's mark appears in the menu bar at the top of the screen")
    }

    // MARK: - System audio

    /// The most serious thing Melo asks for, so the page says plainly what the
    /// access is, what happens to the audio, and what still works if the answer
    /// is no. A vague reassurance here is what turns into a denied permission.
    private var audioAccessPage: some View {
        onboardingPage(
            symbol: audioAccessSymbol,
            title: audioAccessTitle,
            message: audioAccessMessage,
            detail: audioAccessDetail
        ) {
            audioAccessActions
        }
    }

    private var audioAccessMessage: String {
        switch audioPrimer.state {
        case .ready:
            return "macOS granted the access. Melo can now take each app’s audio, apply that app’s volume, EQ, and output, and pass it on."
        case .permissionNeeded:
            return "macOS did not grant the access, so Melo cannot separate one app’s sound from another’s. Open System Settings › Privacy & Security › Audio Recording and switch Melo on."
        default:
            return "To change one app’s volume without changing the rest, Melo has to take that app’s audio, adjust it, and hand it straight back. macOS calls that system audio recording and will ask you to allow it."
        }
    }

    private var audioAccessDetail: String {
        switch audioPrimer.state {
        case .ready:
            return "Melo taps an app only while that app has a control you have changed, and releases it again afterwards."
        case .permissionNeeded:
            return "Without it, Melo still switches your output device, controls its volume, and runs your volume keys. Only per-app volume, EQ, and Boost are unavailable."
        default:
            return "The audio is processed on this Mac and passed through in real time — nothing is recorded, saved, or sent anywhere. Melo plays a short sound so the request arrives while you are reading this. Say no and Melo still controls your output devices and their volume; only per-app volume, EQ, and Boost are unavailable."
        }
    }

    @ViewBuilder
    private var audioAccessActions: some View {
        switch audioPrimer.state {
        case .idle, .preparing:
            // One action, titled after what pressing it does rather than
            // "Allow" — Apple's pre-alert guidance rejects an Allow-alike
            // outright, and this page honours that.
            //
            // It does not honour the rest. That guidance also forbids any route
            // off a pre-alert screen, and Skip, Back, Continue and the window's
            // close button are all still here. The guidance describes a single
            // dedicated pre-alert window; this is one page of an optional flow,
            // and Apple's onboarding guidance for that says to keep it skippable.
            // Where the two conflict, setup you cannot leave is the worse
            // failure, so the escapes stay. Stated rather than glossed, because
            // the deviation is real.
            Button("Play a Sound and Ask macOS") { audioPrimer.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .waitingForMacOS:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for macOS…")
                    .font(DesignTokens.Typography.Scale.body(.medium))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Audio Access Granted", systemImage: "checkmark.circle.fill")
                .font(DesignTokens.Typography.Scale.headline())
                .foregroundStyle(.green)
            Button("Play Again") { audioPrimer.start() }
                .buttonStyle(.bordered)
        case .permissionNeeded:
            Button("Open System Settings") { audioPrimer.openSystemSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Try Again") { audioPrimer.start() }
                .buttonStyle(.bordered)
        case .unavailable(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(DesignTokens.Typography.Scale.caption())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330)
                Button("Try Again") { audioPrimer.start() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var audioAccessSymbol: String {
        switch audioPrimer.state {
        case .ready: return "checkmark.waveform"
        case .permissionNeeded, .unavailable: return "waveform.badge.exclamationmark"
        default: return "waveform.circle.fill"
        }
    }

    private var audioAccessTitle: String {
        switch audioPrimer.state {
        case .ready: return "Per-App Control Is On"
        case .permissionNeeded: return "System Audio Is Still Blocked"
        default: return "Melo Needs to Hear Your Apps"
        }
    }

    // MARK: - Volume keys

    private var accessibilityPage: some View {
        onboardingPage(
            symbol: accessibility.isTrustedCached ? "checkmark.shield.fill" : "keyboard.badge.ellipsis",
            title: accessibility.isTrustedCached ? "Your Volume Keys Reach Melo" : "Let Your Volume Keys Reach Melo",
            message: accessibility.isTrustedCached
                ? "F10, F11, and F12 now change the device Melo has selected, in the step size you choose in Settings › Shortcuts."
                : "F10, F11, and F12 move your Mac’s system volume. Accessibility is what lets Melo see the key press and apply it to the device you actually chose.",
            detail: accessibility.isTrustedCached
                ? "Remove the permission whenever you like in System Settings › Privacy & Security › Accessibility."
                : "macOS will ask you to confirm this in System Settings. Melo uses it for the volume keys and optional play/pause, never to read your screen or your documents. Skip it and everything else still works."
        ) {
            if accessibility.isTrustedCached {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(DesignTokens.Typography.Scale.headline())
            } else if didRequestAccessibility {
                // `requestAccess()` has already opened System Settings once; this
                // is the second chance for anyone who closed it by accident.
                Button("Open System Settings Again") { accessibility.openSystemSettings() }
                    .buttonStyle(.bordered)
            } else {
                Button("Set Up Volume Keys") {
                    didRequestAccessibility = true
                    accessibility.requestAccess()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Analytics

    /// Two buttons rather than a pre-ticked switch. A toggle that is already on
    /// when the page appears collects an answer nobody gave; a toggle that is
    /// off collects nothing but also reads as a setting to be skipped past. An
    /// explicit pair makes "no" a real, one-click answer.
    private var analyticsPage: some View {
        onboardingPage(
            symbol: analyticsSymbol,
            title: analyticsTitle,
            message: "Melo can send anonymous notes about which features get used, so the next version improves the parts you actually reach for.",
            detail: "Never the names of your apps, your devices, or your Mac. Just Melo’s version, your macOS version, and which buttons were pressed. You can change this any time in Settings › General."
        ) {
            switch settings.appSettings.analyticsConsent {
            case .granted:
                Label("Sharing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(DesignTokens.Typography.Scale.headline())
                Button("Stop Sharing") { setAnalyticsConsent(.denied) }
                    .buttonStyle(.bordered)
            case .denied:
                Label("Not Sharing", systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary)
                    .font(DesignTokens.Typography.Scale.headline())
                Button("Share After All") { setAnalyticsConsent(.granted) }
                    .buttonStyle(.bordered)
            case .unasked:
                Button("Share Anonymous Usage") { setAnalyticsConsent(.granted) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Don’t Share") { setAnalyticsConsent(.denied) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var analyticsSymbol: String {
        switch settings.appSettings.analyticsConsent {
        case .granted: return "checkmark.seal.fill"
        case .denied: return "hand.raised.fill"
        case .unasked: return "chart.bar.doc.horizontal"
        }
    }

    private var analyticsTitle: String {
        switch settings.appSettings.analyticsConsent {
        case .granted: return "Thanks for Helping"
        case .denied: return "Melo Won’t Share Anything"
        case .unasked: return "Help Improve Melo?"
        }
    }

    /// The only place in first-run setup that writes consent, and it runs only
    /// from a button press. Advancing past this page without pressing either
    /// button leaves the answer `.unasked`; `complete()` settles that as a no.
    private func setAnalyticsConsent(_ consent: AnalyticsConsent) {
        var appSettings = settings.appSettings
        appSettings.analyticsConsent = consent
        settings.appSettings = appSettings
        // Applied immediately so the SDKs start (or stay down) while the user is
        // still looking at the page where they decided, not after a relaunch.
        TelemetryService.shared.refreshConsent()
        move(to: page + 1)
    }

    // MARK: - Finish

    /// The one page where the reader does the thing instead of reading about it.
    /// Everything before this hands off to a macOS alert; this hands them a real
    /// slider attached to real audio, in the shape of the row they will use every
    /// day. Reciting where the controls live — which is what this page used to do
    /// — is the memorisation failure Apple's onboarding guidance names.
    ///
    /// Nothing on this page writes a setting. Melo's own sound needs no
    /// permission and touches nothing outside this window, so replaying setup
    /// from Settings changes exactly nothing, which is what the row that offers
    /// the replay promises.
    private var finishPage: some View {
        onboardingPage(
            symbol: "hand.draw",
            title: "Try It Once",
            message: "Melo will loop a short sound. Drag its volume and listen — every app in Melo gets a row exactly like this one.",
            detail: "This is Melo’s own sound. Nothing else on your Mac is touched by it."
        ) {
            demoRow
        }
    }

    /// Deliberately built to match the popup's collapsed app row — icon, name,
    /// slider, editable-looking percentage — so the gesture practised here is the
    /// gesture that works later.
    private var demoRow: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)

                Text("Melo Introduction")
                    .font(DesignTokens.Typography.Scale.body(.medium))
                    .lineLimit(1)

                Slider(value: $demo.volume, in: 0...1)
                    .frame(minWidth: 130)
                    .accessibilityLabel("Melo Introduction volume")

                Text("\(Int((demo.volume * 100).rounded()))%")
                    .font(DesignTokens.Typography.Scale.body(.medium))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)

                Button(demo.isPlaying ? "Stop" : "Play") { demo.toggle() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(DesignTokens.Dimensions.Shape.md.fill(DesignTokens.Colors.glassFillStrong))
            .overlay(
                DesignTokens.Dimensions.Shape.md
                    .strokeBorder(DesignTokens.Colors.glassRowBorderHover, lineWidth: 0.5)
            )
            .frame(maxWidth: 470)

            Text(demo.isPlaying
                 ? "Drag the slider. Only this sound changes."
                 : "Press Play, then drag the slider.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(.secondary)

            // Last, not before the control: the one thing worth remembering
            // after setup is where the answers live, and it should not stand
            // between the invitation and the thing being offered.
            Text("That’s setup done. Settings › Guide answers questions by problem as well as by name, and Settings › General can replay this whenever you like.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)
                .padding(.top, DesignTokens.Spacing.sm)
        }
    }

    // MARK: - Page chrome

    private func onboardingPage<Actions: View>(
        symbol: String,
        title: String,
        message: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        onboardingPage(
            customIcon: AnyView(
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 86, height: 86)
                    .background(Circle().fill(.tint.opacity(0.12)))
            ),
            title: title,
            message: message,
            detail: detail,
            actions: actions
        )
    }

    private func onboardingPage<Actions: View>(
        customIcon: AnyView,
        title: String,
        message: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 18) {
            customIcon
                .accessibilityHidden(true)

            // Text-style-relative fonts, not `.system(size:)`. A fixed point size
            // ignores the accessibility text setting entirely, so the flow that
            // claimed to survive large type was in fact never scaling at all.
            Text(title)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(.system(.title3, weight: .medium))
                .multilineTextAlignment(.center)
                // Without this, a page whose text wraps past its ideal height is
                // truncated rather than grown — the clipping this flow used to do
                // at accessibility text sizes.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 410)

            // Stacked rather than side by side once the text is large enough that
            // two titles cannot share a 590pt row. `ViewThatFits` would express
            // this more directly but strips `.borderedProminent` of its accent,
            // which on a permission page removes the only thing marking the
            // button that opens the system alert.
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: DesignTokens.Spacing.sm2) { actions() }
                } else {
                    HStack(spacing: DesignTokens.Spacing.sm2) { actions() }
                }
            }
            .padding(.top, DesignTokens.Spacing.xs)
        }
        .padding(.horizontal, 38)
        .padding(.vertical, DesignTokens.Spacing.xl)
        // `maxHeight: .infinity` inside a ScrollView collapses to the ideal
        // height; a minimum keeps short pages optically centred instead.
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func move(to newPage: Int) {
        withAnimation(DesignTokens.Animation.quick) {
            page = min(pageCount - 1, max(0, newPage))
        }
    }

    private func complete(startTour: Bool, skipped: Bool) {
        var appSettings = settings.appSettings
        appSettings.onboardingVersionCompleted = MeloExperienceVersion.onboarding
        appSettings.guidedTourPending = startTour
        // Skipping setup ends setup. It used to also stamp the guided tour as
        // completed, which recorded a tour the person had explicitly declined
        // to take as one they had been through — and the tour is a separate
        // thing, replayable from Settings. Leaving `guidedTourPending` false is
        // what stops it reappearing uninvited.
        // Leaving setup without answering is a no. Silence must not be readable
        // as agreement, and leaving it `.unasked` would instead queue the
        // standalone prompt at the very next launch, which is worse than either
        // answer: they just walked past the question on purpose.
        if appSettings.analyticsConsent == .unasked {
            appSettings.analyticsConsent = .denied
        }
        settings.appSettings = appSettings
        TelemetryService.shared.refreshConsent()
        demo.stop()
        // Setup deliberately writes no update policy. `SUEnableAutomaticChecks`
        // in Info.plist is the single mechanism that decides the default, and a
        // second one here meant that replaying setup from Settings switched
        // automatic checks back on for anyone who had turned them off.
        if skipped {
            TelemetryService.shared.send(.onboardingSkipped(atPage: TelemetryBucket(count: page + 1)))
        } else {
            TelemetryService.shared.send(.onboardingCompleted(startedTour: startTour))
        }
        // Setup is done and the user has seen what Melo does, so a notification
        // prompt now has context. Deferred from launch on purpose.
        if appSettings.showDeviceDisconnectAlerts {
            NotificationAuthorization.requestIfNeeded()
        }
        onClose(startTour)
    }
}
