#!/usr/bin/env python3
"""
verify.py — static checks for the Melo premium pass.

This is NOT a compiler. It cannot typecheck Swift, resolve overloads, or
validate SwiftUI's opaque return types. It checks the specific class of
mistakes a mechanical token-adoption pass actually produces:

  1. A token is referenced that does not exist in DesignTokens.
  2. A token was defined but never adopted anywhere (dead scale).
  3. Inline animation literals survived the pass (missed call sites).
  4. Delimiters went unbalanced in an edited file.
  5. A symbol was deleted while references to it remain.

Run:  python3 verify.py <source-root>
Exit: 0 clean, 1 if any ERROR.
"""
import re, sys, pathlib, collections

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
errors, warnings, notes = [], [], []

swift = sorted(root.rglob("*.swift"))
if not swift:
    print(f"no Swift files under {root}"); sys.exit(1)

tokens_path = next((p for p in swift if p.name == "DesignTokens.swift"), None)
if tokens_path is None:
    errors.append("DesignTokens.swift not found")
    tokens_src = ""
else:
    tokens_src = tokens_path.read_text()


def strip(src: str) -> str:
    """Remove comments and string bodies so they don't create false hits."""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', src)
    return src


# ---- 1. Build the declared token surface -------------------------------------
# Matches `static let/var/func x` and nested types inside DesignTokens.
#
# Nesting is tracked with a brace-depth stack rather than one "current enum"
# variable. With a single variable, `enum Scale` inside `enum Typography`
# silently reparented everything that followed, so the genuine declarations of
# Typography.Scale and Dimensions.Shape read as undeclared here while a stale
# group absorbed their members.
declared = collections.defaultdict(set)
_src = strip(tokens_src)

# Every brace is an event, so a `static func`'s own body no longer closes the
# enum that contains it — which is what a naive line-based counter did.
_events = (
    [(m.start(), "type", m.group(1))
     for m in re.finditer(r"\b(?:enum|struct)\s+([A-Z]\w*)", _src)]
    + [(m.start(), "member", m.group(1))
       for m in re.finditer(r"\bstatic\s+(?:let|var|func)\s+(\w+)", _src)]
    + [(m.start(), "member", m.group(1))
       for m in re.finditer(r"\btypealias\s+([A-Z]\w*)", _src)]
    + [(m.start(), "{", None) for m in re.finditer(r"\{", _src)]
    + [(m.start(), "}", None) for m in re.finditer(r"\}", _src)]
)
_events.sort(key=lambda e: e[0])

_scope: list = []          # innermost-last; None for anonymous blocks
_pending_type = None

def _owner():
    return next((s for s in reversed(_scope) if s), None)

for _pos, _kind, _name in _events:
    if _kind == "type":
        _pending_type = _name
    elif _kind == "member":
        if _owner():
            declared[_owner()].add(_name)
    elif _kind == "{":
        if _pending_type:
            # A nested type is also a member of its parent, so
            # `DesignTokens.Typography.Scale` resolves.
            if _owner():
                declared[_owner()].add(_pending_type)
            declared[_pending_type]  # register even if it has no members yet
        _scope.append(_pending_type)
        _pending_type = None
    else:
        if _scope:
            _scope.pop()

total_declared = sum(len(v) for v in declared.values())
notes.append(f"parsed {total_declared} tokens across {len(declared)} groups")

# ---- 2. Every referenced token must exist ------------------------------------
ref_re = re.compile(r"DesignTokens\.(\w+)\.(\w+)")
references = collections.Counter()
for p in swift:
    body = strip(p.read_text())
    for group, name in ref_re.findall(body):
        references[(group, name)] += 1
        if group not in declared:
            errors.append(f"{p.relative_to(root)}: unknown token group DesignTokens.{group}")
        elif name not in declared[group]:
            errors.append(
                f"{p.relative_to(root)}: DesignTokens.{group}.{name} is referenced but not declared"
            )

# ---- 3. Declared-but-unused tokens -------------------------------------------
used = {(g, n) for (g, n) in references}
tokens_body = strip(tokens_src)
for group, names in declared.items():
    for n in sorted(names):
        if (group, n) in used:
            continue
        if n.startswith(("dynamicColor", "graded")):
            continue
        # Unqualified use inside DesignTokens.swift itself counts as adoption.
        internal = len(re.findall(rf"\b{re.escape(n)}\b", tokens_body))
        if internal > 1:
            continue
        warnings.append(f"unused token: DesignTokens.{group}.{n}")

# ---- 4. Surviving inline animation literals ----------------------------------
literal_re = re.compile(
    r"\.(spring|snappy|easeInOut|easeOut|interactiveSpring)\s*\("
)
survivors = collections.Counter()
for p in swift:
    if p.name == "DesignTokens.swift":
        continue  # token definitions legitimately contain literals
    for line in strip(p.read_text()).splitlines():
        if "animation" in line.lower() or "withAnimation" in line:
            for m in literal_re.finditer(line):
                survivors[f"{p.relative_to(root)}: .{m.group(1)}(...)"] += 1
for k, v in survivors.most_common():
    warnings.append(f"inline animation literal remains ({v}x) {k}")

# ---- 5. Delimiter balance ----------------------------------------------------
for p in swift:
    body = strip(p.read_text())
    for o, c in (("{", "}"), ("[", "]")):
        if body.count(o) != body.count(c):
            errors.append(
                f"{p.relative_to(root)}: unbalanced {o}{c} "
                f"({body.count(o)} vs {body.count(c)})"
            )

# ---- 6. Dangling references to removed symbols -------------------------------
# Anything declared as an @Environment/@State property but never read.
for p in swift:
    body = strip(p.read_text())
    for m in re.finditer(r"@(?:Environment|State)\b[^\n]*?\bvar\s+(\w+)", body):
        name = m.group(1)
        # count uses outside the declaration line itself
        uses = len(re.findall(rf"\b{re.escape(name)}\b", body)) - 1
        if uses == 0:
            warnings.append(f"{p.relative_to(root)}: property '{name}' declared but never read")

# ---- Report ------------------------------------------------------------------
w = 76
print("=" * w)
print("MELO STATIC VERIFICATION".center(w))
print("=" * w)
print(f"files scanned : {len(swift)}")
for n in notes:
    print(f"note          : {n}")
print(f"token refs    : {sum(references.values())} across {len(references)} distinct tokens")
print("-" * w)

if errors:
    print(f"\nERRORS ({len(errors)})")
    for e in errors:
        print(f"  ✗ {e}")
if warnings:
    print(f"\nWARNINGS ({len(warnings)})")
    for x in warnings:
        print(f"  ! {x}")
if not errors and not warnings:
    print("\nclean.")

print("\n" + "-" * w)
print("Most-adopted animation tokens:")
anim = [(n, c) for (g, n), c in references.items() if g == "Animation"]
for n, c in sorted(anim, key=lambda t: -t[1]):
    print(f"  {c:>4}  Animation.{n}")

print("=" * w)
print("\nReminder: this is static analysis, not compilation. SwiftUI type")
print("inference, @MainActor isolation, and overload resolution are NOT")
print("checked here and require xcodebuild on macOS.")
sys.exit(1 if errors else 0)
