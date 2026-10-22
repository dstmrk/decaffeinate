---
name: decision-ledger
description: Use when closing out a task and handing work back to the user — writing the PR title or description, summarizing what was built, auditing the decisions taken where the prompt or the spec was silent, or reporting the size/cost of a change. Covers the squash merge (the PR title becomes the commit subject with a conventional-commit prefix, the body is written at ~70 columns because GitHub rewraps it, both finished before the merge), the choices ledger (what counts as a decision, entry format, verdict and confidence, least-confident first, an empty ledger on substantial work is a symptom), filing a leftover finding as a GitHub issue, and the mandatory cost table (production code, comments, selftest, docs, plus new structural surfaces). CLAUDE.md rule 8.
---

# decision-ledger — deliver the decisions, not the diff

Reading a diff line by line can't keep pace with how fast code gets
written, and a review that can't keep pace turns into a signature. So
the review moves to the object where human judgment actually decides
something: the decisions. This skill describes the end-of-task artifact.
It is a **pure audit**: it changes no code.

## What a decision is

A choice made **where the prompt, the spec or `CLAUDE.md` were silent**,
and that the user might want to overturn. In this app, for example:

- an invented threshold: polling interval, battery or heat cutoff, the
  settling window before sampling power draw;
- what happens to the Mac in an unplanned state (lid closed + external
  display, locked screen, crash mid-transition);
- a new command in `pmsetCmds`, i.e. a wider sudoers rule;
- a new `UserDefaults` key or menu item (it becomes a contract with
  existing installs);
- **something you decided NOT to do** when someone could reasonably
  expect it in this PR;
- a deliberate divergence from upstream (Pilot Light) or from a repo
  convention.

Not decisions: internal naming, formatting, and anything a `CLAUDE.md`
rule already mandates.

## Entry format

Each entry reads on its own, without the diff and without the chat.

```markdown
### <The choice in one line>

- **Scenario:** what happens to the user, end to end
- **The spec was silent on:** what wasn't specified
- **Rejected alternative:** …and why it lost
- **Consequences:** what becomes more expensive to change later
- **Verdict:** solid · to revisit · needs the user — confidence high/medium/low
```

## Hard rules

- **"It works" is not a verdict.** The question is which guarantee
  holds the behavior up (a `precondition`, CI, a described manual
  check), not whether the build is green.
- **Least confident first.** The reader's attention is finite: spend it
  where you are least sure.
- **An empty ledger on substantial work is a symptom**: reread the
  session and find the choices.
- **The audit doesn't block.** A "needs the user" entry without an
  answer doesn't stop delivery: adopt the provisional call, declare it
  as such and keep it reversible.
- **Say what you couldn't verify** (for example: no local build because
  the session ran on Linux; lid-closed behavior not tried on a MacBook).

## The PR body is a commit message

With squash merging, the PR title and body become the commit on `main`:
git history, the place `git blame` leads to. So:

- **title** = commit subject, with a conventional-commit prefix
  (`fix: …`, `chore: …`, `perf: …`);
- **body at ~70 columns**: GitHub rewraps it at ~72 and loses the
  continuation indent of lists. Single-line bullets, or paragraphs with
  a bold lead-in; keep tables narrow;
- **written before the merge**: afterwards it is immutable history;
- a squash creates a new commit: for a follow-up, restart from `main`
  (`git checkout -B <branch> origin/main`), even with the same name.

## A finding becomes an issue

A "to revisit" entry left open, or a defect found out of scope, becomes
a GitHub issue before the task closes, and the PR links it. Search open
issues first. The body reads on its own: **Problem** (concrete scenario,
numbers, date), **Fix** (decided, or options with the recommended one),
**Tests** (edge cases to cover), **Trigger** (what makes it urgent, if
deferred). A complete fix puts `Closes #N` in the PR; a partial one
mentions the issue without closing it.

## The cost table (always last)

```bash
git diff --stat origin/main...HEAD
```

|                                    | added | removed | net |
| ---------------------------------- | ----- | ------- | --- |
| Production code (no comments)      |       |         |     |
| Comments                           |       |         |     |
| Selftest                           |       |         |     |
| Docs, CI and Claude config         |       |         |     |

Then a paragraph on the **structural surfaces** added or removed, the
ones a line count hides: a sudoers command, a LaunchAgent, a
`UserDefaults` key, a menu item, a timer, a network request, a CI job. A
large net addition for a small behavior change is a finding to declare,
not to bury.
