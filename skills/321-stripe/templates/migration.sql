-- 321-stripe skill template — billing migration pieces ; see SKILL.md
--
-- These are the billing-relevant fragments lifted from the FavSix migration.
-- The numbers below (8, 12) are FavSix's own step numbers; in your app, RENUMBER
-- each "-- N up" block to your migration file's NEXT free step number(s), in
-- order. Mojo::Pg runs each "-- N up" block once, in ascending N.
--
-- The first block assumes an `accounts` table already exists (created in an
-- earlier step) with: kind ('personal'|'team'), plan, and the two stripe_* TEXT
-- columns. If you are creating accounts fresh, fold the three billing columns
-- shown in (0) into your CREATE TABLE instead of ALTERing.


-- (0) For reference — the billing columns FavSix puts on accounts at create
--     time (NOT a migration step; merge into your accounts CREATE TABLE):
--
--     plan                   TEXT NOT NULL DEFAULT 'free',
--     billing_status         TEXT NOT NULL DEFAULT 'free',
--     stripe_customer_id     TEXT,
--     stripe_subscription_id TEXT,


-- N up   (FavSix step 8 — RENUMBER to your next step)
-- Billing: subscription state lives on the account row (1:1). trial_ends_at
-- doubles as the "trial already used" flag (once set, never cleared).
ALTER TABLE accounts ADD COLUMN trial_ends_at      TIMESTAMPTZ;
ALTER TABLE accounts ADD COLUMN current_period_end TIMESTAMPTZ;
CREATE UNIQUE INDEX accounts_stripe_customer_uidx
    ON accounts(stripe_customer_id) WHERE stripe_customer_id IS NOT NULL;

-- Webhook idempotency: each Stripe event id is recorded exactly once.
CREATE TABLE stripe_events (
    event_id    TEXT PRIMARY KEY,
    type        TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- N up   (FavSix step 12 — RENUMBER to your next step)
-- Track whether a card is on file. Set authoritatively from a subscription
-- event's default_payment_method; lets a trialing team that has already added a
-- card stop being nagged to "add a card".
ALTER TABLE accounts ADD COLUMN has_payment_method BOOLEAN NOT NULL DEFAULT false;
