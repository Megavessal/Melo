import AVFoundation
import AppKit
import SwiftUI

/// The sound behind setup's one interactive page.
///
/// Deliberately Melo's own bundled file rather than the audio engine's tap: it
/// needs no permission, so the controls work identically whether the person
/// allowed system audio or refused it, and they cannot alter anything the
/// person has set. A demo that only works after a grant would teach nobody who
/// said no — and they are exactly the people left wondering what Melo does.
///
/// `AVAudioEngine` rather than `AVAudioPlayer`, because the last page now hands
/// over the real `EQPanelView`. `AVAudioPlayer` has no effect chain, so on that
/// path every band the reader drags would move a slider and change nothing they
/// can hear: an equalizer that is visibly real and audibly inert, taught as the
/// first thing they learn about Melo. That is the severed-wiring failure this
/// project has already measured once.
@Observable
@MainActor
final class OnboardingVolumeDemo {
    var volume: Double = 0.7 {
        // Pushed at the node only once it is attached to the engine. The slider
        // can be dragged before Play has ever been pressed, and mixing
        // properties on a detached node are not a supported thing to set;
        // `start()` applies the current value anyway.
        didSet { if isWired { player.volume = Float(volume) } }
    }

    private(set) var isPlaying = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let equalizer = AVAudioUnitEQ(numberOfBands: EQSettings.bandCount)
    @ObservationIgnored private var theme: AVAudioPCMBuffer?
    @ObservationIgnored private var isWired = false

    init() {
        // Bands are shaped here rather than in `prepare()` so a curve dragged
        // before Play is pressed survives: `prepare()` runs on the first press
        // and must not reset gains the reader has already set.
        for (index, band) in equalizer.bands.enumerated() where index < EQSettings.frequencies.count {
            band.filterType = .parametric
            band.frequency = Float(EQSettings.frequencies[index])
            // One octave per band, which is what the panel's 32…16k labels
            // describe — ten octave-spaced ISO centres.
            band.bandwidth = 1.0
            band.bypass = false
        }
    }

