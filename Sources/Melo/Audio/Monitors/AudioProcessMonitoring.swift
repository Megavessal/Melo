@MainActor
protocol AudioProcessMonitoring: AnyObject {
    /// Apps with a live Core Audio process object and therefore eligible for a tap.
    var activeApps: [AudioApp] { get }
    /// Open, user-facing apps discovered through NSWorkspace. This includes apps
    /// that have not initialized Core Audio yet, so the mixer can show them early.
    var openApps: [AudioApp] { get }
    var onAppsChanged: (([AudioApp]) -> Void)? { get set }

    func start()
    func stop()
}
