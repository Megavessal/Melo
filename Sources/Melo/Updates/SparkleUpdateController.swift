import Combine
import Foundation
import Sparkle

@MainActor
final class SparkleUpdateController: ObservableObject {
    /// What is stopping Sparkle from running, in the order it needs fixing.
    ///
    /// Sparkle will not start without both a secure feed and a public key, and an
    /// updater that silently does nothing is indistinguishable from one that found
    /// no updates. Naming the missing piece is the difference between a feature
    /// that looks broken and one that is visibly not set up yet.
    enum ConfigurationProblem: Equatable {
        case feedMissing
        case feedNotSecure
        case signingKeyMissing

        var summary: String {
            switch self {
            case .feedMissing:
                return "No update feed is set yet."
            case .feedNotSecure:
                return "The update feed must be an https address."
            case .signingKeyMissing:
                return "No update signing key is set yet."
            }
        }

        var guidance: String {
            switch self {
            case .feedMissing, .feedNotSecure:
                return "Add the address of your appcast.xml to SUFeedURL in Config/Info.plist."
            case .signingKeyMissing:
                return "Run scripts/sparkle-setup.sh once to create a signing key, then paste the public half into SUPublicEDKey in Config/Info.plist."
            }
        }
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var configurationProblem: ConfigurationProblem?
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard isSynchronizing == false else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var automaticallyDownloadsAndInstalls: Bool {
        didSet {
            guard isSynchronizing == false else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsAndInstalls
        }
    }

    let updaterController: SPUStandardUpdaterController

    private var cancellables: Set<AnyCancellable> = []
    private var isSynchronizing = true

    private var updater: SPUUpdater { updaterController.updater }

    init(bundle: Bundle = .main) {
        let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let problem: ConfigurationProblem?
        if feed.isEmpty {
            problem = .feedMissing
        } else if URL(string: feed)?.scheme?.lowercased() != "https" {
            problem = .feedNotSecure
        } else if publicKey.isEmpty {
            problem = .signingKeyMissing
        } else {
            problem = nil
        }
        let configured = problem == nil

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        isConfigured = configured
        configurationProblem = problem
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        automaticallyDownloadsAndInstalls = updaterController.updater.automaticallyDownloadsUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.canCheckForUpdates = value
                }
            }
            .store(in: &cancellables)

        if configured {
            updaterController.startUpdater()
        }
        isSynchronizing = false
    }

    func checkNow() {
        guard isConfigured, canCheckForUpdates else { return }
        updater.checkForUpdates()
    }
}
