---
name: 321-stripe
description: Use when adding Stripe billing (subscriptions, a no-card free trial, metered/per-seat usage, gating a paid feature, Customer Portal, webhooks) to a Perl Mojolicious SSR app that uses the AXS access model and deploys with 321 - especially team/workspace billing where a paid feature is locked until a team is entitled. Covers the thin REST client, webhook signature verification, the webhook-as-sole-writer billing model, the testable service seam, Minion async processing, and the operational Stripe-side setup (restricted keys, creating objects via API, per-host git-ignored secrets, Portal config, branding).
---

# Stripe billing for 321 / AXS / Mojolicious SSR apps

## Overview

Add **subscription + metered billing** to a Mojolicious SSR app: a one-click
**no-card 30-day trial**, a **paid feature gated** behind entitlement (the
worked example: private team FavSixes), **per-active-member metered** usage
billed monthly, the **Customer Portal** for self-service card management, and
**verified webhooks** as the single source of truth for billing state.

The security-critical and money-critical paths are deliberately thin and
testable. You write: a thin blocking REST client (inert without a key, so the
suite never hits the network), a webhook signature verifier, a Billing **model
that is the only writer of billing columns** (driven by verified webhooks), a
**service seam** so controllers don't hard-wire a live Stripe client, two
**Minion** tasks (process webhook events; report usage), an **entitlement
predicate** that gates the paid feature, and the UI (settings billing section,
trial nudge, locked page). `templates/` are real, shipped, tested code to port.

This skill has two halves:
- **The code** (this file + `templates/`) - port the modules, wire the helpers/
  tasks/routes, gate the feature, add the UI. TDD, one commit per step.
- **The Stripe-side setup** (`references/stripe-setup.md`) - the operational
  runbook: restricted keys, creating the Meter/Product/Price/Webhook **via the
  API**, per-host git-ignored secrets, Customer Portal config, branding,
  account activation. Do this once per environment (test, then live).

**Read `references/gotchas.md` before and during implementation** - the
non-obvious failures (auto_migrate is lazy; `trialing` never flips after a card;
`MOJO_HOME` and the conf merge; the meter-vs-customer default payment method;
restricted-key scopes; never commit a key) that otherwise cost hours or leak a
secret.

## When to use

- Adding paid subscriptions to a Mojo SSR app, especially **team/workspace**
  billing where a feature is locked until the team is on a trial or paid plan.
- A **no-card free trial** that converts via a card added later in the Portal.
- **Metered / per-seat** usage billing (Billing Meters + meter events).
- Self-service billing via the **Stripe Customer Portal**.
- Any time you need to **verify Stripe webhooks** and apply them idempotently.

**Not for:** non-Mojolicious stacks; one-off charges with no subscription;
marketplaces / Connect (out of scope); plan upgrades/downgrades or proration
(the model is one plan - extend if you need tiers); storing card data yourself
(never - the Portal + Checkout own the card).

## What it assumes (adapt these to the target app)

| AXS / 321 piece | What the skill hooks into | Adapt |
|---|---|---|
| Namespace | `<NS>::` in templates | rename to the app's (e.g. `App::`) |
| Accounts | a team/personal `accounts` row with `kind`, an owner + members RBAC | match the app's account/membership model |
| RBAC | `<NS>::Auth::Roles::can_administer_team($role)` | match the app's admin predicate |
| current_user | `$c->current_user` (id + email) | match the app's accessor |
| DB | `$self->db->query('group/name', {binds})` -> `sql/group/name.sql.ep` | match the SQL-template wrapper |
| Migrations | numbered `-- N up` blocks in `db/migration.sql` (Mojo::Pg, `auto_migrate(1)`) | bump N; update the version test |
| Async | Minion with the Pg backend (`minion->enqueue` / `add_task`) | match the app's Minion setup |
| Config | `conf/<mode>.conf` returning a hashref; an app `config` helper | add the secrets-merge block |
| Deploy | `321 go <service> dev|live`; live on a separate host | match the deploy + the per-host secrets file |
| Tests | `Test::Mojo` + a reset-db harness with a truncate list | add `stripe_events` + billing columns |

