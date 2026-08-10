#if MELO_DEV
import AppKit
import SwiftUI

/// Offscreen render harness for reviewing Melo's UI without a screen-recording
/// grant.
///
/// `screencapture` and `CGWindowListCreateImage` both require Screen Recording
/// permission, and a menu-bar-only (`LSUIElement`) app cannot be added to the
/// automation allowlist that would let an agent drive it. Neither path is
/// available in review, so visual claims about this app were previously made
/// without ever looking at it — which is how a guided tour shipped pointing at
/// the wrong controls.
///
/// This renders the real view hierarchy, with the real engine and the real
/// coordinators, into a window that is drawn but never composited to a display,
/// then writes each frame to a PNG via `cacheDisplay(in:to:)`. No permission is
/// involved because nothing is read back off the screen.
///
/// ## What this cannot capture, and what the frames now say about it
///
/// `cacheDisplay` captures the layer tree, not the window server's composite,
/// so `NSVisualEffectView` backdrops (`.regularMaterial`, `.ultraThinMaterial`,
/// `.darkGlassBackground()`) render flat rather than blurred, and a window that
/// is never key gets desaturated accent tint. Two agents have now reported
/// deliberate design as a defect after reading a frame without the caveat, so
/// **the caveat is stamped into every frame** as a band along the bottom edge
/// rather than left in a document nobody has to open. A per-scene note is
/// appended to that caveat, never substituted for it. Judge layout, geometry,
/// spotlight and pointer placement, clipping, iconography, and type from these
/// images. Do not judge blur radius, translucency, vibrancy, or tint saturation.
///
/// ### `glassEffect` takes its content with it
///
/// `.meloGlassSurface(...)` (`VisualEffectBackground.swift`) resolves to
/// SwiftUI's `.glassEffect(_:in:)` on macOS 26. Unlike a material, which loses
/// only its backdrop, a glass surface is rendered entirely by the window
/// server: **its content is absent from the capture as well.** Melo's popup
/// header — the Melo mark, the audio-status dot, the Audio disclosure, the
/// Output/Input toggle, ⌘K, edit-priority and the Settings gear — is one glass
/// island (`MenuBarPopupView.swift:515`, the only call site in `Sources/`), and
/// it had never appeared in a single frame across two runs. Measured on
/// `popup-dark.png`, the hole is 89 points tall at the top edge. It did not
/// look broken; it looked *empty*, which reads as evidence of absence.
///
/// Two things now stop that recurring:
///
/// 1. `Scene.capture = .imageRenderer` rasterizes through SwiftUI's own
///    `ImageRenderer` instead of reading back a layer. It never consults the
///    window server, so glass content it can draw at all, it draws.
/// 2. Every frame is scanned for featureless horizontal bands and the results
///    are named in the provenance band. A whole missing region says so on the
///    artifact.
///
/// The modifier's `accessibilityReduceTransparency` branch — which fills
/// opaquely and would composite fine — is **not** reachable from here:
/// `\.accessibilityReduceTransparency` is a read-only key path, so
/// `.environment(...)` will not compile against it, and the only other way in
/// is the system-wide setting, which is the user's and not this harness's.
///
/// `accessibilityReduceMotion` is absent for the same reason. Motion behaviour
/// is read from source, not captured.
///
/// **Dynamic Type is deliberately not a parameter.** It used to be one, and it
/// did nothing: `.environment(\.dynamicTypeSize, .accessibility3)` leaves every
/// frame typographically identical to the default because Melo sizes its type
/// with fixed `NSFont`/`.system(size:)` values that macOS does not scale. Two
/// frames and every large-text claim built on them were false. A parameter that
/// silently does nothing is worse than an absent one, so it is absent. Large
/// text on this app is **unverified** and cannot be exercised from here.
@MainActor
enum SnapshotHarness {
    /// Set `MELO_SNAPSHOT_DIR=/path` to run the harness instead of the app.
    private static let directoryKey = "MELO_SNAPSHOT_DIR"

    /// Fault injection, for proving the completion sentinel actually works.
    /// Set `MELO_SNAPSHOT_FAIL_AFTER=<n>` and the harness exits after writing
    /// `n` frames and *without* writing the sentinel — exactly what a crash
    /// halfway through a render looks like from outside. `dev-verify-locked.sh`
    /// must reject that output rather than consume it, and this is how that is
    /// demonstrated on demand instead of by racing a `kill` against a build.
    private static let failAfterKey = "MELO_SNAPSHOT_FAIL_AFTER"

    /// Set `MELO_AX_DWELL=<scene name>[,<scene name>...]` and, after the last
    /// frame is written, the harness rebuilds those scenes one at a time and
    /// **holds each window up** instead of exiting, so a separate process can
    /// interrogate them over the accessibility API. See
    /// `dwellForAccessibilityCheck`.
    private static let axDwellKey = "MELO_AX_DWELL"

    /// Longest the harness will hold one accessibility window open waiting for
    /// its `_ax_done`. Generous, because the checker compiles itself first;
    /// bounded, because a checker that never starts must not leave a Melo
    /// process alive in every future `dev-verify` run on this machine.
    ///
    /// Per scene, not per run. Only the first scene of a dwell list can wait on
    /// a checker that has not started yet; by the second, the checker is warm
    /// and the real wait is milliseconds.
    private static let axDwellTimeout: TimeInterval = 120

    /// Both the `AXIdentifier` and the `AXTitle` of the dwell window, so
    /// `scripts/ax-check.sh` scans that window and not whatever else this app
    /// happens to have open. Duplicated as a literal there; a mismatch is
    /// reported by the checker rather than silently widening the scan.
    static let axDwellWindowMarker = "melo-ax-dwell"

    /// Shortest featureless band, in points, worth naming on the frame.
    ///
    /// 48 rather than 16: at 16 the detector named ordinary padding between
    /// cards — `updates-failed-signature` reported five regions, none of them
    /// missing anything — and a warning that fires on every frame is one nobody
    /// reads. The glass header hole is 89 points, so the signal survives.
    private static let blankBandThreshold: CGFloat = 48

