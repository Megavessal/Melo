#if MELO_DEV
import AppKit
import AudioToolbox
import SwiftUI

/// The frames the harness renders. Kept apart from `SnapshotHarness` so the
/// capture mechanism and the list of things worth looking at can change
/// independently.
///
/// Every guided-tour step gets a frame, because the tour's failures are
/// per-step: a spotlight can land on the right control for step one and the
/// wrong one for step six, and a single screenshot of "the tour" hides that
/// completely.
@MainActor
enum SnapshotScenes {

    /// How a seeded timeline lays its clips out.
    ///
    /// A nested type rather than a local one because `seedTimeline` below takes
    /// it as a defaulted parameter, and the three cases are the three shapes the
    /// document model can actually be in — not a menu of drawing options.
    private enum TimelineLayout {
        /// One source, one clip per lane, each later lane offset and trimmed.
        /// What `EditorTrackFixtures.document` builds: one file, extra lanes the
        /// user asked for and filled by hand.
        case staggered
        /// The same, with a fade in and a fade out on every clip and a different
        /// `FadeCurve` per lane. Fades are per-clip and draggable, so they are
        /// the one part of the Chain that is drawn *into* the audio.
        case fades
        /// The same, with the first lane's clip split in two at 45% and a copy of
        /// the left half pasted onto the second lane later on. Split and paste
        /// both produce several clips sharing one source, which is the one
        /// arrangement the other two layouts cannot show.
        case split
    }

    // swiftlint:disable:next function_parameter_count function_body_length
    static func all(
        audioEngine: AudioEngine,
        deviceVolumeMonitor: DeviceVolumeMonitor,
        sparkle: SparkleUpdateController,
        developerUpdates: DeveloperUpdateManager,
        permission: AudioRecordingPermission,
        accessibility: AccessibilityPermissionService,
        mediaKeyStatus: MediaKeyStatus,
        popupVisibility: PopupVisibilityService,
        hudController: HUDWindowController,
        mediaKeyMonitor: MediaKeyMonitor,
        guidedTour: GuidedTourCoordinator,
        settings: SettingsManager
    ) -> [SnapshotHarness.Scene] {
        let dimensions = settings.appSettings.popupSize.dimensions
        let popupSize = CGSize(
            width: dimensions.width + dimensions.contentPadding * 2,
            height: dimensions.maxContentHeight + 96
        )

        // Snapshot runs mutate this app's state to reach the states worth
        // looking at, and must never write any of it to the settings.json of
        // whoever ran them. `prepareForFullErase` switches persistence off for
        // the rest of the process — it cancels the debounced save and gates
        // every write, and deletes nothing.
        //
        // It also has to run before the *first* mutation, not before whichever
        // scene happens to be first in the list, so every scene goes through
        // `applyAppearance` below and that calls it.

        /// Puts the app's own appearance preference where the scene says the
        /// frame should be, and resets the sticky globals a previous scene may
        /// have left leaning.
        ///
        /// It is the shared per-scene reset hook rather than only an appearance
        /// setter — it has erased persistence since it was written — and the
        /// reason everything of that kind belongs *here* is that `scene(...)`
        /// below is not the only caller. `SnapshotHarness.transition(...)` and
        /// `negativeControl(...)` do not go through that wrapper and each calls
        /// this directly, so a reset added to the wrapper alone silently misses
        /// the twenty-two frames that carry the assertions.
        ///
        /// `EditorTimeline.shared` outlives every scene and holds the window a
        /// waveform is looking through. Measured: after
        /// `cutting-room-waveform-handle` seeded zoom 0.4, the four
        /// `cutting-room-transport-*` frames inherited it and printed `0:58.00`
        /// where every window frame printed `0:58.0`. Same trap as
        /// `MeloEasterEggClock`, cleared in the same breath.
        ///
        /// `EditorClipWaveforms.shared` is the third of the same kind and the
        /// worst of them, because what it leaks is a *picture*. It holds one
        /// waveform per source id, seeded by hand for the multitrack scenes; a
        /// scene that did not clear it would draw the previous scene's sources
        /// in lanes cut from different files, and a frame of the wrong audio
        /// drawn convincingly is not a frame anyone can catch by looking. Its
        /// own `resetForSnapshot` asks to be called from exactly here.
        ///
        /// Without this a dark frame of the popup was unreadable, and had been
        /// for the whole of the previous run. `MenuBarPopupView` applies
        /// `.preferredColorScheme(resolvedPopupColorScheme)`, which on a Mac
        /// running Light with `appearance == .system` resolves *light* and
        /// drives the window's `NSAppearance`. The harness's
        /// `.environment(\.colorScheme, .dark)` then made SwiftUI draw
        /// dark-mode foregrounds — white text — over a light AppKit backdrop,
        /// so `popup-dark.png` was a white page containing icons and no words
        /// at all. That is not a material limitation; it was the harness
        /// contradicting the app. Setting the preference the app actually reads
        /// makes the two agree.
        @MainActor func applyAppearance(_ scheme: ColorScheme) {
            settings.prepareForFullErase()
            var appSettings = settings.appSettings
            appSettings.appearance = scheme == .dark ? .dark : .light
            // Pinned, because `SettingsManager` reads the real
            // `~/Library/Application Support/Melo/settings.json` and the harness
            // therefore renders with **whatever theme the person running it
            // happens to have chosen**. That is not a small fragility: the owner
            // switched Melo to Aurora while testing a build, and the next run
            // came back with seven negative controls between 41% and 47% — every
            // one of them correct, because Aurora is a `TimelineView` animation
            // and two captures of one state sample it at two different phases.
            // Fifty-six previous control readings of 0.0000% were not evidence
            // that the frames were stable; they were evidence that the theme on
            // this Mac was a static one.
            //
            // `.systemAccent` is the historical default, so every reference hash
            // in this suite still means what it meant. Theme scenes are
            // unaffected: `themeBackdropScene` hands `MeloThemeBackdrop` a theme
            // directly and never reads this.
            appSettings.visualTheme = .systemAccent
            appSettings.generatedTheme = nil
            settings.appSettings = appSettings
            EditorTimeline.shared.resetForSnapshot()
            EditorClipWaveforms.shared.resetForSnapshot()
        }

        @MainActor func scene(
            _ name: String,
            _ size: CGSize,
            _ scheme: ColorScheme = .dark,
            capture: SnapshotHarness.Capture = .layer,
            note: String? = nil,
            prepare: @escaping @MainActor () -> Void = {},
            assertOnHost: (@MainActor (NSView) -> String?)? = nil,
            content: @escaping @MainActor () -> AnyView
        ) -> SnapshotHarness.Scene {
            SnapshotHarness.Scene(
                name: name,
                size: size,
                colorScheme: scheme,
                capture: capture,
                prepare: {
                    applyAppearance(scheme)
                    // `forcedTime` is sticky and nothing else clears it, so a
                    // theme scene that freezes an easter egg would freeze it
                    // into every frame rendered afterwards. Cleared here, before
                    // each scene's own prepare, so only the scenes that ask for
                    // a forced clock get one.
                    MeloEasterEggClock.forcedTime = nil
                    prepare()
                },
                assertOnHost: assertOnHost,
                note: note,
                content: content
            )
        }

        @MainActor func popup() -> AnyView {
            AnyView(
                MenuBarPopupView(
                    audioEngine: audioEngine,
                    deviceVolumeMonitor: deviceVolumeMonitor,
                    sparkleUpdateController: sparkle,
                    permission: permission,
                    accessibility: accessibility,
                    mediaKeyStatus: mediaKeyStatus,
                    popupVisibility: popupVisibility,
                    hudController: hudController,
                    mediaKeyMonitor: mediaKeyMonitor,
                    guidedTour: guidedTour
                )
            )
        }

        // The popup's own `@State` is the only way into four surfaces: ⌘K's
        // palette, the Input tab, priority-edit mode and an opened app row are
        // each one click deep, and a click is not something a snapshot can
        // perform. A separate name rather than a defaulted overload, because a
        // defaulted overload makes a bare `popup()` call ambiguous.
        @MainActor func seededPopup(
            commandPaletteOpen: Bool = false,
            showingInputDevices: Bool = false,
            editingDevicePriority: Bool = false,
            quietAppsExpanded: Bool = false,
            expandedRowID: String? = nil
        ) -> AnyView {
            AnyView(
                MenuBarPopupView(
                    audioEngine: audioEngine,
                    deviceVolumeMonitor: deviceVolumeMonitor,
                    sparkleUpdateController: sparkle,
                    permission: permission,
                    accessibility: accessibility,
                    mediaKeyStatus: mediaKeyStatus,
                    popupVisibility: popupVisibility,
                    hudController: hudController,
                    mediaKeyMonitor: mediaKeyMonitor,
                    guidedTour: guidedTour,
                    commandPaletteOpen: commandPaletteOpen,
                    showingInputDevices: showingInputDevices,
                    editingDevicePriority: editingDevicePriority,
                    quietAppsExpanded: quietAppsExpanded,
                    expandedRowID: expandedRowID
                )
            )
        }

        // Two remembered apps, so the steps about an app row have a row even
        // when nothing on this Mac is playing audio.
        let demoApps = [
            PinnedAppInfo(
                persistenceIdentifier: "com.apple.Music",
                displayName: "Music",
                bundleID: "com.apple.Music"
            ),
            PinnedAppInfo(
                persistenceIdentifier: "com.apple.Safari",
                displayName: "Safari",
                bundleID: "com.apple.Safari"
            )
        ]
        @MainActor func seedDemoApps() {
            settings.prepareForFullErase()
            for identifier in settings.getIgnoredAppInfo().map(\.persistenceIdentifier) {
                settings.unignoreApp(identifier)
            }
            for app in demoApps {
                settings.pinApp(app.persistenceIdentifier, info: app)
            }
        }

        // The state a first run is actually in: nothing playing and no rows at
        // all. Every app the mixer can currently see is hidden rather than
        // waited for, because this Mac always has apps open.
        @MainActor func emptyAppList() {
            settings.prepareForFullErase()
            for app in demoApps {
                settings.unpinApp(app.persistenceIdentifier)
            }
            for app in audioEngine.displayableApps {
                settings.ignoreApp(
                    app.id,
                    info: IgnoredAppInfo(
                        persistenceIdentifier: app.id,
                        displayName: app.displayName,
                        bundleID: nil
                    )
                )
            }
        }

        @MainActor func updatesTab() -> AnyView {
            AnyView(
                UpdatesTab(sparkle: sparkle, developerUpdates: developerUpdates, sectionTarget: nil)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        }

        var scenes: [SnapshotHarness.Scene] = []

        // Baseline popup, tour inactive, both appearances. Everything else is
        // judged relative to these.
        scenes.append(
            scene("popup-dark", popupSize, .dark, prepare: { guidedTour.finish() }) { popup() }
        )
        scenes.append(
            scene("popup-light", popupSize, .light, prepare: { guidedTour.finish() }) { popup() }
        )

        // One frame per tour step, in order. `prepare` drives the shared
        // coordinator rather than the view's own state, so the step index is
        // the only thing that changes between consecutive frames.
        for (offset, step) in GuidedTourCoordinator.firstRunTour.enumerated() {
            scenes.append(
                scene(
                    String(format: "tour-%02d-%@", offset + 1, step.id),
                    popupSize,
                    .dark,
                    prepare: {
                        seedDemoApps()
                        guidedTour.jump(to: offset, in: .firstRun)
                    }
                ) { popup() }
            )
        }

        // The same steps with no app rows at all — the state a first run is
        // actually in. These are the frames that show whether a step about an
        // app row points at an empty rectangle or says something true.
        for (offset, step) in GuidedTourCoordinator.firstRunTour.enumerated()
        where step.unavailable != nil {
            scenes.append(
                scene(
                    String(format: "tour-empty-%02d-%@", offset + 1, step.id),
                    popupSize,
                    .dark,
                    prepare: {
                        emptyAppList()
                        guidedTour.jump(to: offset, in: .firstRun)
                    }
                ) { popup() }
            )
        }

        // The same empty-state steps in Light Mode.
        for (offset, step) in GuidedTourCoordinator.firstRunTour.enumerated()
        where step.unavailable != nil {
            scenes.append(
                scene(
                    String(format: "tour-empty-light-%02d-%@", offset + 1, step.id),
                    popupSize,
                    .light,
                    prepare: {
                        emptyAppList()
                        guidedTour.jump(to: offset, in: .firstRun)
                    }
                ) { popup() }
            )
        }

        scenes.append(
            scene(
                "tour-light",
                popupSize,
                .light,
                prepare: {
                    seedDemoApps()
                    guidedTour.jump(to: 2, in: .firstRun)
                }
            ) { popup() }
        )

        // MARK: - The popup header

        // The popup's primary navigation — the Melo mark, the audio-status
        // dot, the Audio disclosure, Output/Input, ⌘K, edit-priority and the
        // Settings gear — is a single `meloGlassSurface` island
        // (`MenuBarPopupView.swift:515`). On macOS 26 that is `.glassEffect`,
        // which the window server composites: the capture loses the surface
        // *and everything on it*, so 170pt of blank at the top of every popup
        // frame was read for two runs as a popup with no header.
        //
        // The `accessibilityReduceTransparency` branch of that modifier fills
        // opaquely and would capture fine, but the key path is read-only and
        // the setting is system-wide, so it is not reachable from here.
        // SwiftUI's own `ImageRenderer` is: it draws the tree instead of
        // reading back a layer, so it never asks the window server anything.
        let headerNote = "ImageRenderer: JUDGE THE HEADER ONLY. The mixer body below it is a "
            + "large ⃠ placeholder — SwiftUI cannot draw NSViewRepresentable content on this "
            + "path. The themed backdrop is real and is invisible in every layer capture."
        for (name, scheme) in [
            ("popup-header-light", ColorScheme.light),
            ("popup-header-dark", .dark)
        ] {
            scenes.append(
                scene(
                    name,
                    popupSize,
                    scheme,
                    capture: .imageRenderer,
                    note: headerNote,
                    prepare: {
                        seedDemoApps()
                        guidedTour.finish()
                    }
                ) { popup() }
            )
        }
        // The two tour steps whose anchors live inside the header. Their
        // spotlight geometry was being judged against a region that contained
        // no visible control at all.
        for (offset, step) in GuidedTourCoordinator.firstRunTour.enumerated()
        where step.id == "search" || step.id == "settings" {
            scenes.append(
                scene(
                    String(format: "tour-header-%02d-%@", offset + 1, step.id),
                    popupSize,
                    .light,
                    capture: .imageRenderer,
                    note: headerNote,
                    prepare: {
                        seedDemoApps()
                        guidedTour.jump(to: offset, in: .firstRun)
                    }
                ) { popup() }
            )
        }

        // MARK: - Transitions

        // "Skip Tour" is a control whose entire job is to change state, and no
        // frame had ever shown what it produces.
        //
        // These call the coordinator, and that is a real limit, so every one of
        // them carries `bindingCaveat` on its own frame. Pressing the actual
        // button was implemented and does not work: the offscreen hosting
        // view's accessibility tree is empty, so there is nothing to send a
        // press to. What these frames prove is that the coordinator method
        // produces the state shown. What still binds `Button("Skip Tour")` to
        // `coordinator.skip()` is nothing, and that is written on the frames.
        scenes += SnapshotHarness.transition(
            name: "tour-skip",
            size: popupSize,
            colorScheme: .light,
            floor: SnapshotHarness.animatedFloor,
            note: SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.light)
                seedDemoApps()
                guidedTour.jump(to: 1, in: .firstRun)
            },
            act: { guidedTour.skip() }
        ) { popup() }

