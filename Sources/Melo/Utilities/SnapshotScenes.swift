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
        /// frame should be.
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
            settings.appSettings = appSettings
        }

        @MainActor func scene(
            _ name: String,
            _ size: CGSize,
            _ scheme: ColorScheme = .dark,
            capture: SnapshotHarness.Capture = .layer,
            note: String? = nil,
            prepare: @escaping @MainActor () -> Void = {},
            content: @escaping @MainActor () -> AnyView
        ) -> SnapshotHarness.Scene {
            SnapshotHarness.Scene(
                name: name,
                size: size,
                colorScheme: scheme,
                capture: capture,
                prepare: {
                    applyAppearance(scheme)
                    prepare()
                },
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
                UpdatesTab(sparkle: sparkle, developerUpdates: developerUpdates)
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
        let onboardingSize = CGSize(width: 590, height: 560)
        let onboardingPrimer = FirstRunAudioPrimer(audioEngine: audioEngine)
        let onboardingPageNames = ["welcome", "audio", "keys", "analytics", "tryit"]

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
                + "Guide's button; what the button is wired to is UNVERIFIED.",
            prepare: {
                applyAppearance(.dark)
                audioSectionTarget = nil
            },
            act: {
                audioSectionTarget = guideTarget(entryID: "system-sounds", serial: 1)
            }
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
                    + "the pane. Volume and Calls should be scrolled off above it."
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

        return scenes
    }
}
#endif
