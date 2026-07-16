# <REPO> - agent instructions

<!-- Template from 321-repo-constitution. Fill every <PLACEHOLDER> with the
     repo's REAL commands and observed gotchas; delete sections that do not
     apply. Keep it terse and imperative - pointers over prose. Add rules
     only after their violation has actually occurred once. -->

## Commands - use these EXACTLY, never variants

- Test (always, no exceptions): `<EXACT TEST COMMAND, e.g. PERL5LIB=local/lib/perl5 prove -l t/...>`
  Never `<the tempting wrong variant, e.g. bare prove - it hits the stale system libs>`. Never parallel flags if the suite is serial.
- Deploy: `<EXACT DEPLOY COMMAND, e.g. bin/321 go app.web dev|live>` - the live gate runs the suite; do not bypass it.
- Service lifecycle ONLY via the deploy tool - never pkill/systemctl/raw process control.

## Verify deploys by CONTENT, never by status code

A 200 can come from the old process still holding the port. After every
deploy check at least one of: served asset version (`css?v=NN`), a
version marker, or the behaviour the change introduced.
`<EXACT SMOKE CHECK, e.g. curl -s https://host/ | grep -o 'app.css?v='>`

## Process for non-trivial changes

1. Spec first: `docs/<...>/specs/<date>-<slug>-design.md`; get it approved before code. Ask design forks as explicit either/or questions; record the answer.
2. Plan: `docs/<...>/plans/<date>-<slug>.md` with verbatim code blocks, exact test commands, exact commit message.
3. Implement via a fresh subagent following the plan; tests written FIRST and seen to fail for the right reason.
4. Review via a second fresh subagent (no shared context) judging the commit against the spec. Never skip for small diffs.
5. Ship: full suite -> commit -> push -> deploy dev -> deploy live -> verify by content.
6. Append the outcome to the ledger: `<LEDGER PATH, e.g. .superpowers/sdd/progress.md>`.

## Style

- Match the neighbouring file: same idioms, same fixture helpers, same header comments. When in doubt, copy the shape of `<EXEMPLAR FILE>`.
- SQL lives in named template files (`sql/<group>/<name>.sql.ep`), never inline strings.
- Commit messages: subject + body explaining why. No AI-attribution trailers.
- User-facing copy rules: `<e.g. plain hyphens " - ", never em-dashes>`.

## Known gotchas (append the moment you learn one - mid-session, not at the end)

- `<gotcha 1: e.g. deploy port_check passes if ANY process holds the port>`
- `<gotcha 2: e.g. dev nginx config step needs sudo and always FAILs - known-harmless>`
- `<gotcha 3>`
