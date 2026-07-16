# Repo-constitution audit checklist

Score each item red/green for the repo under audit; fix reds top-first
(the list is in leverage order). An item is green only if it is TRUE ON
DISK - "we usually do this" is red.

## Pillar 1 - test command + deploy gate

- [ ] ONE documented test invocation, copy-pasteable, with any
      interpreter/lib pinning baked in. The tempting wrong variant is
      named in CLAUDE.md with why it breaks.
- [ ] Full suite runs in under ~a minute (agents run it constantly;
      minutes-long suites silently stop being run).
- [ ] Tests exercise the app at the HTTP level (Test::Mojo or
      equivalent), not just units - deploy confidence comes from
      request-in/response-out pins.
- [ ] The deploy tool RUNS the suite and refuses to ship red. Not a
      convention - a gate.
- [ ] Deploy verification is by served content / version marker.
      Grep the docs: if the word "200" appears as a success criterion,
      red. (The port-collision lie: any process holding the port
      passes a status check.)

## Pillar 2 - process artifacts

- [ ] specs/ and plans/ directories exist with the date-slug convention.
- [ ] Plans contain verbatim code blocks + exact commands (transcribe,
      don't interpret).
- [ ] A ledger exists and its last entry matches the repo's actual
      latest shipped state (a stale ledger is worse than none).
- [ ] Design approval happens before implementation, with forks asked
      as explicit either/or questions and answers recorded in the spec.

## Pillar 3 - pins + review

- [ ] The repo's tests fail when the behaviour they pin is broken -
      spot-check by mutation: gut one guard (auth check, WHERE clause,
      sanitizer) and confirm at least one test goes red. Revert.
- [ ] New features add tests written FIRST (the plan's step order shows
      it: test step precedes implementation steps).
- [ ] Review is a separate fresh context from implementation, judging
      the commit against the spec, empowered to run/mutate tests.
- [ ] Review happens for small diffs too.

## Pillar 4 - low entropy

- [ ] Pick any layer (model/controller/SQL/test): do three random files
      share one shape? If a new file could plausibly follow two
      different in-repo idioms, that layer is red.
- [ ] Tests share fixture/sign-in helpers by copying a named exemplar
      (CLAUDE.md names it), not by reinventing per file.
- [ ] SQL is in named per-query files, not inline strings
      (321-sql-template).

## Pillar 5 - memory + skills

- [ ] CLAUDE.md exists, is terse/imperative, and contains the repo's
      REAL observed gotchas (not aspirations). Every entry earned by an
      actual incident.
- [ ] Gotchas get appended the moment they are learned, mid-session.
- [ ] Patterns proven here and useful elsewhere have been extracted to
      shared skills (321-skill for placement) by porting the real,
      tested code - not rewritten from memory.

## Anti-checklist (these being ABSENT is green)

- [ ] No vector-DB/custom memory infrastructure.
- [ ] No CI pipeline duplicating what the deploy gate already enforces.
- [ ] No speculative convention rules nobody has violated.
- [ ] No restructuring-to-mirror-another-repo work items.