    /// Fraction of pixels that must change for a transition to count as having
    /// done something.
    ///
    /// **Not zero, and this is the whole point.** The guided tour draws a
    /// pointer with a pulsing halo, so two captures of the same state taken
    /// 0.6s apart are never byte-identical. Measured on this tree: a no-op
    /// action on `tour-skip` moved 2993 of 2054400 pixels (0.146%), and on
    /// `tour-finish` 2528 (0.123%) — all of it halo phase, and the run went
    /// green. An exact-identity check therefore could not fire on the two
    /// scenes it existed for. Real changes are nothing like that small: the
    /// same two transitions performed for real move 93% of the frame.
    ///
    /// The floor is only trustworthy because `negativeControl(...)` measures
    /// each scene family's actual noise against it on every run. If animation
    /// noise ever climbs past this, the negative control goes red and says the
    /// dead-button check has stopped working for that family — rather than the
    /// check quietly passing everything forever.
    ///
    /// Set from measurement, not taste. Idle noise measured per family over
    /// several runs on this tree: popup 0.0000%, Updates tab 0.0000%, menu bar
    /// mark 0.0000%. Smallest real change in the set: the update badge
    /// appearing, at 1.6709%. 1% sits between the two.
    ///
    /// Two families are animated and get their own floor at the call site
    /// rather than being squeezed under this one — see `Comparison.floor`. A
    /// single global number would either flake on them or go blind on the
    /// quiet families, and a threshold that flakes gets raised until it means
    /// nothing.
    private static let changeThreshold = 0.01

    /// Guided tour: an unbroken pointer halo. Idle noise ranged 0.1252%–0.6358%
    /// across runs; real changes are 49.8%–93.3%. Nothing lives between.
    static let animatedFloor = 0.05

    /// `ImageRenderer` frames draw the themed backdrop — a starfield whose
    /// timeline runs whether or not the popup is on screen, and which no layer
    /// capture contains. Idle noise reached 0.9858%, which would have flaked
    /// against the 1% default. `MenuBarPopupView.isPopupVisible` is `@State`
    /// and private, so the animation cannot be stilled from here.
    static let imageRendererFloor = 0.03

    /// How a frame is rasterized.
    enum Capture {
        /// `NSHostingView.cacheDisplay(in:to:)` — the real AppKit layer tree,
        /// with the real coordinators behind it. The default, and the only path
        /// that sees `NSViewRepresentable` content.
        case layer
        /// SwiftUI's own `ImageRenderer`. Draws the view tree directly instead
        /// of reading back a layer, so it does not depend on the window server
        /// and is the only route with any chance at content inside a
        /// `glassEffect` island. It cannot draw `NSViewRepresentable` content
        /// at all, so it is a supplement to a layer capture, never a swap.
        case imageRenderer
    }

    /// What a frame must prove about the frame it is paired with.
    struct Comparison {
        let partner: String
        /// `true` for a transition: the action must have changed something.
        /// `false` for a negative control: nothing was done, so nothing beyond
        /// this family's animation noise may have moved.
        let mustDiffer: Bool
        /// The dividing line for this family, as a fraction of pixels. Both
        /// sides of a family use the same number, so a negative control passing
        /// is exactly the statement that a dead action would fail.
        let floor: Double
    }

    /// One frame to render.
    struct Scene {
        let name: String
        let size: CGSize
        var colorScheme: ColorScheme = .dark

        /// Which rasterizer produces the frame. See `Capture`.
        var capture: Capture = .layer

        /// Runs on the main actor before the frame is built, then the run loop
        /// is spun. Used to advance the tour, set an update state, or otherwise
        /// put the shared coordinators into the state this frame is meant to
        /// show.
        var prepare: @MainActor () -> Void = {}

        /// Runs against the live hosting view, after layout has settled and
        /// before the capture. Used by `negativeControl` to dwell for the same
        /// span a real transition does, so the noise it measures is the noise a
        /// real transition is measured against.
        ///
        /// This was going to be where a transition pressed a real control, so
        /// that emptying a button's action would be caught rather than papered
        /// over by a coordinator call. **It does not work here.** Walking
        /// `accessibilityChildren()` from the hosting view of this offscreen,
        /// never-key window returns nothing at all — the failure text was
        /// literally "The tree exposed no named elements", for "Skip Tour",
        /// "Finish" and "Back" alike, so `accessibilityPerformPress()` has
        /// nothing to send. AppKit builds SwiftUI's accessibility tree lazily
        /// for an attached assistive client, and there isn't one. Forcing it
        /// means private API in a harness other agents depend on, which is a
        /// worse trade than saying so.
        var actOnHost: (@MainActor (NSView) -> Void)?

        /// Asked of the live hosting view after layout and before the capture.
        /// Returns `nil` when the view is in the state the scene claims, or the
        /// sentence to fail the run with when it is not.
        ///
        /// A pixel percentage cannot distinguish "the pane scrolled to the
        /// section the reader asked for" from "the pane changed somehow", and
        /// the two `settings-audio-guide-*` scenes have been failing on exactly
        /// that difference with no number to show for it. This reads the state
        /// itself. Unlike `actOnHost` it does not need an accessibility tree,
        /// which is why it works where pressing a real control does not.
        var assertOnHost: (@MainActor (NSView) -> String?)?

        /// The frame this one is measured against. See `Comparison`.
        var comparison: Comparison?

        /// Appended to the standard caveat in the provenance band.
        var note: String?

        /// Built **after** `prepare` has run and the run loop has settled, so a
        /// scene may capture state that only exists once an action has been
        /// performed — an `NSImage` a coordinator just rewrote, for instance.
        let content: @MainActor () -> AnyView
    }

