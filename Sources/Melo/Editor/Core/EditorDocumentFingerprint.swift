// Melo/Editor/Core/EditorDocumentFingerprint.swift
//
// "Did switching modes change the document?", as a function.
//
// ## Why this is product code and not four lines inside a snapshot scene
//
// It started inside the scene, which is where the check is *used*, and that is
// the wrong place for it to *live*. A comparison written inside a closure that
// only the render harness can reach can only be exercised by a full render —
// and this project's anchor already records what happens to a rule nobody can
// execute: `scripts/dev-verify.sh` once rendered 83 frames and passed all
// eleven verify scripts over a tree with four wiring points severed, because
// every assertion tested a pure function nothing proved was called.
//
// Out here it is the inverse of that failure rather than another instance of
// it. The function is pure, so a four-file `swiftc` invocation can run it
// against real `EditorDocument` values and prove it *can* fail — and the
// snapshot assertion calls this exact function rather than a copy of it, so
// what the probe exercised is what the render checks. Neither half is
// sufficient: the probe cannot prove the mode switch calls it, and the render
// cannot prove the comparison would notice.
//
// It is deliberately not `#if MELO_DEV`. Compiling an invariant only into the
// developer build means the shipping build's behaviour is described by code
// the shipping build does not contain, and — per the anchor's note about
// `-typecheck` without `-D MELO_DEV` — fixture-only code is precisely the code
// nothing checks.

import Foundation

extension EditorDocument {

    /// The document as bytes.
    ///
    /// **Encoded rather than compared with `==`.** `EditorDocument` is
    /// `Equatable`, so `==` was the obvious spelling and it is the weaker one:
    /// synthesised equality walks the fields that exist today, and a field
    /// added tomorrow joins it only while nobody hand-writes the conformance.
    /// The encoded form is what reaches the session sidecar, so this asks the
    /// question in the shape the consequences take.
    ///
    /// `.sortedKeys`, or this is a flake generator: two encodings of one
    /// unchanged document could differ by dictionary ordering and report a
    /// change nobody made. An assertion that cries wolf gets deleted, and then
    /// the real defect it was covering ships.
    ///
    /// `nil` only when encoding throws, which for this model it does not — no
    /// non-conforming floats reach it, because durations and gains are all
    /// finite by construction. Callers must still treat `nil` as a failure
    /// rather than as a match, which is what `modeSwitchComplaint` does.
    var fingerprint: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    /// `nil` when a mode switch left the document alone, or the sentence to
    /// fail a render with when it did not.
    ///
    /// **Both `nil` arguments are failures, not passes.** The tempting spelling
    /// is `before == after`, which returns `true` for two absent fingerprints
    /// and therefore reports success for a scene where the document never
    /// existed — an assertion that is loudest exactly when it has nothing to
    /// say. Each `nil` gets its own sentence so the reader knows which end went
    /// missing.
    ///
    /// The byte counts are in the message on purpose. "The document changed" is
    /// true and useless; "1284 bytes before, 1231 after" says something was
    /// *removed*, which is the shape of the failure this exists for — a mode
    /// that hides a control and drops the value behind it.
    static func modeSwitchComplaint(before: Data?, after: Data?) -> String? {
        guard let before else {
            return "no document fingerprint was taken before the switch"
        }
        guard let after else {
            return "there is no document after the switch"
        }
        guard before != after else { return nil }
        return "THE MODE EDITED THE DOCUMENT — \(before.count) bytes before the switch, "
            + "\(after.count) after, and they do not match. Switching modes must add and "
            + "remove what is drawn and nothing else."
    }
}
