// ax-check — asserts things about a running Melo's live accessibility tree.
//
//   ax-check <pid> [--dump] <assertion>...
//
// Assertions:
//   adjustable:<pattern>   the element exposes AXIncrement/AXDecrement, and
//                          performing one MOVES the value it speaks
//   button:<label>         every AXButton with that spoken name exposes AXPress
//   absent:<pattern>       nothing in the scene is announced by that name
//   min-elements:<n>       the tree has at least n elements (an anti-vacuity
//                          floor for the assertion above it)
//
// <pattern> is an exact label, or `*suffix` to match on the end of one.
//
// Exit 0 every assertion held · 1 an assertion failed · 2 the tree could not be
// read at all · 3 this process is not accessibility-trusted, so nothing was
// checked.
//
// ## Why this is a separate process
//
// Not a style choice — three measurements, in this repo, on this machine:
//
//   * `NSHostingView.accessibilityChildren()` called from inside the app
//     returns one empty AXGroup. AppKit materialises SwiftUI's element tree
//     lazily, for an attached assistive client, and an app is not one for
//     itself.
//   * `AXUIElementCreateApplication(getpid())` is refused outright:
//     kAXErrorCannotComplete (-25208).
//   * The identical call from out here works, against a bundled `.app`, on a
//     window ordered front off-screen. It need not be visible or key.
//
// ## What SwiftUI's modifiers turn into out here
//
// Measured, because the first attempt at this read AXValue, found nil, and
// concluded the whole approach was dead:
//
//   accessibilityLabel            -> AXDescription
//   accessibilityValue            -> AXValueDescription   (AXValue stays nil)
//   accessibilityAdjustableAction -> AXIncrement / AXDecrement actions
import AppKit
import ApplicationServices

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var dump = false
var treePath: String?
if let flag = arguments.firstIndex(of: "--tree"), arguments.count > flag + 1 {
    treePath = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
}
arguments.removeAll { argument in
    if argument == "--dump" { dump = true; return true }
    return false
}
guard let first = arguments.first, let pid = Int32(first), arguments.count >= 2 || dump else {
    FileHandle.standardError.write(
        Data("usage: ax-check <pid> [--dump] <assertion>...\n".utf8)
    )
    exit(2)
}
let assertions = Array(arguments.dropFirst())

guard AXIsProcessTrusted() else {
    print("NOT CHECKED: this process has no Accessibility grant, so the live "
        + "accessibility tree cannot be read. Grant the terminal running this "
        + "in System Settings > Privacy & Security > Accessibility.")
    exit(3)
}
guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
    // Named rather than left as a bare "not running", because there is one
    // overwhelmingly likely cause and it is not a bug in this app:
    // `build-app.sh` begins by deleting every copy of Sparkle.framework, which
    // kills any Melo already launched from a staged bundle. Inside the lock
    // that cannot happen. A standalone run of this script can land in it.
    print("NOT CHECKED: pid \(pid) is gone. If another agent started a build while this was "
        + "waiting, that build deleted the frameworks out from under the dwelling app. Run "
        + "this through scripts/dev-verify.sh, which holds the lock.")
    exit(2)
}

// MARK: - Tree

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        ? value
        : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func role(_ element: AXUIElement) -> String {
    attribute(element, kAXRoleAttribute as String) as? String ?? "?"
}

/// The spoken name. `accessibilityLabel` lands in AXDescription; AXTitle is
/// what a plain `Button("Quit")` gets, so both are names and both are checked.
func name(_ element: AXUIElement) -> String? {
    if let description = attribute(element, kAXDescriptionAttribute as String) as? String,
       !description.isEmpty {
        return description
    }
    if let title = attribute(element, kAXTitleAttribute as String) as? String, !title.isEmpty {
        return title
    }
    return nil
}

/// `accessibilityValue`, which is NOT AXValue. AXValue is nil on every SwiftUI
/// element measured here; the spoken string is AXValueDescription.
func spokenValue(_ element: AXUIElement) -> String? {
    attribute(element, "AXValueDescription") as? String
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    return names as? [String] ?? []
}

let application = AXUIElementCreateApplication(pid)

/// `SnapshotHarness.axDwellWindowMarker`. The harness stamps it on the one
/// window it holds open for this check.
let dwellMarker = "melo-ax-dwell"