    /// A pair of frames around one action: the state before, and the state the
    /// action actually produced.
    ///
    /// Prefer the `press:` form. `act` is for changes no control can make from
    /// inside a rendered hierarchy — an update arriving over the network, say.
    ///
    /// `act` runs **before** `content` is built, because a scene may read what
    /// the action produced while constructing its view: the menu bar frames
    /// read `NSStatusBarButton.image`, so an action performed after the view
    /// existed changed nothing in it and the transition measured 0.0000%.
    static func transition(
        name: String,
        size: CGSize,
        colorScheme: ColorScheme = .dark,
        capture: Capture = .layer,
        floor: Double = changeThreshold,
        note: String? = nil,
        prepare: @escaping @MainActor () -> Void = {},
        act: @escaping @MainActor () -> Void,
        assertBefore: (@MainActor (NSView) -> String?)? = nil,
        assertAfter: (@MainActor (NSView) -> String?)? = nil,
        content: @escaping @MainActor () -> AnyView
    ) -> [Scene] {
        pair(
            name: name,
            size: size,
            colorScheme: colorScheme,
            capture: capture,
            floor: floor,
            note: note,
            prepare: prepare,
            act: act,
            mustDiffer: true,
            assertBefore: assertBefore,
            assertAfter: assertAfter,
            content: content
        )
    }

    /// The one shape both a transition and its negative control are built from,
    /// so the control measures the same thing a dead action would.
    private static func pair(
        name: String,
        size: CGSize,
        colorScheme: ColorScheme,
        capture: Capture,
        floor: Double,
        note: String?,
        prepare: @escaping @MainActor () -> Void,
        act: @escaping @MainActor () -> Void,
        mustDiffer: Bool,
        assertBefore: (@MainActor (NSView) -> String?)? = nil,
        assertAfter: (@MainActor (NSView) -> String?)? = nil,
        content: @escaping @MainActor () -> AnyView
    ) -> [Scene] {
        [
            Scene(
                name: "\(name)-before",
                size: size,
                colorScheme: colorScheme,
                capture: capture,
                prepare: prepare,
                assertOnHost: assertBefore,
                note: note,
                content: content
            ),
            Scene(
                name: "\(name)-after",
                size: size,
                colorScheme: colorScheme,
                capture: capture,
                prepare: {
                    prepare()
                    settle(seconds: 0.3)
                    act()
                    settle(seconds: 0.3)
                },
                assertOnHost: assertAfter,
                comparison: Comparison(
                    partner: "\(name)-before",
                    mustDiffer: mustDiffer,
                    floor: floor
                ),
                note: note,
                content: content
            )
        ]
    }

    /// The caveat every coordinator-driven transition carries, because the
    /// thing it does not prove is the thing that shipped broken once already.
    static let bindingCaveat = "The action is a coordinator call, not a press of the "
        + "control: emptying the button's own action would leave this frame unchanged. "
        + "What the button is wired to is UNVERIFIED."

    /// A transition whose action is empty, expected to come back unchanged.
    ///
    /// The dead-button check is a measurement, and a measurement with no known
    /// noise floor is not a measurement. This renders one of these per scene
    /// family and **fails the run when the two frames differ by more than the
    /// threshold** — which is what tells you the family is quiet enough for the
    /// transitions above it to mean anything. Without it, a family whose frames
    /// always differ passes every transition forever, which is exactly what the
    /// guided-tour family did.
    ///
    /// It goes through `pair` with `act: {}`, deliberately: an *approximate*
    /// analogue would not do. A first version dwelled on the rendered view
    /// instead of running the same prepare-time path, and it read 0.1491% on
    /// the guided-tour family in the same run that a genuinely dead
    /// `tour-back` read 0.6358% — so it was calibrating against a number no
    /// dead button would ever produce. This is bit-for-bit the code path a
    /// dead action takes, differing only in expectation.
    static func negativeControl(
        name: String,
        size: CGSize,
        colorScheme: ColorScheme = .dark,
        capture: Capture = .layer,
        ceiling: Double = changeThreshold,
        note: String? = nil,
        prepare: @escaping @MainActor () -> Void = {},
        content: @escaping @MainActor () -> AnyView
    ) -> [Scene] {
        let explanation = "NEGATIVE CONTROL: the action between these two frames is empty. "
            + "They must match to within \(String(format: "%.2f", ceiling * 100))% of "
            + "pixels, or a dead control in this family could not be detected."
        return pair(
            name: name,
            size: size,
            colorScheme: colorScheme,
            capture: capture,
            floor: ceiling,
            note: (note.map { $0 + " " } ?? "") + explanation,
            prepare: prepare,
            act: {},
            mustDiffer: false,
            content: content
        )
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[directoryKey] != nil
    }

    // MARK: - Run

    /// Renders every scene and terminates the process. Called instead of, not
    /// alongside, normal startup — the app is a menu-bar agent and would
    /// otherwise sit running with no way for a script to end it.
    /// Held for the whole run. Without it this process is a background,
    /// windowless, silent `.accessory` app, which is precisely what App Nap
    /// exists to throttle — and a throttled run loop produces frames that are
    /// wrong rather than frames that are missing.
    ///
    /// This is a belt, not a diagnosis: App Nap has not been *shown* to be
    /// behind the `settings-audio-guide-*` flake. It is cheap, it cannot change
    /// what any frame contains on a machine where App Nap was never going to
    /// engage, and the turns-per-second line above will say whether it mattered.
    private static var activity: NSObjectProtocol?

    static func run(_ scenes: [Scene]) -> Never {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "rendering snapshot frames"
        )

        guard let path = ProcessInfo.processInfo.environment[directoryKey] else {
            FileHandle.standardError.write(Data("\(directoryKey) not set\n".utf8))
            exit(2)
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(
                Data("cannot create \(path): \(error)\n".utf8)
            )
            exit(2)
        }

        let failAfter = ProcessInfo.processInfo.environment[failAfterKey].flatMap(Int.init)

        // Raw pixel buffers are ~9MB each, so only the frames something is
        // actually measured against are kept.
        let partners = Set(scenes.compactMap { $0.comparison?.partner })
        var retained: [String: Data] = [:]

