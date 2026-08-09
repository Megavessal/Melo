# Skill friction log

Cross-project friction with `vibe-coding-superpower`, `stop-the-slop` and
`gauntlet-loop`, recorded during builds and read during distillation.

**This file is tracked in git on purpose.** `.run-notes/` is gitignored and must
stay that way — it is session handoff material. But friction is cross-project and
has to survive a clone, so it cannot live there. Three prior runs wrote no
friction log at all, and AAR #3 §3.2 traces that directly to the only
durable-looking place to put one being an ignored directory.

One entry per item. Date it. Say what it cost, not just what happened.

---

## 2026-08-08 — the friction log had nowhere durable to live

`self-improvement.md` says to write it into the project repository. The project
correctly gitignores `.run-notes/`, which is where every other cross-session
document ended up, so the guidance and the project's convention combined to
produce no log at all across three runs.

**Cost:** AAR #3 had to be reconstructed from commit messages and the merged pull
request body. That worked only because this project writes unusually detailed
commit messages; on a normal repository the material would simply be gone.

**How to apply:** a gitignored state directory is not durable storage. Run state
is project-local; friction is cross-project. Keep them apart.

---

## 2026-08-08 — telemetry is visible only in the session that spawned the agent

`NEXT-SESSION.md` asked for a third data point on critic wall-clock, and the
handoff pointed at the task notifications. Those belong to a session that had
already ended. Transcript search returns one snippet per session and cannot
reconstruct a per-agent table.

**Cost:** the third data point does not exist and cannot be recovered. Two runs
of critic-cost data is all there will ever be for rounds 1-6.

**How to apply:** append per-agent tokens, tool calls and wall clock to the state
file as each notification arrives. An instruction to collect telemetry that lives
in a handoff always reaches the session *after* the one that could have collected
it.

---

## 2026-08-08 — the invocation of three skills has become ritual

This session was opened as `/vibe-coding-superpower /gauntlet-loop
/stop-the-slop` for a task whose deliverable was an assessment document.
`gauntlet-loop`'s own description excludes that case in its first paragraph
("not for questions and assessments rather than artifacts"), and it was invoked
anyway because the three names now travel together.

**Cost:** context only, not correctness. Recorded because the trend is the thing
to watch, not this instance.

**How to apply:** the judgment lives in `gauntlet-loop`'s "when this is worth
running" section and it works when read. Stacked slash commands skip the reading.
No skill change proposed — a skill that argues with its own invocation is worse.

---

## 2026-08-08 — two loaded skills contradict each other on concurrent file access

`long-run-autonomy.md:66` says never let two agents edit the same files
concurrently. `gauntlet-loop:223` deliberately qualifies exactly that, because
proving a check can fail requires breaking something, sometimes in a file you do
not own. The correction from AAR #2 landed in one skill and not the other.

**Cost:** none this run — the lead followed the more specific skill. But an agent
reading both has a flat prohibition and a qualified protocol with no rule for
resolving them. Only `stop-the-slop` carries a precedence rule.

**How to apply:** see AAR #3 §8.10. Narrow the general skill's version, or have
it defer when the specialist is loaded.

---

## 2026-08-08 — a warning about a blocking prompt arrived only in prose

The handoff warned that `Build Melo.command` ends with `read -r` and can hold the
shared build lock indefinitely. Checking whether `dev-verify.sh` shared that
problem took one grep and it did not — the blocking read is only in the
double-clickable wrapper.

**Cost:** near-zero here, twenty minutes on the run that discovered it.

**How to apply:** the generalisable half is in AAR #3 §4.4 and §8.9 — a finished
process waiting on a keystroke satisfies every liveness signal `gauntlet-loop`
names. Redirecting stdin from `/dev/null` on any long script is free insurance
and worth doing unconditionally.

---

## 2026-08-08 — a scene note that was true of the model and false of the frame

While retuning rocket frequency I read a harness note saying "two should be in
flight" against a frame showing one, and nearly changed working code. Computing
the lane positions showed two lanes genuinely in flight with the second at
x=-52, off the left edge. The note described internal state; the frame is what a
reader checks.

**Cost:** about fifteen minutes, and it would have been a wrong fix rather than a
wasted one.

**How to apply:** general enough to keep — a note attached to a rendered artifact
must describe what is *visible*, not what the model is doing. This is the same
class as `stop-the-slop`'s process-files-are-in-scope rule
(`SKILL.md:42`), one level more specific.

---

## 2026-08-09 — a critic that built nothing found what eleven builders and eighteen scripts missed

The Cutting Room run. `setAnalysis` had zero callers, so `document.analysis` was
nil for the life of every document and "Fix it for me" was permanently disabled
in any shipping build. Eleven builders, ~45 executed DSP assertions, and every
verify script were green. A fresh adversarial critic with no stake found it in
an hour, and the same critic found `revertToOriginal()` documented twice in the
indexed Guide with no caller, and two of four entry points dying after the first
file opened.

**Cost:** none, because it was caught. It would have been the whole feature.

**How to apply:** `gauntlet-loop` says a fresh-context critic beats an agent
checking itself, and it is right, but the sharper point is *which* critic. The
per-piece critics this run never ran — there was nothing rendered to judge until
very late. What paid was the two whole-artifact critics spawned at the end, one
adversarial and one for coherence. If a run can only afford two critics, those
two beat six per-piece ones.

## 2026-08-09 — every frame showing the feature working came from dev-only seeding

Directly downstream of the above, and worse. The harness seeds state with
`#if MELO_DEV` initialisers so a frame can show a populated view. That means a
rendered frame proves the *view* draws state correctly and says nothing about
whether the app can ever produce that state. I looked at a frame captioned
"the file measured, the full proposal on the stack — the state the feature
exists to produce", called the analysis panel the best thing in the feature, and
it could never appear.

**Cost:** two hours of confidence in the wrong thing.

**How to apply:** seeded frames and wiring checks answer different questions and
neither substitutes for the other. `verify-editor-wiring.py` — open a real file
through the real store, assert a measurement lands — is the shape that closes
it. A caller-existence grep is not: it passes the moment a symbol is named
anywhere, including from dead code.

## 2026-08-09 — three checks in one run were blind to the configuration that ships

`swiftc -parse` was green for hours on a missing `import SwiftUI`. `-typecheck`
is blind to Swift 6 isolation errors inside a `deinit`. And `-typecheck` without
`-D MELO_DEV` never parses the harness fixtures at all — which is where a
waveform fixture sat producing plausible-looking wrong output.

**Cost:** roughly an hour across three separate discoveries, each found by the
next tool up rather than the one before it.

**How to apply:** not "use a stronger tool" — a check has to run in the
configuration the code ships in. Now in `CLAUDE.md`.

## 2026-08-09 — the lead cited an instrument reading that was not evidence

I told a builder its window clipped, citing the harness's own `CLIPPED?` warning
on the provenance band. The overflow was real; the citation was worthless. The
builder replicated `featurelessRows` and showed Melo's *own* Settings frames
score 11 and 15 distinct colours on the last row against the Cutting Room's 6 —
any window using `meloThemeBackground` paints a gradient to every edge, so that
warning can never be cleared and never distinguishes anything.

**Cost:** near zero, because the builder checked instead of complying.

**How to apply:** `agent-briefs.md`'s "ask rather than correct" earned its place
three times this run — on the window class, on this, and on a crash where all
three of my hypotheses were refuted with evidence. The form that works is
naming the doubt, saying explicitly that you are not supplying the answer, and
closing with *go look*. Worth noting the failure mode it prevents is the lead's,
not the builder's.