## The recipe (TDD, one commit per step)

Work test-first; the service seam means **no test ever calls Stripe**. `<NS>` =
the app's namespace. Templates referenced by name live in `templates/`.

1. **Secrets plumbing first** (`templates/conf-secrets-merge.pl`). Convert
   `conf/<mode>.conf` to `my $config = {...}; <merge>; $config`, merging a
   **git-ignored** `conf/secrets.local.conf` over it. Add that path to
   `.gitignore`, commit a `conf/secrets.local.conf.example`. Add the Stripe
   config keys as **empty** defaults (`stripe_secret_key`, `stripe_webhook_secret`,
   `stripe_price_id`, `stripe_meter`, `stripe_portal_return_url`). Restricted
   keys (`rk_`) only, **never committed**. (Gotcha: the merge keys on
   `$ENV{MOJO_HOME}`, which `bin/app.pl` must set - see gotchas.)
2. **Migration** (`templates/migration.sql`): `accounts` billing columns
   (`billing_status` default `'free'`, `stripe_customer_id`, `stripe_subscription_id`,
   `trial_ends_at`, `current_period_end`, `has_payment_method` default false), a
   `stripe_events` table (idempotency/audit), and a partial index on
   `stripe_customer_id`. Bump the migration number + its version test; add
   `stripe_events` to the test-harness truncate list.
3. **Thin REST client** (`templates/Stripe-Client.pm`): blocking Mojo::UserAgent
   over the Stripe REST API; **inert (`enabled` false) when no secret key** so
   the suite never touches the network; a `request_handler` **test seam**
   (coderef -> ($ok,$data)). Methods: create_customer, create_subscription
   (trial, no card), create_checkout_session, create_billing_portal_session,
   report_meter_event, retrieve_subscription.
4. **Webhook verify + receive** (`templates/Stripe-Webhook.pm`,
   `templates/Controller-Stripe.pm`): verifier = HMAC-SHA256 of `"<t>.<body>"`
   under the signing secret, 5-min tolerance, constant-time compare, accept any
   `v1` (rotation). Receiver: `503` when no secret, `400` bad signature,
   else **enqueue the Minion job and `200` fast** (never process inline). Add
   the `/stripe/webhook` POST route.
5. **Billing model = sole writer** (`templates/Model-Billing.pm`,
   `templates/sql/billing/*`): `is_entitled` (trialing|active|past_due),
   `gate_private` (personal accounts always pass; teams must be entitled),
   `start_trial`, `apply_subscription_state` (mirror a sub onto the account;
   COALESCE so a NULL bind preserves), `mark_canceled`, `record_event` /
   `event_seen` (idempotency), `note_payment_method` (sticky-OR card-on-file).
6. **Service + seam** (`templates/Billing-Service.pm`, `billing_service` helper
   in `templates/web-wiring.pl`): `begin_trial` (create customer + trialing
   sub, then persist via the model - **once per account**), `report_usage`
   (active-member count once per period via a meter event, idempotency key
   `<account>:<from>`). The `billing_service` app helper builds the service with
   a live client; **controller tests override the helper** to inject a stub
   `request_handler`.
7. **Minion tasks** (`templates/web-wiring.pl`): `stripe_event` =
   **process-then-record** (skip if `event_seen`; apply idempotently; record
   last - so a mid-job failure reprocesses safely). Handle
   `customer.subscription.created/updated/deleted`, `invoice.paid/
   payment_failed/upcoming`, `customer.updated`. `stripe_report_usage` calls
   `report_usage`. The webhook controller enqueues `stripe_event`.
