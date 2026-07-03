# Bootstrap gotchas

The non-obvious failures when standing up (and first deploying) the AXS
baseline. Most cost hours because the app *looks* fine until a specific path
runs.

## Mojo::Pg version drift breaks Minion

`Minion::Backend::Pg` requires **Mojo::Pg >= 5**. A perlbrew's ambient
`site_perl` often carries an older Mojo::Pg (e.g. 4.29), so running the suite or
the app against ambient libs dies at startup with:

```
Mojo::Pg version 5 required--this is only version 4.29 at .../Minion/Backend/Pg.pm
```

Fix: install deps into a **project-local** `local/lib/perl5`
(`cpanm -L local --installdeps .`) and always run with that ahead of ambient —
which is exactly why `321.yml` pins `test: PERL5LIB=local/lib/perl5 prove -lr t`.
The pinned `cpanfile` requires `Mojo::Pg >= 5.0` so a fresh install can't regress
to the old one. Never let ambient site_perl decide whether a deploy ships.

## The `@INC` glob that breaks `321 do`

`bin/l2d` prepends `local/lib/perl5` to `@INC` — but must **not** glob every
subdirectory of it onto `@INC`. A namespace dir (e.g. `HTTP/`) then shadows core
`Config.pm`, and every `321 do <svc> <subcommand>` dies with
`Global symbol "%Config" requires explicit package name`. The hypnotoad daemon
dodges it (it loads `Config` early); subcommands don't. The shipped `bin/l2d`
does the right thing (single `unshift`, no glob). If you ever add arch-specific
paths, resolve only `$Config{archname}`, never the whole tree. `321 doctor`
locates an offending script.

## `auto_migrate` is lazy — runs on first DB use, not at boot

`$pg->auto_migrate(1)` applies pending `-- N up` blocks the first time the app
touches the DB, **not** when the process starts. So a fresh deploy has *not*
migrated until the first request that hits Postgres. Consequences:

- A health check that avoids the DB will pass before the schema exists.
- Two blocks with the same number, or an **edit to an already-applied block**,
  will not re-run. Never edit a shipped `-- N up`; always add the next number
  and bump `t/01-migration.t`'s expected version.

## The secrets merge needs `$ENV{MOJO_HOME}`

`conf/<mode>.conf` merges `conf/secrets.local.conf` only when
`$ENV{MOJO_HOME}` is set (`bin/l2d` sets it, and `321 do` reproduces it). If you
run the app some other way without `MOJO_HOME`, the merge **silently no-ops** and
every secret (Postmark token, Stripe keys) reads as its empty default — mail is
logged instead of sent, Stripe is inert — with no error. Symptom: "it works on
the daemon but a subcommand can't see the keys." Set `MOJO_HOME`.

## The session cookie must stay host-only

There are two cookies and they must not collide:

- `l2d` — the **Mojolicious signed-cookie session**. Transient flow state only
  (the sign-in email in flight). **Host-only: never give it a `Domain`.**
- `l2d_session` — the **DB-backed login** cookie (a Nanoid token; only its
  sha256 hash is stored). In production this one sets `Domain` (`cookie_domain`)
  so login persists across apex + subdomains.

If you give the Mojo session a `Domain`, the same cookie name exists at both the
host and the parent domain; the browser sends the **stale** one, transient state
(and later the WebAuthn challenge) is lost, and passkey login fails with
`no_challenge`. Keep login in `l2d_session`, not the Mojo session.

## Passcodes and tokens are hashed at rest

Store only `sha256_hex` of the 6-digit code and of the session token. The
plaintext code exists only in the email + memory; the raw token only in the
signed cookie. A `passcodes` or `sessions` table full of plaintext is the bug.

## Test DB reset must also drain Minion

`reset_db` truncates the tables **and** calls `$app->minion->reset({all=>1})`.
`minion` is a Mojolicious *helper*, not a method, so `$app->can('minion')` is
always false — detect it via `$app->renderer->get_helper('minion')`. Skip this
and stale failed jobs from earlier test files leak across runs and break any
global job-count assertion. Add each feature skill's tables to the `@TABLES`
list (e.g. `webauthn_credentials`, `stripe_events`) or its rows survive the
reset.

## SQL templates are cached in-process

`L2D::DB` caches each `sql/<group>/<name>.sql.ep` forever after first load —
fast in production, but in dev an **edit to a `.sql.ep` needs a service restart**
(`321 restart`) to take effect. Editing SQL and seeing no change is almost always
this.

## Reverse proxy: set it or live URLs are wrong

`bin/l2d` sets `MOJO_REVERSE_PROXY=1`. TLS terminates at nginx and the app
listens on loopback, so without it `req->is_secure` is false, generated URLs come
out `http://`, and the production `secure` cookie flag misbehaves. Keep it set.

## No Postmark token = logged, not sent (by design)

With `postmark_server_token` empty (dev + tests), `L2D::Email::Sender` logs
`[email:log] to=… code=…` instead of calling Postmark and returns success. That
is intended — sign-in works with zero email infra. Don't mistake the log line for
a failure; grep it for the code when testing sign-in locally.
