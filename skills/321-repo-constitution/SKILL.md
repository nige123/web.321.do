---
name: 321-repo-constitution
description: Use when a repo feels less effective with coding agents than it should - the agent re-learns deploy quirks each session, ships style-drift, verifies deploys that didn't happen, loses design context on crash/compaction - or when standing up agent discipline in an existing repo, writing its CLAUDE.md, or porting "why does repo A work so well" to repo B. Triggers: agent-ready, repo constitution, CLAUDE.md, ineffective sessions, lost context, re-learning gotchas.
---

# Repo constitution: what makes a repo agent-effective

## Overview

An agent's context is volatile; a repo's files are not. Every recurring
agent failure is knowledge that lived only in a conversation. The
constitution is the set of on-disk artifacts + disciplines that let a
fresh agent (or the same one after a crash) be immediately effective -
proven on favsix.com, where features ship end-to-end in hours and
independent review has caught real pre-ship vulnerabilities.

For a GREENFIELD 321-family app, use 321-bootstrap-saas first - it
ships this baseline. This skill is for existing repos and for the
discipline layer no scaffold can install.

## The five pillars (priority order)

### 1. One fast test command, and a deploy gate that RUNS it

A full HTTP-level suite runnable in seconds via one blessed invocation
(document the EXACT command - interpreter/lib pinning included, e.g.
`PERL5LIB=local/lib/perl5 prove -l t/...`, never bare `prove`). Then
the critical move the obvious setup misses: **the deploy tool itself
runs the suite and refuses to ship red.** A rule says "test before
deploy"; a gate makes forgetting impossible. Mechanical enforcement
beats instruction everywhere you can afford it (interpreter
self-checks, version-stamped smoke endpoints, the gate).

### 2. Session-survivable process artifacts

Three layers, all in-repo:
- **Spec** (`docs/.../specs/<date>-<slug>-design.md`) - the approved
  design. The user approves it BEFORE code; design forks are asked as
  explicit either/or questions, and the answer is recorded in the spec.
- **Plan** (`docs/.../plans/<date>-<slug>.md`) - steps with **verbatim
  code blocks**, exact test commands, exact commit message. A plan an
  agent must interpret produces variance; a plan it can transcribe
  produces the reviewed design. Verbatim plans are what make fresh,
  even cheap-model, implementer subagents reliable.
- **Ledger** (`.superpowers/sdd/progress.md` or similar, git-ignored is
  fine) - append-only record across features: what shipped, commits,
  review verdicts, accepted minors, deploy verifications. The plan
  resumes one feature; the ledger resumes the PROJECT. After any crash
  or compaction, the next session reads the ledger instead of
  re-deriving state. See `templates/progress-ledger.md`.

### 3. Tests as pins, born red

Every behaviour worth keeping gets a pin that FAILED before the fix
existed (watch it fail for the right reason, then make it pass). For
security-relevant pins, **mutation-test once**: break the guard
(drop the WHERE clause, gut the sanitizer) and confirm the pin fails -
a pin that can't fail isn't a pin. Independent review (fresh subagent,
no shared context with the implementer, judging the commit against the
spec) is where this pays: reviewers who can cheaply run and mutate the
suite catch the bugs the implementer can't see.

### 4. Low entropy: one idiom per layer

New code should be "the same shape as the last ten features": one
house pattern for models, one for controllers, one for SQL (each query
its own named file - see 321-sql-template), one fixture idiom in tests
("copy t/09's sign_in helper"), one header-comment style. The agent
pattern-matches from neighbouring files instead of inventing, so style
drift never starts and briefs can say "match the file next door".
Add a convention rule only after its violation actually occurred.

### 5. Captured gotchas + extracted skills

- Operational traps (the deploy false-positive, the stale-interpreter
  trap, the port-collision lie) go in durable memory/CLAUDE.md **the
  moment they're learned**, mid-session - sessions crash, files don't.
- When a pattern proves out in one repo, **extract it into a shared
  skill** (see 321-skill for placement): port the real, tested code
  with adaptation notes, not a from-memory rewrite. Skills are the
  cross-repo transfer mechanism - this document is itself one.

## Bootstrapping an existing repo

1. Write `CLAUDE.md` from `templates/CLAUDE.md` - fill in the EXACT
   commands and the repo's real, already-observed gotchas. Terse and
   imperative; pointers over prose.
2. Get the suite to one fast command; wire the deploy gate to it.
3. Create the specs/plans/ledger locations; adopt the cadence
   (spec -> approval -> plan -> fresh implementer subagent ->
   independent reviewer -> ship) for anything non-trivial.
4. Audit with `references/audit-checklist.md`; fix the reds
   highest-leverage first.

## What NOT to build

No vector-DB memory (a read-first markdown file wins at this scale),
no heavyweight CI while the deploy gate runs the suite, no bespoke
lint tooling beyond a checked-in formatter config, no restructuring a
working repo to mirror another's skeleton - port the disciplines, not
the layout. Don't pre-enumerate hypothetical failures: constitution
entries are earned by something actually biting.

## Common mistakes

The top three: **verifying deploys by status code** (a 200 can come
from the old process still holding the port - verify served content or
a version marker); **plans that describe instead of transcribe**
(interpretation is where implementer variance enters); **treating the
review as optional when the diff looks small** (today's small diff is
where the open redirect lives). More in `references/audit-checklist.md`.
