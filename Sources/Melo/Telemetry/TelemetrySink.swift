// Melo/Telemetry/TelemetrySink.swift
import Foundation
import os

#if canImport(TelemetryDeck)
import TelemetryDeck
#endif

/// Where a signal goes once `TelemetryService` has decided it may be sent.
///
/// The sink takes a `TelemetryEvent`, never a name and a dictionary. Pushing
/// the string conversion down to the last possible moment means no caller can
/// hand a sink text of its own.
protocol TelemetrySink: Sendable {
    func send(_ event: TelemetryEvent, environment: TelemetryEnvironment)
}

/// The default, and what ships when the vendor packages are not linked. It is
/// not a placeholder to be swapped in later by mistake: consent-denied and
/// consent-unasked both resolve to this, so the failure mode of every code path
/// in this module is "nothing leaves the machine".
struct NoOpSink: TelemetrySink {
    func send(_ event: TelemetryEvent, environment: TelemetryEnvironment) {}
}

#if MELO_DEV
/// Prints what *would* have been sent. Compiled only into developer builds so
/// the payload of a new event can be eyeballed before it is ever pointed at a
/// real project — reviewing redaction by reading the enum is not the same as
/// seeing the line that would go over the wire.
struct ConsoleSink: TelemetrySink {
    private static let logger = Logger(subsystem: "dev.melo.telemetry", category: "ConsoleSink")

    func send(_ event: TelemetryEvent, environment: TelemetryEnvironment) {
        let merged = environment.parameters.merging(event.parameters) { _, eventValue in eventValue }
        let rendered = merged
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        Self.logger.debug("would send \(event.signalName, privacy: .public) \(rendered, privacy: .public)")
    }
}
#endif

#if canImport(TelemetryDeck)
/// Live product analytics. Only constructed by `TelemetryService` after the
/// SDK has been started, which itself only happens on granted consent.
struct VendorAnalyticsSink: TelemetrySink {
    func send(_ event: TelemetryEvent, environment: TelemetryEnvironment) {
        let merged = environment.parameters.merging(event.parameters) { _, eventValue in eventValue }
        TelemetryDeck.signal(event.signalName, parameters: merged)
    }
}
#endif