        var failures = 0
        for (index, scene) in scenes.enumerated() {
            if let failAfter, index >= failAfter {
                fail(
                    "\(failAfterKey)=\(failAfter): stopping before \(scene.name) "
                    + "with no completion sentinel. This is fault injection."
                )
                writeLogs(to: directory)
                exit(3)
            }

            guard let frame = render(scene) else {
                fail("render failed \(scene.name)")
                failures += 1
                continue
            }

            if let comparison = scene.comparison {
                if compare(scene: scene, comparison: comparison, pixels: frame.pixels, retained: retained) {
                    failures += 1
                }
            }
            if partners.contains(scene.name) {
                retained[scene.name] = frame.pixels
            }

            let destination = directory.appendingPathComponent("\(scene.name).png")
            do {
                try frame.png.write(to: destination)
                print("wrote \(destination.path)")
            } catch {
                fail("write failed \(scene.name): \(error)")
                failures += 1
            }
        }

        // Written before the sentinel so it is present on a run that fails.
        // Measured baseline on this machine: 241.8 turns/s over a 296s render.
        // The loop returns as soon as a source is serviced rather than sitting
        // out its 0.02s, so a healthy rate is several times the nominal 50/s —
        // materially below that baseline is a throttled loop, and App Nap
        // throttling this process is the one suspect left for the
        // `settings-audio-guide-*` flake that has not been refuted.
        measurements.append(
            String(
                format: "run loop: %d turns over %.1fs asked for (%.1f turns/s)",
                settleTurns, settleSeconds,
                settleSeconds > 0 ? Double(settleTurns) / settleSeconds : 0
            )
        )
        writeLogs(to: directory)

        // A completion sentinel, written last and only here. Without it the only
        // way to tell a finished run from a run that died halfway is to watch
        // the file count stop changing — which is also exactly what a crash
        // looks like, so a partial render reported itself as success.
        let sentinel = directory.appendingPathComponent("_complete")
        try? Data(
            "\(scenes.count - failures - assertionFailures)/\(scenes.count)\n".utf8
        ).write(to: sentinel)

        print("snapshots: \(scenes.count - failures)/\(scenes.count) written to \(path)")

        // After the sentinel, deliberately. The frames are the expensive part
        // of this run and every consumer of them keys off `_complete`; a dwell
        // that hung, or an accessibility checker that failed, must not be able
        // to retract a render that already happened.
        dwellForAccessibilityCheck(scenes, directory: directory)

