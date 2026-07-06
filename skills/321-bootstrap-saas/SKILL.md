---
name: 321-bootstrap-saas
description: Use when starting a brand-new server-side-rendered SaaS web app in the 123.do / 321 family — an empty or near-empty repo that first needs the AXS baseline (Mojolicious app class, email-passcode sign-in, DB-backed sessions, accounts/teams + roles, the SQL-template DB layer, Minion, config + per-host secrets, test harness, 321.yml) before the 321-passkeys / 321-stripe / 321-sql-template skills can bolt on. Triggers: bootstrap, scaffold, skeleton, baseline, greenfield, "new Mojolicious SaaS", "start a new AXS app".
---

# Bootstrap a new SSR SaaS (AXS baseline)

## Overview

Scaffold the **base app that every other 321 skill assumes already exists**.
`321-passkeys`, `321-stripe`, and `321-sql-template` all bolt onto an app that
already has: a `<NS>::Web` Mojolicious class, email-passcode sign-in, a
DB-backed `sessions` table + `current_user`/`start_session_for` helpers, an
`accounts` (personal + team) model with owner/admin/member roles, the
`$db->query('group/name', {...})` SQL-template layer, Minion, `conf/<mode>.conf`
merging a git-ignored `conf/secrets.local.conf`, a `Test::Mojo` harness, and a
`321.yml`. This skill ships that base as **real, runnable, tested code** in
`templates/skeleton/` — copy it, rename, and you have a live app the feature
skills extend.

The worked example is namespaced `L2D::` / `l2d` (the app it was first cut for,
love2.do) exactly as the sibling skills use `F6::` / favsix. **Rename it to
yours** (see step 2).

## When to use

- The repo is empty (or just a spec/brand) and you need a working SSR app before
  any product feature.
- You are about to adopt `321-passkeys` or `321-stripe` and there is no AXS base
  for them to attach to.
- You want the 123.do house conventions (passcode auth, SQL templates, Minion,
  `321` deploy) rather than inventing an architecture.

**Not for:** an app that already has the AXS base (go straight to the feature
skill); non-Mojolicious stacks; password/OAuth auth (this baseline is
passcode-first by design — passkeys are added later as a faster path).

## What it ships (`templates/skeleton/`)

```
bin/l2d                     entry script (sets MOJO_HOME/MODE/CONFIG + reverse-proxy; starts L2D::Web)
cpanfile                    Mojolicious, Mojo::Pg>=5, Minion, Nanoid (versions pinned)
321.yml                     service manifest for `321 go` (web + minion worker)
.gitignore                  ignores local/, logs, conf/secrets.local.conf
conf/development.conf       hashref config; merges conf/secrets.local.conf via $MOJO_HOME
conf/production.conf        live config (cookie_domain set here)
conf/secrets.local.conf.example   per-host secrets template (never commit the real one)
db/migration.sql            "-- 1 up": users, passcodes, sessions, accounts, account_members
lib/L2D/Web.pm              app class: config, db+migrations, Minion, helpers, routes
lib/L2D/DB.pm + DB/SQL.pm   the SQL-template engine (see 321-sql-template)
lib/L2D/Auth/{Sessions,Passcodes,Roles}.pm   AXS identity core
lib/L2D/Model/{Users,Accounts}.pm            user + personal/team account model
lib/L2D/Email/Sender.pm     Postmark sender (logs instead of sending with no token)
lib/L2D/Web/Controller/*    Home, Health, Auth (passcode), Signup, Accounts
templates/…, public/…       minimal layout, auth pages, starter CSS
t/…                         Test::L2D harness + 00-load, 01-migration, 02-auth
```

## The recipe

1. **Copy the skeleton into your repo root.**
   `cp -a <this skill>/templates/skeleton/. /home/s3/app.yourapp.dev/`
   (`cp -a` preserves the `bin/l2d` exec bit and the dotfiles.)

2. **Rename the example to your app.** Two tokens: the Perl namespace `L2D` and
   the lowercase slug `l2d`. From the repo root:
   ```bash
   grep -rlZ -e 'L2D' -e 'l2d' . | xargs -0 sed -i -e 's/L2D/YourNs/g' -e 's/l2d/yourslug/g'
   mv lib/L2D lib/YourNs
   mv t/lib/Test/L2D.pm t/lib/Test/YourNs.pm
   # optionally rename bin/l2d -> bin/yourslug and update 321.yml `entry:`+worker cmd
   ```
   Review the diff — pick real hosts/ports in `321.yml`, a real
   `db_connect_string`, and fresh `cookie_secrets`. Then set the three
   `CHANGE-ME` values in `321.yml` by hand (`repo:`, `ssh:`, `ssh_key:`) —
   they are deliberately sed-proof so a bulk rename cannot half-rewrite them.
   **Residue gate (mandatory before the first deploy):**
   ```bash
   grep -rn CHANGE-ME . --exclude-dir=local && echo "STOP: placeholders remain"
   ```
   A compound placeholder that shares a substring with your domain WILL be
   half-rewritten by rename seds into something that looks right and fails
   much later (see gotchas: the `you/` clone failure).