/// The dwelled-on window, not the app — so the walk covers the scene under test
/// and nothing else.
///
/// Two measurements forced each half of this. Walking from the application
/// element reaches the AppKit menu bar, where an `Open Recent` entry named
/// `sightline.tgz` was flagged as an SF Symbol name on the first run. Walking
/// all windows still reached `What's New in Melo`, a second window a scene had
/// opened and left standing, whose 20 elements no assertion here is about.
func scanRoots() -> [AXUIElement] {
    let windows = attribute(application, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
    let marked = windows.filter { window in
        attribute(window, kAXIdentifierAttribute as String) as? String == dwellMarker
            || attribute(window, kAXTitleAttribute as String) as? String == dwellMarker
    }
    guard marked.isEmpty else { return marked }
    print("  WARN  no window is marked \(dwellMarker.debugDescription); scanning all "
        + "\(windows.count) window(s) of pid \(pid) instead, which is noisier than intended")
    return windows.isEmpty ? [application] : windows
}

/// Every element under those roots, in tree order. Re-walked after each action
/// rather than held: SwiftUI rebuilds its element tree when state changes, so
/// an AXUIElement captured before an action can be answering for a view that no
/// longer exists.
func walk() -> [(element: AXUIElement, name: String?, role: String)] {
    var found: [(AXUIElement, String?, String)] = []
    func visit(_ element: AXUIElement, _ depth: Int) {
        guard depth < 40, found.count < 6000 else { return }
        found.append((element, name(element), role(element)))
        for child in children(element) { visit(child, depth + 1) }
    }
    for root in scanRoots() { visit(root, 0) }
    return found
}

var tree = walk()

/// What the assertions below were actually run against. Written every time,
/// because "the tree did not contain X" is a claim nobody can check afterwards
/// unless the tree was kept.
func describeTree() -> String {
    var lines = ["— \(tree.count) elements under pid \(pid) —"]
    for entry in tree {
        let value = spokenValue(entry.element).map { " value=\($0.debugDescription)" } ?? ""
        let acts = actions(entry.element).filter { $0 != "AXShowMenu" }
        let actionText = acts.isEmpty ? "" : " actions=\(acts)"
        lines.append("  \(entry.role) \(entry.name?.debugDescription ?? "-")\(value)\(actionText)")
    }
    return lines.joined(separator: "\n") + "\n"
}

let description = describeTree()
if dump { print(description, terminator: "") }
if let treePath { try? Data(description.utf8).write(to: URL(fileURLWithPath: treePath)) }

func matches(_ label: String?, _ pattern: String) -> Bool {
    guard let label else { return false }
    if pattern.hasPrefix("*") { return label.hasSuffix(String(pattern.dropFirst())) }
    return label == pattern
}

// MARK: - Assertions

var failures = 0
func pass(_ message: String) { print("  PASS  \(message)") }
func fail(_ message: String) { print("  FAIL  \(message)"); failures += 1 }

func assertAdjustable(_ pattern: String) {
    let candidates = tree.filter {
        matches($0.name, pattern) && actions($0.element).contains(kAXIncrementAction as String)
    }
    guard let target = candidates.first else {
        let named = tree.filter { matches($0.name, pattern) }
        if named.isEmpty {
            fail("nothing in the tree is named \(pattern) — the label is gone, so VoiceOver "
                + "cannot find this control at all")
        } else {
            fail("\(named.count) element(s) named \(pattern) expose "
                + "\(actions(named[0].element)) — no AXIncrement. The adjustable action is "
                + "gone, so VoiceOver can read this value but never change it")
        }
        return
    }
    let label = target.name ?? pattern
    guard let before = spokenValue(target.element) else {
        fail("\(label.debugDescription) is adjustable but speaks no value, so a VoiceOver user "
            + "adjusting it hears nothing change")
        return
    }

    // Increment first; decrement only if increment moved nothing. A control at
    // the top of its range is a legitimate reason for one direction to be a
    // no-op, and it is not the reason this check exists.
    var moved: (direction: String, after: String)?
    for action in [kAXIncrementAction as String, kAXDecrementAction as String] {
        guard actions(target.element).contains(action) else { continue }
        guard AXUIElementPerformAction(target.element, action as CFString) == .success else {
            continue
        }
        usleep(500_000)
        tree = walk()
        // By label, not by the handle: reordering a device rebuilds the row.
        let after = tree.first { matches($0.name, pattern) && $0.name == target.name }
            .flatMap { spokenValue($0.element) }
        if let after, after != before {
            moved = (action, after)
            break
        }
    }

    guard let moved else {
        fail("\(label.debugDescription): AXIncrement and AXDecrement both ran and the spoken "
            + "value did not move off \(before.debugDescription). The action is wired to "
            + "nothing, or it does not write the value it announces")
        return
    }
    pass("\(label.debugDescription) \(before.debugDescription) -> "
        + "\(moved.after.debugDescription) via \(moved.direction)")
}

/// An icon-only control that carries a real spoken name **and can be activated**.
///
/// The press requirement is not decoration on this assertion; it is most of it.
/// Without it this function checked a role and a string and nothing about
/// behaviour — this project's named anti-pattern, sitting inside the newest
/// check in the tree. It passed, green and confident, on an
/// `AXButton "Expand device details"` that exposed no actions whatsoever:
/// `.accessibilityAddTraits(.isButton)` on an `onTapGesture` region announces a
/// button to VoiceOver and gives its user nothing to press. Same class of
/// defect as an adjustable action wired to nothing, and it took severing the
/// fix and watching the whole suite stay green to see it.
///
/// Every match is checked, not the first: two device rows carry each of these
/// labels, and a check that stops at one would pass a tree where the second is
/// broken.
func assertButton(_ label: String) {
    let named = tree.filter { matches($0.name, label) }
    let buttons = named.filter { $0.role == kAXButtonRole as String }
    guard !buttons.isEmpty else {
        if named.isEmpty {
            fail("no element is named \(label.debugDescription) — an icon-only button with no "
                + "label is announced by VoiceOver as \"button\" and nothing else")
        } else {
            fail("\(label.debugDescription) exists but its role is "
                + "\(named.map(\.role)) rather than AXButton")
        }
        return
    }
    let unpressable = buttons.filter {
        !actions($0.element).contains(kAXPressAction as String)
    }
    guard unpressable.isEmpty else {
        fail("\(unpressable.count) of \(buttons.count) AXButton(s) named "
            + "\(label.debugDescription) expose \(actions(unpressable[0].element)) — no AXPress. "
            + "VoiceOver announces a button and has nothing to activate: a tap-gesture region "
            + "wearing .accessibilityAddTraits(.isButton) with no matching .accessibilityAction")
        return
    }
    pass("AXButton \(label.debugDescription) — \(buttons.count) element(s), role AXButton, "
        + "AXPress present on all")
}

/// Nothing in the scene may be announced by this name.
///
/// The obvious version of this assertion — "does any label look like an SF
/// Symbol name" — was written first, and it is **dead**. Measured: with
/// `.accessibilityHidden(true)` deleted from the grab handle in
/// `DeviceEditRow`, `Image(systemName: "line.3.horizontal")` came back as
/// `AXImage "Drag"`. macOS resolves a symbol through its own catalogue before
/// anything reaches an assistive client, so a raw `speaker.wave.2.fill` is not
/// what leaks — a plausible English word is, and that shape of check could
/// never have gone red. This one can: the two `AXImage "Drag"` elements above
/// are what it saw.
func assertAbsent(_ pattern: String) {
    let offenders = tree.compactMap { entry -> String? in
        matches(entry.name, pattern) ? "\(entry.role) \(entry.name!.debugDescription)" : nil
    }
    guard offenders.isEmpty else {
        fail("\(offenders.count) element(s) are announced as \(pattern.debugDescription): "
            + "\(offenders.joined(separator: ", ")). A decorative Image(systemName:) lost its "
            + ".accessibilityHidden(true), so VoiceOver now stops on a picture that does nothing")
        return
    }
    pass("nothing is announced as \(pattern.debugDescription) (\(tree.count) elements scanned)")
}

func assertMinimumElements(_ minimum: Int) {
    guard tree.count >= minimum else {
        fail("the tree has \(tree.count) element(s), under the floor of \(minimum). Absence "
            + "assertions above cannot mean anything against a tree that did not materialise")
        return
    }
    pass("\(tree.count) elements in the tree (floor \(minimum))")
}

for assertion in assertions {
    let parts = assertion.split(separator: ":", maxSplits: 1).map(String.init)
    switch (parts.first ?? "", parts.count > 1 ? parts[1] : "") {
    case ("adjustable", let pattern):
        assertAdjustable(pattern)
    case ("button", let label):
        assertButton(label)
    case ("absent", let pattern):
        assertAbsent(pattern)
    case ("min-elements", let value):
        assertMinimumElements(Int(value) ?? 0)
    default:
        fail("unknown assertion \(assertion.debugDescription)")
    }
}

exit(failures == 0 ? 0 : 1)