        exit(failures == 0 && assertionFailures == 0 ? 0 : 1)
    }

    // MARK: - Accessibility dwell

    /// Holds one scene's window up so `scripts/ax-check.sh` can drive it.
    ///
    /// ## Why a dwell at all
    ///
    /// Every accessibility claim in this app was checked by grepping source for
    /// a modifier, which stays green when the modifier is present and wired to
    /// nothing — the exact failure the project anchor names last. Actually
    /// performing an `accessibilityAdjustableAction` and watching the spoken
    /// value move is the only check that can tell those apart, and it is
    /// possible only from outside the process. Measured, in this order:
    ///
    /// * `NSHostingView.accessibilityChildren()` from in here returns a single
    ///   empty `AXGroup`. AppKit builds the SwiftUI element tree lazily, for an
    ///   attached assistive client, and this process is not one.
    /// * `AXUIElementCreateApplication(getpid())` — asking oneself — is refused
    ///   outright with `kAXErrorCannotComplete` (-25208).
    /// * The same call from a *separate* process works, against a bundled
    ///   `.app`, on a window that has been `orderFrontRegardless()`n. It does
    ///   not need to be visible, on screen, or key.
    ///
    /// So the missing piece was never the checker. It was that this harness
    /// renders and exits, leaving no window for anyone to ask about. This is
    /// that window: the real scene, staged by the same `stage(_:)` a frame goes
    /// through, held open on a pid the checker is handed directly.
    ///
    /// The handshake is two files in the snapshot directory — `_ax_ready`
    /// carries the pid, `_ax_done` is the checker saying it has finished — and
    /// a hard timeout, because a checker that never starts must not strand a
    /// Melo process on this machine forever.
    private static func dwellForAccessibilityCheck(_ scenes: [Scene], directory: URL) {
        guard let raw = ProcessInfo.processInfo.environment[axDwellKey], !raw.isEmpty else {
            return
        }
        let names = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Every name is resolved before any of them is dwelled, and one bad
        // name abandons the whole phase rather than being skipped.
        //
        // A dwell list that silently dropped an unmatched name is the quietest
        // way this gate could stop covering something: the scene it named would
        // simply stop being checked, every remaining assertion would still pass,
        // and the run would be green. Renaming a scene in `SnapshotScenes.swift`
        // is an ordinary edit for someone who has never read this file, so that
        // is not a hypothetical.
        let resolved = names.map { name in (name, scenes.first { $0.name == name }) }
        let missing = resolved.filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty else {
            try? Data(
                ("\(axDwellKey) names no scene that exists: \(missing.joined(separator: ", ")). "
                 + "Nothing was dwelled and nothing was checked — fix the name or the scene "
                 + "list, do not ignore this.\n").utf8
            ).write(to: directory.appendingPathComponent("_ax_error"))
            return
        }

        for scene in resolved.compactMap(\.1) {
            dwell(scene, directory: directory)
        }
    }

    /// Holds one scene's window up and waits for the checker to release it.
    ///
    /// The handshake is per scene — `_ax_ready_<name>` carries the pid,
    /// `_ax_done_<name>` is the checker saying it has finished with that one.
    /// Per-scene filenames rather than one pair reused: with a single pair, the
    /// gap between deleting the last scene's `_ax_ready` and writing the next
    /// one is a window in which the checker reads a stale file and interrogates
    /// the wrong scene, and it would do it silently.
    ///
    /// A bare `_ax_done`, with no scene suffix, releases whatever scene is
    /// waiting. `dev-verify-locked.sh` writes exactly that from its EXIT trap,
    /// so an early exit anywhere in that script cannot strand this process
    /// holding a window for the full timeout.
    private static func dwell(_ scene: Scene, directory: URL) {
        let ready = directory.appendingPathComponent("_ax_ready_\(scene.name)")
        let done = directory.appendingPathComponent("_ax_done_\(scene.name)")
        let abort = directory.appendingPathComponent("_ax_done")
        try? FileManager.default.removeItem(at: ready)
        try? FileManager.default.removeItem(at: done)

        scene.prepare()
        settle(seconds: 0.35)
        let (window, host, _) = stage(scene)
        // Same teardown as `render`, for the same reason. Only a handful of
        // scenes are ever dwelled, so this leaks a handful of graphs rather than
        // a hundred and fifty — but it is the identical bug in the identical
        // shape, and leaving one instance of it in this file would invite the
        // next reader to conclude the pattern is fine.
        defer {
            window.close()
            window.contentView = nil
        }

        // A name for the checker to aim at. Rendering a scene can leave other
        // windows of this app standing — `What's New in Melo` was in the first
        // tree ever dumped — and every element in one is noise the assertions
        // would have to be written around. Marking the window means the scan is
        // exactly the scene, and stays exactly the scene when someone adds a
        // frame that opens a window.
        window.setAccessibilityIdentifier(axDwellWindowMarker)
        window.title = axDwellWindowMarker

        // A second layout pass and a longer settle than a capture gets. A frame
        // only needs the pixels to be final; the accessibility tree is built on
        // demand from the view hierarchy, and the checker attaches to whatever
        // exists at the moment it asks.
        host.layoutSubtreeIfNeeded()
        settle(seconds: 1.0)

        try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: ready)

        // Spinning the run loop is not idling: the accessibility API delivers
        // to this process on the main thread, so a `sleep` here would leave
        // every request from the checker unanswered.
        //
        // The window is re-ordered on every pass, and that is the fix for a
        // race that made this gate lie. Something in this app orders the dwell
        // window out a few seconds after it goes up — measured by the gap
        // between `_ax_ready` and the checker's tree dump across runs: at 1s,
        // 1s and 6s the tree was the scene, and at 7s and 16s the app had zero
        // windows and the checker walked into macOS's menu bar instead. Which
        // code path does it is NOT established; what is established is that
        // holding the window is not something this loop can assume it has
        // already done once. Re-asserting is cheap, invisible at
        // (-30000, -30000), and does not depend on ever finding the culprit.
        let deadline = Date().addingTimeInterval(axDwellTimeout)
        while Date() < deadline,
              !FileManager.default.fileExists(atPath: done.path),
              !FileManager.default.fileExists(atPath: abort.path) {
            if !window.isVisible {
                window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            }
            window.orderFrontRegardless()
            settle(seconds: 0.25)
        }
    }

    /// Returns `true` when the comparison failed.
    private static func compare(
        scene: Scene,
        comparison: Comparison,
        pixels: Data?,
        retained: [String: Data]
    ) -> Bool {
        guard let pixels else {
            fail("\(scene.name): no pixel buffer, so its comparison could not be made")
            return true
        }
        guard let before = retained[comparison.partner] else {
            fail("\(scene.name) is measured against \(comparison.partner), which was not rendered")
            return true
        }
        guard let moved = changedFraction(before, pixels) else {
            fail("\(scene.name): pixel buffers are not comparable with \(comparison.partner)")
            return true
        }

        let percent = String(format: "%.4f%%", moved * 100)
        let floor = String(format: "%.4f%%", comparison.floor * 100)
        measurements.append(
            String(
                format: "%@ vs %@: %@ of pixels moved (floor %@) — %@",
                scene.name,
                comparison.partner,
                percent,
                floor,
                comparison.mustDiffer ? "must exceed" : "must stay under"
            )
        )

        if comparison.mustDiffer, moved < comparison.floor {
            fail(
                "TRANSITION HAD NO EFFECT — \(scene.name) differs from \(comparison.partner) "
                + "by only \(percent), under the \(floor) floor. The action changed nothing."
            )
            return true
        }
        if !comparison.mustDiffer, moved >= comparison.floor {
            fail(
                "NEGATIVE CONTROL MOVED — \(scene.name) differs from \(comparison.partner) "
                + "by \(percent) with no action performed at all, over the \(floor) floor. "
                + "Frames in this family are not stable enough for the dead-button check "
                + "to fire on them; a control that stopped working here would pass."
            )
            return true
        }
        return false
    }

    /// Fraction of pixels differing between two same-shaped buffers.
    private static func changedFraction(_ lhs: Data, _ rhs: Data) -> Double? {
        guard lhs.count == rhs.count, lhs.count >= 4 else { return nil }
        let total = lhs.count / 4
        var changed = 0
        lhs.withUnsafeBytes { (left: UnsafeRawBufferPointer) in
            rhs.withUnsafeBytes { (right: UnsafeRawBufferPointer) in
                var offset = 0
                while offset + 4 <= left.count {
                    var differs = false
                    var channel = 0
                    while channel < 4 {
                        if left[offset + channel] != right[offset + channel] {
                            differs = true
                            break
                        }
                        channel += 1
                    }
                    if differs {
                        changed += 1
                    }
                    offset += 4
                }
            }
        }
        return Double(changed) / Double(total)
    }

    // MARK: - Logs

    /// The harness is launched with `open -n`, so its stderr goes to the system
    /// log and not to the terminal running `dev-verify.sh`. Every reason a
    /// scene failed was therefore written somewhere nobody looks.
    private static var failureLog: [String] = []
    /// Counted separately from render and comparison failures because a scene
    /// whose frame is perfectly good can still be showing the wrong thing.
    private static var assertionFailures = 0
    /// Every comparison's measured number, failing or not, so the threshold's
    /// margins are auditable on a green run rather than only on a red one.
    private static var measurements: [String] = []

    private static func fail(_ message: String) {
        failureLog.append(message)
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func writeLogs(to directory: URL) {
        write(failureLog, to: directory.appendingPathComponent("_failures.log"))
        write(measurements, to: directory.appendingPathComponent("_transitions.log"))
    }

    private static func write(_ lines: [String], to destination: URL) {
        guard !lines.isEmpty else {
            try? FileManager.default.removeItem(at: destination)
            return
        }
        try? Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: destination)
    }

    // MARK: - Rendering

    /// Everything up to and including a settled, laid-out hosting view in a
    /// window the window server believes is on screen.
    ///
    /// Extracted rather than duplicated because the accessibility dwell has to
    /// be *the same* window as a rendered frame, not a lookalike: AppKit only
    /// materialises SwiftUI's accessibility tree for a window that has been
    /// ordered front, and a second, subtly different staging path would make
    /// "the checker saw it" and "the frames show it" two different claims.
    private static func stage(_ scene: Scene) -> (window: NSWindow, host: NSView, root: AnyView) {
        let frame = NSRect(origin: .zero, size: scene.size)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(
            named: scene.colorScheme == .dark ? .darkAqua : .aqua
        )
        window.isOpaque = true
        window.backgroundColor = backing(scene.colorScheme)
        // `NSWindow` created this way defaults to releasing itself on close, so
        // anything that closes it drops the last reference and the local here
        // becomes a dangling object. The accessibility dwell has to be able to
        // re-order a window that something else took away, which means the
        // window has to still exist to be re-ordered.
        window.isReleasedWhenClosed = false

        let root = AnyView(
            scene.content()
                .environment(\.colorScheme, scene.colorScheme)
                .frame(width: scene.size.width, height: scene.size.height)
        )

        let host = NSHostingView(rootView: root)
        host.frame = frame
        window.contentView = host

        // Drawn, but positioned far off any display's bounds: SwiftUI needs a
        // window that believes it is visible to run a full layout pass, and
        // `orderOut` gives an empty capture.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()

        // Preference keys, anchor bounds, and `.onGeometryChange` feedback all
        // settle on a later pass than the first, so a single synchronous render
        // captures a half-laid-out frame. Spinning the run loop lets those
        // settle; the guided tour overlay in particular positions its card from
        // a measured height that does not exist on pass one.
        settle(seconds: 0.65)
        host.layoutSubtreeIfNeeded()
        settle(seconds: 0.25)

        return (window, host, root)
    }

    private static func render(_ scene: Scene) -> (png: Data, pixels: Data?)? {
        scene.prepare()
        // Coordinators that react to the prepared state do so on a later turn
        // of the run loop — `SparkleUpdateController.$updateReminder` is
        // delivered `.receive(on: RunLoop.main)`, for one — so a `content`
        // closure that reads what a coordinator produced needs the loop spun
        // before it is built, not only before the capture.
        settle(seconds: 0.35)

        let (window, host, root) = stage(scene)

        // The action goes here rather than in `prepare` so it can reach the
        // rendered hierarchy and press a control in it.
        if let act = scene.actOnHost {
            act(host)
            host.layoutSubtreeIfNeeded()
            settle(seconds: 0.35)
        }

        if let assertion = scene.assertOnHost, let complaint = assertion(host) {
            fail("\(scene.name): \(complaint)")
            assertionFailures += 1
        }

        // `contentView = nil` as well as `close()`, and the second half is the
        // load-bearing one.
        //
        // `isReleasedWhenClosed` is false — the accessibility dwell needs a
        // window something else may have ordered out to still exist — so closing
        // one keeps its `contentView`, and the `NSHostingView` in it stays alive
        // with its whole SwiftUI graph. Those graphs are still subscribed:
        // `EditorStore.shared`, `EditorTimeline.shared`, `SettingsManager`,
        // every coordinator a scene touches. By the hundred and fiftieth frame a
        // single `prepare()` was invalidating around a hundred and fifty stale
        // view graphs at once.
        //
        // Measured: three runs of the same binary died at scenes 149, 150 and
        // 152 — a monotonically advancing death point is the signature of a race
        // whose odds rise with each leaked graph rather than of a bad scene, and
        // this is where the graphs came from.
        //
        // **This is not the crash and fixing it does not fix the crash.** The
        // cause is a `@Published` write dispatched inside `NSHostingView.layout()`
        // and it belongs to the view that does it. Said plainly because a harness
        // change that makes a real bug stop reproducing is the worst outcome
        // available here. It is done anyway for a reason that stands on its own:
        // a hundred and fifty live view graphs all observing the same two
        // singletons is not a condition any user's machine will ever be in, so
        // every frame after the first hundred was being rendered under conditions
        // the product does not have. That is a measurement problem whether or not
        // anything ever crashes.
        defer {
            window.close()
            window.contentView = nil
        }

        let rep: NSBitmapImageRep
        switch scene.capture {
        case .layer:
            guard let layerRep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return nil
            }
            host.cacheDisplay(in: host.bounds, to: layerRep)
            rep = layerRep
        case .imageRenderer:
            // The window above is still built and settled: `ImageRenderer` runs
            // no `onAppear` and no layout feedback of its own, so a view whose
            // state is established by the hosting pass has to have had one.
            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            renderer.isOpaque = false
            guard let image = renderer.nsImage,
                  let data = image.tiffRepresentation,
                  let rendered = NSBitmapImageRep(data: data) else {
                return nil
            }
            rendered.size = scene.size
            rep = rendered
        }

        guard let png = band(rep, scene: scene) else { return nil }
        return (png, rawPixels(rep))
    }

    /// A copy of the bitmap's own bytes, for comparing two frames.
    private static func rawPixels(_ rep: NSBitmapImageRep) -> Data? {
        guard !rep.isPlanar, rep.samplesPerPixel == 4, let bytes = rep.bitmapData else {
            return nil
        }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    // MARK: - Provenance band

    /// Composites the captured bitmap above a band that says, on the artifact
    /// itself, what the artifact is and what it cannot show. Every previous
    /// false finding from this harness came from someone reading a frame
    /// without the caveat that travels separately from it.
    private static func band(_ rep: NSBitmapImageRep, scene: Scene) -> Data? {
        let width = max(scene.size.width, 1)
        let height = max(scene.size.height, 1)
        let scale = max(CGFloat(rep.pixelsWide) / width, 1)

        let paragraph = NSMutableParagraphStyle()
        // Wrapping, not truncation. Truncation cut the explanatory half of
        // every sentence that mattered — a frame that ended at "Either
        // genuinely empty" told the reader nothing at all.
        paragraph.lineBreakMode = .byWordWrapping

        let lines = bandLines(rep, scene: scene, paragraph: paragraph)
        let textWidth = width - 16
        let heights = lines.map { line in
            ceil(
                line.boundingRect(
                    with: NSSize(width: textWidth, height: 400),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
            )
        }
        let bandHeight = max(40, heights.reduce(0, +) + CGFloat(lines.count) * 3 + 10)
        let outHeight = height + bandHeight

        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((width * scale).rounded()),
            pixelsHigh: Int((outHeight * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        out.size = NSSize(width: width, height: outHeight)

        guard let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // AppKit's origin is bottom-left, so the band is at y = 0 and the
        // capture sits above it.
        let content = NSRect(x: 0, y: bandHeight, width: width, height: height)
        rep.draw(in: content)

        // The capture is of the *hosting view*, not the window, so the window's
        // opaque backing colour is not in it, and every pixel the view did not
        // paint itself comes back fully transparent — which is most of a popup
        // frame, because the popup's background is the material the layer
        // capture drops. Those frames were not "flat"; they were empty, and a
        // PNG with a transparent body reads as white in every viewer, so the
        // app's white dark-mode text landed on white and `popup-dark.png` was a
        // page with no words on it for two entire runs.
        //
        // `destinationOver` paints only where nothing was painted, so it fills
        // in the missing base without touching a single captured pixel.
        context.compositingOperation = .destinationOver
        backing(scene.colorScheme).setFill()
        content.fill()

        context.compositingOperation = .sourceOver
        NSColor(calibratedRed: 0.42, green: 0.06, blue: 0.09, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: bandHeight).fill()

        var cursor = bandHeight - 5
        for (line, lineHeight) in zip(lines, heights) {
            cursor -= lineHeight
            line.draw(
                with: NSRect(x: 8, y: cursor, width: textWidth, height: lineHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            cursor -= 3
        }

        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    }

    private static func bandLines(
        _ rep: NSBitmapImageRep,
        scene: Scene,
        paragraph: NSParagraphStyle
    ) -> [NSAttributedString] {
        let identity = String(
            format: "%@ · %.0f×%.0fpt · %@%@",
            scene.name,
            scene.size.width,
            scene.size.height,
            scene.colorScheme == .dark ? "dark" : "light",
            scene.capture == .imageRenderer ? " · SwiftUI ImageRenderer (not a layer capture)" : ""
        )

        // The note is appended, never substituted. It used to replace this, so
        // the frames carrying a note — the AutoEQ fixtures and the menu bar
        // mark — were layer captures whose bands never mentioned materials at
        // all, in a harness whose doc comment claimed every frame was stamped.
        var caveat = "cacheDisplay layer capture — material blur, translucency, vibrancy and "
            + "accent tint are NOT composited. Do not judge them here."
        if scene.capture == .imageRenderer {
            caveat = "SwiftUI ImageRenderer — no window-server compositing, and no "
                + "NSViewRepresentable content at all."
        }
        if let note = scene.note {
            caveat += "  " + note
        }

        let report = regionReport(rep, scene: scene)
        let reportColour: NSColor = report.alarming
            ? NSColor(calibratedRed: 1, green: 0.84, blue: 0.3, alpha: 1)
            : NSColor(calibratedWhite: 0.7, alpha: 1)

        var lines: [NSAttributedString] = []
        lines.append(attributed(identity, NSFont.boldSystemFont(ofSize: 9.5), .white, paragraph))
        lines.append(
            attributed(
                caveat,
                NSFont.systemFont(ofSize: 8.5),
                NSColor(calibratedWhite: 0.88, alpha: 1),
                paragraph
            )
        )
        lines.append(
            attributed(report.text, NSFont.boldSystemFont(ofSize: 8.5), reportColour, paragraph)
        )
        return lines
    }

    private static func attributed(
        _ string: String,
        _ font: NSFont,
        _ colour: NSColor,
        _ paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]
        )
    }

    // MARK: - Featureless-region detection

    /// Names horizontal bands of the frame that carry no drawn detail, and
    /// flags content that runs off the bottom edge.
    ///
    /// This exists because of the popup header: it lives inside a `glassEffect`
    /// surface, so the capture contained neither the surface nor the controls
    /// on it, and 89 points of nothing at the top of every popup frame read as
    /// "the design has no header" rather than "the harness did not capture
    /// one". Silence had to be made to say something.
    private static func regionReport(
        _ rep: NSBitmapImageRep,
        scene: Scene
    ) -> (text: String, alarming: Bool) {
        let rows = Int(max(scene.size.height, 1))
        guard rows > Int(blankBandThreshold), rep.pixelsWide > 0 else {
            return ("Frame too short to scan for missing regions.", false)
        }

        let featureless = featurelessRows(rep, rows: rows)

        var runs: [(start: Int, end: Int)] = []
        var start: Int?
        for row in 0...rows {
            let isFeatureless = row < rows && featureless[row]
            if isFeatureless, start == nil { start = row }
            if !isFeatureless, let begin = start {
                runs.append((begin, row - 1))
                start = nil
            }
        }

        // Whole frame flat. The old detector missed this outright: the single
        // run reached the bottom edge and bottom-touching runs were dropped, so
        // an entirely blank frame reported nothing wrong with it.
        if let only = runs.first, runs.count == 1, only.start == 0, only.end >= rows - 2 {
            return ("ENTIRE FRAME IS ONE FLAT COLOUR — nothing was drawn, or all of it was "
                    + "composited by the window server. This frame shows nothing.", true)
        }

        var alarms: [String] = []
        var asides: [String] = []
        for run in runs where CGFloat(run.end - run.start + 1) >= blankBandThreshold {
            let length = run.end - run.start + 1
            if run.end >= rows - 2 {
                // A trailing band is the scene being taller than its content,
                // which is by construction rather than by loss.
                asides.append("trailing \(length)pt below the last drawn row")
            } else {
                alarms.append("rows \(run.start)–\(run.end) (\(length)pt)")
            }
        }

        // Content that runs to the last row was very likely cut off. Nothing
        // marked clipping before, so `updates-failed-signature` sliced its own
        // text mid-glyph in silence.
        let clipped = !featureless[rows - 1]

        var parts: [String] = []
        if clipped {
            parts.append(
                "CLIPPED? — drawn content reaches the last row, so this frame probably cuts "
                + "content off. Make the scene taller."
            )
        }
        if !alarms.isEmpty {
            parts.append(
                "FEATURELESS REGION(S) — " + alarms.joined(separator: "; ")
                + ". Either genuinely empty, or content inside a glassEffect surface that the "
                + "window server composited and this capture cannot show. Do not read blank as "
                + "absent."
            )
        }
        if parts.isEmpty {
            parts.append("No featureless region over \(Int(blankBandThreshold))pt, and content "
                         + "does not reach the bottom edge.")
        }
        parts.append(contentsOf: asides)
        return (parts.joined(separator: " "), clipped || !alarms.isEmpty)
    }

    private static func featurelessRows(_ rep: NSBitmapImageRep, rows: Int) -> [Bool] {
        let scale = max(CGFloat(rep.pixelsHigh) / CGFloat(rows), 1)
        let columns = 32

        // Distinct colours across the row, not unanimity across it.
        //
        // The old test required every sampled column to be the identical
        // colour, which the guided-tour overlay defeated on its own: its scrim
        // is inset, so at row 40 of `tour-skip-before` 22 of 24 samples were
        // flat scrim and the two at the frame edges were page background. Three
        // colours, no detail, and the detector went silent for the whole frame
        // — on 22 of 61 frames, every one of them a tour frame with the same
        // 89pt header hole the band correctly named elsewhere.
        func isFeatureless(_ row: Int) -> Bool {
            let y = min(rep.pixelsHigh - 1, Int(CGFloat(row) * scale))
            var seen: [NSColor] = []
            for step in 0..<columns {
                let x = step * (rep.pixelsWide - 1) / (columns - 1)
                guard let sample = rep.colorAt(x: x, y: y) else { return false }
                if !seen.contains(where: { $0 == sample }) {
                    seen.append(sample)
                    if seen.count > 3 { return false }
                }
            }
            return true
        }

        var featureless = [Bool](repeating: false, count: rows)
        // Every second row: a lost region is measured in tens of points, and a
        // per-pixel walk through `colorAt` is not free.
        for row in stride(from: 0, to: rows, by: 2) {
            featureless[row] = isFeatureless(row)
        }
        for row in stride(from: 1, to: rows, by: 2) {
            featureless[row] = featureless[row - 1]
        }
        // The last row decides the clipping call, so it is measured rather than
        // inherited from its neighbour.
        featureless[rows - 1] = isFeatureless(rows - 1)
        return featureless
    }

    // MARK: - Support

    /// The opaque base a frame is composited over. Matched to the resolved base
    /// of the materials the capture cannot draw, so contrast in the image means
    /// roughly what contrast on screen would mean.
    private static func backing(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark
            ? NSColor(calibratedWhite: 0.11, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
    }

    /// Where the first `NSScrollView` under `view` is parked, in points from the
    /// top of its content. `nil` when the hierarchy has no scroll view at all,
    /// which is itself worth failing on: a scene that asserts a scroll position
    /// against a pane that stopped being scrollable would otherwise pass.
    ///
    /// SwiftUI's `ScrollView` is an `NSScrollView` underneath on macOS. Reading
    /// `contentView.bounds.origin.y` is reading the same number the user sees
    /// the effect of, which is the point — it is not a proxy for the scroll, it
    /// is the scroll.
    static func scrollOffset(in view: NSView) -> CGFloat? {
        if let scroll = view as? NSScrollView {
            return scroll.contentView.bounds.origin.y
        }
        for child in view.subviews {
            if let found = scrollOffset(in: child) { return found }
        }
        return nil
    }

    /// Fails unless the pane is parked at least `atLeast` points down.
    ///
    /// The pair of these on `settings-audio-guide-*` is a calibrated
    /// instrument rather than a threshold picked by taste: the `-before` frame
    /// of the same transition asserts the pane is at the top, so the two
    /// together prove the assertion can tell the states apart. A floor with no
    /// matching control is a number that has never been shown to fail.
    static func requireScrolled(atLeast points: CGFloat) -> @MainActor (NSView) -> String? {
        { host in
            guard let offset = scrollOffset(in: host) else {
                return "no NSScrollView in the hierarchy, so the guided scroll "
                    + "could not have happened and nothing here would have said so"
            }
            guard offset >= points else {
                return String(
                    format: "parked %.0fpt from the top of its content, needs at least "
                        + "%.0fpt — the guided scroll did not happen", Double(offset),
                    Double(points)
                )
            }
            return nil
        }
    }

    /// The control for `requireScrolled`. Fails if the pane has moved at all.
    static func requireAtTop() -> @MainActor (NSView) -> String? {
        { host in
            guard let offset = scrollOffset(in: host) else {
                return "no NSScrollView in the hierarchy"
            }
            guard offset <= 1 else {
                return String(
                    format: "expected the top of the content, found %.0fpt down",
                    Double(offset)
                )
            }
            return nil
        }
    }

    /// Spins the main run loop. Internal because a scene's `prepare` sometimes
    /// has to let a coordinator react before the next thing it does.
    static func settle(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            settleTurns += 1
        }
        settleSeconds += seconds
    }

    /// How many turns the run loop has actually taken, against how many seconds
    /// were asked for.
    ///
    /// A `settle` that returns on time says nothing about whether anything ran.
    /// macOS throttles a background process's run loop under App Nap, and a
    /// throttled loop starves every animation and every `RunLoop.main`-delivered
    /// publisher the frames depend on while each `settle` still returns exactly
    /// when its deadline says. The ratio is the only way to see that from the
    /// outside, and it is written on green runs as well as red ones — a number
    /// that only appears on failure is a number nobody has a baseline for.
    private(set) static var settleTurns = 0
    private(set) static var settleSeconds: TimeInterval = 0
}
#endif