3. **Install deps into a project-local lib** (never rely on ambient site_perl —
   see gotchas): `cpanm -L local --installdeps .`

4. **Create the databases:** `createdb yourslug` and `createdb yourslug_test`.
   `auto_migrate(1)` applies `db/migration.sql` on first DB use — no manual
   migrate step.

5. **Run the tests:** `MOJO_CONFIG=t/conf/test.conf PERL5LIB=local/lib/perl5 prove -lr -It/lib t`
   — 00-load, 01-migration, 02-auth (the full passcode → session flow) should be
   green.

6. **Run it locally** (via the 321-command skill): `321 go yourslug.web` — or
   `morbo -l http://*:8500 bin/l2d` for a quick loop. Passcode emails are
   **logged** (grep the log for the code) until a Postmark token is set.

7. **Deploy** with `321 go yourslug.web live` once `321.yml` live host/ssh are
   filled in. See the **321-command** skill; do not hand-roll ubic/nginx/certbot.

## The seam: base vs feature skills

The base owns the identity core; each feature skill appends the next
`-- N up` migration block, adds its tables to the `Test::L2D` truncate list, and
registers its own helpers/routes/Minion tasks. Keep the base's helper **names
and shapes** stable — that is the contract.

| Concern | Owned by | Bolt-on hook |
|---|---|---|
| users, passcodes, sessions, accounts, account_members | **this skill** (`-- 1 up`) | — |
| `<NS>::Web` app class, `db`/`current_user`/`start_session_for` helpers | **this skill** | feature skills add helpers alongside |
| SQL-template engine (`DB.pm`, `DB/SQL.pm`) | this skill ships it | **321-sql-template** — the authority on it |
| passkeys (`webauthn_credentials`, WebAuthn routes) | **321-passkeys** | reuses `start_session_for`; `-- N up` |
| Stripe billing (accounts billing cols, `stripe_events`) | **321-stripe** | reuses `can_administer_team`; `-- N up` |
| deploy / restart / logs | **321-command** | reads `321.yml` |

## Decisions baked into the skeleton

- **Passcode-first auth, no passwords.** A 6-digit code (sha256-hashed at rest)
  proves the email; `find_or_create_by_email` makes the user. Passkeys come
  later as a faster path, never a prerequisite.
- **Two cookies, two jobs.** The Mojolicious signed-cookie session (`l2d`) holds
  only transient flow state (sign-in email in flight) and is **host-only**.
  Login persistence is a **separate DB-backed `l2d_session` cookie** carrying a
  Nanoid token whose only the sha256 hash is stored — so sessions are revocable.
- **SQL in templates, not an ORM.** Every query is `sql/<group>/<name>.sql.ep`,
  called by name. Values always bind via `[name]`; never interpolate.
- **`auto_migrate(1)`.** Pending `-- N up` blocks apply lazily on first DB use.
- **Secrets never committed.** `conf/<mode>.conf` merges a git-ignored
  `conf/secrets.local.conf`, keyed on `$ENV{MOJO_HOME}`.
- **Async via Minion (Pg backend).** Email sends from a worker, so delivery
  survives the request and retries with backoff.
- **`321` owns deploy.** `bin/l2d` behind hypnotoad + nginx; never invoke
  ubic/morbo/certbot directly.
- **No en- or em-dashes, anywhere.** House copy rule: never use `–`, `—`,
  `&ndash;` or `&mdash;` in templates, code comments, user-facing copy, README
  or commit messages - write a plain hyphen (" - ") instead. Typographic
  middots as brand marks are fine; long dashes are not.
- **Every source file opens with the copyright header.**
  `# Copyright Nige Ltd. Author: Nigel Hamilton.` is line 1 of every Perl
  module, script, test and conf file (line 2 under a shebang); `/* ... */`
  form in CSS, `// ...` form in JS. The skeleton ships it everywhere; every
  source file you ADD to the app carries it too. (SQL templates and .html.ep
  partials are exempt - house practice keeps those header-free.)

## Verify

- `prove -lr -It/lib t` green (the 3 base tests exercise health, migration, and
  the end-to-end passcode sign-in that sets the session cookie).
- Copyright-header gate (run from the repo root; also rerun it before any
  later commit that adds source files):
  ```bash
  grep -rL 'Copyright Nige Ltd' lib bin t conf public && echo "STOP: header missing"
  ```
- `bin/l2d get /health` prints `ok`.
- Sign up in a browser, grep the log for the passcode, enter it, land on
  `/@yourhandle`.

## Common mistakes

See **references/gotchas.md** — the non-obvious failures (Mojo::Pg version drift
vs Minion, the `@INC` glob that breaks `321 do`, lazy `auto_migrate`, the
`$MOJO_HOME` secrets-merge dependency, the host-only session-cookie collision,
in-process SQL-template caching) that otherwise cost hours.
