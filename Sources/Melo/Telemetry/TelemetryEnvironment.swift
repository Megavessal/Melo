// Melo/Telemetry/TelemetryEnvironment.swift
import Foundation

/// The context attached to every signal, kept deliberately blunt.
///
/// Why it is this coarse: Melo has a small user base. "MacBook Pro (14-inch,
/// M3 Max)" + "macOS 26.1 build 25B78" + "pt-BR" is, in a population of a few
/// thousand, very close to a unique row — cross-referenced with a timestamp it
/// is a fingerprint even though no single field is an identifier. So the model
/// is reduced to a silicon generation, the OS to its minor version with the
/// build discarded, and the locale to a bare language code with no region.
/// Nothing here is derived from the machine's name, the user's name, the
/// serial number, or any hardware UUID.
struct TelemetryEnvironment: Sendable, Equatable {
    /// Melo's marketing version, e.g. "2.9.3". No build number: it adds
    /// resolution that only matters to a developer reading a crash, and Sentry
    /// carries its own build metadata for that.
    let appVersion: String
    /// macOS major.minor only, e.g. "26.1". The build string ("25B78") is
    /// deliberately dropped — it separates beta testers from everyone else and
    /// answers no product question.
    let systemVersion: String
    let hardware: HardwareClass
    /// Language only, never the region. "pt" rather than "pt-BR": the region
    /// narrows a population far faster than the language does.
    let languageCode: String

    /// Broad silicon generation. Not a model identifier — "MacBookPro18,3"
    /// would pin down screen size, year, and often the configuration.
    enum HardwareClass: String, Sendable {
        case appleSiliconM1
        case appleSiliconM2
        case appleSiliconM3
        case appleSiliconM4
        case appleSiliconLater
        case other
    }

    static func current() -> TelemetryEnvironment {
        TelemetryEnvironment(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            systemVersion: systemMinorVersion(),
            hardware: hardwareClass(),
            languageCode: Locale.current.language.languageCode?.identifier ?? "und"
        )
    }

    /// Merged into each signal's payload by the sinks.
    var parameters: [String: String] {
        [
            "meloVersion": appVersion,
            "systemVersion": systemVersion,
            "hardware": hardware.rawValue,
            "language": languageCode
        ]
    }

    private static func systemMinorVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    /// Reads the CPU brand string only to classify it, then throws it away. The
    /// brand string itself is never stored or transmitted, because Apple ships
    /// variants ("M3 Max") that are far more specific than the question being
    /// asked, which is only ever "is this machine fast enough for the audio
    /// path Melo wants to use".
    private static func hardwareClass() -> HardwareClass {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return .other
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return .other
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let brand = String(decoding: bytes, as: UTF8.self)
        guard brand.contains("Apple") else { return .other }
        if brand.contains("M1") { return .appleSiliconM1 }
        if brand.contains("M2") { return .appleSiliconM2 }
        if brand.contains("M3") { return .appleSiliconM3 }
        if brand.contains("M4") { return .appleSiliconM4 }
        // Anything newer than the generations this build knows about is folded
        // into one bucket rather than reported verbatim, so a brand-new machine
        // is not the only one of its kind in the dataset on launch day.
        return .appleSiliconLater
    }
}
