import AppKit
import OSLog

/// Keeps Melo's Dock tile matched to the system appearance.
///
/// macOS 26 expresses appearance-aware app icons through Icon Composer's
/// `.icon` format, which an asset-catalog `.appiconset` cannot describe: a
/// catalog carries exactly one artwork, and that artwork is what Finder and the
/// Applications folder show. The Dock tile of a *running* application is a
/// separate surface that can be set directly, so Melo swaps its own tile when
/// the appearance changes rather than shipping one icon that is wrong half the
/// time.
///
/// Both artworks are the same pixel drawing with the same waveform colours; only
/// the plate behind it changes, so the two never read as different brands.
@MainActor
final class DockIconAppearanceCoordinator {
    static let shared = DockIconAppearanceCoordinator()

    private nonisolated static let logger = Logger(subsystem: "dev.local.Melo", category: "DockIcon")

    private var observer: NSObjectProtocol?
    private var cache: [String: NSImage] = [:]

    private init() {}

    /// Applies the correct tile now and follows the system from then on. Safe to
    /// call more than once; the observer is only registered the first time.
    func start() {
        apply()
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            // This notification fires slightly before NSApp.effectiveAppearance
            // settles, so read the appearance on the next main-queue turn
            // instead of inside the callback.
            Task { @MainActor in
                DockIconAppearanceCoordinator.shared.apply()
            }
        }
    }

    /// Also called after the Dock preference is toggled on: a tile that appears
    /// for the first time picks up whatever icon is set at that moment.
    func apply() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = isDark ? "AppIconDark" : "AppIconLight"
        guard let image = image(named: name) else {
            // Falling through leaves the catalog icon in place, which is the
            // dark artwork — wrong in light mode, but never a missing tile.
            Self.logger.error("Appearance icon \(name, privacy: .public) is missing from the asset catalog")
            return
        }
        NSApp.applicationIconImage = image
    }

    private func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let image = NSImage(named: name) else { return nil }
        cache[name] = image
        return image
    }
}