        // The last step's button says "Finish" and shares the advance path with
        // "Next". Whether it ends the tour or leaves the overlay up is only
        // answerable from an image of the state after it runs.
        let lastStep = GuidedTourCoordinator.firstRunTour.count - 1
        scenes += SnapshotHarness.transition(
            name: "tour-finish",
            size: popupSize,
            colorScheme: .light,
            floor: SnapshotHarness.animatedFloor,
            note: SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.light)
                seedDemoApps()
                guidedTour.jump(to: lastStep, in: .firstRun)
            },
            act: { guidedTour.next() }
        ) { popup() }

        // "Back" moves the tour the other way and shares the overlay's whole
        // layout machinery with Next.
        scenes += SnapshotHarness.transition(
            name: "tour-back",
            size: popupSize,
            colorScheme: .light,
            floor: SnapshotHarness.animatedFloor,
            note: SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.light)
                seedDemoApps()
                guidedTour.jump(to: 2, in: .firstRun)
            },
            act: { guidedTour.back() }
        ) { popup() }

        // MARK: - Negative controls
        //
        // One per scene family, each a pair of frames with nothing done between
        // them. They are the calibration for every transition above: a family
        // whose two idle frames differ by more than the floor is a family in
        // which a dead control cannot be detected, and the run goes red saying
        // so. The guided-tour family is why these exist — its pointer halo
        // pulses continuously, so its frames never matched, so `act: { }` — an
        // action strictly worse than a dead button — passed. Measured on this
        // tree before the floor existed: tour-skip 0.146%, tour-finish 0.123%,
        // both green.
        scenes += SnapshotHarness.negativeControl(
            name: "control-tour",
            size: popupSize,
            colorScheme: .light,
            ceiling: SnapshotHarness.animatedFloor,
            note: "Guided-tour family: the animated pointer halo makes this the noisiest "
                + "surface in the set. Pinned to the step whose halo measured worst (0.4730%), "
                + "so the calibration is the worst case rather than a flattering one.",
            prepare: {
                applyAppearance(.light)
                seedDemoApps()
                guidedTour.jump(to: 2, in: .firstRun)
            }
        ) { popup() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-popup",
            size: popupSize,
            colorScheme: .dark,
            note: "Popup with no overlay.",
            prepare: {
                applyAppearance(.dark)
                seedDemoApps()
                guidedTour.finish()
            }
        ) { popup() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-header",
            size: popupSize,
            colorScheme: .light,
            capture: .imageRenderer,
            ceiling: SnapshotHarness.imageRendererFloor,
            note: "ImageRenderer family.",
            prepare: {
                applyAppearance(.light)
                seedDemoApps()
                guidedTour.finish()
            }
        ) { popup() }

        // MARK: - What's New

        let notes = MeloReleaseNotes.all
        scenes.append(
            scene("whats-new", CGSize(width: 560, height: 620), .dark) {
                AnyView(WhatsNewView(notes: notes, onDone: {}, onShowMe: {}))
            }
        )
        // Every step, not the first four: the walkthrough's failure was that
        // consecutive steps cut the same hole, which only a complete series
        // shows. Reopened from Settings → About, which hands over the whole
        // history — the header claimed these were "updates you have not seen
        // yet" in this state too, and no frame had ever shown it.
        scenes.append(
            scene("whats-new-replay", CGSize(width: 560, height: 620), .light) {
                AnyView(
                    WhatsNewView(
                        notes: notes,
                        showsFullHistory: true,
                        onDone: {},
                        onShowMe: {}
                    )
                )
            }
        )
        let releaseTour = WhatsNewCoordinator.tourSteps(for: notes)
        for (offset, step) in releaseTour.enumerated() {
            scenes.append(
                scene(
                    String(format: "whatsnew-tour-%02d-%@", offset + 1, step.id),
                    popupSize,
                    .light,
                    prepare: {
                        seedDemoApps()
                        guidedTour.jump(to: offset, in: .custom(releaseTour))
                    }
                ) { popup() }
            )
        }
        // A release note pointing at a control that only exists while an app is
        // playing. Nothing in the shipped notes does this yet, which is exactly
        // why the fallback had never been rendered: the What's New tour builds
        // its alternates from data rather than from hand-written copy.
        let syntheticNote = MeloReleaseNote(
            id: "snapshot-appvolume",
            version: "0.0.0",
            build: 0,
            headline: "A note about a control that is not always there",
            items: [
                MeloReleaseNote.Item(
                    id: "snapshot-appvolume",
                    title: "Per-app volume got finer steps",
                    detail: "An app's slider now moves in smaller increments near the quiet end.",
                    target: .appVolume
                )
            ]
        )
        let syntheticTour = WhatsNewCoordinator.tourSteps(for: [syntheticNote])
        scenes.append(
            scene(
                "whatsnew-tour-empty-appVolume",
                popupSize,
                .light,
                prepare: {
                    emptyAppList()
                    guidedTour.jump(to: 0, in: .custom(syntheticTour))
                }
            ) { popup() }
        )

        // MARK: - First-run setup

        // This flow requests real system permissions and had never been
        // rendered, so nobody reviewing it could see what it says before macOS
        // asks. Its own comments admitted the pages used to clip.
        // Must track `OnboardingWindowController`'s real content rect. It was
        // 560 while the window opened at 560; when the window grew to 700 for the
        // equalizer this stayed behind, and the frame showed "Keep Melo in the
        // Dock" sliced in half against the page dots — a defect that existed only
        // in the snapshot. A scene that renders a size the app never opens at
        // produces both false alarms and false comfort.
        let onboardingSize = CGSize(width: 590, height: 700)
        let onboardingPrimer = FirstRunAudioPrimer(audioEngine: audioEngine)
        // Index-driven, so this list has to track the page switch in
        // `FirstRunOnboardingView`. It did not when the Bluetooth page was
        // restored at index 3: `setup-04-analytics.png` rendered the Bluetooth
        // page, `setup-05-tryit.png` rendered analytics, and the try-it page
        // stopped being rendered at all — a frame whose name is a lie about its
        // contents, and one page silently dropped from review.
        let onboardingPageNames = ["welcome", "audio", "keys", "bluetooth", "analytics", "tryit"]

        @MainActor func onboarding(page: Int) -> AnyView {
            AnyView(
                FirstRunOnboardingView(
                    settings: settings,
                    accessibility: accessibility,
                    audioPrimer: onboardingPrimer,
                    audioEngine: audioEngine,
                    initialPage: page,
                    onClose: { _ in }
                )
            )
        }

        for (offset, name) in onboardingPageNames.enumerated() {
            scenes.append(
                scene(String(format: "setup-%02d-%@", offset + 1, name), onboardingSize, .dark) {
                    onboarding(page: offset)
                }
            )
        }
        // Was `setup-audio-xxxl`, at `dynamicTypeSize: .accessibility3`. The
        // parameter did nothing, so the frame was a default-size render wearing
        // an accessibility name. Kept as a light-mode render of the same page
        // at the taller window, which is a real second look; large text on this
        // page is **unverified**.
        scenes.append(
            scene("setup-audio-light-tall", CGSize(width: 590, height: 900), .light) {
                onboarding(page: 1)
            }
        )

        // The Bluetooth page is the only page this release adds, and it is the
        // one that ends in a system dialog. Its light rendering was unverified
        // with only the dark loop above.
        scenes.append(
            scene("setup-bluetooth-light", onboardingSize, .light) { onboarding(page: 3) }
        )

        // MARK: - Settings surfaces

        scenes.append(
            scene("settings-guide", CGSize(width: 720, height: 560), .dark) {
                AnyView(SettingsGuideView())
            }
        )
        scenes.append(
            scene("settings-guide-light", CGSize(width: 720, height: 560), .light) {
                AnyView(SettingsGuideView())
            }
        )
        // The guide's search is the half of it that people actually use, and the
        // default frame only ever shows the browse state.
        scenes.append(
            scene("settings-guide-search", CGSize(width: 720, height: 560), .dark) {
                AnyView(SettingsGuideView(initialQuery: "music is too loud on zoom"))
            }
        )
        // A popup-resident result, so the frame covers the other of the guide's
        // two actions: the one that opens the menu bar popup rather than a tab.
        scenes.append(
            scene("settings-guide-search-popup", CGSize(width: 720, height: 560), .dark) {
                AnyView(SettingsGuideView(initialQuery: "this app is too quiet"))
            }
        )
        scenes.append(
            scene("settings-updates", CGSize(width: 620, height: 620), .dark) { updatesTab() }
        )

        // MARK: - Update states

        // All but "up to date" need a live server and a published release to
        // reach, so without setting them directly the states nobody can see are
        // exactly the ones that matter — a failed download, a signature that did
        // not validate, an update sitting downloaded and waiting.
        let hourAgo = Date().addingTimeInterval(-3600)
        let pending = SparkleUpdateController.PendingUpdate(
            version: "2.9.5",
            build: "300",
            notes: nil,
            notesAreHTML: true,
            notesURL: URL(string: "https://megavessal.github.io/Melo/notes/2.9.5.html"),
            downloadBytes: 14_680_064,
            published: hourAgo,
            isCritical: false
        )
        let updateStates: [(String, SparkleUpdateController.Activity)] = [
            ("updates-checking", .checking),
            ("updates-uptodate", .upToDate),
            ("updates-available", .available(pending)),
            ("updates-downloading", .downloading(pending)),
            ("updates-ready", .readyToInstall(pending)),
            (
                "updates-failed-network",
                .failed(
                    SparkleUpdateController.Failure(
                        summary: "Melo couldn’t reach the update server.",
                        recovery: "Check your internet connection and try again. Nothing on this Mac was changed.",
                        detail: "The Internet connection appears to be offline."
                    )
                )
            ),
            (
                "updates-failed-signature",
                .failed(
                    SparkleUpdateController.Failure(
                        summary: "The download didn’t match its signature, so Melo threw it away.",
                        recovery: "Your installed Melo is untouched. This can mean a damaged download or a feed that isn’t genuine; try again, and if it keeps happening, download Melo again from its website.",
                        detail: "An error occurred while extracting the archive. Please try again later."
                    )
                )
            )
        ]
        for (name, activity) in updateStates {
            scenes.append(
                scene(
                    name,
                    CGSize(width: 620, height: 620),
                    .dark,
                    prepare: { sparkle.setActivityForSnapshot(activity, lastCheck: hourAgo) }
                ) { updatesTab() }
            )
        }
        // Skip and Remind Me Later, driven by the methods their buttons call,
        // against a controller that actually has an update waiting.
        //
        // These were set states — `.skipped(pending)` handed straight to the
        // card — which is the shape of the original defect: a frame showing
        // what the state is supposed to become, proving nothing about whether
        // the button reaches it. `skipPendingUpdate()` and `remindLater()` both
        // `guard let pendingUpdate`, so neither could run at all until
        // `setPendingUpdateForSnapshot(_:)` existed to put one there. It does
        // now, and it writes through `didSet`, so the seam produces a state the
        // app can really be in rather than one it cannot.
        //
        // Still coordinator-driven, so `bindingCaveat` applies to these as well.
        @MainActor func decision(
            name: String,
            act: @escaping @MainActor () -> Void
        ) -> [SnapshotHarness.Scene] {
            SnapshotHarness.transition(
                name: name,
                size: CGSize(width: 620, height: 700),
                colorScheme: .dark,
                note: SnapshotHarness.bindingCaveat,
                prepare: {
                    applyAppearance(.dark)
                    sparkle.setPendingUpdateForSnapshot(pending)
                    sparkle.setActivityForSnapshot(.available(pending), lastCheck: hourAgo)
                },
                act: act
            ) { updatesTab() }
        }
        scenes += decision(name: "updates-skipped", act: { sparkle.skipPendingUpdate() })
        scenes += decision(name: "updates-deferred", act: { sparkle.remindLater() })
        // Leaves no pending update behind for the frames that follow.
        scenes.append(
            scene(
                "updates-after-decisions",
                CGSize(width: 620, height: 620),
                .dark,
                prepare: {
                    sparkle.setPendingUpdateForSnapshot(nil)
                    sparkle.setActivityForSnapshot(.upToDate, lastCheck: hourAgo)
                }
            ) { updatesTab() }
        )

        // The developer path's worst outcome: the swap ran, the new build never
        // came up, and the installer put the old one back. Only reachable in
        // real life by shipping a build that will not launch.
        scenes.append(
            scene(
                "updates-rolled-back",
                CGSize(width: 620, height: 1160),
                .dark,
                prepare: {
                    sparkle.setActivityForSnapshot(.upToDate, lastCheck: hourAgo)
                    developerUpdates.setStatusForSnapshot(
                        .rolledBack(
                            version: "2.9.5",
                            build: 300,
                            reason: "The new build was installed but never finished starting up, so Melo put the version you were running back."
                        ),
                        logURL: URL(fileURLWithPath: "/tmp/install-developer-update-300.log")
                    )
                }
            ) { updatesTab() }
        )
        // The release-notes history, open. It is a disclosure, so the state
        // holding every version's changes is invisible in every other frame.
        scenes.append(
            scene(
                "updates-release-notes",
                CGSize(width: 620, height: 1500),
                .dark,
                prepare: { sparkle.setActivityForSnapshot(.upToDate, lastCheck: hourAgo) }
            ) {
                AnyView(
                    UpdatesTab(
                        sparkle: sparkle,
                        developerUpdates: developerUpdates,
                        sectionTarget: nil,
                        releaseNotesExpanded: true
                    )
                    .background(Color(nsColor: .windowBackgroundColor))
                )
            }
        )
        scenes.append(
            scene(
                "updates-available-light",
                CGSize(width: 620, height: 620),
                .light,
                prepare: { sparkle.setActivityForSnapshot(.available(pending), lastCheck: hourAgo) }
            ) { updatesTab() }
        )

        // MARK: - AutoEQ, from a fixture

        // This Mac reports no correction-capable output, so the tour's AutoEQ
        // step has only ever rendered its "nothing connected supports it"
        // alternate and the wand itself has never appeared in any frame.
        //
        // The rows below render the component directly with a fixture device,
        // so the control the tour describes is inspectable on its own.
        //
        // This comment used to end "the device list cannot be seeded … there is
        // no seam reachable from this file", and that is no longer true — a
        // `#if MELO_DEV` `setDevicesForSnapshot(_:)` now exists on
        // `AudioDeviceMonitor` and the `tour-autoeq-seeded*` scenes at the end
        // of this file drive the tour's own spotlight through it. Keeping the
        // correction rather than deleting the claim, so nobody re-derives it.
        let fixtureHeadphones = AudioDevice(
            id: AudioDeviceID(0),
            uid: "snapshot-fixture-headphones",
            name: "Snapshot Fixture Headphones",
            icon: nil,
            supportsAutoEQ: true
        )
        let fixtureSpeakers = AudioDevice(
            id: AudioDeviceID(1),
            uid: "snapshot-fixture-speakers",
            name: "Snapshot Fixture Speakers",
            icon: nil,
            supportsAutoEQ: false
        )
        @MainActor func deviceRow(_ device: AudioDevice, isDefault: Bool) -> AnyView {
            AnyView(
                DeviceRow(
                    device: device,
                    isDefault: isDefault,
                    volume: 0.62,
                    isMuted: false,
                    onSetDefault: {},
                    onVolumeChange: { _ in },
                    onMuteToggle: {},
                    autoEQProfileManager: audioEngine.autoEQProfileManager,
                    autoEQFavoriteIDs: settings.favoriteAutoEQProfileIDs,
                    onAutoEQSelect: { _ in },
                    onAutoEQImport: {}
                )
            )
        }
        scenes.append(
            scene(
                "autoeq-device-rows",
                CGSize(width: 420, height: 140),
                .light,
                note: "Fixture devices, not this Mac's hardware. The top row is "
                    + "correction-capable, so it carries the AutoEQ wand; the bottom row is not."
            ) {
                AnyView(
                    VStack(spacing: 8) {
                        deviceRow(fixtureHeadphones, isDefault: true)
                        deviceRow(fixtureSpeakers, isDefault: false)
                    }
                    .padding(12)
                    .background(Color(nsColor: .windowBackgroundColor))
                )
            }
        )
        // The wand's popover. `AutoEQPicker` presents it through `PopoverHost`,
        // an `NSViewRepresentable` that puts up a real `NSPopover` — which is a
        // separate window and is therefore absent from every capture of the
        // popup. Rendering the panel directly is the only way its empty state,
        // its search field and its preamp switch are ever seen.
        scenes.append(
            scene(
                "autoeq-search-panel",
                CGSize(width: 300, height: 460),
                .light,
                note: "AutoEQ popover content, rendered directly: an NSPopover is its own "
                    + "window and never appears in a capture of the popup."
            ) {
                AnyView(
                    AutoEQSearchPanel(
                        profileManager: audioEngine.autoEQProfileManager,
                        favoriteIDs: settings.favoriteAutoEQProfileIDs,
                        selectedProfileID: nil,
                        onSelect: { _ in },
                        onDismiss: {},
                        onImport: {},
                        onToggleFavorite: { _ in },
                        importErrorMessage: nil
                    )
                    .frame(width: 260)
                    .padding(12)
                    .background(Color(nsColor: .windowBackgroundColor))
                )
            }
        )

        // MARK: - The popup with an update waiting

        // This is the surface a waiting update actually reaches — Melo used to
        // announce one by adding a second menu bar extra, which no frame can
        // show and which the HIG forbids. Appended late: `prepare` sets shared
        // controller state, and every earlier popup frame must stay free of the
        // banner.
        for (name, scheme) in [("popup-update-dark", ColorScheme.dark), ("popup-update-light", .light)] {
            scenes.append(
                scene(
                    name,
                    popupSize,
                    scheme,
                    prepare: {
                        seedDemoApps()
                        guidedTour.finish()
                        sparkle.setUpdateReminderForSnapshot(pending)
                    }
                ) { popup() }
            )
        }

        // MARK: - The menu bar mark and its update badge

        // `NSStatusBarButton` is not a SwiftUI view and cannot be put in a
        // scene, so the badge `MenuBarIconCoordinator` draws had never been
        // seen by anyone — a shipped feature with no image of it in existence.
        //
        // The status item does exist in this process: `FluidMenuBarExtra`
        // creates it, and the coordinator the app started at launch owns its
        // image. So rather than photograph a status item, this finds that
        // button and renders the `NSImage` the *shipped* code path put on it —
        // `apply()` → `badged(_:)`. Nothing here re-draws the badge, which is
        // the point: a harness that drew its own copy would pass while the
        // real one was broken.
        //
        // A menu bar extra is a template image, so it is shown on both a light
        // and a dark chip, at the real 22×18pt canvas and magnified with
        // nearest-neighbour so the punched ring's pixels can be counted.
        @MainActor func statusBarButton() -> NSStatusBarButton? {
            func search(_ view: NSView) -> NSStatusBarButton? {
                if let button = view as? NSStatusBarButton,
                   button.accessibilityTitle() == "Melo" {
                    return button
                }
                for subview in view.subviews {
                    if let match = search(subview) { return match }
                }
                return nil
            }
            for window in NSApp.windows {
                if let contentView = window.contentView, let match = search(contentView) {
                    return match
                }
            }
            return nil
        }

        @MainActor func chip(_ image: NSImage, dark: Bool, magnification: CGFloat) -> AnyView {
            let width = image.size.width * magnification
            let height = image.size.height * magnification
            return AnyView(
                Image(nsImage: image)
                    .resizable()
                    .interpolation(magnification > 1 ? .none : .high)
                    .renderingMode(.template)
                    .foregroundStyle(dark ? Color.white : Color.black)
                    .frame(width: width, height: height)
                    .padding(magnification > 1 ? 12 : 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(dark ? Color.black : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.gray.opacity(0.4), lineWidth: 1)
                    )
            )
        }

        @MainActor func menuBarMark() -> AnyView {
            guard let button = statusBarButton() else {
                return AnyView(
                    Text(
                        "No NSStatusBarButton with accessibilityTitle \"Melo\" was found in "
                        + "NSApp.windows. The menu bar extra did not materialize in this "
                        + "process, so the badge is UNVERIFIED for this run."
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                )
            }
            guard let image = button.image else {
                return AnyView(
                    Text("The status button exists but its image is nil. UNVERIFIED.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color(nsColor: .windowBackgroundColor))
                )
            }
            let facts = [
                String(format: "canvas %.0f×%.0fpt", image.size.width, image.size.height),
                "template: \(image.isTemplate)",
                "VoiceOver: \(image.accessibilityDescription ?? "—")",
                "tooltip: \(button.toolTip?.replacingOccurrences(of: "\n", with: " / ") ?? "—")"
            ]
            return AnyView(
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        chip(image, dark: false, magnification: 1)
                        chip(image, dark: true, magnification: 1)
                        Text("actual size")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        chip(image, dark: false, magnification: 10)
                        chip(image, dark: true, magnification: 10)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(facts, id: \.self) { fact in
                            Text(fact)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            )
        }

        // Rendered as a transition, so the badge is not merely visible but
        // demonstrably *caused* by a waiting update: if the two frames came out
        // pixel-identical the harness would fail the run.
        scenes += SnapshotHarness.transition(
            name: "menubar-icon",
            size: CGSize(width: 560, height: 380),
            colorScheme: .light,
            note: "The real NSImage from the live NSStatusBarButton, drawn by "
                + "MenuBarIconCoordinator. Template image shown on both chips; 10× is "
                + "nearest-neighbour so the punched ring is countable.",
            prepare: {
                applyAppearance(.light)
                sparkle.setUpdateReminderForSnapshot(nil)
                SnapshotHarness.settle(seconds: 0.4)
            },
            // Not a control press: an update arriving is not something any
            // button in this hierarchy does.
            act: {
                sparkle.setUpdateReminderForSnapshot(pending)
                SnapshotHarness.settle(seconds: 0.4)
            }
        ) { menuBarMark() }

        // Calibration for the two static families. Both should sit at or near
        // zero; if either starts moving, something in it is nondeterministic
        // and its transitions stop meaning anything.
        scenes += SnapshotHarness.negativeControl(
            name: "control-menubar",
            size: CGSize(width: 560, height: 380),
            colorScheme: .light,
            note: "Menu bar mark family.",
            prepare: {
                applyAppearance(.light)
                sparkle.setUpdateReminderForSnapshot(pending)
                SnapshotHarness.settle(seconds: 0.4)
            }
        ) { menuBarMark() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-updates",
            size: CGSize(width: 620, height: 620),
            colorScheme: .dark,
            note: "Settings → Updates family.",
            prepare: {
                applyAppearance(.dark)
                sparkle.setActivityForSnapshot(.available(pending), lastCheck: hourAgo)
            }
        ) { updatesTab() }

        // MARK: - What a percent means, and what the EQ costs in level
        //
        // Four states with no frame in existence: the EQ panel's automatic
        // headroom readout, the same panel on a curve that only cuts, an app
        // row past unity, and Find an Action's own arithmetic. Each is built
        // from the component the app really uses, with a fixture standing in
        // for state this Mac cannot reach — not from a copy of what the state
        // is meant to look like.

        // `AudioApp` needs a live pid to come out of the engine, so the row
        // frames use the same fixture the SwiftUI previews use. `MockData`
        // carries no `#if DEBUG`, so it is in this build.
        let rowApp = MockData.sampleApps[4]  // "Music"
        let rowDevices = MockData.sampleDevices

        @MainActor func appRow(
            volume: Float,
            boost: BoostLevel,
            eq: EQSettings,
            expanded: Bool
        ) -> AnyView {
            AnyView(
                AppRow(
                    app: rowApp,
                    volume: volume,
                    audioLevel: 0.4,
                    devices: rowDevices,
                    selectedDeviceUID: rowDevices[1].uid,
                    isFollowingDefault: false,
                    defaultDeviceUID: rowDevices[0].uid,
                    boost: boost,
                    onVolumeChange: { _ in },
                    onMuteChange: { _ in },
                    onDeviceSelected: { _ in },
                    eqSettings: eq,
                    isEQExpanded: expanded
                )
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
            )
        }

        // 1. The boosting preset. `.electronic` is the curve the headroom rule
        //    was written for: peak +7 dB, no compensating cut anywhere in it.
        let boostingCurve = EQSettings(
            bandGains: [7, 6, 4, 0, -2, -2, 1, 3, 4, 3],
            isEnabled: true
        )
        let eqRowSize = CGSize(width: 560, height: 430)
        for (name, scheme) in [
            ("eq-headroom-boosting", ColorScheme.dark),
            ("eq-headroom-boosting-light", .light)
        ] {
            scenes.append(
                scene(
                    name,
                    eqRowSize,
                    scheme,
                    note: "Fixture app row, open, carrying the Electronic curve "
                        + "[7,6,4,0,-2,-2,1,3,4,3]. The headroom readout sits beside the EQ "
                        + "switch; the ten band sliders must be UNSHIFTED — the preamp is a "
                        + "level change, not a curve change."
                ) {
                    appRow(volume: 1.0, boost: .x1, eq: boostingCurve, expanded: true)
                }
            )
        }

        // 2. The same panel on a curve that only cuts. It already has headroom,
        //    so there must be no label at all — "−0.0 dB" would be a readout
        //    about the absence of a thing.
        scenes.append(
            scene(
                "eq-headroom-cut-only",
                eqRowSize,
                .dark,
                note: "Same row, Bass Cut [-6,-5,-4,-2,0,0,0,0,0,0]. A cut-only curve takes no "
                    + "headroom, so NO dB readout may appear beside the EQ switch. Compare "
                    + "against eq-headroom-boosting."
            ) {
                appRow(volume: 1.0, boost: .x1, eq: EQPreset.bassCut.settings, expanded: true)
            }
        )

        // 3. An app row past unity. 100% base volume × 2× boost is the state the
        //    row used to report as "200%" while Find an Action called the same
        //    app "100%".
        scenes.append(
            scene(
                "app-row-200-percent",
                CGSize(width: 560, height: 96),
                .dark,
                note: "Fixture row, collapsed, volume 1.0 × boost 2×. The readout must say "
                    + "200% — effective gain × 100, the one definition of a percent in Melo."
            ) {
                appRow(volume: 1.0, boost: .x2, eq: .flat, expanded: false)
            }
        )
        // The same state with the row open, so the slider position and the
        // editable field can be read against the collapsed readout. 200% of a
        // 0–400 range is the centre-plus-one-sixth mark, not the far right.
        scenes.append(
            scene(
                "app-row-200-percent-open",
                CGSize(width: 560, height: 430),
                .dark,
                note: "Same 200% state, open. Three numbers must agree: the collapsed readout, "
                    + "the editable field, and the slider's own position on a 0–400 track whose "
                    + "unity marker sits at the centre."
            ) {
                appRow(volume: 1.0, boost: .x2, eq: .flat, expanded: true)
            }
        )

        // 4. Find an Action, empty query.
        //
        // The palette's app fixture cannot be invented: `audioEngine.apps` is
        // `processMonitor.activeApps` behind `private(set)`, and the
        // `AudioProcessMonitoring` seam is an init parameter on `AudioEngine`,
        // which this file receives already built. So the boost is set on
        // whatever CoreAudio really sees, and when it sees nothing the frame
        // says so rather than showing a palette with an unexplained absence.
        @MainActor func seedBoostedApp() {
            guard let app = audioEngine.apps.first else { return }
            audioEngine.setBoost(for: app, to: .x2)
            audioEngine.setVolume(for: app, to: 1.0)
        }

        @MainActor func palette() -> AnyView {
            AnyView(
                ConsumerCommandPalette(
                    audioEngine: audioEngine,
                    sparkleUpdateController: sparkle,
                    onOpenSettings: {},
                    onClose: {}
                )
            )
        }

        @MainActor func paletteWithFixtureBanner() -> AnyView {
            let seeded = audioEngine.apps.first.map {
                "Fixture: \($0.name) at volume 1.0 × 2× boost. "
                + "Its Raise row must read “Now 200% — this makes it 210%”."
            }
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    Text(
                        seeded ?? "NO ACTIVE AUDIO APP ON THIS MAC. `audioEngine.apps` is "
                        + "`processMonitor.activeApps`, which is private(set); the only seam "
                        + "is the `processMonitor:` init parameter on AudioEngine, and this "
                        + "harness is handed an engine that is already built. The boosted-app "
                        + "arithmetic below is therefore UNVERIFIED for this run."
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(audioEngine.apps.isEmpty ? Color.red : Color.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))

                    palette()
                }
            )
        }

        scenes.append(
            scene(
                "palette-empty-query",
                popupSize,
                .dark,
                note: "Find an Action with nothing typed. The banner states the fixture. "
                    + "Whether a “Raise …” row is present here at all is the thing to read.",
                prepare: {
                    seedDemoApps()
                    guidedTour.finish()
                    seedBoostedApp()
                }
            ) { paletteWithFixtureBanner() }
        )

        // 5. The Guide, asked the question the new headroom rule creates.
        //
        // A boosting preset now costs up to 7 dB of level, and the only
        // explanation of that on any surface is a `.help()` tooltip on a
        // tertiary label. Melo's *other* preamp — the imported AutoEQ profile's
        // — has a labelled switch and a Guide entry ("Prevent Profile
        // Clipping") whose keywords include "quieter after a profile". This
        // frame is the search a user runs after picking Electronic and hearing
        // it get quieter: it shows what the Guide offers them.
        scenes.append(
            scene(
                "settings-guide-search-quieter-preset",
                CGSize(width: 720, height: 560),
                .dark,
                note: "Guide search for the symptom the automatic EQ headroom produces. Read "
                    + "whether any result is about the built-in equaliser's preamp rather than "
                    + "about imported AutoEQ profiles."
            ) {
                AnyView(SettingsGuideView(initialQuery: "quieter after a preset"))
            }
        )

        // 6. **NOT BUILT: the palette with “Music to 200%” typed.**
        //
        // `ConsumerCommandPalette.searchText` is `@State private`, and every
        // path that turns a query into rows — `filteredCommands`,
        // `directIntentCommands(query:)`, `resultsList` — is `private` too. The
        // view's only initializer parameters are the engine, the update
        // controller and two closures, so there is no way to hand it a query
        // from here. Typing into it is the documented dead end: the offscreen
        // hosting view exposes no accessibility tree, so `actOnHost` has
        // nothing to send a keystroke to.
        //
        // The missing seam is one initializer parameter — `initialQuery`, the
        // same one `SettingsGuideView(initialQuery:)` already has and which
        // `settings-guide-search` renders through. Until it exists, "Set Music
        // to 200%" is **unverified** as a visible row, and a frame that drew it
        // would be a picture of what the state is supposed to be.

        // MARK: - The command palette, with a query actually typed

        // Until now this file recorded "NOT BUILT: the palette with a query
        // typed" as a dead end, because `searchText` was `@State private` and
        // every path from a query to rows was private too. So the palette's
        // whole reason for existing — you type what you want and it finds it —
        // had never been rendered, and a coverage gap that made most of the
        // settings catalog unreachable sat there unseen. `initialQuery` is the
        // seam that closes it, in the same shape `SettingsGuideView` already had.
        @MainActor func paletteQuery(_ query: String) -> AnyView {
            AnyView(
                ConsumerCommandPalette(
                    audioEngine: audioEngine,
                    sparkleUpdateController: sparkle,
                    onOpenSettings: {},
                    onClose: {},
                    initialQuery: query
                )
            )
        }
        let paletteSize = CGSize(width: 560, height: 460)

        // Deterministic: the settings catalog is static and needs no apps and no
        // devices, so this frame reads the same on any Mac. It is the anchor —
        // if the query-to-rows path renders at all, it renders here.
        scenes.append(
            scene("palette-query-setting", paletteSize, .dark,
                  note: "Query \"launch at login\". Expect a HELP row titled "
                      + "\"Launch at Login\" with its Settings location beneath. "
                      + "Roughly a hundred catalog entries were unreachable from "
                      + "this box before; this is the class of row that fixes.") {
                paletteQuery("launch at login")
            }
        )
        // Also deterministic. The empty state had never been rendered either.
        scenes.append(
            scene("palette-query-nomatch", paletteSize, .dark,
                  note: "Query \"zzqqxx\". Expect the no-match state. What this "
                      + "says when it finds nothing is the whole of the "
                      + "experience for anyone who searches a word Melo does "
                      + "not know.") {
                paletteQuery("zzqqxx")
            }
        )
        // Fixture-dependent: needs Music in `displayableApps` on the render
        // machine. If it is absent the frame shows only help rows, which is
        // still a true reading rather than a broken one.
        scenes.append(
            scene("palette-query-volume", paletteSize, .dark,
                  note: "Query \"set music to 200%\". This exact phrasing scored "
                      + "zero before — one filler word away from working. If a "
                      + "Music row is absent here, check whether the fixture app "
                      + "is present before reading it as a regression.",
                  prepare: { seedDemoApps() }) {
                paletteQuery("set music to 200%")
            }
        )

        // MARK: - Themes and their easter eggs

        // No theme scene existed at all until now: every popup frame rendered
        // whatever `visualTheme` defaults to, which is `.systemAccent`. So the
        // rocket gate and all three new eggs were unverifiable by definition —
        // which is how rockets came to be flying on a theme they do not belong
        // on without any frame showing it.
        //
        // `forcedTime` replaces wall-clock time for the eggs *and* the rockets,
        // so a rare visitor can be captured at a chosen moment without making it
        // any commoner. Making an easter egg more frequent so a test can see it
        // would be trading the feature for the test.
        // `capture: .imageRenderer`, and this is the whole reason these scenes
        // are worth anything. The first version of them rendered the popup on
        // the default `.layer` path, and `theme-space-rocket`,
        // `theme-galaxy-rocket` and `theme-aurora-egg` came back **byte
        // identical** — three themes drawing different gradients, different star
        // fields, a nebula, four aurora ribbons and two mountain silhouettes,
        // producing the same pixels, because the themed backdrop draws none of
        // it into a layer capture. Every background pixel measured exactly
        // (37,37,37), the harness's own backing colour, i.e. unpainted.
        //
        // So the absence of a rocket on a theme that must not have one proved
        // nothing: it was equally absent from the two themes that must. The
        // control and the test were the same empty frame. `ImageRenderer` draws
        // the tree rather than reading back a layer, which is the same reason
        // `popup-header-*` exists.
        //
        // The backdrop is rendered alone: the popup body is largely
        // `NSViewRepresentable` and comes back as a placeholder on this path, so
        // rendering the whole popup would spend the frame on the half that is
        // not under test.
        @MainActor func themeBackdropScene(
            _ name: String,
            _ theme: MeloVisualTheme,
            _ scheme: ColorScheme,
            at forcedTime: TimeInterval,
            accentHex: String = "#3B82F6",
            note: String
        ) -> SnapshotHarness.Scene {
            scene(name, popupSize, scheme, capture: .imageRenderer, note: note, prepare: {
                var appSettings = settings.appSettings
                appSettings.customAccentHex = accentHex
                settings.appSettings = appSettings
                MeloEasterEggClock.forcedTime = forcedTime
            }) {
                AnyView(
                    MeloThemeBackdrop(
                        theme: theme,
                        customAccentHex: accentHex,
                        generatedTheme: nil
                    )
                    .frame(width: popupSize.width, height: popupSize.height)
                )
            }
        }

        scenes.append(themeBackdropScene(
            "theme-space-rocket", .space, .dark, at: 5.4,
            note: "Rockets belong here. Exactly one is on screen, and that is "
                + "correct: two lanes are mid-flight at t=5.4, but the second "
                + "sits at x=-52, already past the left edge. The earlier note "
                + "here said 'two should be in flight', which is true of the "
                + "model and false of the frame — it reads as a half-failure and "
                + "invites a fix to something that works. This frame and "
                + "theme-galaxy-rocket are the controls for the gate: if they are "
                + "empty, an empty theme-mac-egg proves nothing."
        ))
        scenes.append(themeBackdropScene(
            "theme-galaxy-rocket", .galaxy, .dark, at: 5.4,
            note: "Rockets belong here too. One on screen, for the same reason "
                + "as theme-space-rocket — same forced time, same lane phases."
        ))
        // Light on purpose: `.systemAccent` and `.custom` are the two themes that
        // do not force dark appearance, and the claim about these two visitors is
        // that a dark outline carries them on a pale panel. A light frame is what
        // would falsify that.
        scenes.append(themeBackdropScene(
            "theme-mac-egg", .systemAccent, .light, at: 77.1,
            note: "The desk Mac, peeked with its screen lit. No rocket may appear "
                + "here — that is the gate under test. Accent tint desaturates in "
                + "this harness, so the screen's colour stays unverified; the "
                + "outline and body are what this frame can prove."
        ))
        scenes.append(themeBackdropScene(
            "theme-aurora-egg", .aurora, .dark, at: 204.7,
            note: "A single warm cabin window on the far ridge, below the far "
                + "silhouette and above the near one. No rocket may appear here."
        ))
        // Two frames, at the two ends of the range, because this is the visitor
        // whose legibility claim is most likely to be wrong: the user picks the
        // colour. A near-white brush on a white panel and a near-black one on a
        // black panel are where "the outline carries it, not the hue" either
        // holds or dies. A mid-blue accent would prove neither.
        scenes.append(themeBackdropScene(
            "theme-custom-egg", .custom, .light, at: 23.58, accentHex: "#F2F2F2",
            note: "The brush at the end of its sweep, in a near-white accent on a "
                + "light panel. If the stroke and bristles vanish here, the "
                + "shape-carries-it claim is false at the pale end."
        ))
        scenes.append(themeBackdropScene(
            "theme-custom-egg-dark", .custom, .dark, at: 23.58, accentHex: "#101010",
            note: "The same brush in a near-black accent on a dark panel — the "
                + "other end of the same range."
        ))

        // MARK: - The Guide's "Show me" lands on the section

        // "Show me" used to switch tab and print a breadcrumb across the top of
        // the window; it now scrolls the tab to the heading the entry names.
        // The only way to see that happened is a frame of a tab standing
        // somewhere other than its top, and until now no frame in this list
        // rendered a Settings tab at all.
        //
        // The target is built by the shipping derivation from the shipping
        // catalog entry, not from a string written here: if
        // `sectionTitle(inLocation:)` stops resolving, or the tab's `.id`
        // anchors stop matching it, no target is produced, the "after" frame
        // comes back identical to its "before", and `mustDiffer` fails the run.
        // That is the assertion; the frame is its readable half.
        var audioSectionTarget: SettingsSectionTarget?

        @MainActor func audioTab() -> AnyView {
            AnyView(
                AudioTab(
                    settings: settings,
                    audioEngine: audioEngine,
                    deviceVolumeMonitor: deviceVolumeMonitor,
                    callDuckingManager: CallDuckingManager(audioEngine: audioEngine),
                    powerSourceMonitor: PowerSourceMonitor(audioEngine: audioEngine),
                    sectionTarget: audioSectionTarget
                )
            )
        }

        /// The target the Guide entry `id` produces, through the shipping path.
        @MainActor func guideTarget(entryID: String, serial: Int) -> SettingsSectionTarget? {
            let entry = SettingsGuideEntry.all.first { $0.id == entryID }
            return SettingsGuideEntry.sectionTitle(inLocation: entry?.location).map {
                SettingsSectionTarget(section: $0, serial: serial)
            }
        }

        let audioTabSize = CGSize(width: 860, height: 620)

        scenes += SnapshotHarness.transition(
            name: "settings-audio-guide-devices",
            size: audioTabSize,
            colorScheme: .dark,
            note: "BEFORE is the Audio tab as it opens. AFTER is the same tab after the "
                + "Guide entry \"System Sounds\" asked for its section. Devices is the last "
                + "of six sections, so the scroll stops at the end of the content and "
                + "Devices sits low in the pane rather than pinned to the top — that is "
                + "correct. The thing to read is that the Volume section is no longer on "
                + "screen. The action is a target handed to the tab, not a press of the "
                + "Guide's button; what the button is wired to is UNVERIFIED. The "
                + "scroll position is asserted on the live view as a number, in both "
                + "frames — see the pair of assertions below.",
            prepare: {
                applyAppearance(.dark)
                audioSectionTarget = nil
            },
            act: {
                audioSectionTarget = guideTarget(entryID: "system-sounds", serial: 1)
            },
            // The control and the assertion, on the same pane through the same
            // code path, differing only in what they expect. A floor on the
            // AFTER frame alone would be a number nobody has watched fail.
            //
            // Both floors were set from a run with them raised to an
            // unsatisfiable 20000pt, so the numbers are measured rather than
            // guessed: BEFORE reported exactly 0pt and AFTER reported 602pt.
            // 200pt sits far below the real descent and far above anything the
            // tab does at rest.
            assertBefore: SnapshotHarness.requireAtTop(),
            assertAfter: SnapshotHarness.requireScrolled(atLeast: 200)
        ) { audioTab() }

        // A section that can reach the very top of the pane, so the frame shows
        // the landing rather than the end of the scroll.
        scenes.append(
            scene(
                "settings-audio-guide-smartsound",
                audioTabSize,
                .dark,
                note: "The Audio tab after the Guide entry \"Smart Sound\" asked for its "
                    + "section. Smart Sound is the third of six, so it can reach the top of "
                    + "the pane. Volume and Calls should be scrolled off above it.",
                // This frame had no check of any kind. It is not a transition,
                // so no pixel floor covers it, and it has been failing in step
                // with `settings-audio-guide-devices` — silently, because
                // nothing was looking. The number is smaller than the Devices
                // floor because Smart Sound is the third section rather than
                // the last: measured the same way, it lands at 346pt against
                // Devices' 602pt.
                assertOnHost: SnapshotHarness.requireScrolled(atLeast: 120)
            ) {
                AnyView(
                    AudioTab(
                        settings: settings,
                        audioEngine: audioEngine,
                        deviceVolumeMonitor: deviceVolumeMonitor,
                        callDuckingManager: CallDuckingManager(audioEngine: audioEngine),
                        powerSourceMonitor: PowerSourceMonitor(audioEngine: audioEngine),
                        sectionTarget: guideTarget(entryID: "adaptive", serial: 2)
                    )
                )
            }
        )

        // 7. The six surfaces behind a click. Until now `tour-07-search`
        //    spotlighted the ⌘K button and nothing had ever seen what it opens,
        //    which is exactly what makes a button look verified when it isn't.
        scenes.append(
            scene("popup-command-palette", popupSize, .dark,
                  prepare: { seedDemoApps(); guidedTour.finish() }) {
                seededPopup(commandPaletteOpen: true)
            }
        )
        scenes.append(
            scene("popup-command-palette-light", popupSize, .light,
                  prepare: { seedDemoApps(); guidedTour.finish() }) {
                seededPopup(commandPaletteOpen: true)
            }
        )
        // Every frame ever rendered has been the Output tab.
        scenes.append(
            scene("popup-input-devices", popupSize, .dark,
                  prepare: { guidedTour.finish() }) {
                seededPopup(showingInputDevices: true)
            }
        )
        // Priority-edit mode, both tabs. The input branch is a different row:
        // no expand affordance and no Paired block.
        scenes.append(
            scene("popup-edit-priority", popupSize, .dark,
                  prepare: { guidedTour.finish() }) {
                seededPopup(editingDevicePriority: true)
            }
        )
        scenes.append(
            scene("popup-edit-priority-input", popupSize, .dark,
                  prepare: { guidedTour.finish() }) {
                seededPopup(showingInputDevices: true, editingDevicePriority: true)
            }
        )
        // An app row open with no tour card over it. Every existing view of
        // `AppRowControls` and `EQPanelView` is partly covered by a callout.
        scenes.append(
            scene("popup-app-expanded", popupSize, .dark,
                  prepare: { seedDemoApps(); guidedTour.finish() }) {
                seededPopup(quietAppsExpanded: true, expandedRowID: "com.apple.Music")
            }
        )

        // 8. The AutoEQ tour anchor, with a device that actually supports
        //    correction.
        //
        // These are last on purpose. `setDevicesForSnapshot(_:)` sets
        // `snapshotDevicesPinned`, after which `AudioDeviceMonitor.refresh()`
        // returns early for the rest of the process — otherwise a Bluetooth
        // device connecting mid-render would silently replace the fixture. So
        // every scene that needs this Mac's real hardware has already run by
        // the time these mount, and nothing above this line changes.
        //
        // What this closes: this Mac reports no correction-capable output, so
        // tour step 4 has only ever rendered its "nothing connected supports
        // it" alternate, and the wand the step's sentence names has never
        // appeared in any frame. The alternate is correct behaviour and worth
        // keeping a frame of — `tour-04-autoEQ` above still renders it. What
        // was missing is the other branch.
        let seededHeadphones = AudioDevice(
            id: AudioDeviceID(9001),
            uid: "snapshot-seeded-headphones",
            name: "Snapshot Seeded Headphones",
            icon: nil,
            supportsAutoEQ: true
        )
        let seededSpeakers = AudioDevice(
            id: AudioDeviceID(9002),
            uid: "snapshot-seeded-speakers",
            name: "Snapshot Seeded Speakers",
            icon: nil,
            supportsAutoEQ: false
        )
        @MainActor func pinSeededDevices() {
            (audioEngine.deviceMonitor as? AudioDeviceMonitor)?
                .setDevicesForSnapshot([seededHeadphones, seededSpeakers])
        }

        if let autoEQIndex = GuidedTourCoordinator.firstRunTour
            .firstIndex(where: { $0.id == "autoEQ" }) {
            scenes.append(
                scene(
                    "tour-autoeq-seeded",
                    popupSize,
                    .dark,
                    prepare: {
                        seedDemoApps()
                        pinSeededDevices()
                        guidedTour.jump(to: autoEQIndex, in: .firstRun)
                    }
                ) { popup() }
            )
            scenes.append(
                scene(
                    "tour-autoeq-seeded-light",
                    popupSize,
                    .light,
                    prepare: {
                        seedDemoApps()
                        pinSeededDevices()
                        guidedTour.jump(to: autoEQIndex, in: .firstRun)
                    }
                ) { popup() }
            )
        }

        // The device list itself with a correction-capable row present, so the
        // wand can be judged outside the tour's scrim as well as inside it.
        scenes.append(
            scene(
                "popup-devices-seeded",
                popupSize,
                .dark,
                prepare: {
                    seedDemoApps()
                    pinSeededDevices()
                    guidedTour.finish()
                }
            ) { popup() }
        )

        // MARK: - Melo Edit
        //
        // These frames are the only look anyone gets at this window without
        // running it, and they are deliberately unflattering: the empty Chain,
        // the move with no rationale, the format that needs a tool this Mac
        // does not have.
        //
        // The seeding seam is `EditorStore.setForSnapshot(document:waveform:)`,
        // which pins the fixture so the debounced re-render cannot reach a
        // `RenderEngine` for a file that does not exist and blank the frame. Every
        // editor view binds to `EditorStore.shared`, so without it every
        // Melo Edit frame would be the empty state. A few views add their own
        // seeding on top, for state the store does not hold: an expanded row, a
        // drop target, a zoom, a playing transport, an in-flight job.
        //
        // **These frames appear last in the list on purpose.** `setForSnapshot`
        // pins the store for the rest of the process, `EditorRecents.setForSnapshot`
        // pins the recents list, and `JobStripTuning.seedSnapshotJobs` drops the
        // strip's quiet delay to zero. None of that may reach a popup or Settings
        // frame above this line.

        let editor = EditorStore.shared

        // A fixed instant, so nothing in these frames is a function of when they
        // were rendered. Nothing draws `measuredAt` or `openedAt` today; a frame
        // that silently becomes nondeterministic when something does is a frame
        // whose negative control starts flaking for no discoverable reason.
        let editorInstant = Date(timeIntervalSince1970: 1_770_000_000)

        let editorAudioURL = URL(fileURLWithPath: "/Users/you/Music/morning-show-ep41.wav")
        let editorSource = EditorSource(
            url: editorAudioURL,
            displayName: "morning-show-ep41",
            origin: .file(originalURL: editorAudioURL),
            duration: 250,
            sampleRate: 48_000,
            channelCount: 2,
            formatDescription: "WAV · 32-bit · 48 kHz stereo"
        )

        // Two measurements of the same kind of file, and the difference between
        // them is the whole novice path. Every number here is one `MoveProposer`
        // actually reads: the loudness gap, the true peak, the noise floor, the
        // silence at each end, the interior gaps, the DC offset, dual-mono.
        //
        // `quietReport` is below every threshold in the proposer, so Podcast
        // proposes the full Chain. `compliantReport` is inside all of them, so
        // Podcast proposes nothing at all and says so. A picker that stopped
        // consulting the measurement would draw these two identically, which is
        // what `scripts/verify-cutting-room.py` reads the frames for.
        let quietReport = AnalysisReport(
            integratedLUFS: -22.4,
            truePeakDBTP: -0.4,
            loudnessRangeLU: 7.4,
            peakDBFS: -0.6,
            noiseFloorDBFS: -48.5,
            dcOffset: 0.0042,
            clippedSampleCount: 0,
            spectralTiltDBPerOctave: -2.1,
            leadingSilence: 1.8,
            trailingSilence: 2.4,
            interiorSilences: [31.2...33.4, 88.0...90.4, 150.2...152.1],
            isEffectivelyMono: true,
            measuredAt: editorInstant
        )
        let compliantReport = AnalysisReport(
            integratedLUFS: -16.2,
            truePeakDBTP: -1.6,
            loudnessRangeLU: 6.0,
            peakDBFS: -2.0,
            noiseFloorDBFS: -62.0,
            dcOffset: 0.00008,
            clippedSampleCount: 0,
            spectralTiltDBPerOctave: -2.0,
            leadingSilence: 0.1,
            trailingSilence: 0.2,
            interiorSilences: [],
            isEffectivelyMono: false,
            measuredAt: editorInstant
        )

        // The real proposal, from the shipped proposer, rather than a hand-written
        // list of what a proposal is supposed to look like. That is the point: if
        // `MoveProposer` stops producing rationales, or stops producing moves, the
        // Chain frames show it rather than showing a fixture that cannot change.
        let proposedMoves = MoveProposer.propose(
            for: quietReport,
            destination: DestinationCatalogue.podcast,
            source: editorSource
        )

        // A Chain somebody has been working in: the proposal, one move they added
        // by hand (so no rationale — the row has to survive that), and one they
        // switched off rather than deleted, which is the whole reason a
        // non-destructive Chain is worth having.
        var mixedMoves = proposedMoves
        mixedMoves.insert(
            Move(kind: .gain(dB: 1.5), rationale: nil),
            at: min(2, mixedMoves.count)
        )
        // Index 1, not the last of nine. A 320×520 pane holds about four rows of
        // this Chain, so switching off the last one produced a frame whose
        // provenance band promised a dimmed move the image physically could not
        // contain — and it was read, correctly, as "nothing here is dim". A
        // proposed move rather than the hand-added one, so the dimming is judged
        // on a three-line row with a rationale on it.
        if mixedMoves.count > 1 {
            mixedMoves[1].isEnabled = false
        }
        /// The move the disable transition switches off. Same reasoning: it has
        /// to be above the fold or the two frames differ only where nobody can
        /// see, and the pixel assertion in `verify-cutting-room.py` reads them.
        let moveToDisable = proposedMoves.count > 1 ? proposedMoves[1] : proposedMoves.first

        // One move per inspector worth a frame. The proposal above contains no
        // gain, no fade and no equalizer, so these are built here; `MoveInspector`
        // is reached through the row's own disclosure rather than rendered
        // directly, which is what makes the frame evidence that the row opens onto
        // it.
        let inspectorBands = EQSettings(
            bandGains: [3, 2, 0, -2, -3, -1, 1, 2, 3, 2],
            isEnabled: true
        ).autoEQFilters
        let inspectorMoves: [Move] = [
            Move(
                kind: .trim(start: 1.8, end: 247.6),
                rationale: "There's 1.8s of room tone at the front and 2.4s at the end — "
                    + "this starts you at the first sound and stops at the last."
            ),
            Move(kind: .gain(dB: 1.5), rationale: nil),
            Move(
                kind: .normalize(appliedGainDB: 6.4, measuredLUFS: -22.4, targetLUFS: -16),
                rationale: "This measured −22.4 LUFS, 6.4 dB under what podcast wants — "
                    + "this moves it to −16.0."
            ),
            Move(kind: .fadeOut(length: 2.5, curve: .equalPower), rationale: nil),
            Move(kind: .equalizer(bands: inspectorBands, preampDB: -3), rationale: nil)
        ]

        // Named so the recents list is the same on every machine. Without this the
        // empty state shows whatever the person running the harness opened that
        // morning, and "does the first screen look right" becomes a question about
        // their music library.
        //
        // One of each `Kind`, not three files. The field exists because the row's
        // leading glyph tells a dropped file, a link extraction and a recording
        // apart using the same three symbols as the entry cards below them, and a
        // fixture of three `.file` rows would render a screen that cannot show the
        // only thing the field is for.
        let editorRecents: [EditorRecent] = [
            EditorRecent(
                url: editorAudioURL,
                displayName: "morning-show-ep41",
                formatDescription: "WAV · 48 kHz stereo",
                duration: 250,
                openedAt: editorInstant,
                kind: .file
            ),
            EditorRecent(
                url: URL(
                    fileURLWithPath:
                        "/Users/you/Library/Application Support/Melo/Extractions/interview-clip.m4a"
                ),
                displayName: "interview-clip",
                formatDescription: "AAC · 256 kbps · 44.1 kHz stereo",
                duration: 96.4,
                openedAt: editorInstant.addingTimeInterval(-3_600),
                kind: .link
            ),
            EditorRecent(
                url: URL(
                    fileURLWithPath:
                        "/Users/you/Library/Application Support/Melo/Recordings/take-2.caf"
                ),
                displayName: "Recording, 9 Aug at 14:02",
                formatDescription: "CAF · 32-bit float · 48 kHz stereo",
                duration: 47.5,
                openedAt: editorInstant.addingTimeInterval(-7_200),
                kind: .recording
            )
        ]

        /// The drawing fixture, and the only one. The store used to carry a
        /// second, and it was deleted rather than repaired.
        ///
        /// `WaveformData.buckets` is `bucketCount * channelCount`,
        /// channel-interleaved, because the render draws a lane per channel. The
        /// store's fixture still emitted one lane per bucket, so a stereo frame
        /// drawn from it read adjacent *time* samples as left and right: two lanes
        /// that differed slightly, looked like a working stereo drawing, and were
        /// not one. Two fixture generators that both have to keep agreeing with
        /// the bucket layout is the defect class `CLAUDE.md:138` already records,
        /// so there is one, here, next to the scenes that read it.
        ///
        /// The channels get different content on purpose: two identical lanes in
        /// a frame then read as a defect rather than as an artefact of the
        /// fixture.
        ///
        /// ## Why it is shaped like this
        ///
        /// **A fixture that flatters the drawing is worse than no fixture.**
        /// Until 2026-08-09 this was `sin(position * .pi) * 0.85` times a
        /// 37-cycle tremor over 900 buckets — about twenty-four buckets per
        /// wobble — with `rms` pinned to a constant `peak * 0.62`. Every frame
        /// anyone had ever judged the waveform from was therefore a smooth
        /// synthetic hump, symmetric about zero, with a crest factor that never
        /// moved: no transients, no quiet passages, no bucket-to-bucket change
        /// at all. The owner looked at one and called the waveform ugly, and a
        /// good half of what they were looking at was this function.
        ///
        /// So it now generates something with the properties real audio has and
        /// that one did not:
        ///
        /// - **Passages.** A programme of eight sections at different levels,
        ///   including two near-silent ones, rather than one arch.
        /// - **Transients.** A hit on a per-passage spacing with a fast decay
        ///   off it, every fourth one louder, which is what makes a drawing look
        ///   like music rather than like a signal generator.
        /// - **Bucket-to-bucket grain** from an integer hash, not a slow sine.
        /// - **Asymmetry.** `minimum` is not `-maximum`. Real waveforms are not
        ///   symmetric about zero and a drawing that is looks manufactured.
        /// - **A crest factor that moves.** The RMS-to-peak ratio is low in the
        ///   percussive passages, high in the sustained ones, and collapses on
        ///   each transient — which is the whole reason the drawing carries two
        ///   weights instead of one.
        ///
        /// **Deterministic**, from an integer hash rather than `Double.random`:
        /// `SnapshotHarness.negativeControl` renders a scene twice and requires
        /// the two frames to be near-identical, so a fixture that varied per
        /// call would make every waveform control fail and every transition
        /// pass.
        ///
        /// 2048 buckets because that is what `EditorStore.waveformBuckets`
        /// really asks for. The old 900 sat close enough to
        /// `EditorWaveformView.isDense`'s threshold at Melo's window widths that
        /// a display scale of 3 would have silently dropped the RMS core out of
        /// every fit-zoom frame.
        /// `variant` is what makes a multitrack frame worth rendering.
        ///
        /// A lane draws its clip from that clip's *source*, so a document built
        /// from four files needs four different pictures. Without one, every
        /// source at the same duration produces the same buckets, four lanes
        /// draw the same waveform, and the frame looks exactly like a working
        /// multitrack timeline while proving nothing at all — the same failure
        /// the two-lanes-from-one-channel note above records, one level up.
        ///
        /// It rotates which passage of the programme lands in which section of
        /// the file and salts the grain, so the takes differ in level, crest
        /// and transient spacing rather than only in length. It does **not**
        /// move the section boundaries: `programme` is searched by ascending
        /// `until` and reordering those would break the search.
        ///
        /// **`variant: 0` is byte-identical to what this produced before the
        /// parameter existed** — rotation zero, salt unchanged — so every scene
        /// written against the single-source fixture renders the frame it
        /// rendered yesterday.
        @MainActor func editorWaveform(
            duration: TimeInterval,
            channels: Int,
            buckets: Int = 2_048,
            variant: Int = 0
        ) -> WaveformData {
            let lanes = max(channels, 1)
            let span = max(duration, 0.001)
            let bucketsPerSecond = Double(buckets) / span

            // The integer hash `MeloVisualTheme`'s star field uses, which is
            // already this project's answer to "deterministic noise".
            func noise(_ index: Int, _ salt: Int) -> Double {
                var value = UInt64(truncatingIfNeeded: index &* 1_103_515_245 &+ salt &* 12_345)
                value ^= value >> 16
                value &*= 0x7FEB_352D
                value ^= value >> 15
                return Double(value % 10_000) / 10_000
            }

            // The take: where each passage ends as a fraction of the file, how
            // loud it is, its RMS-to-peak ratio, and how often it hits — in
            // seconds, so the shape survives a different bucket count or a
            // different fixture duration.
            let programme: [(until: Double, level: Double, crest: Double, hit: Double)] = [
                (0.035, 0.05, 0.78, 1.30),   // room tone before it starts
                (0.230, 0.88, 0.40, 0.42),   // in loud, and percussive
                (0.310, 0.24, 0.70, 0.63),   // it drops away
                (0.520, 0.66, 0.60, 0.47),   // the body of it
                (0.560, 0.03, 0.62, 1.10),   // a near-silent gap
                (0.775, 0.95, 0.35, 0.31),   // the loudest passage, the peakiest
                (0.900, 0.42, 0.72, 0.55),   // settling
                (2.000, 0.13, 0.80, 0.90),   // the tail. Past 1 so nothing falls off the end.
            ]

            // Which passage plays in which section. Zero leaves the programme
            // exactly as written.
            let rotation = ((variant % programme.count) + programme.count) % programme.count

            var data: [WaveformData.Bucket] = []
            data.reserveCapacity(buckets * lanes)
            for index in 0..<buckets {
                let position = Double(index) / Double(max(buckets - 1, 1))
                let section = programme.firstIndex { position < $0.until } ?? programme.count - 1
                let passage = programme[(section + rotation) % programme.count]

                for lane in 0..<lanes {
                    let salt = 1 + lane * 7_919 + variant * 104_729
                    // A transient every `hit` seconds, decaying over the two or
                    // three buckets after it, with every fourth one louder so
                    // the pattern reads as a bar rather than as a metronome.
                    let period = max(2, Int((passage.hit * bucketsPerSecond).rounded()) + lane)
                    let attack = exp(-Double(index % period) / 2.4)
                        * ((index / period) % 4 == 0 ? 1.0 : 0.66)
                    // Two incommensurate drifts, so nothing in the picture
                    // repeats on a period the eye can find.
                    let drift = 0.82
                        + 0.11 * sin(position * 23.7 + Double(lane) * 2.1)
                        + 0.07 * sin(position * 61.3)
                    let grain = 0.66 + 0.42 * noise(index, salt)
                    let tilt = lane == 0 ? 1.0 : 0.78
                    // 0.42 between hits rather than 0.30, measured: the lower
                    // floor left the mean peak at 0.17 against a maximum of
                    // 0.88, which draws as isolated spikes over an empty lane
                    // rather than as a passage of music with transients in it.
                    let peak = min(passage.level * (0.42 + 0.58 * attack) * grain * drift * tilt, 0.98)
                    let trough = peak * (0.62 + 0.34 * noise(index, salt + 1))
                    // The crest factor moves: a transient is all peak and little
                    // energy, and the ratio recovers between them.
                    let ratio = min(
                        max(passage.crest * (1 - 0.42 * attack) * (0.86 + 0.28 * noise(index, salt + 2)), 0.06),
                        0.94
                    )
                    data.append(
                        WaveformData.Bucket(
                            minimum: Float(-trough),
                            maximum: Float(peak),
                            rms: Float(peak * ratio)
                        )
                    )
                }
            }
            return WaveformData(buckets: data, duration: duration)
        }

        /// Jobs and the finished-export card are shared state that outlives a
        /// scene, so every seed clears them. Without this the first frame after
        /// the job strip would carry a progress strip nobody asked for, and the
        /// window's negative control would move as a job's clock ticked.
        @MainActor func clearEditorJobs() {
            JobStripTuning.clearSnapshotSeeding(in: editor)
            // `clearSnapshotSeeding` leaves the two timings where a seeded strip
            // needs them — no quiet delay, no automatic retirement. Every scene
            // that is not about the strip wants the shipping numbers back, so a
            // frame of the window is a frame of the window the app really draws.
            JobStripTuning.quietDelay = 0.25
            JobStripTuning.settledLinger = 3
        }

        @MainActor func seedEditor(
            moves: [Move] = [],
            destination: Destination? = nil,
            analysis: AnalysisReport? = nil,
            selection: ClosedRange<TimeInterval>? = nil,
            playhead: TimeInterval = 0,
            selectedMove: Move.ID? = nil,
            source: EditorSource? = nil
        ) {
            clearEditorJobs()
            EditorRecents.shared.setForSnapshot(editorRecents)
            let resolved = source ?? editorSource
            var document = EditorDocument(source: resolved)
            document.moves = moves
            document.destination = destination
            document.analysis = analysis
            editor.setForSnapshot(
                document: document,
                waveform: editorWaveform(
                    duration: resolved.duration,
                    channels: resolved.channelCount
                )
            )
            // After `setForSnapshot`, which resets both of these.
            editor.selection = selection
            editor.playhead = playhead
            editor.selectedMoveID = selectedMove
            // `setForSnapshot` clears `lastError` today, and the two error frames
            // below rely on it not leaking into the thirty scenes after them.
            // Said here as well, so the two scenes do not depend on a line in
            // someone else's file staying where it is.
            editor.setErrorForSnapshot(nil)
        }

        /// The window with nothing open. Pinned first and closed second: `close()`
        /// alone would leave the store unpinned, and an unpinned store is one a
        /// later debounced re-render can reach.
        @MainActor func emptyEditor() {
            seedEditor()
            editor.close()
        }

        // MARK: - Seeding a timeline
        //
        // `seedEditor` above is deliberately untouched. It builds
        // `EditorDocument(source:)` — one track, one clip, the master list under
        // its old name — and it does **not** seed per-source pictures, so every
        // scene written before clips existed falls back to the store's mix
        // overview exactly as it did. Multitrack seeding is separate rather than
        // an extra argument on that call, because the two differ in what they
        // pin, not only in how many lanes they ask for.

        /// One drawing per source, so two lanes cut from different files cannot
        /// come out looking the same.
        ///
        /// **This is the whole reason a multitrack frame is evidence.** Without
        /// a seeded overview `EditorClipWaveforms` has nothing for the source
        /// and the view falls back to the store's mix, which is one picture — so
        /// four lanes of four different files draw four copies of the same
        /// waveform, at the right lengths, in the right places. That renders as
        /// a working multitrack timeline and is not one, and no amount of
        /// looking at the frame finds it.
        @MainActor func seedClipWaveforms(_ document: EditorDocument) {
            var seeded: [UUID: WaveformData] = [:]
            for (index, source) in document.sources.enumerated() {
                seeded[source.id] = editorWaveform(
                    duration: source.duration,
                    channels: source.channelCount,
                    variant: index
                )
            }
            EditorClipWaveforms.shared.setForSnapshot(seeded)
        }

        /// Pins a multitrack document, its per-source pictures, and the four
        /// published selections `setForSnapshot` resets on the way in.
        ///
        /// Returns every clip id in document order — track by track, clip by
        /// clip — because `hoveredClip:` and `edit:` are addressed by id and a
        /// scene has no other way to name one. The ids are fresh on every call,
        /// which is fine and is why nothing captures them: a scene that needs
        /// one reads it back off the store inside its `content` closure, which
        /// the harness builds *after* `prepare` has run.
        @discardableResult
        @MainActor func installDocument(
            _ document: EditorDocument,
            selection: ClosedRange<TimeInterval>? = nil,
            playhead: TimeInterval = 0,
            selectedClips: [Int] = [],
            selectedTrack: Int? = nil
        ) -> [Clip.ID] {
            clearEditorJobs()
            EditorRecents.shared.setForSnapshot(editorRecents)
            editor.setForSnapshot(
                document: document,
                // The mix, for the transport's readouts and for anything still
                // reading `store.waveform`. The lanes do not draw from it.
                waveform: editorWaveform(
                    duration: max(document.duration, 0.001),
                    channels: document.source.channelCount
                )
            )
            seedClipWaveforms(document)

            // After `setForSnapshot`, which resets all four of these.
            editor.selection = selection
            editor.playhead = playhead
            editor.selectedMoveID = nil
            editor.setErrorForSnapshot(nil)

            let ids = document.tracks.flatMap { $0.clips.map(\.id) }
            editor.selectedClipIDs = Set(
                selectedClips.compactMap { ids.indices.contains($0) ? ids[$0] : nil }
            )
            if let selectedTrack, document.tracks.indices.contains(selectedTrack) {
                editor.selectedTrackID = document.tracks[selectedTrack].id
            }
            return ids
        }

        /// A fade in and a fade out on every clip, one curve per lane.
        ///
        /// Long enough to see: at fit zoom on a 478pt pane, 22% of the first
        /// lane's 250s clip is about 105 points of slope. A fade of a couple of
        /// seconds is arithmetically present and visually absent, which makes
        /// for a frame that cannot answer the question it was rendered for.
        @MainActor func applyFades(_ document: inout EditorDocument) {
            let curves: [FadeCurve] = [.linear, .equalPower, .exponential]
            for track in document.tracks.indices {
                let curve = curves[track % curves.count]
                for clip in document.tracks[track].clips.indices {
                    let span = document.tracks[track].clips[clip].duration
                    document.tracks[track].clips[clip].fadeIn = span * 0.22
                    document.tracks[track].clips[clip].fadeOut = span * 0.30
                    document.tracks[track].clips[clip].fadeCurve = curve
                }
            }
        }

        /// The first lane's clip split in two, and the left half pasted onto the
        /// second lane further along.
        ///
        /// Split makes two clips sharing one source and abutting exactly, which
        /// is what makes the seam worth photographing: two name strips and one
        /// hairline where there used to be an unbroken drawing. The paste lands
        /// past the old end of the project on purpose — `EditorDocument.duration`
        /// is the end of the last clip, so the ruler has to grow.
        @MainActor func applySplit(_ document: inout EditorDocument) {
            guard let original = document.tracks.first?.clips.first else { return }
            let cut = original.sourceIn + original.duration * 0.45

            var left = original
            left.sourceOut = cut
            var right = original
            right.id = UUID()
            right.sourceIn = cut
            right.start = original.start + (cut - original.sourceIn)
            document.tracks[0].clips = [left, right]

            guard document.tracks.count > 1 else { return }
            var pasted = left
            pasted.id = UUID()
            pasted.start = original.end - left.duration * 0.6
            document.tracks[1].clips.append(pasted)
        }

        /// The timeline family's one seeding call.
        ///
        /// - Parameters:
        ///   - selectedClips: Indices into the returned list, so a scene can say
        ///     "the second clip" without holding an id it cannot know yet.
        @discardableResult
        @MainActor func seedTimeline(
            trackCount: Int = 1,
            layout: TimelineLayout = .staggered,
            selection: ClosedRange<TimeInterval>? = nil,
            playhead: TimeInterval = 0,
            selectedClips: [Int] = []
        ) -> [Clip.ID] {
            var document = EditorTrackFixtures.document(
                source: editorSource,
                trackCount: trackCount
            )
            switch layout {
            case .staggered: break
            case .fades: applyFades(&document)
            case .split: applySplit(&document)
            }
            return installDocument(
                document,
                selection: selection,
                playhead: playhead,
                selectedClips: selectedClips
            )
        }

        /// The track-header family's seeding call: one file, several lanes, each
        /// with its own name, level, pan and quieting.
        ///
        /// Carries the master Chain, the destination and the measurement,
        /// because these are frames of the whole window and a window with an
        /// empty sidebar is a window nobody ships.
        @discardableResult
        @MainActor func seedTracks(
            count: Int,
            names: [Int: String] = [:],
            gains: [Int: Double] = [:],
            pans: [Int: Double] = [:],
            muted: Set<Int> = [],
            soloed: Set<Int> = []
        ) -> [Clip.ID] {
            installDocument(
                EditorTrackFixtures.document(
                    source: editorSource,
                    trackCount: count,
                    names: names,
                    gains: gains,
                    pans: pans,
                    muted: muted,
                    soloed: soloed,
                    master: proposedMoves,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                ),
                playhead: 58
            )
        }

        /// The shape the add-a-track rule actually produces: several *sources*,
        /// one track each, all starting together and each named after the file
        /// it came from.
        ///
        /// `openSource` adds a track rather than replacing the document, so this
        /// — not `seedTracks` — is what a user gets by dropping a second file
        /// in. Its durations are staggered by the fixture, so the lanes end at
        /// different points and a document whose duration stopped being read
        /// shows it.
        @discardableResult
        @MainActor func seedLayered(
            _ names: [String],
            gains: [Int: Double] = [:],
            pans: [Int: Double] = [:],
            muted: Set<Int> = [],
            soloed: Set<Int> = []
        ) -> [Clip.ID] {
            installDocument(
                EditorTrackFixtures.layered(
                    from: editorSource,
                    names: names,
                    gains: gains,
                    pans: pans,
                    muted: muted,
                    soloed: soloed,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                ),
                playhead: 58
            )
        }

        /// Puts the shared timeline where the *view* would leave it, before the
        /// view exists.
        ///
        /// **Only a transition needs this, and it needs it structurally.**
        /// `EditorWaveformView` calls `EditorTimeline.adopt` from its `body`,
        /// and `adopt` refits the window whenever the source id it is handed is
        /// not the one it adopted last. The shared `prepare` clears that id, so
        /// the frame rendered after an `act` would refit and throw away whatever
        /// the act did to the window — which for a follow transition is the
        /// entire thing being tested. Adopting here, in `prepare`, with the same
        /// seed the view will pass, makes the view's own call a no-op and lets
        /// the act survive into the picture.
        @MainActor func primeTimeline(zoom: Double, width: CGFloat) {
            guard let document = editor.document else { return }
            EditorTimeline.shared.adopt(
                sourceID: document.sources.first?.id,
                duration: max(document.duration, 0.001),
                sampleRate: document.source.sampleRate,
                width: width,
                seed: EditorTimeline.Seed(zoomFraction: zoom, windowStart: nil, centreOn: nil)
            )
        }

        /// A clip id off the store, read at `content` time. See
        /// `installDocument` for why it is not captured from the seed.
        @MainActor func timelineClip(track: Int, index: Int = 0) -> Clip.ID? {
            guard let tracks = editor.document?.tracks, tracks.indices.contains(track) else {
                return nil
            }
            let clips = tracks[track].clips
            return clips.indices.contains(index) ? clips[index].id : nil
        }

        let editorSize = CGSize(width: 1000, height: 640)
        let chainPaneSize = CGSize(width: 320, height: 520)
        let sidebarPaneSize = CGSize(width: 320, height: 420)
        let waveformSize = CGSize(width: 660, height: 320)
        let eqCurveSize = CGSize(width: 480, height: 150)

        /// The timeline pane as a **multitrack** 1000×640 window really gives it,
        /// so lane heights in these frames are the lane heights a user gets.
        ///
        /// Width: 1000 less the 320pt sidebar, the 200pt header column and the
        /// two dividers between them. Height: `EditorTrackMetrics`' own
        /// arithmetic — the window less 130 for the title-bar inset, the header
        /// and the transport.
        ///
        /// The number that matters is the height, because it decides how many
        /// lanes fit. A lane never goes below `EditorTrackMetrics
        /// .minimumLaneHeight`, which is **86**, and `n` lanes need `92n + 26`
        /// points of pane. 510 holds five. Six is past it, on purpose, and the
        /// scene that shows that says so.
        let timelineSize = CGSize(width: 478, height: 510)

        /// The header column at its own width, which is fixed at 200.
        let headerColumnSize = CGSize(width: EditorTrackMetrics.columnWidth, height: 420)

        /// The column alone, on a ground, because it has none of its own — in
        /// the window it sits on the themed backdrop.
        @MainActor func headerColumn() -> AnyView {
            AnyView(
                TrackHeaderColumn(store: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        }

        @MainActor func editorWindow(dropTargeted: Bool = false) -> AnyView {
            AnyView(
                EditorRootView(
                    store: editor,
                    settings: settings,
                    dropTargeted: dropTargeted,
                    recents: EditorRecents.shared
                )
            )
        }

        /// A sidebar pane in the chrome the window gives it, so the frame is
        /// judged at the width and inset it really has.
        @MainActor func sidebarPane<Content: View>(
            _ title: String,
            @ViewBuilder _ content: () -> Content
        ) -> AnyView {
            AnyView(
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    SectionHeader(title: title)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                    content()
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            )
        }

        @MainActor func chainPane(expanded: Move.ID? = nil, dropTarget: Int? = nil) -> AnyView {
            sidebarPane("The Chain") {
                // `settings` because that is what the window passes it; the
                // equalizer inspector's preset list is absent without one, and a
                // frame of a pane composed differently from the window is a frame
                // of something the app never draws.
                ChainPanelView(
                    store: editor,
                    expandedMoveID: expanded,
                    settings: settings,
                    dropTargetIndex: dropTarget
                )
            }
        }

        @MainActor func destinationPane() -> AnyView {
            sidebarPane("Where’s it going?") { DestinationPicker(store: editor) }
        }

        @MainActor func analysisPane() -> AnyView {
            sidebarPane("What I found") { AnalysisSummaryView(store: editor) }
        }

        let glassNote = "The theme card puts its glass in a `.background`, not around its "
            + "content, so the words survive a layer capture and only the finish is missing. "
            + "Judge the finish from the -render frame; judge everything else here."

        // Two frames of the response canvas alone, and they are the only pair in
        // this set that exists for a machine rather than for a person.
        //
        // `scripts/verify-cutting-room.py` subtracts them. Everything that is the
        // same in both — the grid, the decade labels, the recessed ground —
        // cancels, and what is left is the drawn response of a single +9 dB
        // peaking band at 1 kHz. The script then asserts the topmost surviving
        // pixel sits where 1 kHz and +9 dB land on a log frequency axis and a
        // ±15 dB vertical one, which it works out itself. A curve drawn from
        // anything other than `BiquadMath`'s coefficients does not land there.
        //
        // The canvas is pinned to the top of the scene so the script knows where
        // the plot is without measuring it: `EQCurveView` is a fixed 108pt tall,
        // so it occupies exactly the first 108 points of a 150pt frame.
        @MainActor func eqCurveOnly(_ bands: [AutoEQFilter]) -> AnyView {
            AnyView(
                VStack(spacing: 0) {
                    EQCurveView(
                        bands: bands,
                        preampDB: 0,
                        showsHandles: false,
                        highlighted: nil,
                        onDragBand: nil
                    )
                    Spacer(minLength: 0)
                }
                .frame(width: eqCurveSize.width, height: eqCurveSize.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            )
        }
        let probeBand = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 9, q: 1.4)

        let jobStripSize = CGSize(width: 700, height: 380)

        // MARK: - The frames that carry an assertion
        //
        // Thirty-six frames, ordered ahead of the ones that are only there to be
        // looked at. A deliberate hedge, not a preference.
        //
        // Three runs in a row have died part-way through this block, and all of
        // this sat at the end of it — so every truncated run threw away exactly
        // the frames that assert something and kept the ones that merely show
        // something. The six transitions carry `mustDiffer`, which is the
        // dead-control check; the ten negative controls are what makes those
        // six mean anything; and six frames here are read as pixels by
        // `scripts/verify-cutting-room.py`, which cannot run its rendered tier
        // at all without them. As of this ordering they are the first seven
        // entries in the block.
        //
        // A judgeable frame that is missing is a gap someone notices. A missing
        // assertion is a gap that reports itself as nothing being wrong.

        // MARK: Melo Edit transitions
        //
        // Four wires, each of which would compile, render and look plausible if
        // it were cut. All four act through the store rather than by pressing the
        // control, so `bindingCaveat` applies to every one of them: what the
        // button is bound to stays unverified, what the store's method produces
        // does not.

        // The pair the verify script reads. Same source, same destination, same
        // layout — only the measurement differs. If the picker stops asking
        // `MoveProposer` what to do, these two frames become identical.
        scenes.append(
            scene(
                "cutting-room-destination-quiet", sidebarPaneSize, .dark,
                note: "Podcast, on a file measured at −22.4 LUFS. The caption under the button "
                    + "is a count of moves the proposer produced from THIS measurement.",
                prepare: {
                    seedEditor(
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport
                    )
                }
            ) { destinationPane() }
        )
        scenes.append(
            scene(
                "cutting-room-destination-compliant", sidebarPaneSize, .dark,
                note: "The same pane, the same destination, on a file already inside every one "
                    + "of Podcast's published tolerances. It must say so and disable the button. "
                    + "Compared against cutting-room-destination-quiet by "
                    + "scripts/verify-cutting-room.py: identical frames mean the button stopped "
                    + "reading the measurement.",
                prepare: {
                    seedEditor(
                        destination: DestinationCatalogue.podcast,
                        analysis: compliantReport
                    )
                }
            ) { destinationPane() }
        )

        scenes.append(
            scene("cutting-room-eqcurve-flat", eqCurveSize, .light,
                  note: "Flat reference for the probe below. The canvas is the first 108pt.",
                  prepare: { seedEditor() }) {
                eqCurveOnly(EQResponseCurve.flatGraphicBands)
            }
        )
        scenes.append(
            scene("cutting-room-eqcurve-probe", eqCurveSize, .light,
                  note: "One peaking band: 1 kHz, +9 dB, Q 1.4, no preamp. Subtracted from "
                      + "cutting-room-eqcurve-flat, the highest remaining pixel is the peak of "
                      + "the drawn response and must land at 1 kHz and +9 dB.",
                  prepare: { seedEditor() }) {
                eqCurveOnly([probeBand])
            }
        )

        scenes += SnapshotHarness.transition(
            name: "cutting-room-destination-reacts",
            size: sidebarPaneSize,
            colorScheme: .dark,
            note: "BEFORE is Podcast on a file measured at −22.4 LUFS; AFTER is the same pane, "
                + "same destination, after the measurement is replaced with one already inside "
                + "every Podcast tolerance. The button and its caption are the only things that "
                + "may move, and they must. A destination that had quietly become a preset "
                + "would render these two identically. " + SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.dark)
                seedEditor(
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                )
            },
            act: {
                seedEditor(
                    destination: DestinationCatalogue.podcast,
                    analysis: compliantReport
                )
            }
        ) { destinationPane() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-chain-fills",
            size: chainPaneSize,
            colorScheme: .dark,
            note: "The proposal landing on the Chain as one edit. BEFORE is the empty state, "
                + "AFTER is \(proposedMoves.count) rows. " + SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.dark)
                seedEditor(
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                )
            },
            act: { editor.replaceMoves(proposedMoves) }
        ) { chainPane() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-chain-disables",
            size: chainPaneSize,
            colorScheme: .dark,
            note: "The second row switched off — above the fold on purpose, since this pane "
                + "holds about four of nine rows. It must stay on the list and dim: a move that "
                + "vanished when it was switched off would make A/B listening impossible, which "
                + "is the whole reason the Chain is non-destructive. Its switch and chevron stay "
                + "full strength, because the switch is what you press to bring it back. "
                + SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.dark)
                seedEditor(
                    moves: proposedMoves,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                )
            },
            act: {
                if let moveToDisable {
                    editor.setEnabled(false, for: moveToDisable.id)
                }
            }
        ) { chainPane() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-waveform-selects",
            size: waveformSize,
            colorScheme: .dark,
            note: "The drawing following `store.selection`. Identical frames would mean the "
                + "canvas is drawing a selection it is not reading — and the first run of this "
                + "pair measured exactly 0.0000%, which turned out not to be the canvas at all: "
                + "`EditorTimeline.duration` was still its default of 1, so the window was one "
                + "second wide, the ruler read 0:00.0–0:00.9, and a selection at 42–96s was off "
                + "screen in both frames. A shipping bug — a 4:10 file opened showing one second "
                + "of itself. " + SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.dark)
                seedEditor(playhead: 58)
            },
            act: { editor.selection = 42...96 }
        ) { AnyView(EditorWaveformView(store: editor)) }

        // The one wire in the multitrack build that cannot be seen in any still
        // frame, and the only evidence that follow works at all.
        //
        // Both frames hold the playhead at the same 240s, off the right-hand
        // edge of a window that starts at zero. The act does what playback does
        // — turns following on and asks the timeline to reveal where the
        // playhead now is — and nothing else. So the only thing that can differ
        // is the window paging, and **identical frames mean `page(toReveal:)`
        // never fired**. Every other transition in this file survives its
        // subject being dead by moving something else; this one does not.
        //
        // `primeTimeline` is load-bearing here rather than decorative: without
        // it the after frame's own `adopt` refits the window and erases the page.
        scenes += SnapshotHarness.transition(
            name: "timeline-follow-pages",
            size: timelineSize,
            colorScheme: .dark,
            note: "Follow while playing. Three tracks, zoomed to 0.5 so the whole project is "
                + "NOT on screen — at fit-to-window there is nothing to follow and `page` "
                + "returns false by design. The playhead is at 4:00 in BOTH frames and is off "
                + "the right edge in the before; the act calls `beginFollowing()` and "
                + "`reveal(240)`, which is what `EditorWaveformView`'s `.onChange(of: "
                + "store.playhead)` calls on every tick of playback. The window must jump "
                + "forward and land the playhead a tenth in from the left. Identical frames "
                + "mean follow is dead. What is UNVERIFIED: that `EditorPlayback` advances "
                + "`store.playhead` at all, and that the `.onChange` is still attached — a "
                + "scene cannot run the audio clock. " + SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.dark)
                seedTimeline(trackCount: 3, playhead: 240)
                primeTimeline(zoom: 0.5, width: timelineSize.width)
            },
            act: {
                EditorTimeline.shared.beginFollowing()
                EditorTimeline.shared.reveal(editor.playhead)
            }
        ) { AnyView(EditorWaveformView(store: editor, zoom: 0.5)) }

        // The governing decision, made falsifiable. One track and the window is
        // the window this app shipped with: no header column, no mixer. Add a
        // track and the column appears in place.
        //
        // The act is `editor.addTrack()` — the same call, on the same store,
        // that both the column's "Add an Empty Track" strip and the menu item
        // make. Identical frames mean `EditorDocument.isMultitrack` never
        // flipped `timelineArea` over to `multitrackTimeline`, which is a
        // one-line branch that compiles perfectly well pointing at the wrong
        // arm.
        scenes += SnapshotHarness.transition(
            name: "cutting-room-adds-track",
            size: editorSize,
            colorScheme: .dark,
            note: "BEFORE is the single-track window — one lane, full width between two "
                + "dividers, no header column, exactly what this app shipped with. AFTER is "
                + "the same window one `addTrack()` later: a 200pt header column appears on "
                + "the left, the lanes divide, and the new lane is empty because an added "
                + "track has no audio in it yet. Identical frames mean the layout never "
                + "noticed. " + SnapshotHarness.bindingCaveat,
            prepare: {
                applyAppearance(.dark)
                seedEditor(
                    moves: proposedMoves,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport,
                    playhead: 58
                )
            },
            act: { _ = editor.addTrack() }
        ) { editorWindow() }

        // MARK: Melo Edit negative controls
        //
        // One per new family, all on the harness's default 1% ceiling.
        //
        // That number was reasoned before it was measured — nothing in
        // Melo Edit animates at rest, the themed backdrop draws nothing into
        // a layer capture, the `.systemAccent` visitor is pinned out of frame for
        // the one ImageRenderer control, and the job strip's indeterminate sweep
        // is a 3pt capsule over 28% of a 668pt row and so bounded at 0.8% of a
        // 700×380 frame.
        //
        // **Measured on the first complete run: every one of these read
        // 0.0000%.** Not "under the ceiling" — zero. So the whole 1% is margin,
        // including for the job strip, whose sweep evidently lands on the same
        // phase in both captures because both frames are seeded the same way in
        // the same code path.
        //
        // The transitions these calibrate, from the same run: destination-reacts
        // 7.9055%, chain-fills 11.5889%, chain-disables 1.8813%, all against the
        // 1% floor. `chain-disables` is the thin one and it is thin for a correct
        // reason: dimming one row of nine changes only the *inked* pixels inside
        // it, and text is mostly background. It is also the pair
        // `verify-cutting-room.py` reads for the dimming assertion, so anything
        // that changes how much of a row moves shows up there first — which is
        // the behaviour wanted, not a margin to pad.
        //
        // If one of these ever goes red the number in `_transitions.log` is the
        // measurement and the ceiling is set from it. It is not raised to make a
        // run green.

        scenes += SnapshotHarness.negativeControl(
            name: "control-cutting-room",
            size: editorSize,
            colorScheme: .dark,
            note: "Melo Edit window family, layer capture.",
            prepare: {
                applyAppearance(.dark)
                seedEditor(
                    moves: proposedMoves,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                )
            }
        ) { editorWindow() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-cutting-room-render",
            size: editorSize,
            colorScheme: .dark,
            capture: .imageRenderer,
            note: "Melo Edit window family, ImageRenderer. The clock is forced to t=40, "
                + "which is outside the `.systemAccent` visitor's 4…10.2s appearance window, so "
                + "the one animated element in this capture path is off screen by construction.",
            prepare: {
                applyAppearance(.dark)
                MeloEasterEggClock.forcedTime = 40
                seedEditor(
                    moves: proposedMoves,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                )
            }
        ) { editorWindow() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-chain-panel",
            size: chainPaneSize,
            colorScheme: .dark,
            note: "Chain panel family.",
            prepare: {
                applyAppearance(.dark)
                MeloEasterEggClock.forcedTime = nil
                seedEditor(
                    moves: proposedMoves,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                )
            }
        ) { chainPane() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-destination",
            size: sidebarPaneSize,
            colorScheme: .dark,
            note: "Destination picker family. This is the control for the assertion that "
                + "cutting-room-destination-quiet and -compliant must differ.",
            prepare: {
                applyAppearance(.dark)
                seedEditor(
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                )
            }
        ) { destinationPane() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-waveform",
            size: waveformSize,
            colorScheme: .dark,
            note: "Waveform family.",
            prepare: {
                applyAppearance(.dark)
                seedEditor(selection: 42...96, playhead: 58)
            }
        ) { AnyView(EditorWaveformView(store: editor)) }

        scenes += SnapshotHarness.negativeControl(
            name: "control-eq-curve",
            size: eqCurveSize,
            colorScheme: .light,
            note: "EQ response family. The pixel assertion in verify-cutting-room.py subtracts "
                + "two frames from this family, so a family that moved on its own would make "
                + "that subtraction meaningless.",
            prepare: {
                applyAppearance(.light)
                seedEditor()
            }
        ) { eqCurveOnly([probeBand]) }

        scenes += SnapshotHarness.negativeControl(
            name: "control-editor-jobs",
            size: jobStripSize,
            colorScheme: .dark,
            note: "Job strip family, including the indeterminate sweep — the noisiest surface "
                + "in Melo Edit. Seeded identically in both frames, so the elapsed "
                + "readouts are anchored to each frame's own prepare rather than drifting apart.",
            prepare: {
                applyAppearance(.dark)
                seedEditor(
                    moves: proposedMoves,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport
                )
                JobStripTuning.seedSnapshotJobs(in: editor)
            }
        ) { AnyView(JobProgressStrip(store: editor)) }

        // Three more, one per family the multitrack build adds. Nothing in any
        // of them animates at rest — the lanes are a `Canvas`, the headers are a
        // fader, a pan slider and two buttons, and no scene here seeds a
        // playing transport — so all three go on the harness's default 1%
        // ceiling like the seven above.
        //
        // **These have never been measured.** The seven above read 0.0000% on
        // their first complete run and the reasoning for these is the same
        // reasoning, which is not the same thing as a number. If one comes back
        // red, the figure in `_transitions.log` is the measurement and the
        // ceiling is set from it. It is not raised to make a run green.

        scenes += SnapshotHarness.negativeControl(
            name: "control-timeline",
            size: timelineSize,
            colorScheme: .dark,
            note: "Multitrack timeline family. Seeded, primed and drawn EXACTLY as "
                + "timeline-follow-pages is — three lanes, zoom 0.5, playhead off the right "
                + "edge — with the act removed. That transition's whole assertion is that two "
                + "frames of this pane are identical unless the window pages, so its control "
                + "has to be the same pane in the same state and not merely the same family.",
            prepare: {
                applyAppearance(.dark)
                seedTimeline(trackCount: 3, playhead: 240)
                primeTimeline(zoom: 0.5, width: timelineSize.width)
            }
        ) { AnyView(EditorWaveformView(store: editor, zoom: 0.5)) }

        scenes += SnapshotHarness.negativeControl(
            name: "control-track-headers",
            size: headerColumnSize,
            colorScheme: .dark,
            note: "Track header column family: four headers with names, gains, pans, one "
                + "muted and one soloed.",
            prepare: {
                applyAppearance(.dark)
                seedTracks(
                    count: 4,
                    names: [0: "Host", 1: "Guest", 2: "Intro bed", 3: "Room tone"],
                    gains: [1: -3.5, 2: -9, 3: -18],
                    pans: [1: 0.24, 2: -0.6],
                    muted: [3],
                    soloed: [1]
                )
            }
        ) { headerColumn() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-cutting-room-multitrack",
            size: editorSize,
            colorScheme: .dark,
            note: "The whole window with three tracks in it. Separate from control-cutting-room "
                + "because that one is seeded single-track and therefore draws no header "
                + "column at all — it is the control for cutting-room-adds-track's BEFORE "
                + "frame, and this is the control for its AFTER.",
            prepare: {
                applyAppearance(.dark)
                seedTracks(count: 3)
            }
        ) { editorWindow() }

        // MARK: The whole window

        let windowNote = "The real 1000×640 the window opens at. The themed backdrop behind it "
            + "is an NSVisualEffectView plus a Canvas and draws nothing into a layer capture — "
            + "the flat ground is the harness, not the design."

        /// **`cutting-room-loaded-dark` and `-light` have moved, and it is
        /// expected.** Written into their notes rather than left for the next
        /// reader to litigate, because a diff against the previous run's frames
        /// is the first thing anyone does and this one is not a regression.
        ///
        /// Four changes, all of them chrome around the drawing:
        ///
        /// 1. The horizontal scroll strip now costs **10pt unconditionally**,
        ///    reserved whether or not it is drawn — a strip that appeared only
        ///    when zoomed in changed every lane's height on a zoom and sheared
        ///    the lanes against a header column that did not move.
        /// 2. A clip reserves a **14pt name strip** across its top. That band is
        ///    the move handle, which exists so that dragging the *body* can go on
        ///    meaning "select a range of time".
        /// 3. The clip body now has a **4.5%-alpha wash and a hairline border**,
        ///    so a clip has an extent you can see. (Not the resting fill
        ///    `CLAUDE.md` forbids: that rule is about popup rows blending with a
        ///    material, and a clip with no body is not a clip.)
        /// 4. The **master cut flags moved to the bottom of the lanes**. They
        ///    used to sit under the ruler, which is now where a clip's name is.
        ///
        /// The waveform inside the clip is unchanged.
        let loadedMovedNote = " EXPECTED MOVEMENT vs the previous run, all chrome: the scroll "
            + "strip now costs 10pt unconditionally; a clip reserves a 14pt name strip for the "
            + "move handle; the clip body gained a 4.5%-alpha wash and a hairline border; and "
            + "the master cut flags moved from under the ruler to the bottom of the lanes, "
            + "because the ruler's old spot is now where a clip's name is. Content INSIDE the "
            + "waveform is unchanged — a diff here is not a regression."

        scenes.append(
            scene(
                "cutting-room-empty-dark", editorSize, .dark,
                note: windowNote + " Recents are a fixture, not this Mac's history: one file, "
                    + "one link extraction and one recording, so the three leading glyphs can "
                    + "be told apart against the three entry cards below them.",
                prepare: { emptyEditor() }
            ) { editorWindow() }
        )
        scenes.append(
            scene(
                "cutting-room-empty-light", editorSize, .light,
                note: windowNote,
                prepare: { emptyEditor() }
            ) { editorWindow() }
        )
        scenes.append(
            scene(
                "cutting-room-loaded-dark", editorSize, .dark,
                note: windowNote + " Podcast chosen, the file measured, the full proposal on "
                    + "the Chain — the state the feature exists to produce." + loadedMovedNote,
                prepare: {
                    seedEditor(
                        moves: proposedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport,
                        selection: 42...96,
                        playhead: 58
                    )
                }
            ) { editorWindow() }
        )
        scenes.append(
            scene(
                "cutting-room-loaded-light", editorSize, .light,
                note: windowNote + loadedMovedNote,
                prepare: {
                    seedEditor(
                        moves: proposedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport,
                        selection: 42...96,
                        playhead: 58
                    )
                }
            ) { editorWindow() }
        )
        // The drop affordance exists only while a drag is over the window and the
        // harness cannot drag, so `dropTargeted:` is the only way this is ever
        // seen. It is also the one piece of feedback that decides whether dropping
        // a file feels invited or merely tolerated.
        scenes.append(
            scene(
                "cutting-room-drop-target", editorSize, .dark,
                note: windowNote + " Seeded drop state.",
                prepare: { emptyEditor() }
            ) { editorWindow(dropTargeted: true) }
        )
        // The sentence a user reads at the worst moment they will have with this
        // feature: they dropped something in and it did not open.
        //
        // The copy is `AudioFileIO.Failure`'s own, read out of the shipped enum
        // rather than transcribed, so a change to what Melo says shows up in the
        // frame instead of in a stale fixture. Two widths, because the banner is
        // the one surface here whose whole job is a sentence, and a sentence that
        // is fine at 1000pt and clipped at the 820pt minimum is a sentence nobody
        // has read at the size that matters.
        //
        // `setErrorForSnapshot` deliberately does not pin, so it goes after the
        // seed rather than instead of it.
        let unreadableFailure = AudioFileIO.Failure
            .unreadable(URL(fileURLWithPath: "/Users/you/Downloads/piano-loop.aif"))
        let tooLongFailure = AudioFileIO.Failure.tooLong(9_678)

        scenes.append(
            scene(
                "cutting-room-error-empty", editorSize, .dark,
                note: windowNote + " A file that would not open, over the empty state — the "
                    + "state a bad drop actually lands in. The banner shows `errorDescription` "
                    + "only; `AudioFileIO.Failure` also writes a `recoverySuggestion` and "
                    + "nothing on this surface reads it.",
                prepare: {
                    emptyEditor()
                    editor.setErrorForSnapshot(
                        unreadableFailure.errorDescription ?? "Melo couldn’t read that."
                    )
                }
            ) { editorWindow() }
        )
        scenes.append(
            scene(
                "cutting-room-error-narrow", CGSize(width: 820, height: 520), .light,
                note: "The window at its 820×520 minimum, carrying the longest failure sentence "
                    + "in the feature over a loaded document. This is where the banner, the "
                    + "header's name and format chip, and the sidebar's three sections are all "
                    + "competing for the same room.",
                prepare: {
                    seedEditor(
                        moves: proposedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport
                    )
                    editor.setErrorForSnapshot(
                        tooLongFailure.errorDescription ?? "That file is too long."
                    )
                }
            ) { editorWindow() }
        )

        // The one path that draws the themed backdrop and the glass. It also
        // cannot draw `NSViewRepresentable`, and the backdrop contains one, so the
        // material behind everything comes back as a placeholder.
        scenes.append(
            scene(
                "cutting-room-loaded-render", editorSize, .dark,
                capture: .imageRenderer,
                note: "ImageRenderer. The themed gradient and any easter-egg visitor are real "
                    + "here and invisible in every layer capture; the `.popover` material inside "
                    + "MeloThemeBackdrop is an NSViewRepresentable and cannot be drawn on this "
                    + "path at all. Judge the theme, not the material.",
                prepare: {
                    seedEditor(
                        moves: proposedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport
                    )
                }
            ) { editorWindow() }
        )

        // MARK: The Chain

        scenes.append(
            scene(
                "cutting-room-chain-empty-dark", chainPaneSize, .dark,
                note: "No destination chosen, so the empty state points at the picker.",
                prepare: { seedEditor() }
            ) { chainPane() }
        )
        scenes.append(
            scene(
                "cutting-room-chain-empty-light", chainPaneSize, .light,
                prepare: { seedEditor() }
            ) { chainPane() }
        )
        scenes.append(
            scene(
                "cutting-room-chain-proposed-dark", chainPaneSize, .dark,
                note: "The Chain `MoveProposer` really produced for this measurement. Every row "
                    + "must carry a sentence naming the number that caused it; a row with no "
                    + "third line is a move nothing measured.",
                prepare: {
                    seedEditor(
                        moves: proposedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport
                    )
                }
            ) { chainPane() }
        )
        scenes.append(
            scene(
                "cutting-room-chain-proposed-light", chainPaneSize, .light,
                prepare: {
                    seedEditor(
                        moves: proposedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport
                    )
                }
            ) { chainPane() }
        )
        scenes.append(
            scene(
                "cutting-room-chain-mixed", chainPaneSize, .dark,
                note: "The proposal plus one hand-added Gain at row 3, which has no rationale, "
                    + "and row 2 switched off rather than deleted. Both are inside the four rows "
                    + "this pane can hold. The count of disabled moves sits in the control strip.",
                prepare: {
                    seedEditor(
                        moves: mixedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport,
                        selectedMove: mixedMoves.count > 2 ? mixedMoves[2].id : nil
                    )
                }
            ) { chainPane() }
        )
        scenes.append(
            scene(
                "cutting-room-chain-drop", chainPaneSize, .dark,
                note: "Mid-reorder, with the insertion line at index 3. Reachable only by "
                    + "dragging, which the harness cannot do.",
                prepare: {
                    seedEditor(
                        moves: proposedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport
                    )
                }
            ) { chainPane(dropTarget: 3) }
        )

        // One frame per inspector. A disclosure that discloses the wrong numbers
        // is invisible from outside, and until now nothing had opened one.
        let inspectorNames = ["trim", "gain", "normalize", "fade", "equalizer"]
        for (offset, name) in inspectorNames.enumerated() where offset < inspectorMoves.count {
            let move = inspectorMoves[offset]
            scenes.append(
                scene(
                    "cutting-room-inspector-\(name)", chainPaneSize, .dark,
                    note: "Row \(offset + 1) disclosed. The inspector is reached through the "
                        + "row's own chevron, so this frame is evidence the row opens onto it "
                        + "rather than evidence that MoveInspector renders.",
                    prepare: {
                        seedEditor(
                            moves: inspectorMoves,
                            destination: DestinationCatalogue.podcast,
                            analysis: quietReport,
                            selectedMove: move.id
                        )
                    }
                ) { chainPane(expanded: move.id) }
            )
        }

        // MARK: The sidebar panes on their own

        scenes.append(
            scene(
                "cutting-room-destination-unchosen", sidebarPaneSize, .dark,
                note: "Nothing picked. The button must say what it needs rather than being "
                    + "enabled and doing nothing.",
                prepare: { seedEditor(analysis: quietReport) }
            ) { destinationPane() }
        )
        scenes.append(
            scene(
                "cutting-room-destination-ringtone", sidebarPaneSize, .light,
                note: "A chosen row opens to show the published numbers behind it. Ringtone's "
                    + "−12 LUFS is Melo's own choice and the catalogue says so in a comment; the "
                    + "row says the number either way.",
                prepare: {
                    seedEditor(
                        destination: DestinationCatalogue.ringtone,
                        analysis: quietReport
                    )
                }
            ) { destinationPane() }
        )

        scenes.append(
            scene(
                "cutting-room-analysis-quiet", sidebarPaneSize, .dark,
                note: "Every measured fact with the sentence that says what it is.",
                prepare: {
                    seedEditor(
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport
                    )
                }
            ) { analysisPane() }
        )
        scenes.append(
            scene(
                "cutting-room-analysis-compliant", sidebarPaneSize, .light,
                note: "Already at the target. The verdict line has to say that in fewer words "
                    + "than it takes to say it is not.",
                prepare: {
                    seedEditor(
                        destination: DestinationCatalogue.podcast,
                        analysis: compliantReport
                    )
                }
            ) { analysisPane() }
        )
        scenes.append(
            scene(
                "cutting-room-analysis-nodestination", sidebarPaneSize, .dark,
                note: "Measured, but nowhere to compare it against.",
                prepare: { seedEditor(analysis: quietReport) }
            ) { analysisPane() }
        )
        scenes.append(
            scene(
                "cutting-room-analysis-measuring", sidebarPaneSize, .dark,
                note: "Before the measurement lands. One line, not a skeleton.",
                prepare: { seedEditor(destination: DestinationCatalogue.podcast) }
            ) { analysisPane() }
        )

        // MARK: The waveform and the transport

        let waveformNote = "A synthetic two-lane fixture, not a decoded file — judge the "
            + "drawing, the ruler, the selection chrome and the playhead, not the shape of the "
            + "sound. The two lanes carry deliberately different content, so two identical "
            + "lanes here would mean a channel is not being read from its own bucket."

        scenes.append(
            scene(
                "cutting-room-waveform-fit", waveformSize, .dark, note: waveformNote,
                prepare: { seedEditor(playhead: 58) }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )
        scenes.append(
            scene(
                "cutting-room-waveform-selection", waveformSize, .dark,
                note: waveformNote + " A selection with both handles in view.",
                prepare: { seedEditor(selection: 42...96, playhead: 58) }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )
        scenes.append(
            scene(
                "cutting-room-waveform-zoomed", waveformSize, .light,
                note: waveformNote + " Zoomed in with the scroll bar showing, which only appears "
                    + "once the view is no longer fit to the window.",
                prepare: { seedEditor(selection: 42...96, playhead: 58) }
            ) {
                AnyView(EditorWaveformView(store: editor, zoom: 0.62, windowStart: 38))
            }
        )
        scenes.append(
            scene(
                "cutting-room-waveform-handle", waveformSize, .dark,
                note: waveformNote + " The upper selection handle in its grabbed state, which is "
                    + "otherwise reachable only by putting a pointer on it. No `windowStart`: "
                    + "with one, the seeded window did not contain the seeded selection and the "
                    + "frame had no chrome in it at all. `applySeeds` centres the seeded edge "
                    + "when the window is left to it, so the handle frames itself.",
                prepare: { seedEditor(selection: 42...96, playhead: 58) }
            ) {
                AnyView(
                    EditorWaveformView(
                        store: editor,
                        zoom: 0.4,
                        hoveredEdge: .upper
                    )
                )
            }
        )

        // MARK: The four waveform styles
        //
        // One frame each at fit zoom, all four seeded identically, so they are a
        // comparison rather than four separate pictures. The style is passed to
        // the view rather than written to `UserDefaults`, so nothing here
        // changes what the frames after it render.
        //
        // Then the two that aggregate. `.bars` and `.pixel` each combine several
        // columns into one shape, and the invariant they have to keep is the one
        // `EditorWaveformView` states next to `drawsCore`: when the buckets are
        // coarser than the pixels, the RMS core is not drawn at all, because one
        // bucket stretched across forty columns paints as a solid slab of
        // constant level that is not a measurement of anything. In those two
        // frames the bars and the blocks must be **outlines only** — one weight
        // of colour, no denser core inside them. A second, stronger shape inside
        // the envelope there is the defect.

        let styleNote = waveformNote + " Style comparison: the same fixture, the same "
            + "selection, the same playhead, drawn four ways."

        for style in EditorWaveformStyle.allCases {
            scenes.append(
                scene(
                    "cutting-room-waveform-style-\(style.rawValue)", waveformSize, .dark,
                    note: styleNote + " This one is \(style.label).",
                    prepare: { seedEditor(selection: 42...96, playhead: 58) }
                ) {
                    AnyView(EditorWaveformView(store: editor, style: style))
                }
            )
        }

        for style in [EditorWaveformStyle.bars, .pixel] {
            scenes.append(
                scene(
                    "cutting-room-waveform-coarse-\(style.rawValue)", waveformSize, .dark,
                    note: "Zoomed to about three seconds, where the fixture has far fewer "
                        + "buckets than the surface has pixels. \(style.label) has to drop its "
                        + "RMS core here and draw the peak extent alone. A denser second shape "
                        + "inside the envelope in this frame is one number stretched across "
                        + "forty columns and drawn as if it were measured.",
                    prepare: { seedEditor(playhead: 31) }
                ) {
                    AnyView(
                        EditorWaveformView(
                            store: editor,
                            zoom: 0.27,
                            windowStart: 30,
                            style: style
                        )
                    )
                }
            )
        }

        // The row that chooses between them, exactly as `EverydayTab` builds it.
        // Its four thumbnails are drawn by `EditorWaveformLanesCanvas` — the
        // same routine the pane above uses — so a thumbnail that does not match
        // its style's frame in this same run means the picker is lying about
        // what it selects.
        let stylePickerSize = CGSize(width: 540, height: 130)
        @MainActor func stylePickerRow(_ selected: EditorWaveformStyle) -> AnyView {
            AnyView(
                SettingsSection("Melo Edit") {
                    SettingsRow("Waveform", description: "How the sound is drawn.") {
                        EditorWaveformStylePicker(selection: .constant(selected))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            )
        }

        scenes.append(
            scene(
                "cutting-room-waveform-style-picker", stylePickerSize, .dark,
                note: "Settings › Everyday › Melo Edit. Bars selected, which is the default.",
                prepare: { seedEditor() }
            ) { stylePickerRow(.bars) }
        )
        scenes.append(
            scene(
                "cutting-room-waveform-style-picker-light", stylePickerSize, .light,
                note: "The same row in light, with Pixel chosen. The thumbnails use the "
                    + "waveform's own dynamic palette, so both appearances need looking at.",
                prepare: { seedEditor() }
            ) { stylePickerRow(.pixel) }
        )

        let transportSize = CGSize(width: 700, height: 72)
        @MainActor func transportStrip(
            playing: Bool? = nil,
            looping: Bool? = nil,
            bypassed: Bool? = nil,
            preparing: Bool? = nil
        ) -> AnyView {
            AnyView(
                VStack(spacing: 0) {
                    Divider()
                    EditorTransportBar(
                        store: editor,
                        playing: playing,
                        looping: looping,
                        bypassed: bypassed,
                        preparing: preparing
                    )
                    Divider()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            )
        }

        let transportNote = "Playback lives behind an AVAudioEngine the harness has no device "
            + "for, so the active states are seeded. What the buttons are wired to is UNVERIFIED "
            + "from this frame; what they look like when they are on is not."
        scenes.append(
            scene("cutting-room-transport-idle", transportSize, .dark, note: transportNote,
                  prepare: { seedEditor(playhead: 58) }) { transportStrip() }
        )
        scenes.append(
            scene("cutting-room-transport-playing", transportSize, .dark, note: transportNote,
                  prepare: { seedEditor(selection: 42...96, playhead: 58) }) {
                transportStrip(playing: true, looping: true)
            }
        )
        scenes.append(
            scene("cutting-room-transport-bypassed", transportSize, .light, note: transportNote,
                  prepare: { seedEditor(playhead: 58) }) {
                transportStrip(playing: true, bypassed: true)
            }
        )
        scenes.append(
            scene("cutting-room-transport-preparing", transportSize, .dark, note: transportNote,
                  prepare: { seedEditor(playhead: 58) }) {
                transportStrip(preparing: true)
            }
        )

        // MARK: The equalizer, at both depths

        @MainActor func eqPanel(depth: EditorEQPanel.Depth) -> AnyView {
            AnyView(
                EditorEQPanel(
                    bands: inspectorBands,
                    preampDB: -3,
                    settings: settings,
                    depth: depth,
                    onChange: { _, _ in }
                )
                .padding(DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            )
        }
        let eqPanelSize = CGSize(width: 420, height: 580)
        scenes.append(
            scene("cutting-room-eq-graphic", eqPanelSize, .dark,
                  note: "Ten bands — the panel that already ships in the popup, writing "
                      + "AutoEQFilters at Melo's own frequencies. The preamp readout is derived "
                      + "from the curve, not typed.",
                  prepare: { seedEditor() }) { eqPanel(depth: .graphic) }
        )
        scenes.append(
            scene("cutting-room-eq-parametric", eqPanelSize, .dark,
                  note: "The same array with frequency and Q unlocked, and grabbable handles on "
                      + "the curve. Switching depth must not change the sound.",
                  prepare: { seedEditor() }) { eqPanel(depth: .parametric) }
        )
        scenes.append(
            scene("cutting-room-eq-graphic-light", eqPanelSize, .light,
                  prepare: { seedEditor() }) { eqPanel(depth: .graphic) }
        )


        // MARK: The theme, the sheets and the strip

        scenes.append(
            scene("cutting-room-theme-welcome-dark", CGSize(width: 700, height: 340), .dark,
                  note: glassNote,
                  prepare: { seedEditor() }) {
                AnyView(
                    MeloThemeWelcomeCard(
                        themeDuration: MeloThemeRemix.measuredDuration,
                        onStart: { _ in },
                        onDismiss: {}
                    )
                    .padding(DesignTokens.Spacing.xl)
                    .frame(width: 700, alignment: .top)
                )
            }
        )
        scenes.append(
            scene("cutting-room-theme-welcome-light", CGSize(width: 700, height: 340), .light,
                  note: glassNote,
                  prepare: { seedEditor() }) {
                AnyView(
                    MeloThemeWelcomeCard(
                        themeDuration: MeloThemeRemix.measuredDuration,
                        onStart: { _ in },
                        onDismiss: {}
                    )
                    .padding(DesignTokens.Spacing.xl)
                    .frame(width: 700, alignment: .top)
                )
            }
        )
        scenes.append(
            scene("cutting-room-theme-welcome-render", CGSize(width: 700, height: 340), .dark,
                  capture: .imageRenderer,
                  note: "ImageRenderer, so the glass surface behind the card has a chance of "
                      + "appearing at all. This is the only frame in which the card's finish is "
                      + "judgeable; every other one shows its content on a flat ground.",
                  prepare: { seedEditor() }) {
                AnyView(
                    MeloThemeWelcomeCard(
                        themeDuration: MeloThemeRemix.measuredDuration,
                        onStart: { _ in },
                        onDismiss: {}
                    )
                    .padding(DesignTokens.Spacing.xl)
                    .frame(width: 700, alignment: .top)
                )
            }
        )

        scenes.append(
            scene("cutting-room-export-aac", CGSize(width: 560, height: 660), .dark,
                  note: "Eight formats, all of them writable: six macOS encodes itself and two "
                      + "— MP3 and Opus — through the ffmpeg Melo ships. Nothing in this grid "
                      + "should read as unavailable. Bit depth is fixed per format and is not "
                      + "offered as a choice, so a format with no depth control is correct.",
                  prepare: {
                      seedEditor(
                          moves: proposedMoves,
                          destination: DestinationCatalogue.podcast,
                          analysis: quietReport
                      )
                  }) {
                AnyView(
                    ExportSheet(
                        store: editor,
                        isPresented: .constant(true),
                        format: AudioFormatKind.m4aAAC
                    )
                )
            }
        )
        scenes.append(
            scene("cutting-room-export-mp3", CGSize(width: 560, height: 660), .dark,
                  note: "MP3, available. Melo ships its own ffmpeg at Contents/Helpers/ffmpeg "
                      + "and the locator prefers it over anything on PATH, so this frame is the "
                      + "visible end of a wire that runs through a shell script no Swift test "
                      + "can reach: if build-app.sh stops copying the binary, or signing leaves "
                      + "it non-executable, this tile flips to the needs-a-tool state and says "
                      + "so. Read the bit-depth and rate line too — those are fixed per format "
                      + "and are not offered as a choice.",
                  prepare: {
                      seedEditor(
                          moves: proposedMoves,
                          destination: DestinationCatalogue.podcast,
                          analysis: quietReport
                      )
                  }) {
                AnyView(
                    ExportSheet(
                        store: editor,
                        isPresented: .constant(true),
                        format: AudioFormatKind.mp3
                    )
                )
            }
        )

        // MARK: The two sheets that used to be one frame each
        //
        // Both sheets now take a seed, and it is deliberately **not**
        // `#if MELO_DEV`: a state only reachable in a dev build is a state the
        // release build's layout was never checked against, which is the whole
        // point of looking. Seeded means inert — no clipboard read, no tool
        // lookup, no process spawn, no tap, nothing published into the store —
        // so these frames are a picture of a state rather than a working sheet.
        //
        // Before the seams, one branch of each was renderable and it was
        // whichever branch this Mac happened to produce. `cutting-room-link-no-ytdlp`
        // kept its name because the state it shows has not changed; what changed
        // is that it no longer depends on the render machine not having yt-dlp.
        //
        // Layer captures throughout, and that is a choice. Neither sheet contains
        // a `glassEffect` island, so nothing here is composited away and an
        // ImageRenderer frame would buy no content — while costing the text field
        // and the progress bar, which that path draws as solid no-entry bars
        // because it cannot draw the controls at all.
        let linkSheetSize = CGSize(width: 500, height: 460)
        let samplePageURL = URL(string: "https://example.com/watch?v=melo-snapshot")
            ?? URL(fileURLWithPath: "/")
        let foundPreview = LinkPreview(
            title: LinkImportSeed.longTitle,
            siteName: "Example",
            uploader: "The Morning Show",
            duration: 4_218,
            thumbnailFileURL: nil,
            isLive: false
        )

        @MainActor func linkSheet(_ seed: LinkImportSeed) -> AnyView {
            AnyView(
                LinkImportSheet(store: editor, isPresented: .constant(true), seed: seed)
                    .frame(width: linkSheetSize.width, alignment: .top)
            )
        }

        scenes.append(
            scene("cutting-room-link-no-ytdlp", linkSheetSize, .dark,
                  note: "yt-dlp is not installed. Seeded rather than inherited from the render "
                      + "machine, so this frame says the same thing on a Mac that has it.",
                  prepare: { emptyEditor() }) {
                linkSheet(LinkImportSeed(phase: .needsTool, toolVersion: nil))
            }
        )
        scenes.append(
            scene("cutting-room-link-idle", linkSheetSize, .light,
                  note: "The sheet as it opens with nothing pasted. The footer names the "
                      + "yt-dlp it found, which is the only place the second network surface "
                      + "this feature adds is visible.",
                  prepare: { emptyEditor() }) {
                linkSheet(LinkImportSeed(phase: .idle))
            }
        )
        // The state the whole sheet exists for, carrying the most variable content
        // in the piece: a 150-character page title. Real titles run this long
        // routinely, and the question is whether it wraps or pushes the card open.
        scenes.append(
            scene("cutting-room-link-found", linkSheetSize, .dark,
                  note: "A found page with a 150-character title and no thumbnail — the "
                      + "placeholder is correct, not a missing image. What to read: whether the "
                      + "title wraps inside the card or forces it wider, and whether the "
                      + "uploader · length · site line survives underneath it.",
                  prepare: { emptyEditor() }) {
                linkSheet(
                    LinkImportSeed(
                        phase: .found(foundPreview),
                        linkText: samplePageURL.absoluteString
                    )
                )
            }
        )
        scenes.append(
            scene("cutting-room-link-working", linkSheetSize, .dark,
                  note: "Mid-extraction. The bar is determinate because yt-dlp reports a "
                      + "percentage; the stage line is what it is doing and the detail line is "
                      + "how far in.",
                  prepare: { emptyEditor() }) {
                linkSheet(
                    LinkImportSeed(
                        phase: .working(
                            fraction: 0.42,
                            stage: "Getting the audio",
                            detail: "3.1 MB of 7.4 MB · 1.2 MB/s"
                        ),
                        linkText: samplePageURL.absoluteString
                    )
                )
            }
        )
        // The longest sentence the extractor can produce, so it is the one that
        // decides whether the failure row wraps or clips. Read out of the shipped
        // enum rather than transcribed.
        scenes.append(
            scene("cutting-room-link-failed", linkSheetSize, .light,
                  note: "The longest failure sentence in the extractor: the download arrived in "
                      + "a container macOS cannot open and Melo's own ffmpeg was not there to "
                      + "convert it. Since Melo now ships that binary, reaching this means the "
                      + "app is missing a copy it was built with — so the sentence sends them "
                      + "to reinstalling rather than to Homebrew. Rendered live out of "
                      + "LinkExtractionFailure, so the frame follows the copy rather than "
                      + "quoting a version of it.",
                  prepare: { emptyEditor() }) {
                linkSheet(
                    LinkImportSeed(
                        phase: .failed(
                            LinkExtractionFailure.needsFFmpeg(fileExtension: "webm")
                                .errorDescription
                                ?? "Melo’s own ffmpeg isn’t there to convert it."
                        ),
                        linkText: samplePageURL.absoluteString
                    )
                )
            }
        )

        // Four apps, never more. `ImageRenderer` returns blank for `ScrollView`
        // content once the list scrolls, measured by the piece's own builder, and
        // a fifth row is what starts the scroll.
        let recordApps = Array(MockData.sampleApps.prefix(4))
        let recordSheetSize = CGSize(width: 500, height: 520)

        @MainActor func recordSheet(_ seed: SystemRecordSeed) -> AnyView {
            AnyView(
                SystemRecordSheet(store: editor, isPresented: .constant(true), seed: seed)
                    .frame(width: recordSheetSize.width, alignment: .top)
            )
        }

        scenes.append(
            scene("cutting-room-record-arm", recordSheetSize, .dark,
                  note: "Arming. Recording one app rather than the whole Mac is the headline "
                      + "here and is impossible in every other audio editor on this machine, so "
                      + "the question is whether the list reads as the offer it is.",
                  prepare: { emptyEditor() }) {
                recordSheet(SystemRecordSeed(apps: recordApps))
            }
        )
        scenes.append(
            scene("cutting-room-record-nothing-playing", recordSheetSize, .light,
                  note: "Nothing is making sound. The honest empty case, and a state a first "
                      + "run lands in constantly — seeded, so it is not a function of what the "
                      + "render machine had open.",
                  prepare: { emptyEditor() }) {
                recordSheet(SystemRecordSeed(apps: []))
            }
        )
        scenes.append(
            scene("cutting-room-record-permission", recordSheetSize, .dark,
                  note: "Before macOS has granted audio capture. Config/Info.plist's "
                      + "NSAudioCaptureUsageDescription is the sentence the system dialog will "
                      + "carry; this is the one Melo writes itself.",
                  prepare: { emptyEditor() }) {
                recordSheet(SystemRecordSeed(needsPermission: true, apps: recordApps))
            }
        )
        scenes.append(
            scene("cutting-room-record-running", recordSheetSize, .dark,
                  note: "Recording one app, 1:18 in, meter at 0.62. The level and the clock are "
                      + "handed in; nothing is being captured.",
                  prepare: { emptyEditor() }) {
                recordSheet(
                    SystemRecordSeed(
                        state: .recording,
                        level: 0.62,
                        elapsed: 78,
                        source: recordApps.first.map { .app(pid: $0.id, name: $0.name) }
                            ?? .everything,
                        apps: recordApps
                    )
                )
            }
        )
        scenes.append(
            scene("cutting-room-record-dropping", recordSheetSize, .dark,
                  note: "The same recording, losing frames. A recorder that quietly drops audio "
                      + "and says nothing is the worst outcome this sheet has, so whether the "
                      + "count is visible at a glance is the whole of this frame.",
                  prepare: { emptyEditor() }) {
                recordSheet(
                    SystemRecordSeed(
                        state: .recording,
                        level: 0.44,
                        elapsed: 214,
                        droppedFrameCount: 1_284,
                        apps: recordApps
                    )
                )
            }
        )
        scenes.append(
            scene("cutting-room-record-failed", recordSheetSize, .light,
                  note: "The tap could not be set up. The sentence is the only thing the user "
                      + "gets, so it has to say what to do next.",
                  prepare: { emptyEditor() }) {
                recordSheet(
                    SystemRecordSeed(
                        state: .failed(
                            "Melo couldn’t start recording. Another app has exclusive use of "
                            + "the output device."
                        ),
                        apps: recordApps
                    )
                )
            }
        )

        scenes.append(
            scene("cutting-room-jobs", jobStripSize, .dark,
                  note: "Five rows: a render 38 seconds in with an estimate, a write nearly "
                      + "done, an indeterminate measurement, a failure that will not leave on "
                      + "its own, and a cancellation. Start times are backdated, so the elapsed "
                      + "and remaining readouts have something to say.",
                  prepare: {
                      seedEditor(
                          moves: proposedMoves,
                          destination: DestinationCatalogue.podcast,
                          analysis: quietReport
                      )
                      JobStripTuning.seedSnapshotJobs(in: editor)
                  }) { AnyView(JobProgressStrip(store: editor)) }
        )
        scenes.append(
            scene("cutting-room-jobs-finished", CGSize(width: 700, height: 260), .dark,
                  note: "The finished-export card, with the before-and-after it measured. No "
                      + "click can reach this state in a rendered frame.",
                  prepare: {
                      seedEditor(
                          moves: proposedMoves,
                          destination: DestinationCatalogue.podcast,
                          analysis: quietReport
                      )
                      JobStripTuning.seedSnapshotOutcome(in: editor)
                  }) { AnyView(JobProgressStrip(store: editor)) }
        )

        // MARK: The multitrack timeline
        //
        // **None of this had ever been rendered.** The document model, the
        // lanes, the zoom, the clip gestures and the fades were all compiled and
        // in places executed, and not one frame showed a second track. These
        // eleven and the follow transition above are the first look.
        //
        // All of them are the timeline pane at `timelineSize`, which is the pane
        // a multitrack 1000×640 window really gives — except `timeline-calm`,
        // which is at `waveformSize` so it can be diffed directly against
        // `cutting-room-waveform-fit`.
        //
        // Every one seeds a per-source picture through `seedClipWaveforms`. Two
        // lanes that look the same here mean two lanes ARE the same, which is
        // the only reading of these frames that is worth anything.

        let timelineNote = "Synthetic fixtures, not decoded files — judge the lanes, the ruler "
            + "alignment, the clip chrome and the selections, not the shape of the sound. Each "
            + "source draws its own picture; two identical lanes would mean a lane is drawing "
            + "the mix instead of its clip's source."

        scenes.append(
            scene(
                "timeline-calm", waveformSize, .dark,
                note: timelineNote + " ONE track, seeded the same way and rendered at the same "
                    + "size as cutting-room-waveform-fit — the pair exists so the claim \"open a "
                    + "file and the window looks like it did\" can be checked rather than "
                    + "asserted. `EditorRootView` gives a single-track document the identical "
                    + "view tree it always had, so the only differences allowed here are the "
                    + "clip body's wash and hairline and the 10pt scroll strip. No name strip: "
                    + "one clip on one lane does not draw one.",
                prepare: { seedTimeline(trackCount: 1, playhead: 58) }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )

        scenes.append(
            scene(
                "timeline-three-tracks", timelineSize, .dark,
                note: timelineNote + " Three lanes dividing one pane. What to check: every lane "
                    + "is the same height, the gaps are equal, and a clip's left edge sits under "
                    + "the ruler tick for its own start time — the ruler and the lanes are laid "
                    + "out in the same coordinate space and read the same viewport, so a lane "
                    + "that has drifted is a real defect and not a rounding artefact. Lanes 2 "
                    + "and 3 are offset and trimmed windows onto the same source, which is what "
                    + "the source pool is for.",
                prepare: { seedTimeline(trackCount: 3, playhead: 58) }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )

        scenes.append(
            scene(
                "timeline-both-selections", timelineSize, .dark,
                note: timelineNote + " The two selections that coexist and must not be confused: "
                    + "a TIME SPAN of 0:42–1:36, drawn warm across every lane, and a SELECTED "
                    + "CLIP — the second lane's — carrying an accent ring. They mean different "
                    + "things and different keys act on them, so a frame in which they read as "
                    + "one kind of highlight is a frame reporting a real problem.",
                prepare: {
                    seedTimeline(
                        trackCount: 3,
                        selection: 42...96,
                        playhead: 58,
                        selectedClips: [1]
                    )
                }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )

        scenes.append(
            scene(
                "timeline-clip-hovered", timelineSize, .dark,
                note: timelineNote + " The hovered state, which is the ONLY state in which the "
                    + "move handle and the two fade handles exist — Melo is flat at rest and the "
                    + "hover is the interaction signal. A pointer is not something a snapshot "
                    + "can hold, so `hoveredClip:` is the only route to this frame. Judge "
                    + "whether the handles are findable without being loud, and whether the name "
                    + "strip's wash makes the drag target obvious.",
                prepare: { seedTimeline(trackCount: 3, playhead: 58) }
            ) {
                AnyView(
                    EditorWaveformView(
                        store: editor,
                        hoveredClip: timelineClip(track: 1),
                        hoveredPart: .move
                    )
                )
            }
        )

        scenes.append(
            scene(
                "timeline-drag-move", timelineSize, .dark,
                note: timelineNote + " A drag in progress: the second lane's clip lifted 22s "
                    + "later and one lane DOWN, drawn where the pointer would have it before "
                    + "mouse-up commits it. Nothing else reaches this state — the harness "
                    + "photographs states, not gestures. The clip is drawn live over the lane it "
                    + "is landing on; what to check is that the preview is the clip itself and "
                    + "not a ghost rectangle, because the preview clamps through the same "
                    + "`EditorClipEdit` the store commits.",
                prepare: { seedTimeline(trackCount: 3, playhead: 58) }
            ) {
                AnyView(
                    EditorWaveformView(
                        store: editor,
                        edit: timelineClip(track: 1).map { .move(ids: [$0], by: 22, lanes: 1) }
                    )
                )
            }
        )

        scenes.append(
            scene(
                "timeline-fades", timelineSize, .light,
                note: timelineNote + " Fades as real slopes in the audio, not wedges laid over "
                    + "it: the drawn columns are scaled by the clip's own envelope, which is "
                    + "what makes dragging a fade handle change the picture. A fade in of 22% "
                    + "and out of 30% on every clip, one curve per lane — linear, equal-power, "
                    + "exponential, top to bottom. The three must be distinguishable from each "
                    + "other; if they are not, the curve is not reaching the drawing. Light, "
                    + "because the clip wash is 34% white here against 4.5% in dark and this is "
                    + "where the body and its hairline are loudest.",
                prepare: { seedTimeline(trackCount: 3, layout: .fades, playhead: 58) }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )

        scenes.append(
            scene(
                "timeline-fade-handle", timelineSize, .dark,
                note: timelineNote + " A fade handle grabbed mid-drag: the second lane's fade in "
                    + "pulled out to 45s. Fit zoom on purpose, so the clip's leading edge and "
                    + "the whole slope are both in frame. The handle lives in a 12pt band at the "
                    + "clip's top corner and the trim edge is the same x below it — two "
                    + "different drags that start life at the same point, which is the thing "
                    + "worth looking hard at.",
                prepare: { seedTimeline(trackCount: 3, layout: .fades, playhead: 58) }
            ) {
                AnyView(
                    EditorWaveformView(
                        store: editor,
                        hoveredClip: timelineClip(track: 1),
                        hoveredPart: .fadeIn,
                        edit: timelineClip(track: 1).map { .fadeIn(id: $0, seconds: 45) }
                    )
                )
            }
        )

        scenes.append(
            scene(
                "timeline-trim-zoomed", timelineSize, .dark,
                note: timelineNote + " A trim in progress, zoomed in. The second lane's clip has "
                    + "its `sourceIn` dragged from 0:20 to 1:30 — and the point of the frame is "
                    + "that the audio inside does NOT squash: a trim is a window onto the "
                    + "source, so pulling the edge in reveals less of the same picture and "
                    + "pulling it back out brings the audio back, because nothing was thrown "
                    + "away. The new edge is dragged to roughly the clip's midpoint, which is "
                    + "where the seeded window centres itself.",
                prepare: { seedTimeline(trackCount: 3, playhead: 58) }
            ) {
                AnyView(
                    EditorWaveformView(
                        store: editor,
                        zoom: 0.35,
                        edit: timelineClip(track: 1).map { .trimStart(id: $0, sourceIn: 90) }
                    )
                )
            }
        )

        scenes.append(
            scene(
                "timeline-zoomed-clipped", timelineSize, .light,
                note: timelineNote + " Zoomed to 0.78 with the window starting at 1:00, so every "
                    + "clip body runs off one or both edges of the pane. What to check: a clip "
                    + "whose start is off screen still draws its body to the edge rather than "
                    + "stopping short or starting a fresh rounded corner in the middle of the "
                    + "pane, the scroll strip's thumb reflects where in the project this window "
                    + "sits, and the ruler is still legible at this density.",
                prepare: { seedTimeline(trackCount: 3, playhead: 78) }
            ) {
                AnyView(EditorWaveformView(store: editor, zoom: 0.78, windowStart: 60))
            }
        )

        scenes.append(
            scene(
                "timeline-split-paste", timelineSize, .dark,
                note: timelineNote + " Split and paste, which both make several clips out of one "
                    + "source. Lane 1's clip is split at 45% into two abutting clips — look for "
                    + "two name strips and one hairline seam where there was an unbroken "
                    + "drawing, and for the audio continuing across the seam, because a split "
                    + "moves numbers and copies no samples. Lane 2 carries a pasted copy of the "
                    + "left half, landing past the old end of the project, so the ruler has had "
                    + "to grow to the new last clip.",
                prepare: { seedTimeline(trackCount: 3, layout: .split, playhead: 58) }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )

        scenes.append(
            scene(
                "timeline-six-tracks", timelineSize, .dark,
                note: "SIX tracks in a pane that holds five, and it is in the list deliberately "
                    + "— this is what being past the floor looks like, and it is worth seeing "
                    + "rather than describing. A lane never shrinks below "
                    + "`EditorTrackMetrics.minimumLaneHeight`, which is 86 because that is what "
                    + "a header needs (`MuteButton` is built to the 28pt touch target and cannot "
                    + "shrink), and `n` lanes need `92n + 26` points of pane. This pane is 510, "
                    + "so five fit and the sixth CLIPS AT THE BOTTOM. The clipping is the "
                    + "documented trade, not a bug in the lanes: neither the lanes nor the "
                    + "header column scrolls vertically yet, and they clip together so they "
                    + "cannot shear. Judge how bad it is, not whether it is wrong.",
                prepare: { seedTimeline(trackCount: 6, playhead: 58) }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )

        // MARK: The track headers
        //
        // The other half of the multitrack window, and the half that decides
        // whether the lanes are usable: a name, a level, a pan, and the two
        // buttons that quiet a track.
        //
        // Row `n` has to sit level with lane `n`, and nobody measures anybody to
        // make that happen — the column reserves the same ruler band above and
        // scroll strip below and hands a `VStack` rows that are all equally
        // flexible. **A shear between the two sides is the defect these frames
        // exist to catch**, so read every one of them across the divider before
        // reading anything else.

        let trackHeaderNote = "The header column beside the lanes. Check the alignment FIRST: header "
            + "row n must be level with lane n, top and bottom, across the divider. The two "
            + "sides reach their heights by separate routes that are only guaranteed to agree "
            + "while they reserve the same ruler band and scroll strip."

        scenes.append(
            scene(
                "cutting-room-tracks-two", editorSize, .dark,
                note: trackHeaderNote + " TWO sources, one track each, both starting at zero and each "
                    + "named after the file it came from — which is what dropping a second file "
                    + "into an open document actually produces, since bringing in audio adds a "
                    + "track rather than replacing the document. The two lanes end at different "
                    + "points because the sources are different lengths.",
                prepare: { seedLayered(["morning-show-ep41", "interview-clip"]) }
            ) { editorWindow() }
        )

        scenes.append(
            scene(
                "cutting-room-tracks-four", editorSize, .light,
                note: trackHeaderNote + " FOUR sources, named, levelled and panned. Each lane draws "
                    + "its own source, so four lanes that look alike would mean the per-source "
                    + "pictures are not being read. The pans read C, 24R, 60L and 35R in the "
                    + "30pt readouts; the gains are −3.5, −9 and −18 dB. Light, because the "
                    + "fader track, the pan slider and the clip wash are all at their most "
                    + "different from dark here.",
                prepare: {
                    seedLayered(
                        [
                            "morning-show-ep41",
                            "interview-clip",
                            "Recording, 9 Aug at 14:02",
                            "room-tone"
                        ],
                        gains: [1: -3.5, 2: -9, 3: -18],
                        pans: [1: 0.24, 2: -0.6, 3: 0.35]
                    )
                }
            ) { editorWindow() }
        )

        scenes.append(
            scene(
                "cutting-room-tracks-soloed", editorSize, .dark,
                note: trackHeaderNote + " One track soloed. **Solo is a render-time filter, not a "
                    + "state change on the others** — nothing is written to tracks 1 and 3, and "
                    + "un-soloing restores exactly what was there. So the question this frame "
                    + "answers is whether the two tracks that have gone quiet LOOK quiet without "
                    + "looking muted, since muted is a different state with a different button "
                    + "and a different way back.",
                prepare: { seedTracks(count: 3, soloed: [1]) }
            ) { editorWindow() }
        )

        scenes.append(
            scene(
                "cutting-room-tracks-muted", editorSize, .dark,
                note: trackHeaderNote + " Two of three muted. Compare against "
                    + "cutting-room-tracks-soloed: a muted track and a track silenced BY someone "
                    + "else's solo are different states and must not draw the same, because the "
                    + "way out of each one is a different button.",
                prepare: { seedTracks(count: 3, muted: [0, 2]) }
            ) { editorWindow() }
        )

        scenes.append(
            scene(
                "cutting-room-tracks-column", headerColumnSize, .dark,
                note: "The column alone at its real 200pt width, with four headers carrying "
                    + "every state at once: named, gained, panned, one muted, one soloed. 200 is "
                    + "narrow on purpose — this is enough to name a track and quiet it, not a "
                    + "mixer channel strip, and at the 820pt minimum window it already leaves "
                    + "the waveform under 300pt. What the fader costs is the thing to judge: "
                    + "roughly 68pt of travel over 36 dB. The band at the top is the ruler's "
                    + "height, reserved so the first header is level with the first lane, and "
                    + "the \"Add an Empty Track\" strip is in it because the lanes divide the "
                    + "whole pane and leave no spare strip at the foot.",
                prepare: {
                    seedTracks(
                        count: 4,
                        names: [0: "Host", 1: "Guest", 2: "Intro bed", 3: "Room tone"],
                        gains: [1: -3.5, 2: -9, 3: -18],
                        pans: [1: 0.24, 2: -0.6],
                        muted: [3],
                        soloed: [1]
                    )
                }
            ) { headerColumn() }
        )

        scenes.append(
            scene(
                "cutting-room-tracks-narrow", CGSize(width: 820, height: 520), .light,
                note: "The window at its 820×520 MINIMUM with three tracks — the tightest this "
                    + "layout is ever asked to be. 320 of sidebar and 200 of header column leave "
                    + "about 297pt of waveform, which is the thinnest the drawing ever gets. "
                    + "Three lanes is also exactly what fits here: the pane is the window less "
                    + "130, and `n` lanes need `92n + 26` points. A fourth track at this size "
                    + "clips. Read the header row's name, fader and pan readout for truncation "
                    + "before anything else.",
                prepare: {
                    seedTracks(
                        count: 3,
                        names: [0: "Host", 1: "Guest", 2: "Intro bed"],
                        gains: [1: -3.5, 2: -9],
                        pans: [1: 0.24, 2: -0.6],
                        soloed: [1]
                    )
                }
            ) { editorWindow() }
        )

        // MARK: - The docked panels
        //
        // The right-hand pane stopped being an accordion. Every header is the
        // full 320pt of the pane and the *whole* strip is the press target,
        // more than one panel may be open at once, and which are open is
        // remembered per document in the session sidecar.
        //
        // **Why these are transitions and not still frames.** A still frame of a
        // shut panel proves the header draws. It proves nothing at all about
        // pressing it — and "the control draws and does nothing" is the exact
        // failure this project has shipped before and now keeps a whole
        // mechanism to catch. Every pair below runs `EditorStore
        // .toggleOpenPanel`, which is the header button's entire action, and
        // then asserts the store landed on the set it claims *and* that the
        // frame moved. The two together are what a press produces; neither
        // alone is.
        //
        // `SnapshotHarness.bindingCaveat` still applies and is on every note:
        // the harness cannot press an AppKit control in an offscreen never-key
        // window (the accessibility tree is empty there — see the `actOnHost`
        // comment in `SnapshotHarness`), so emptying the button's own closure
        // would leave these frames unchanged. What `toggleOpenPanel` does is
        // verified; that the header is bound to it is not.
        //
        // ## The floor
        //
        // The harness default, 1%. Not chosen by taste: `control-cutting-room`
        // is this same family — the whole window, layer capture, seeded the same
        // way — and measured **0.0000%** on its first complete run, so the
        // entire 1% is margin. The changes here are nothing like marginal: the
        // pane is 320 of 1000 points wide and an opening body claims roughly
        // half of 612 points of it, which is about 16% of the frame. The one to
        // watch is `-all-three`, where the two already-open bodies only
        // *shrink* to make room; that still moves every row in both of them.
        //
        // `control-editor-panels` below is seeded exactly as these are, rather
        // than leaning on `control-cutting-room`, for the reason `control-
        // timeline` gives about `timeline-follow-pages`: a control has to be the
        // same pane in the same state, not merely the same family.

        /// Puts the pane in a known state. Every pair states both ends, so no
        /// frame here inherits a panel set from the scene before it — the
        /// sticky-global trap `applyAppearance` exists for, one object along.
        @MainActor func seedPanels(
            _ panels: Set<EditorPanel>,
            moves: [Move] = [],
            scheme: ColorScheme = .dark
        ) {
            // The scheme is a parameter and not a constant because one pair
            // below is light. `SnapshotHarness.transition` does not go through
            // the `scene(...)` wrapper, so nothing else calls this for it — a
            // hard-coded `.dark` here would render a frame the harness labels
            // light with the app's own appearance set the other way, which is
            // the exact contradiction that produced an unreadable `popup-dark`.
            applyAppearance(scheme)
            seedEditor(
                moves: moves,
                destination: DestinationCatalogue.podcast,
                analysis: quietReport
            )
            editor.setOpenPanelsForSnapshot(panels)
        }

        /// Reads the store rather than the pixels.
        ///
        /// A pixel diff says *something* moved. This says the pane is showing
        /// the panels the scene's name promises — which is the difference
        /// between a header that toggles the right panel and one that toggles a
        /// panel. Both assertions are cheap and they fail on different bugs.
        @MainActor func panelsAre(
            _ expected: Set<EditorPanel>
        ) -> (@MainActor (NSView) -> String?) {
            { _ in
                let actual = editor.openPanels ?? []
                guard actual != expected else { return nil }
                let name = { (set: Set<EditorPanel>) in
                    set.isEmpty ? "none" : set.map(\.rawValue).sorted().joined(separator: "+")
                }
                return "open panels are \(name(actual)), expected \(name(expected))"
            }
        }

        let panelCaveat = " " + SnapshotHarness.bindingCaveat

        scenes += SnapshotHarness.transition(
            name: "cutting-room-panel-chain-opens",
            size: editorSize,
            colorScheme: .dark,
            note: "BEFORE has only Where's it going? open; AFTER has the Chain open BESIDE it. "
                + "This is the frame that says the pane is no longer an accordion — under the "
                + "old one, opening the Chain shut the picker, so the reader lost the control "
                + "they had just used in order to see what it did. Two bodies, one pane, each "
                + "taking an equal share of what the three headers leave." + panelCaveat,
            prepare: { seedPanels([.destination], moves: proposedMoves) },
            act: { editor.toggleOpenPanel(.chain) },
            assertBefore: panelsAre([.destination]),
            assertAfter: panelsAre([.destination, .chain])
        ) { editorWindow() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-panel-chain-shuts",
            size: editorSize,
            colorScheme: .dark,
            note: "The other direction, and the state nothing could reach before: AFTER has ALL "
                + "THREE panels shut. Three headers, hairlines, and the themed ground under "
                + "them. It has to stay legible — a pane of nothing but strips is what somebody "
                + "who wants the timeline as wide as it goes will choose, and `[]` survives a "
                + "reopen because the sidecar tells `nil` (nobody said) from `[]` (they said "
                + "no)." + panelCaveat,
            prepare: { seedPanels([.chain], moves: proposedMoves) },
            act: { editor.toggleOpenPanel(.chain) },
            assertBefore: panelsAre([.chain]),
            assertAfter: panelsAre([])
        ) { editorWindow() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-panel-destination-opens",
            size: editorSize,
            colorScheme: .dark,
            note: "From all three shut to the destination picker alone. The BEFORE frame is the "
                + "only place the shut pane is judged on its own terms: three headers at 28pt, "
                + "each carrying its panel's answer — the destination's name, the measured "
                + "LUFS, the move count — because a header that only says its own name wastes "
                + "the one line it has." + panelCaveat,
            prepare: { seedPanels([], moves: proposedMoves) },
            act: { editor.toggleOpenPanel(.destination) },
            assertBefore: panelsAre([]),
            assertAfter: panelsAre([.destination])
        ) { editorWindow() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-panel-destination-shuts",
            size: editorSize,
            colorScheme: .light,
            note: "Shutting one of two, which leaves the Chain the whole pane. Light, because "
                + "the header fills, the accent stripe on an open header and the hairlines "
                + "between panels are all at their most different from dark here — a 5% black "
                + "wash on light glass is the easiest of the four to get wrong." + panelCaveat,
            prepare: { seedPanels([.destination, .chain], moves: proposedMoves, scheme: .light) },
            act: { editor.toggleOpenPanel(.destination) },
            assertBefore: panelsAre([.destination, .chain]),
            assertAfter: panelsAre([.chain])
        ) { editorWindow() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-panel-analysis-opens",
            size: editorSize,
            colorScheme: .dark,
            note: "What I found opening UNDER an already-open Chain. The Chain does not move to "
                + "the top and does not shut: the panels are in a fixed order and opening one "
                + "takes room from the others rather than replacing them. AFTER is the second "
                + "two-panels-open frame in this block and the only one where the pair is "
                + "adjacent." + panelCaveat,
            prepare: { seedPanels([.chain], moves: proposedMoves) },
            act: { editor.toggleOpenPanel(.analysis) },
            assertBefore: panelsAre([.chain]),
            assertAfter: panelsAre([.chain, .analysis])
        ) { editorWindow() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-panel-analysis-shuts",
            size: editorSize,
            colorScheme: .dark,
            note: "The analysis panel alone, then shut. Judge the AFTER header's summary: a shut "
                + "What I found has to still say the loudness it measured, or shutting it "
                + "throws away the one number the reader opened it for." + panelCaveat,
            prepare: { seedPanels([.analysis], moves: proposedMoves) },
            act: { editor.toggleOpenPanel(.analysis) },
            assertBefore: panelsAre([.analysis]),
            assertAfter: panelsAre([])
        ) { editorWindow() }

        scenes += SnapshotHarness.transition(
            name: "cutting-room-panel-all-three",
            size: editorSize,
            colorScheme: .dark,
            note: "Two open, then three. **The tightest this pane is ever asked to be**: 612 "
                + "points less 84 of headers and four hairlines is about 176 each, and all "
                + "three bodies scroll inside themselves, so nothing may overflow and nothing "
                + "may be clipped mid-row. Read the boundaries between the three bodies before "
                + "reading anything inside them. This is also the pair where the change is "
                + "smallest — the two open bodies only shrink — so it is the one that would go "
                + "under the floor first if anything about the layout stopped moving."
                + panelCaveat,
            prepare: { seedPanels([.destination, .analysis], moves: proposedMoves) },
            act: { editor.toggleOpenPanel(.chain) },
            assertBefore: panelsAre([.destination, .analysis]),
            assertAfter: panelsAre([.destination, .analysis, .chain])
        ) { editorWindow() }

        scenes += SnapshotHarness.negativeControl(
            name: "control-editor-panels",
            size: editorSize,
            colorScheme: .dark,
            note: "Docked panel family. Seeded exactly as cutting-room-panel-chain-opens' BEFORE "
                + "frame is — one panel open, the full proposal on the Chain — with the act "
                + "removed. Every transition above asserts that two frames of this pane differ "
                + "when a panel is toggled; this is the statement that they do NOT differ when "
                + "nothing is, which is the only thing that makes the seven above mean anything.",
            prepare: { seedPanels([.destination], moves: proposedMoves) }
        ) { editorWindow() }

        // MARK: - A/B compare
        //
        // The second lane under each clip, and the audible flip that swaps what
        // plays. Four things need frames and one of them cannot have one; this
        // block says which is which before it says anything else.
        //
        // **What these frames prove.** That the lane can be off and is off by
        // default. That turning it on takes its space out of the clip and not
        // out of the header alignment. That the clip body draws the *processed*
        // picture and the strip draws the raw one — `timeline-compare-chain` is
        // the pair that catches two identical waveforms, and how is written on
        // it. That engaging bypass inverts which of the two is at full weight,
        // so a still frame says what the ear is getting.
        //
        // **What they cannot prove, and it is the important half.** There is no
        // file behind a snapshot source: `RenderEngine` throws on every call
        // from here, `EditorClipWaveforms` counts two failures and stops asking,
        // and the processed picture in these frames is therefore *seeded*. No
        // frame in this suite is evidence that Melo's real chain changes Melo's
        // real waveform. That claim belongs to
        // `scripts/verify-compare-bypass.py`, which renders both sides of the
        // split through the shipping `RenderEngine` and compares samples — and
        // which also executes the length invariant the strip's geometry rests
        // on, since a processed render of a different duration would draw the
        // two pictures against different spans of the same ruler.
        //
        // The seeded picture is not an arbitrary second fixture. It is the raw
        // fixture put through the arithmetic the scene's own chain describes —
        // `+7 dB` then a ceiling at `−1 dBTP` — so the loud passages squash
        // against the ceiling while the quiet ones lift, which is a change of
        // *shape* and not a scaled copy. A stand-in that differed only in
        // amplitude would let a compare lane that ignored the shape of the
        // processed data pass.

        /// Both sticky globals this family sets, put back.
        ///
        /// `EditorPlayback.shared.isBypassed` outlives a scene exactly the way
        /// `EditorTimeline` and `EditorClipWaveforms` do, and the shared
        /// `applyAppearance` hook does not clear it — so a bypassed frame would
        /// grey every clip in every scene rendered after this block. These
        /// scenes are last in the list, which bounds the damage to nothing
        /// today; anything appended below here has to call this first.
        /// `showsCompareLane` is cleared by `setForSnapshot` as well, and is
        /// repeated here so a scene that does not reseed still starts clean.
        @MainActor func resetCompareState() {
            EditorPlayback.shared.setBypassed(false)
            editor.showsCompareLane = false
        }

        /// The chain these frames compare against: a lift and a ceiling.
        ///
        /// Two moves rather than one because one would be a level change and
        /// the whole argument above is that a level change is too weak a
        /// stand-in. `gain` is the move every proposal starts with and
        /// `limiter` is the one that changes the crest factor, which is the
        /// property the drawing carries two weights to show.
        let compareChain: [Move] = [
            Move(
                kind: .gain(dB: 7),
                rationale: "This is 7 dB under where a podcast wants it — this lifts it."
            ),
            Move(kind: .limiter(ceilingDBTP: -1, releaseMS: 60), rationale: nil)
        ]

        /// The raw fixture through `compareChain`'s arithmetic.
        ///
        /// Peaks first, then the ceiling, then the RMS scaled by however much
        /// the ceiling actually took off that bucket — which is what a limiter
        /// does and what makes the core visibly fatten against the envelope in
        /// the loud passages. Deterministic, because `negativeControl` renders a
        /// scene twice and requires the two frames to match.
        @MainActor func compareFixture(
            _ data: WaveformData,
            gainDB: Double,
            ceilingDBTP: Double
        ) -> WaveformData {
            let gain = Float(pow(10.0, gainDB / 20))
            let ceiling = Float(pow(10.0, ceilingDBTP / 20))
            let buckets = data.buckets.map { bucket -> WaveformData.Bucket in
                let maximum = min(bucket.maximum * gain, ceiling)
                let minimum = max(bucket.minimum * gain, -ceiling)
                let wanted = bucket.maximum * gain
                let squash = wanted > 0 ? min(maximum / wanted, 1) : 1
                return WaveformData.Bucket(
                    minimum: minimum,
                    maximum: maximum,
                    rms: min(bucket.rms * gain * squash, ceiling)
                )
            }
            return WaveformData(buckets: buckets, duration: data.duration, joins: data.joins)
        }

        /// Seeds one processed picture per clip, matching each clip's source to
        /// the same `variant` `seedClipWaveforms` gave it.
        ///
        /// Matching the variant is the whole point: the strip and the clip have
        /// to be two readings of the *same take*, or the frame shows two
        /// different sounds and proves nothing about the chain.
        @MainActor func seedCompareFixtures() {
            guard let document = editor.document else { return }
            var seeded: [Clip.ID: WaveformData] = [:]
            for track in document.tracks {
                for clip in track.clips {
                    guard let source = document.source(clip.sourceID),
                          let variant = document.sources.firstIndex(where: { $0.id == clip.sourceID })
                    else { continue }
                    seeded[clip.id] = compareFixture(
                        editorWaveform(
                            duration: source.duration,
                            channels: source.channelCount,
                            variant: variant
                        ),
                        gainDB: 7,
                        ceilingDBTP: -1
                    )
                }
            }
            EditorClipWaveforms.shared.setProcessedForSnapshot(
                seeded,
                chain: EditorChain.stamp(document)
            )
        }

        /// The family's one seed: two lanes, a chain on the master, the compare
        /// lane on, and the processed pictures in place.
        ///
        /// Two tracks and not three. At 510 points a two-lane pane gives each
        /// lane 236, so the 30pt strip is a tenth of it and both readings are
        /// large enough to judge; at six lanes the strip is a third of an 86pt
        /// lane and the frame becomes a question about the floor rather than
        /// about the comparison. The crowded case has its own frame below.
        @MainActor func seedCompare(
            trackCount: Int = 2,
            comparing: Bool = true,
            processed: Bool = true
        ) {
            resetCompareState()
            var document = EditorTrackFixtures.document(
                source: editorSource,
                trackCount: trackCount,
                master: compareChain,
                destination: DestinationCatalogue.podcast,
                analysis: quietReport
            )
            // A gain and a fade on the second clip, so the frame also answers
            // "does the user's own mixer show up in the comparison" — it does,
            // in the clip and not in the strip, which is what `compareColumns`
            // refusing the envelope means in a picture.
            if document.tracks.count > 1, !document.tracks[1].clips.isEmpty {
                document.tracks[1].clips[0].gainDB = -6
                document.tracks[1].clips[0].fadeIn = 18
                document.tracks[1].clips[0].fadeCurve = .equalPower
            }
            installDocument(document, playhead: 58)
            if processed { seedCompareFixtures() }
            editor.showsCompareLane = comparing
        }

        let compareNote = "Synthetic fixtures, not decoded files. The strip under each clip is "
            + "the RAW source; the clip above it is the same source through the master chain "
            + "(+7 dB, then a −1 dBTP ceiling), SEEDED rather than rendered — there is no file "
            + "here for RenderEngine to read. So these frames are evidence about the LANE: that "
            + "it appears, that it takes its space from the clip and not from the header "
            + "alignment, that one span of the ruler carries both readings, and which of the two "
            + "is drawn at full weight. They are NOT evidence that the real chain changes the "
            + "real waveform — scripts/verify-compare-bypass.py owns that claim and executes it."

        scenes.append(
            scene(
                "timeline-compare-lanes", timelineSize, .dark,
                note: compareNote + " Two lanes with the compare lane ON. What to check: the "
                    + "strip sits directly under its clip and starts and ends at the same two x "
                    + "positions, the loud passages in the clip above are visibly squashed "
                    + "against a ceiling the strip below does not have, and lane 2's clip — "
                    + "which carries −6 dB of its own gain and an 18s fade — shows both in the "
                    + "CLIP and neither in the STRIP, because the reference is untouched by the "
                    + "user's mixer as well as by Melo's chain.",
                prepare: { seedCompare() }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )

        scenes.append(
            scene(
                "timeline-compare-crowded", timelineSize, .light,
                note: compareNote + " FIVE lanes, which is what this pane holds before it clips. "
                    + "478 points of lanes less four 6pt gaps over five lanes is 90.8 each, so "
                    + "the strip takes 30 and leaves the clip 57.8 — under the 54pt "
                    + "channel-split floor, which is why every clip here draws ONE merged lane "
                    + "where timeline-compare-lanes draws two. This is the frame that says what "
                    + "the lane costs at the density it hurts most: judge whether the clip above "
                    + "is still a drawing of audio at 58 points, and whether the strip is still "
                    + "readable at 30. If either answer is no, the floor in "
                    + "`EditorWaveformMetrics.compareLaneMinimumClipHeight` is the number to "
                    + "move — it is set at 44 and cannot bite while a lane is 86. Light, because "
                    + "the strip's recessed ground is 5% black here against 22% in dark and this "
                    + "is where it is closest to the clip's own wash.",
                prepare: { seedCompare(trackCount: 5) }
            ) { AnyView(EditorWaveformView(store: editor)) }
        )

        // Off, then on. The before frame is also the whole of the "it can be
        // turned off" claim: it is the timeline this app already drew, at the
        // lane heights it already used, with no strip and no second render
        // asked for.
        scenes += SnapshotHarness.transition(
            name: "timeline-compare-lane",
            size: timelineSize,
            colorScheme: .dark,
            note: compareNote + " BEFORE is the lane OFF, which is the default and is the same "
                + "timeline as timeline-three-tracks at two lanes. AFTER is one "
                + "`store.toggleCompareLane()` later. Identical frames mean the switch does not "
                + "reach the geometry — and note what a *partial* failure looks like here, "
                + "because it is the likely one: if the strip were added to the lane instead of "
                + "carved out of it, this pair would still differ and the defect would show up "
                + "as the header column shearing away from the lanes in "
                + "cutting-room-compare-window. Read that frame too. "
                + SnapshotHarness.bindingCaveat,
            prepare: { seedCompare(comparing: false) },
            act: { editor.toggleCompareLane() }
        ) { AnyView(EditorWaveformView(store: editor)) }

        // **The pair that catches two identical waveforms**, which is the way
        // this feature fails while looking like it works.
        //
        // Both frames have the compare lane on and the same document. The only
        // difference is whether a processed picture exists: the act clears it,
        // so the clip body falls back to the raw overview and both readings
        // become the same numbers. If the clip body were *always* drawing the
        // raw overview — the failure — the two frames would differ only by the
        // strip's caption changing from "Original" to "Original · chain not
        // rendered", which is a few hundred pixels of a 478×510 frame, about
        // 0.1%, and therefore UNDER the 1% floor. So the floor is not margin
        // here; it is the assertion. Anything that makes the caption longer
        // weakens it, which is why the caption is short.
        scenes += SnapshotHarness.transition(
            name: "timeline-compare-chain",
            size: timelineSize,
            colorScheme: .dark,
            note: compareNote + " BEFORE: the clip draws the chain's picture and the strip draws "
                + "the raw one, so the two differ. AFTER: the processed picture is taken away, "
                + "the clip falls back to the raw overview, and the two readings become "
                + "identical — which the strip admits to in its caption. Identical FRAMES mean "
                + "the clip body never drew the processed data at all, i.e. the compare lane is "
                + "drawing the same waveform twice. The caption alone is about 0.1% of this "
                + "frame and cannot carry the 1% floor on its own, which is what makes this a "
                + "real assertion rather than a change detector.",
            prepare: { seedCompare() },
            act: {
                EditorClipWaveforms.shared.setProcessedForSnapshot(
                    [:],
                    chain: editor.document.map { EditorChain.stamp($0) } ?? ""
                )
            }
        ) { AnyView(EditorWaveformView(store: editor)) }

        // The audible flip, as far as a still frame can carry it.
        //
        // `toggleBypass()` is the store surface a menu item calls and is the
        // same `EditorPlayback.setBypassed` the B key drives through
        // `setBypassHeld`, so this exercises the one flag both routes move.
        // What it cannot show is the sound: there is no file, no render and no
        // audio graph here, so the buffer swap in `EditorPlayback` is
        // UNVERIFIED by this frame and is what `verify-compare-bypass.py`
        // covers instead.
        scenes += SnapshotHarness.transition(
            name: "timeline-compare-bypass",
            size: timelineSize,
            colorScheme: .dark,
            note: compareNote + " BYPASS. BEFORE: the edit is playing, so the clip is at full "
                + "weight and the strip is the quiet reference. AFTER: one "
                + "`store.toggleBypass()`, and the two inks SWAP — the clip greys out and the "
                + "strip comes up to full weight with an accented \"Original · playing\". That "
                + "inversion is the whole marker for which of the two you are hearing; there is "
                + "no badge to get out of step. Identical frames mean the picture cannot tell "
                + "you what is in your ears, which is the one failure this feature must not "
                + "have. What is UNVERIFIED here: that the SOUND changes. No file, no render, "
                + "no audio graph. " + SnapshotHarness.bindingCaveat,
            prepare: { seedCompare() },
            act: { editor.toggleBypass() }
        ) { AnyView(EditorWaveformView(store: editor)) }

        // The whole window with the lane on, and the reason it is here rather
        // than being one more timeline frame: the compare strip is carved out
        // of the lane precisely so `TrackHeaderColumn` — which divides the same
        // lane by the same function in the other pane — does not move. That
        // claim is only checkable across the divider.
        scenes.append(
            scene(
                "cutting-room-compare-window", editorSize, .dark,
                note: compareNote + " The whole 1000×640 window with the compare lane on. **Read "
                    + "the alignment across the divider FIRST**: header row n must still be "
                    + "level with lane n, top and bottom. The strip comes out of the bottom of "
                    + "the lane rather than being added to it, so a header that has shifted "
                    + "means the strip is being added somewhere and the two panes have started "
                    + "disagreeing about how tall a lane is — which is a worse defect than the "
                    + "lane being ugly.",
                prepare: { seedCompare(trackCount: 3) }
            ) { editorWindow() }
        )

        // The control for the three transitions above.
        //
        // Seeded exactly as their BEFORE frames are — same document, same
        // chain, same seeded pictures, lane on, bypass off — with the act
        // removed, following `control-timeline`'s reasoning that a control has
        // to be the same pane in the same state and not merely the same family.
        //
        // **The ceiling is the harness default and it was reasoned, not
        // measured here.** Nothing in this pane animates at rest: the lanes are
        // a `Canvas`, the fixture is deterministic from an integer hash, and no
        // scene in this block seeds a playing transport. The seven Melo Edit
        // controls that preceded this one all read 0.0000% on their first
        // complete run, and `control-timeline` — the same view, the same
        // capture path, the same seeding route — is on the same 1% ceiling.
        // That is a citation, not a measurement of THIS pair. If it comes back
        // red the number in `_transitions.log` is the measurement and the
        // ceiling is set from it; it is not raised to make a run green. It
        // matters more here than in most families, because
        // `timeline-compare-chain` deliberately leans on the floor being higher
        // than a caption's worth of pixels.
        scenes += SnapshotHarness.negativeControl(
            name: "control-timeline-compare",
            size: timelineSize,
            colorScheme: .dark,
            note: "Compare lane family. Seeded exactly as timeline-compare-chain's BEFORE frame "
                + "is, with the act removed.",
            prepare: { seedCompare() }
        ) { AnyView(EditorWaveformView(store: editor)) }

        // Sticky state, put back for anything appended after this block. The
        // three globals this family leans on all outlive a scene, and two of
        // them are not cleared by the shared `applyAppearance` hook.
        scenes.append(
            scene(
                "control-compare-reset", CGSize(width: 200, height: 60), .dark,
                note: "Not a frame anyone needs to look at. It exists so the sticky state this "
                    + "block sets — `EditorPlayback.isBypassed`, `EditorStore.showsCompareLane` "
                    + "and the seeded processed pictures — is cleared by a scene rather than by "
                    + "whoever appends the next one remembering to. `EditorTimeline` and "
                    + "`EditorClipWaveforms` have the same trap and are cleared by "
                    + "`applyAppearance`; these two are not, and adding them there is a change "
                    + "to a hook four other builders are writing against this week.",
                prepare: {
                    resetCompareState()
                    EditorClipWaveforms.shared.resetForSnapshot()
                }
            ) { AnyView(Color.clear) }
        )

        // MARK: - Simple and Full
        //
        // `.run-notes/TIMELINE-FRAME.md` recorded a decision against two modes
        // and the owner reversed it; the reversal is written into that file.
        // The rule the reversal is built on is the one these frames exist to
        // hold: **switching adds and removes what is drawn, and never moves the
        // timeline, the waveform, or a byte of the document.**
        //
        // ## What each of these can and cannot prove
        //
        // A pixel diff says the window changed. It cannot say the document
        // survived, and it cannot tell "the pane redrew" from "the time axis
        // refitted and every sample is now three points to the left". So every
        // pair here carries `assertBefore`/`assertAfter` reading live state,
        // and the pixel comparison is the *weaker* of the two checks rather
        // than the only one:
        //
        //  * `modeIs` — the store landed where the scene's name says.
        //  * `documentUnchanged` — `EditorStore.documentFingerprintForSnapshot`
        //    encodes the document either side of the switch and the bytes must
        //    match. This is the assertion that matters most and the one with
        //    the nastiest failure behind it: a mode that quietly drops a pan it
        //    is about to stop drawing would survive every frame anybody looked
        //    at, and the user would find out at export.
        //  * `viewportUnchanged` — `EditorTimeline.shared.viewport` is
        //    `Equatable` and holds start, visible span, duration, sample rate
        //    and pane width. Identical either side is the executable form of
        //    "it never moves the waveform" on the axis a waveform is drawn
        //    along. It is not a claim about the pane's *height*: Full's clip
        //    strip costs the timeline 26 points and `EditorClipStrip` says so.
        //
        // ## The floor, measured rather than chosen
        //
        // This is the Cutting Room window family — 1000×640, layer capture,
        // store seeded through `setForSnapshot` — and that family's idle noise
        // is on record. Across the `_transitions.log` files of previous runs on
        // this machine: `control-cutting-room` 16 runs, `control-cutting-room-
        // render` 16, `control-editor-jobs` 16, `control-cutting-room-
        // multitrack` 8 — **fifty-six negative-control measurements, every one
        // of them 0.0000%**. Nothing in this window animates on its own; there
        // is no pointer halo and no starfield on the layer path.
        //
        // The smallest *real* change recorded in the same family is
        // `cutting-room-stack-disables` at **1.8813%** — one toggle flipping on
        // one row of the 320pt pane. So the gap between noise and signal here
        // is the whole interval from 0 to 1.88, and the harness default of 1%
        // sits in it with two orders of magnitude of margin on the noise side.
        // The two `must exceed` pairs below keep that default. `control-editor-
        // mode` re-measures the number on every run rather than trusting this
        // paragraph, seeded exactly as the transitions are.
        //
        // The round trip's ceiling is **tighter than the default and is derived
        // rather than picked**: 0.05%. A 1000×640 frame is 640 rows, so one
        // full-width hairline moving is 1/640 = 0.156% of it. 0.05% is a third
        // of a hairline — under the smallest visible artifact a mode switch
        // could leave behind, and still infinitely above the measured 0.0000%.
        // Leaving it at 1% would let a switch come back with six points of the
        // pane redrawn wrong and call it identical.

        /// Carries a fingerprint from the moment before a switch to the
        /// assertion that runs after it.
        ///
        /// A local class rather than a captured `var`: the two closures are
        /// escaping and are handed to the harness separately, and this makes
        /// what is shared between them a named thing rather than a box the
        /// compiler happens to make. It is also the only honest way to do it —
        /// the fingerprint cannot be taken in `prepare`, because `prepare`
        /// builds a *new* document with fresh UUIDs every time it runs, so a
        /// before-frame's fingerprint and an after-frame's would differ for
        /// reasons that have nothing to do with the mode.
        final class ModeWitness {
            var document: Data?
            var viewport: EditorTimelineViewport?
            /// Set when `act` ran, so an assertion cannot silently pass on a
            /// scene whose action never happened.
            var acted = false
        }

        /// Everything the mode family needs, in one call: appearance, a
        /// document, per-source pictures, a known viewport, panels, and the
        /// mode itself.
        ///
        /// **The mode is stated by every scene here, including the Simple
        /// ones.** `EditorStore.mode` is read out of `UserDefaults` when the
        /// singleton is built, and the harness runs on a machine where somebody
        /// may have chosen Full in the real app — so a scene that said nothing
        /// would render whichever mode the developer last used. Same trap
        /// `applyAppearance` exists for.
        @MainActor func seedMode(
            _ mode: EditorMode,
            tracks: Int = 1,
            panels: Set<EditorPanel>,
            scheme: ColorScheme = .dark
        ) {
            applyAppearance(scheme)
            if tracks > 1 {
                installDocument(
                    EditorTrackFixtures.document(
                        source: editorSource,
                        trackCount: tracks,
                        names: [0: "Host", 1: "Guest", 2: "Music bed"],
                        gains: [1: -3.5, 2: -12],
                        pans: [1: -0.3, 2: 0.45],
                        master: proposedMoves,
                        destination: DestinationCatalogue.podcast,
                        analysis: quietReport
                    ),
                    playhead: 58,
                    selectedClips: [1],
                    selectedTrack: 1
                )
            } else {
                seedEditor(
                    moves: proposedMoves,
                    destination: DestinationCatalogue.podcast,
                    analysis: quietReport,
                    playhead: 58
                )
            }
            // A known window, set before the view exists, so `adopt` in the
            // waveform's body is a no-op and `viewportUnchanged` is comparing
            // the axis rather than racing the first layout pass. See
            // `primeTimeline`'s own note.
            primeTimeline(zoom: 1, width: timelineSize.width)
            editor.setOpenPanelsForSnapshot(panels)
            editor.setModeForSnapshot(mode)
        }

        @MainActor func modeIs(_ expected: EditorMode) -> (@MainActor (NSView) -> String?) {
            { _ in
                editor.mode == expected
                    ? nil
                    : "mode is \(editor.mode.rawValue), expected \(expected.rawValue)"
            }
        }

        /// Takes the two readings a switch must not disturb.
        @MainActor func witness(_ box: ModeWitness) {
            box.document = editor.documentFingerprintForSnapshot()
            box.viewport = EditorTimeline.shared.viewport
            box.acted = true
        }

        /// The whole invariant, in one assertion, reported with enough detail
        /// to act on.
        ///
        /// Every branch names what it saw. A check that fails with "the
        /// document changed" sends the next reader back into the render to find
        /// out how; the byte counts and the two viewports do not answer that on
        /// their own either, but they say *which* of the three things moved,
        /// which is the difference between a morning and a minute.
        @MainActor func unchanged(
            _ box: ModeWitness,
            mode expected: EditorMode
        ) -> (@MainActor (NSView) -> String?) {
            { _ in
                guard box.acted else {
                    return "the action never ran, so nothing was compared — this assertion "
                        + "would have passed on an empty act"
                }
                if editor.mode != expected {
                    return "mode is \(editor.mode.rawValue), expected \(expected.rawValue)"
                }
                // The comparison itself is in `EditorDocumentFingerprint.swift`
                // rather than here, and that file's header says why: a check
                // written inside a closure only the harness can reach can only
                // be exercised by a full render, so nothing proves it is
                // capable of failing. Out there it is a pure function a
                // four-file `swiftc` run can be pointed at.
                if let complaint = EditorDocument.modeSwitchComplaint(
                    before: box.document,
                    after: editor.documentFingerprintForSnapshot()
                ) {
                    return complaint
                }
                guard let viewportBefore = box.viewport else {
                    return "no viewport was taken before the switch"
                }
                let viewportAfter = EditorTimeline.shared.viewport
                // The **time window**, and deliberately not the pane's width.
                //
                // Measured: this compared whole viewports and reported
                // "124.999…125.001 over 478.0pt, now …over 679.0pt" on a pair
                // whose two frames are pixel-for-pixel the same width. The time
                // window was identical to the last decimal; only the width
                // differed, and 679 is the correct one. The width reaches
                // `EditorTimeline` a run-loop turn *after* layout — it has to,
                // because writing it during layout is the re-entrancy crash this
                // project already paid for — so the BEFORE frame reads the
                // previous scene's width and the AFTER frame reads this one's.
                // A stale number on one side of the pair is not a mode moving a
                // waveform.
                //
                // Nothing is lost by dropping it. "Full must not move the
                // waveform" is a claim about which slice of time is under the
                // pointer, which is what these three fields are; a pane that
                // genuinely changed width would move every pixel in the
                // timeline and the transition's own comparison covers that.
                if viewportBefore.start != viewportAfter.start
                    || viewportBefore.end != viewportAfter.end
                    || viewportBefore.duration != viewportAfter.duration {
                    return "THE MODE MOVED THE TIMELINE — window was "
                        + "\(viewportBefore.start)…\(viewportBefore.end) of "
                        + "\(viewportBefore.duration)s, now "
                        + "\(viewportAfter.start)…\(viewportAfter.end) of "
                        + "\(viewportAfter.duration)s."
                }
                return nil
            }
        }

        let modeCaveat = " " + SnapshotHarness.bindingCaveat

        let toFull = ModeWitness()
        scenes += SnapshotHarness.transition(
            name: "cutting-room-mode-to-full",
            size: editorSize,
            colorScheme: .dark,
            note: "BEFORE is what everybody gets: Simple, one sound, the destination picker and "
                + "the Chain. AFTER is the same window one press later. Read the pane first — "
                + "Master is a fourth header that was not there, and the Chain's rows have "
                + "gained the chevron that opens each move's own controls. Then read the strip "
                + "under the transport, which is the selected clip's numbers and the only thing "
                + "here that costs the timeline any height. Nothing in the waveform may have "
                + "moved sideways; the assertion checks that as numbers rather than by eye."
                + modeCaveat,
            prepare: { seedMode(.simple, panels: [.destination, .chain]) },
            act: {
                witness(toFull)
                editor.setMode(.full)
            },
            assertBefore: modeIs(.simple),
            assertAfter: unchanged(toFull, mode: .full)
        ) { editorWindow() }

        let tracksToFull = ModeWitness()
        scenes += SnapshotHarness.transition(
            name: "cutting-room-mode-tracks-to-full",
            size: editorSize,
            colorScheme: .dark,
            note: "Three lanes, and this is the frame the track headers are judged on. In BOTH "
                + "frames every header carries a colour band down its leading edge — the one "
                + "thing the VEGAS screenshot gives away for free — and a level bar under its "
                + "name. AFTER adds the decibel ladder under each bar and the pan slider under "
                + "each fader. **The lanes must be the same height in both frames**: "
                + "`EditorTrackMetrics.minimumLaneHeight` reserves Full's two extra rows in "
                + "Simple as well, precisely so a mode switch cannot resize a waveform. Judge "
                + "that by laying the two frames over each other, and the time axis by the "
                + "assertion." + modeCaveat,
            prepare: { seedMode(.simple, tracks: 3, panels: [.chain]) },
            act: {
                witness(tracksToFull)
                editor.setMode(.full)
            },
            assertBefore: modeIs(.simple),
            assertAfter: unchanged(tracksToFull, mode: .full)
        ) { editorWindow() }

        // Hand-built rather than `transition(...)` or `negativeControl(...)`,
        // because it is neither: the action is real and the frames must
        // **match**. `transition` hard-codes `mustDiffer: true` and
        // `negativeControl` hard-codes an empty act, and the shape between them
        // — a real action that must come back to where it started — is the only
        // way to state idempotence as a picture. `pair(...)` is private, so the
        // two `Scene`s are written out; they are the same shape it builds.
        let roundTrip = ModeWitness()
        let roundTripCeiling = 0.0005
        let roundTripNote =
            "ROUND TRIP: Simple → Full → Simple, in one action, and the two frames must MATCH to "
            + "within 0.05% of pixels. Not a negative control — the action really runs, twice — "
            + "and not a transition, because a mode that cannot be undone exactly is a mode "
            + "nobody can safely try. The assertion is the stronger half: the document's encoded "
            + "bytes and the timeline's window are compared either side, so a switch that "
            + "dropped a pan value or refitted the zoom fails even if the pixels happen to land "
            + "back where they were." + modeCaveat
        let roundTripContent: @MainActor () -> AnyView = { editorWindow() }
        let roundTripPrepare: @MainActor () -> Void = {
            seedMode(.simple, tracks: 3, panels: [.destination, .chain])
        }
        scenes.append(
            SnapshotHarness.Scene(
                name: "cutting-room-mode-round-trip-before",
                size: editorSize,
                colorScheme: .dark,
                prepare: roundTripPrepare,
                assertOnHost: modeIs(.simple),
                note: roundTripNote,
                content: roundTripContent
            )
        )
        scenes.append(
            SnapshotHarness.Scene(
                name: "cutting-room-mode-round-trip-after",
                size: editorSize,
                colorScheme: .dark,
                prepare: {
                    roundTripPrepare()
                    SnapshotHarness.settle(seconds: 0.3)
                    witness(roundTrip)
                    editor.setMode(.full)
                    // Settled in between, so the Full state is really built and
                    // laid out rather than collapsed into one turn of the run
                    // loop with the switch back. A round trip that never
                    // reached Full proves nothing about coming home from it.
                    SnapshotHarness.settle(seconds: 0.3)
                    editor.setMode(.simple)
                    SnapshotHarness.settle(seconds: 0.3)
                },
                assertOnHost: unchanged(roundTrip, mode: .simple),
                comparison: SnapshotHarness.Comparison(
                    partner: "cutting-room-mode-round-trip-before",
                    mustDiffer: false,
                    floor: roundTripCeiling
                ),
                note: roundTripNote,
                content: roundTripContent
            )
        )

        scenes += SnapshotHarness.negativeControl(
            name: "control-editor-mode",
            size: editorSize,
            colorScheme: .dark,
            note: "Mode family. Seeded exactly as `cutting-room-mode-to-full`'s BEFORE frame is, "
                + "with the act removed. The two pairs above assert that this window differs "
                + "when the mode changes; this is the statement that it does NOT differ when "
                + "nothing changes, which is the only thing that makes them mean anything. It "
                + "also re-measures the family's noise on every run, so the 1% floor and the "
                + "round trip's 0.05% ceiling stop being a paragraph and start being a number.",
            prepare: { seedMode(.simple, panels: [.destination, .chain]) }
        ) { editorWindow() }

        return scenes
    }
}
#endif
