# Gotchas

## The cron line (the most common failure)

A bare crontab entry runs the WRONG PERL and a half-configured app. Every part
of the house block exists for a reason:

- `perlbrew exec --with perl-5.42.x` - bare `perl` under cron is the system
  perl; the app's runtime lives in perlbrew.
- `PERL5LIB=/home/s3/<repo>/local/lib/perl5` - required; without it the
  bundled Mojolicious is shadowed by the system one and the app won't boot.
- `MOJO_MODE=production MOJO_CONFIG=...` - cron's environment is empty;
  nothing is inherited from your shell.
- `CRON_TZ=Europe/London` - fires at 07:00 London through BST/GMT flips. The
  report *date* is computed in London time in SQL anyway, so a drifted fire
  time changes nothing about the content.
- The live crontab user is `ubuntu` (zorda), not root and not s3. Log to
  `/tmp/<app>-report.log`.
- 321 does not install or manage this cron. It is per-service ops - keep the
  block in the service repo (paydance keeps `docs/ops/daily-report.md`; copy
  that habit) and reinstall by hand if the host is rebuilt.

## The Minion temptation

Enqueue-from-cron, claim/release ledgers, retry backoff: for one owner email
a day this is machinery without payoff. The house failure mode is benign: the
command dies, the cron log shows it, tomorrow's run still fires, and
`321 do <svc> live report --force` re-sends today by hand if it mattered.
Only reach for Minion when the report becomes a *product* email to many
recipients (see wh.ax `report monthly`).

## Livery drift (the second shell)

The passcode email and the report must share the sender's `_shell`. If you
find yourself creating `templates/layouts/email.html.ep` alongside it, you
are forking the brand - fold it back into the sender. (wh.ax renders template
*files* through its sender instead of string-building; acceptable variant,
still exactly one shell.)

## Subject line rules

- Headline numbers go IN the subject
  (`FavSix daily - 2026-06-12: 3 signups, 2 active`) - the owner triages from
  the inbox list without opening.
- Plain ` - ` separators; the email test asserts `unlike qr/\x{2014}/`.
  Em-dashes are banned copy-wide in this family.
- Quiet-day variant (paydance refinement, worth porting): when every
  yesterday metric is zero, render one calm line -
  "A quiet day - no new activity." - and end the subject with "a quiet day"
  instead of sending a table of zeros.

## SQL traps

- Never compare a `timestamptz` column to a bare date: both sides must pass
  through `AT TIME ZONE 'Europe/London'`, with half-open bounds
  (`>= day, < day+1`). Grouping uses
  `to_char((col AT TIME ZONE 'Europe/London'), 'YYYY-MM-DD')`.
- Postgres `count(*)` comes back as a string-y bigint - numify with `+ 0`
  before it hits JSON or sprintf (`Model-Reporting.pm` does this everywhere).
- The `generate_series` day axis keeps zero-activity days present; deriving
  the axis from the data would silently skew `avg7`.
- Repeated `[bind]` placeholders in one `.sql.ep` are fine - the engine emits
  one `?` per occurrence.

## Testing

- The command test never touches the network: override the `email_sender`
  helper with a counting fake (`report-command.t`). Covers idempotency,
  `--force`, `--dry-run`, and the inert-without-recipient path.
- The livery test builds a fixture summary hash and overrides `_send` to
  capture subject + html (`report-email.t`): branded subject with headline
  numbers, every section present, footer host, no em-dash.
- When adapting series queries, seed boundary rows (23:59 London vs 00:01 the
  next day) and assert exact counts - this pins the `AT TIME ZONE` logic,
  including across DST.

## Porting checklist

- Rename `F6::` to your namespace; `Test::F6`/`test_mojo` to your harness.
- The favsix tables in `sql/*.sql.ep` (`favarrays`, `tile_clicks`,
  `accounts`, `stripe_events`) are the adaptation point - swap for your own
  growth / engagement / billing sources. Keep `day_axis.sql.ep` verbatim.
- Keep `_day_axis` / `_pivot` / `_trend` verbatim in the Reporting model.
- `Command-report.pm` uses `$db->raw(...)` for the two inline queries (date
  resolution + audit); the AXS baseline `DB.pm` ships `raw`, so this ports
  as-is.
- `daily_report_to` goes in production.conf only. The billing section assumes
  321-stripe (`stripe_events`, `billing_status`); trim it if the app has no
  billing yet, and add it back when 321-stripe lands.
