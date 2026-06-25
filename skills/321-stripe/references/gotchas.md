# Gotchas

The non-obvious failures from a shipped implementation. Read before and during.

## Migrations & deploy

- **`auto_migrate` is lazy.** Mojo::Pg's `auto_migrate(1)` runs migrations on the
  **first database use**, not at boot. A fresh deploy that restarts the app has
  NOT migrated until a DB-backed request hits it - and **321's `port_check` is a
  TCP probe**, so "Deployed successfully" can be true while the new column still
  doesn't exist. Symptom: `column "…" does not exist` right after a green
  deploy, `mojo_migrations.version` one behind. Fix: hit any DB-backed route
  (`curl https://host/@anything`) to trigger it, or run it explicitly. Always
  verify the migration version, not just the deploy status.

- **Verify runtime config loading, not just `do conf`.** The secrets merge keys
  on `$ENV{MOJO_HOME}` (so it can find `conf/secrets.local.conf`). `bin/app.pl`
  must set `$ENV{MOJO_HOME} //= "$FindBin::Bin/.."` **before** loading the app;
  `hypnotoad -f bin/app.pl` runs that, so prod is fine. But a bare `do
  conf/x.conf` in a one-off script with `MOJO_HOME` unset silently **skips the
  merge** - the key looks absent. Prove the running app actually loaded the key:
  `perl bin/app.pl eval 'print app->config("stripe_secret_key") ? "ok" : "EMPTY"'`.

## Secrets & keys

- **Never `sk_`, never commit.** Use **restricted keys** (`rk_`). A key pushed to
  GitHub is auto-revoked by GitHub + Stripe secret-scanning within minutes -
  it's burned, rotate it. Keys live only in the **git-ignored**
  `conf/secrets.local.conf` (test on dev, live on prod, `chmod 600`).

- **Restricted-key scopes must cover build AND runtime.** Object creation needs
  Products/Prices/Billing Meters/Webhook Endpoints **write**; runtime needs
  Customers/Checkout Sessions/Customer portal/Meter Event Stream **write** +
  Subscriptions **read**. A missing scope `403`s mid-build with a message naming
  the scope. **Account read is not included** by default, so you cannot read
  `charges_enabled` with the runtime key - that's intentional least-privilege.

- **Stripe Organization vs account.** Keys and objects are per **account**; an
  Organization is just a container. Make sure the intended account is selected.

## Webhooks

- **`503` until the signing secret is set is CORRECT**, not a bug. With the
  secret loaded, an **unsigned** POST returns `400` ("bad signature") - that's
  the healthy "secret present" signal. `200` requires a valid signature. So a
  `503 -> 400` flip after configuring the secret proves it loaded; a signed
  probe returning `200` proves it's the **correct** secret.

- **A *test* webhook must not target the *live* app.** Test events delivered to
  the live URL fail signature checks against the live secret. The dev host is
  usually not publicly reachable, so for dev either skip the webhook (the trial
  flow writes its own state via `start_trial`, so inbound webhooks aren't needed
  to start a trial) or use `stripe listen --forward-to localhost:PORT/stripe/webhook`.

- **Process-then-record idempotency.** In the `stripe_event` task: skip if
  `event_seen` **first**, apply the change (idempotently), `record_event`
  **last**. A mid-job crash then reprocesses safely on Minion retry. An event
  whose customer matches no account is still recorded (so Stripe stops retrying
  an event you can never apply) - log it, don't fail the job.

## Subscriptions, trials & payment methods

- **A subscription stays `trialing` after a card is added.** Stripe keeps it
  `trialing` until the trial end date, then charges. So `status == trialing`
  does **not** mean "no card". Don't nag "add a card" off status alone - track
  `has_payment_method` and switch the copy. (The bug that motivated the
  `has_payment_method` column.)

- **Card-on-file: subscription vs customer default.** A Portal card-add usually
  sets BOTH the subscription's `default_payment_method` and the customer's
  `invoice_settings.default_payment_method`, but not always. Read **both** -
  `customer.subscription.created/updated` (sub-level) AND `customer.updated`
  (customer-level) - and make the flag **sticky/OR** so a "no card on this
  object" event never clears a true set by the other source. Card *removal* is
  surfaced by the `past_due` path, not by clearing the flag.

- **The thin client only does GET/POST.** It dispatches anything non-GET as POST.
  A `DELETE` routed through it becomes a POST = an *update*, not a delete - it
  returns `200` while doing nothing you intended (a "cleanup" that silently
  no-ops). For real deletes/cancels use `curl -X DELETE`. Note deleting a
  customer **cascades** to cancel its subscriptions, which is handy when the
  restricted key lacks Subscriptions-write to cancel a sub directly.

- **Metered prices reject an explicit `quantity`** in a Checkout line item -
  omit it. (Stripe meters the usage; you don't pass a seat count at checkout.)

## Dates

- **`Mojo::Date` can't parse a Postgres `TIMESTAMPTZ` string** like
  `2026-06-28 22:48:24.315315+01`. Normalise first: space -> `T`, drop the
  fractional seconds, pad a bare `+01` offset to `+01:00`. (Used by the
  trial-days-left helper for the nudge.) The app's own `to_datetime` output
  (RFC3339 `…Z`) parses fine; the raw driver format does not.

## Activation (live)

- **Objects + webhook work before activation; charging does not.** A no-card
  trial still starts pre-activation - activation (business profile + bank
  details) only governs the charge when the trial converts. Don't block the
  build on activation; do flag to the user that real revenue waits on it.
