import Foundation

/// Small, consumer-facing change history. It stores complete Melo snapshots so
/// Undo can safely restore a volume, route, EQ, Scene, or output change without
/// teaching the user which low-level setting moved.
@Observable
@MainActor
final class ConsumerUndoManager {
    private(set) var entries: [ConsumerChangeRecord] = []
    private var lastKey: String?
    private var lastRecordDate: Date?
    private let coalescingWindow: TimeInterval = 1.0
    private let maximumEntries = 12

    var canUndo: Bool { !entries.isEmpty }
    var latest: ConsumerChangeRecord? { entries.first }

    func record(label: String, key: String, snapshot: ConsumerScene) {
        let now = Date()
        if lastKey == key,
           let lastRecordDate,
           now.timeIntervalSince(lastRecordDate) < coalescingWindow {
            // Extend the quiet-period window while a slider or repeated keypress
            // is still active, but keep the original pre-change snapshot.
            self.lastRecordDate = now
            return
        }

        entries.insert(ConsumerChangeRecord(label: label, date: now, snapshot: snapshot), at: 0)
        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }
        lastKey = key
        self.lastRecordDate = now
    }

    func takeLatest() -> ConsumerChangeRecord? {
        guard !entries.isEmpty else { return nil }
        lastKey = nil
        lastRecordDate = nil
        return entries.removeFirst()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func clear() {
        entries.removeAll()
        lastKey = nil
        lastRecordDate = nil
    }
}
