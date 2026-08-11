import Foundation
import Observation

/// Keeps the menu-bar popup's contents out of the launch burst, by one turn of
/// the run loop and not one moment longer.
///
/// `FluidMenuBarExtraWindow.init` calls
/// `setContentSize(hostingView.intrinsicContentSize)`, which forces SwiftUI to
/// lay the whole popup out while the scene list is still being built — inside
/// the same block of main-thread work as everything else Melo does at launch.
/// Until this flips, the content closure returns a correctly-sized empty box,
/// which costs nothing to measure.
///
/// ## The delay is zero, and that was measured rather than assumed
///
/// This began with a 700ms delay, on the reasoning that the layout is main-
/// thread work which has to happen somewhere, so it should happen when nobody
/// is waiting. That reasoning was wrong twice over, and the watchdog said so:
///
/// | | launch freeze | opening the popup |
/// |---|---|---|
/// | no gate at all | 439–458ms | — |
/// | gate, 700ms delay | 283–408ms | **1643ms** |
/// | gate, next turn | **310ms** | nothing over 120ms |
///
/// The 700ms delay bought nothing at launch that the bare hop did not already
/// buy, and it moved a freeze onto the first click — the one moment the user is
/// certainly waiting — where it was five times worse than the launch cost it
/// replaced, because the window is being shown *and* animated from one point
/// tall at the same time as the graph is built.
///
/// So the whole benefit is the hop, not the wait. Leaving the run loop once is
/// enough to put this outside the launch block; by the time a person has looked
/// at the menu bar and moved a pointer, it has long since finished.
///
/// *Rejected:* waiting for the first click. That is the 1643ms column.
@Observable
@MainActor
final class PopupWarmUp {
    static let shared = PopupWarmUp()

    /// `false` for the first `delay` seconds of the process, then true forever.
    private(set) var isReady = false

    private var started = false

    private init() {}

    /// One hop, no sleep. See the table above for why there is no interval here.
    func begin() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            isReady = true
        }
    }

    /// Brings the contents in now, for a caller that knows the popup is about to
    /// be needed. Safe to call repeatedly.
    func readyNow() {
        isReady = true
    }

    /// The render harness renders the popup directly and never launches into an
    /// idle run loop, so a scene would photograph the placeholder. Snapshot runs
    /// start ready.
    func readyForSnapshot() {
        started = true
        isReady = true
    }
}
