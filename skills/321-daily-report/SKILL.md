---
name: 321-daily-report
description: Use when adding a daily owner / business-metrics email to a Mojolicious app in the 123.do / 321 family - a branded morning digest of yesterday's KPIs (signups, active users, engagement, revenue) mailed to the business owner by cron. Triggers: daily report, daily alert email, owner report, metrics digest, KPI email, daily pulse, "keep me up to date with the numbers", report command, daily_report_to.
---

# Daily owner report (branded metrics email)

## Overview

One email at 07:00 each morning telling the owner how the business moved
yesterday: headline numbers in the subject, sectioned metric tables with
prior-day deltas and 7-day averages in the body, wrapped in the app's own
branded email shell. This is the shipped app.favsix.com implementation
(trend cells, send-once audit, flags, tests); the same shape runs in
app.paydance.com, app.wh.ax, api.123.do and love.honeywillow.com.
`templates/` are that real, tested code (`F6::` - rename to your namespace).

## When to use

- Any AXS-baseline app (321-bootstrap-saas) with real users/activity worth a
  morning pulse.
- "Email me the numbers every day" on an existing family app.

**Not for:** digests to many end users (that is a Minion-batched product
feature - see wh.ax `report monthly`); realtime alerting (this is a daily
summary, not a pager).

## The shape (see templates/)

| Piece | File | Job |
|---|---|---|
| Migration | `migration.sql` | `daily_reports` send-once audit (report_date PK) |
| Command | `Command-report.pm` | `report [YYYY-MM-DD] [--dry-run] [--force] [--to=ADDR]` - one shot: gather, render, send, record |
| Model | `Model-Reporting.pm` | `daily_summary($date)` - pure reads; every metric a trend cell `{value, prev, avg7, dir}` |
| SQL | `sql/*.sql.ep` | `day_axis` + one UNION ALL series query per section + leaderboard / funnel one-offs |
| Sender methods | `Email-Sender-report.pm` | `send_daily_report`, `_report_table`, `_delta_html`, preheader-aware `_shell` |
| Tests | `report-command.t`, `report-email.t` | lifecycle (idempotent / force / dry-run / inert) + livery assertions |

## The recipe

1. Migration: append `daily_reports`; bump the migration-version test; add the
   table to the harness truncate list.
2. Port `Model-Reporting.pm`. The **section methods and series queries are the
   adaptation point**: keep `_day_axis` / `_pivot` / `_trend` verbatim, swap
   the favsix tables for YOUR growth / engagement / billing metrics. Date
   filters stay in SQL as `AT TIME ZONE 'Europe/London'` casts - never Perl
   date math.
3. Add the sender methods to your baseline `Email::Sender`; replace `_shell`
   with the preheader-aware one so every app email keeps one livery. Subject =
   `<App> daily - <date>: <headline numbers>`, plain hyphens (no em-dashes
   anywhere - a test asserts it).
4. Port `Command-report.pm`: yesterday-in-London computed in SQL, empty
   recipient = inert skip, audit-row idempotency.
5. Config: `daily_report_to => 'nige@123.do'` in production.conf only; leaving
   it out of dev/test confs keeps the command inert there.
6. Port both tests: the command test stubs the `email_sender` helper with a
   counting fake; the email test overrides `_send` to capture subject/html and
   asserts the livery.
7. Cron on the **live** host, in the `ubuntu` crontab - same block 123.do,
   favsix and paydance already use (321 does not manage cron; document the
   block in the service repo, e.g. `docs/ops/daily-report.md`):

   ```
   # <app>-daily-report
   CRON_TZ=Europe/London
   0 7 * * *  /home/ubuntu/perl5/perlbrew/bin/perlbrew exec --with perl-5.42.0 env MOJO_MODE=production MOJO_CONFIG=/home/s3/<repo>/conf/production.conf PERL5LIB=/home/s3/<repo>/local/lib/perl5 perl /home/s3/<repo>/bin/app.pl report >> /tmp/<app>-report.log 2>&1
   ```

   Manual run on live: `321 do <service> live report` (add
   `--to you@example.com --force` for a test send).

## Decisions baked in

- **A one-shot `report` command, not a Minion task.** Cron runs it; it sends
  synchronously and dies loudly into the cron log on failure. One email a day
  needs no queue, no claim/release ledger, no worker dependency - the audit
  table already makes double-fires and re-runs harmless, and
  `321 do <svc> live report` re-sends by hand. All five shipped repos do it
  this way; keep the `report` name so the family muscle memory works.
- **Date = yesterday in Europe/London, computed in SQL.**
  `((now() AT TIME ZONE 'Europe/London')::date - 1)` - the subject, the audit
  key and every query agree, with no DateTime dependency and no OS/DB session
  timezone influence.
- **Every metric is a trend cell.** `{value, prev, avg7, dir}` over an 8-day
  `generate_series` axis. The delta arrow and the 7-day average are what make
  a single day's number readable; a bare count is noise.
- **One livery shell for all app mail.** The report reuses the sender's
  `_shell`, so passcode, invite and report emails read as one family. Never a
  second email layout - two shells drift apart.
- **Inert without a recipient.** Empty `daily_report_to` logs and returns;
  dev and CI can run the command safely.
- **Email-client-proof markup.** Table layout, inline styles only, absolute
  live-host logo URL, hidden preheader div, HTML entities for the delta
  arrows (`&#9650;`), never glyph literals.

## Common mistakes

See `references/gotchas.md` - the cron perlbrew/PERL5LIB trap, the Minion
temptation, second-shell livery drift, em-dash subjects, bigint numify, and
the boundary-seeding test trick.
