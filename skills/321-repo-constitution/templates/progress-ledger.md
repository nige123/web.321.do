# <REPO> - SDD progress ledger

<!-- Template from 321-repo-constitution. Append-only; newest at the bottom.
     One block per shipped feature (or per meaningful attempt). This file is
     the project's recovery map: after a crash or compaction the next session
     reads this instead of re-deriving state. Git-ignored is fine - it is an
     operational log, not documentation. -->

## <FEATURE NAME> SHIPPED (<date>)

- Trigger: <user request or observed bug, one line>
- Spec: <path> (status: approved "<user's approval words>")
- Plan: <path>
- Task 1: commit <hash> - <one-line what>. Implementer <model/agent>, TDD red->green.
- Review round 1: <Approved | NEEDS FIXES + the findings, one line each,
  with severity and whether confirmed-exploitable or speculative>
- Fix: commit <hash> - <what changed>; new pins failed red first.
- Re-review: <verdict + what the reviewer re-verified>
- Ship: pushed <range>; dev + live deployed; live verified by CONTENT: <the exact checks and what they showed>
- Suite: <N> tests green (was <M>; +<what was added>)
- Accepted minors / follow-ups (recorded, NOT committed to): <list or "none">