8. **Gate the paid feature** (the `gate_private` predicate): on **create/update**
   block the save and redirect to `/@:handle/settings#billing` with a flash; on
   **view** render the locked page (`templates/ui/locked.html.ep`). Personal
   accounts bypass entirely. The feature's read query must carry `billing_status`
   (and `kind`) so the gate has its inputs.
9. **UI + billing controller** (`templates/ui/*`, `templates/Controller-Billing.pm`):
   the status-driven **settings billing section** (free/canceled -> Start trial;
   trialing -> Manage billing + trial end date, "card will be charged" once
   `has_payment_method`; active -> Manage billing; past_due -> Update payment),
   the dismissible **trial-nudge banner** (`billing_banner` helper, session-
   scoped dismiss), and the controller actions `start_trial`, `portal`,
   `dismiss_nudge`. Actions are owner/admin only; members see status text.
10. **Stripe-side setup** - follow `references/stripe-setup.md`: create a
    **restricted test key**, create Meter + Product + metered Price + Webhook
    **via the API**, write the per-host `conf/secrets.local.conf`, set
    `stripe_price_id` in the committed conf, configure the **Customer Portal**,
    set **Branding**. Then repeat in **live** mode with a live key. Verify the
    webhook flips `503 -> 400 (unsigned) -> 200 (signed)`.
11. **Verify + ship.** Full suite green (serial); deploy dev + live via 321;
    confirm the live webhook and do one end-to-end trial.

## Decisions baked into the templates

- **No-card trial, card later.** One click starts a 30-day trial with no card
  (`payment_behavior: default_incomplete`, `trial_settings.end_behavior.
  missing_payment_method: cancel`); the card is added later via the Portal.
- **Gate at the door, one-click trial.** Nothing is locked retroactively beyond
  the gate. Entitled = `trialing | active | past_due`. Personal accounts are
  always free; only teams are gated.
- **Webhooks are the only writer** of billing state, applied idempotently
  (process-then-record against `stripe_events`). The HTTP receiver only verifies
  + enqueues + acks 200; all state changes happen in the Minion worker.
- **Testable seam, never a live call in tests.** The client is inert without a
  key; the `billing_service` helper is overridden in tests to inject a stub.
- **Metered, per active member.** Billing Meter (aggregation sum) + a recurring
  metered Price tied to it; usage reported once per period.
- **Secrets never committed.** Restricted keys (`rk_`), per-host git-ignored
  `conf/secrets.local.conf`, test keys on dev / live keys on the prod host.
- **Card-on-file is sticky.** Tracked from both the subscription's and the
  customer's default payment method; never cleared by a "no card here" event
  (card removal is surfaced by the `past_due` path).

## Verify

- **Headless (the default).** Override the `billing_service` helper to return a
  service whose client has a stub `request_handler`; assert: trial action ->
  account becomes `trialing` with customer/subscription/trial_ends_at set; the
  gate blocks a free team's private create/update/view and allows an entitled
  one; webhook verify accepts a good signature and rejects bad/expired/mismatched;
  `stripe_event` is idempotent (re-deliver = no-op); the settings + nudge copy
  switches on `billing_status` and `has_payment_method`.
- **Live (once, per environment).** Unsigned `POST /stripe/webhook` -> `400`
  (secret loaded); a validly-signed event -> `200` (correct secret; sign it
  from the host where the `whsec_` lives - see the runbook). Then a real
  one-click trial: the customer + trialing subscription appear in the dashboard.

## Common mistakes

See `references/gotchas.md`. The top ones: **auto_migrate is lazy** (runs on
first DB use, not at boot - a fresh deploy hasn't migrated until a DB request
hits it); a subscription **stays `trialing` after a card is added** (don't key
"add a card" on status - track `has_payment_method`); the conf **secrets merge
needs `$ENV{MOJO_HOME}`** (set in `bin/app.pl`); **never `sk_`, never commit a
key** (GitHub + Stripe secret-scanning auto-revoke); restricted-key **scopes**
must cover both object-creation and runtime; the webhook returns **503 until the
signing secret is set** (that is correct, not a bug).