    func toggle() {
        if isPlaying {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard prepare(), let theme else { return }
        do {
            try engine.start()
        } catch {
            return
        }
        // Re-scheduled on every press: `stop()` empties the node's queue, so a
        // second Play would otherwise run a started engine in silence.
        player.scheduleBuffer(theme, at: nil, options: .loops)
        player.volume = Float(volume)
        player.play()
        isPlaying = true
    }

    func stop() {
        player.stop()
        engine.stop()
        isPlaying = false
    }

    /// Puts the curve the reader is dragging onto the sound they are hearing.
    /// The single connection point between `EQPanelView` and the audio, called
    /// from one `onChange` so a preset pick reaches the sound by the same route
    /// a band drag does.
    func apply(_ settings: EQSettings) {
        let gains = settings.clampedGains
        for (index, band) in equalizer.bands.enumerated() where index < gains.count {
            band.gain = settings.isEnabled ? gains[index] : 0
        }
        // The same automatic headroom the real EQ path applies
        // (`EQSettings.preampDB`), so a boosting curve reads as the tone change
        // it is rather than as "louder" — and so the panel's own Headroom
        // label, which is visible on this page, describes something true.
        equalizer.globalGain = settings.isEnabled ? settings.preampDB : 0
    }

    private func prepare() -> Bool {
        if isWired { return true }
        // The full theme, not a clip: 90 seconds is long enough to play with the
        // volume and the EQ without the track restarting under you, which a
        // two-second loop did on roughly every third drag.
        // `MeloThemePlayback.currentURL` rather than the bundle directly: someone
        // who remixed the theme in the Cutting Room and adopted their version
        // hears theirs here, and everyone else falls back to the bundled
        // `MeloTheme.m4a`. This is the only sound that indirection covers —
        // `FirstRunAudioPrimer` keeps the bundled `MeloJingle.m4a`, because that
        // clip plays while macOS is showing the system-audio permission sheet
        // and a user-supplied recording at that moment is a bad surprise at the
        // worst possible time.
        guard let url = MeloThemePlayback.currentURL,
              let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        // Decoded once into a looping buffer rather than re-scheduled at the end
        // of each pass: `.loops` repeats inside the render thread with no gap and
        // no completion handler to hop back to the main actor from. It costs the
        // decoded theme in memory for as long as setup is open, and that is freed
        // with the window.
        guard file.length > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return false }
        do {
            try file.read(into: buffer)
        } catch {
            return false
        }
        theme = buffer

        engine.attach(player)
        engine.attach(equalizer)
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        isWired = true
        return true
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
    /// The last page's equalizer state. Local, and deliberately not any app's
    /// stored curve: the panel is the real one, so a binding into settings here
    /// would mean a tutorial drag silently re-tuning an app the reader has not
    /// met yet.
    @State private var demoEQ = EQSettings()

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

    // Six pages: three permission asks, one consent question, and the two
    // bookends. The menu bar motion and update-policy pages that used to sit
    // here are still gone, and for the reason they were cut — they are
    // configuration, Apple's onboarding guidance is to ship a reasonable
    // default and postpone that, and both have a home in Settings and an entry
    // in the Guide.
    //
    // Bluetooth came back, and not on the old argument. That page existed to
    // opt people in *ahead of* a prompt that fired at launch; nothing reaches
    // IOBluetooth at launch any more, so there is no ambush left to pre-empt.
    // What is left is a feature that ships off and is otherwise reachable only
    // from a switch in Settings, which means a new user has no way to find out
    // Melo can reconnect their headphones at all. That is a setup question —
    // the same shape as the two pages above it, ending in the same system
    // dialog, raised by a press with the reason on screen.
    //
    // `MeloExperienceVersion.onboarding` is deliberately NOT bumped, even
    // though this flow now asks something the version-3 flow did not.
    // `SettingsManager.decodeSettings` already migrates every pre-existing
    // install to `bluetoothFeaturesEnabled = true`, so the replay would show
    // that cohort a page whose question is answered before they arrive; and
    // `WhatsNewCoordinator.showIfNeeded` stamps the build as seen when setup
    // suppresses it, so bumping would spend the whole release's What's New on
    // one already-answered page. The permission itself is re-requested in
    // context, in the popup, which has copy for the waiting and the refused
    // case. See `MeloExperienceVersion` for the same decision from the other
    // side.
    private let pageCount = 6

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
                    case 3: bluetoothPage
                    case 4: analyticsPage
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
                    // "Show Me", not "Show Me Around": the tour overlay has three
                    // entry points and they should not each name it differently.
                    Button("Show Me") { complete(startTour: true, skipped: false) }
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

    // MARK: - Bluetooth

    /// What the permission actually buys, stated exactly: paired-but-disconnected
    /// audio devices listed in the popup, and a Connect button on them. Nothing
    /// else in Melo touches Bluetooth — playing to AirPods that are already
    /// connected, per-app volume, EQ and routing are all Core Audio and work
    /// whether this is allowed or refused. The old version of this page promised
    /// battery levels, which Melo has never read.
    ///
    /// Pressing the button raises the macOS dialog here rather than banking a
    /// preference for later, which is what makes this a setup page instead of a
    /// switch with prose around it: the answer arrives while the reason is still
    /// on screen, and the page can then say what it found. That is the same
    /// bargain the system-audio page makes two pages earlier.
    private var bluetoothPage: some View {
        onboardingPage(
            symbol: bluetoothSymbol,
            title: bluetoothTitle,
            message: bluetoothMessage,
            detail: bluetoothDetail
        ) {
            bluetoothActions
        }
    }

    /// Four states, read from the monitor rather than from the setting, because
    /// the setting only records the answer to "may Melo look" — it says nothing
    /// about whether macOS then allowed it. A pre-existing install arrives here
    /// with the setting already on and nothing looked at yet, which is `.offer`.
    private enum BluetoothPageState {
        case offer
        case waitingForMacOS
        case ready
        case blocked
    }

    private var bluetoothState: BluetoothPageState {
        let monitor = audioEngine.bluetoothDeviceMonitor
        guard monitor.isStarted else { return .offer }
        // False for exactly as long as the system dialog is up: the first power
        // read is the call macOS puts the dialog in front of.
        guard monitor.hasCompletedFirstScan else { return .waitingForMacOS }
        return monitor.isBluetoothOn ? .ready : .blocked
    }

    private var bluetoothSymbol: String {
        switch bluetoothState {
        case .offer, .waitingForMacOS: return "antenna.radiowaves.left.and.right"
        case .ready: return "checkmark.circle.fill"
        case .blocked: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var bluetoothTitle: String {
        switch bluetoothState {
        case .offer, .waitingForMacOS: return "Connect Headphones from Melo"
        case .ready: return "Melo Can See Bluetooth"
        case .blocked: return "Melo Can’t See Bluetooth"
        }
    }

    private var bluetoothMessage: String {
        switch bluetoothState {
        case .offer:
            return "Melo can list the headphones and speakers you have paired but are not connected to right now, and connect them without a trip to System Settings."
        case .waitingForMacOS:
            return "macOS is asking whether Melo may use Bluetooth. Answer either way — the rest of Melo is unaffected."
        case .ready:
            let names = audioEngine.bluetoothDeviceMonitor.pairedDevices.map(\.name)
            guard !names.isEmpty else {
                return "Nothing paired is sitting disconnected at the moment. When something is, it appears in Melo ready to connect."
            }
            let count = names.count == 1 ? "One paired device is" : "\(names.count) paired devices are"
            return "\(count) waiting: \(names.joined(separator: ", "))."
        case .blocked:
            // `powerState` reports hardware-off and permission-refused
            // identically, with no way found to tell them apart, so naming one
            // cause would be a guess. The popup says the same thing for the same
            // reason.
            return "macOS reports “Bluetooth is off” and “Melo may not use Bluetooth” in exactly the same way, so Melo cannot tell you which one this is."
        }
    }

    private var bluetoothDetail: String {
        switch bluetoothState {
        case .offer, .waitingForMacOS:
            return "That is all this permission does. Per-app volume, EQ, routing, and playing to AirPods that are already connected all work without it. You can change your mind later in Settings › General."
        case .ready:
            return "Open Melo’s device list and press the reorder button: anything paired and disconnected is listed under Paired, with a Connect button. Switch this off any time in Settings › General."
        case .blocked:
            return "Check that Bluetooth is switched on, and that Melo is switched on in System Settings › Privacy & Security › Bluetooth. This page notices on its own if you turn Bluetooth on. Everything else in Melo works either way."
        }
    }

    @ViewBuilder
    private var bluetoothActions: some View {
        switch bluetoothState {
        case .offer:
            // Named for what pressing it does, not "Allow" — the same reading of
            // Apple's pre-alert guidance the system-audio page works from.
            Button("Show My Paired Devices") { enableBluetoothFeatures() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Not Now") { declineBluetoothFeatures() }
                .buttonStyle(.bordered)
        case .waitingForMacOS:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for macOS…")
                    .font(DesignTokens.Typography.Scale.body(.medium))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Bluetooth Features On", systemImage: "checkmark.circle.fill")
                .font(DesignTokens.Typography.Scale.headline())
                .foregroundStyle(.green)
        case .blocked:
            // No button. The two things to check are a Control Center switch and
            // a System Settings pane Melo has no verified deep link to, and
            // `start()` registered the power-on observer, so switching Bluetooth
            // on refreshes this page without anything to press.
            EmptyView()
        }
    }

    /// The only route from setup to IOBluetooth, and it runs from a press. The
    /// call this replaces sat in `complete()`, where finishing setup raised a
    /// Bluetooth dialog with no Bluetooth reason anywhere on screen;
    /// `scripts/verify-unasked-actions.py` fails the build if it drifts back to
    /// anything but a button action.
    ///
    /// Deliberately does not advance the page: the result of the press — the
    /// devices found, or the reason none were — is the point, and it renders
    /// here.
    private func enableBluetoothFeatures() {
        var appSettings = settings.appSettings
        appSettings.bluetoothFeaturesEnabled = true
        settings.appSettings = appSettings
        audioEngine.startBluetoothMonitoringIfEnabled()
    }

    /// A real no, not a Continue wearing a softer word. Writing the setting is
    /// what separates "asked and declined" from "never asked" for the one cohort
    /// where they differ — a pre-existing install arrives with the feature
    /// already migrated on, and walking past this page has to leave it on while
    /// pressing this has to turn it off.
    private func declineBluetoothFeatures() {
        var appSettings = settings.appSettings
        appSettings.bluetoothFeaturesEnabled = false
        settings.appSettings = appSettings
        move(to: page + 1)
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
    /// Everything before this hands off to a macOS alert; this hands them the
    /// popup's own row and the popup's own equalizer, attached to real audio, so
    /// the minute spent here is a minute spent in the control surface rather
    /// than reading a description of it. Reciting where the controls live —
    /// which is what this page used to do — is the memorisation failure Apple's
    /// onboarding guidance names.
    ///
    /// No icon, and tighter than the pages before it. A page whose content is
    /// itself the illustration does not also need a symbol above the title, and
    /// the ten EQ bands need every point the chrome can give back — see the
    /// height note on `playground`.
    ///
    /// Two things here outlive the window, and both only from a control the
    /// reader operated: the Dock switch, which is Settings › General's own
    /// preference, and saving, renaming or deleting an EQ preset, which is that
    /// button doing exactly what it says. The curve itself, the volume and the
    /// sound are local to this window, so arriving on this page and leaving
    /// again still changes nothing — which is what the Settings row offering to
    /// replay setup promises.
    private var finishPage: some View {
        onboardingPage(
            customIcon: AnyView(EmptyView()),
            // `scripts/verify-consumer-foundations.py` matches this title
            // literally, as its only proof that the flow still ends on the page
            // that hands over a control. Rename it there in the same change.
            title: "Try It Once",
            // Two lines each, at these widths. Every line of copy here is a line
            // the equalizer does not get: see the height note on `playground`.
            message: "Every app in Melo gets this row and this equalizer. Press Play, then drag anything you can see.",
            detail: "Melo’s own theme, playing inside this window only. Nothing else on your Mac is touched by it.",
            spacing: DesignTokens.Spacing.md,
            verticalPadding: DesignTokens.Spacing.md
        ) {
            playground
        }
    }

    /// The popup's app row, running on Melo's theme instead of on an app.
    ///
    /// `ExpandableGlassRow`, `LiquidGlassSlider`, `EditablePercentage` and
    /// `EQPanelView` are the same types `AppRow` builds from, at the popup's own
    /// content width — not a tutorial mock of them. The point of the page is
    /// that the control practised here *is* the control met later, and a
    /// look-alike would teach a surface that does not exist.
    ///
    /// Two controls of the real row are left out rather than shown dead: the
    /// device picker and the boost chevrons have nothing to act on in a window
    /// with no app in it. The Play button is the page's own, because the popup
    /// never needs one.
    ///
    /// Height, because this page is the one that can overflow: the ten EQ bands
    /// alone are 100pt inside a panel that is about 160, the row around them
    /// about 250, and the window's own chrome — Skip, dots, Back/Show Me — takes
    /// roughly 130 before the scroll area starts. That leaves about 350pt of
    /// viewport at the 480pt minimum height and about 430 at the height the
    /// window opens at, against a page that wants roughly 550. It scrolls, and
    /// the copy above is cut to two lines and one line to keep the overflow to
    /// the tail. Order is the mitigation: the row and its equalizer come first,
    /// so what falls below the fold is the Dock switch and the closing
    /// paragraph, never the thing the page invites you to touch.
    private var playground: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            ExpandableGlassRow(isExpanded: true) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: DesignTokens.Dimensions.rowContentHeight - 4,
                            height: DesignTokens.Dimensions.rowContentHeight - 4
                        )
                        // The name beside it is the label; an unnamed image
                        // element here would just be a stop with nothing in it.
                        .accessibilityHidden(true)

                    // Name over a quiet second line, exactly where a real row
                    // carries its routing subtitle — and what belongs there for
                    // a piece of music is what a music app would put there.
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Melo Theme")
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                        Text(demo.isPlaying ? "Playing — 1:30, looping" : "Melo’s own theme — 1:30")
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(demo.isPlaying ? "Stop" : "Play") { demo.toggle() }
                        .buttonStyle(.bordered)
                }
                .frame(height: DesignTokens.Dimensions.rowContentHeight)
            } expandedContent: {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        LiquidGlassSlider(
                            value: $demo.volume,
                            accessibilityTitle: "Melo Theme volume",
                            valueDescription: { "\(Int(($0 * 100).rounded()))%" }
                        )
                        .frame(width: DesignTokens.Dimensions.sliderWidth)
                        .scrollWheelStep($demo.volume, in: 0.0...1.0)

                        EditablePercentage(
                            percentage: Binding(
                                get: { Int((demo.volume * 100).rounded()) },
                                set: { demo.volume = Double($0) / 100 }
                            ),
                            range: 0...100,
                            subject: "Melo Theme"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    Divider()
                        .padding(.vertical, 2)

                    EQPanelView(
                        settings: $demoEQ,
                        // The reader's real presets, and real save/rename/delete.
                        // A picker stocked with fake entries, or a save button
                        // that closes its field and stores nothing, teaches a
                        // control by lying about it once.
                        userPresets: settings.getUserPresets(),
                        onPresetSelected: { demoEQ = $0.settings },
                        onUserPresetSelected: { demoEQ = $0.settings },
                        onSettingsChanged: { _ in },
                        onSavePreset: { name, eq in settings.createUserPreset(name: name, settings: eq) },
                        onDeleteUserPreset: { settings.deleteUserPreset(id: $0) },
                        onRenameUserPreset: { settings.updateUserPreset(id: $0, name: $1) }
                    )
                }
                .padding(.top, DesignTokens.Spacing.sm)
            }
            // One wire from the panel to the sound, watching the state every
            // path writes. Hanging it off `onSettingsChanged` instead would
            // leave preset picks silent, because the panel reports those
            // through their own callbacks.
            .onChange(of: demoEQ) { _, curve in demo.apply(curve) }
            .frame(width: DesignTokens.Dimensions.contentWidth)

            // No caption under the row repeating "press Play, then drag": the
            // page's own message says it, and the row's second line already
            // reports whether the track is playing. Two of those, and the
            // equalizer loses another line of height to say nothing new.
            dockSettingRow

            // Last, not before the control: the one thing worth remembering
            // after setup is where the answers live, and it should not stand
            // between the invitation and the thing being offered.
            Text("That’s setup done. Settings › Guide answers questions by problem, and Settings › General can replay this whenever you like.")
                .font(DesignTokens.Typography.Scale.footnote())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)
        }
    }

    /// Settings' own row and switch, for Settings' own preference
    /// (`showInDock`) — the reader meets the control here in the shape it keeps.
    ///
    /// "Keep", not "Show", and the subtitle says *after setup*. Setup's own
    /// window holds a Dock tile for as long as it is open, whatever the
    /// preference says, so a switch labelled "Show Melo in the Dock" would sit
    /// beside an icon that is already there and appear to do nothing when
    /// flipped. What it really decides is what happens when this window closes,
    /// and that is what it now says.
    ///
    /// A two-way binding, not an opt-in: anyone replaying setup may already have
    /// switched this on from Settings or the menu bar, and a box that always
    /// arrived unticked would offer to take that away.
    private var dockSettingRow: some View {
        SettingsRow(
            "Keep Melo in the Dock",
            description: "When setup finishes, keep a Dock icon as well as the menu bar. Change it any time in Settings › General."
        ) {
            Toggle("", isOn: Binding(
                get: { settings.appSettings.showInDock },
                set: { newValue in
                    var appSettings = settings.appSettings
                    appSettings.showInDock = newValue
                    settings.appSettings = appSettings
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .frame(width: DesignTokens.Dimensions.contentWidth)
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

    /// `spacing` and `verticalPadding` default to the flow's normal page rhythm.
    /// The last page passes tighter values because its actions block is a full
    /// app row and a ten-band equalizer: at the window's 480pt minimum the
    /// scroll area is only a few hundred points tall, and page chrome set for a
    /// paragraph and a button spends a fifth of it on air.
    private func onboardingPage<Actions: View>(
        customIcon: AnyView,
        title: String,
        message: String,
        detail: String,
        spacing: CGFloat = 18,
        verticalPadding: CGFloat = DesignTokens.Spacing.xl,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: spacing) {
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
        .padding(.vertical, verticalPadding)
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
        // Bluetooth needs no equivalent settling and must not get one. Its
        // default is already off, so walking past that page is the quiet answer;
        // and the only people who reach here with it on are a pre-existing
        // install that had the feature before setup ran, which forcing to a
        // default would take away.
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
