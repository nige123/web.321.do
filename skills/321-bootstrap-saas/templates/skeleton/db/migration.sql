-- Mojo::Pg migration. Numbered "-- N up" blocks, applied in order by
-- auto_migrate(1) on first DB use. NEVER edit a shipped block - add the next
-- "-- N up". There are no "down" blocks by design.
--
-- This is the AXS identity core. Feature skills append the next blocks:
--   321-stripe   -> "-- 2 up": accounts billing columns + stripe_events table
--   321-passkeys -> "-- 3 up": webauthn_credentials + users.webauthn_user_handle
-- When you adopt one, give it the next free number and bump t/01-migration.t.

-- 1 up

-- auth identity
CREATE TABLE users (
    user_id    BIGSERIAL PRIMARY KEY,
    email      TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- single-use email sign-in passcodes. `code` is the sha256 hex of the 6-digit
-- code - the plaintext code only ever exists in the email and in memory.
CREATE TABLE passcodes (
    passcode_id BIGSERIAL PRIMARY KEY,
    email       TEXT NOT NULL,
    code        TEXT NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX passcodes_email_idx ON passcodes(email);

-- database-backed session tokens. Only the sha256 hash of the token is stored;
-- the raw token lives in the signed 'l2d_session' cookie. Server-side rows
-- make sessions revocable (sign-out, sign-out-everywhere).
CREATE TABLE sessions (
    session_id         BIGSERIAL PRIMARY KEY,
    user_id            BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    session_token_hash TEXT NOT NULL UNIQUE,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at         TIMESTAMPTZ NOT NULL,
    revoked_at         TIMESTAMPTZ
);

-- public identity: personal + team accounts share one handle namespace, one
-- membership table, one billing surface. A user has exactly one personal
-- account and may own/join many teams.
CREATE TABLE accounts (
    account_id     BIGSERIAL PRIMARY KEY,
    handle         TEXT NOT NULL UNIQUE,
    kind           TEXT NOT NULL CHECK (kind IN ('personal', 'team')),
    owner_user_id  BIGINT NOT NULL REFERENCES users(user_id),
    display_name   TEXT,
    bio            TEXT,
    avatar_url     TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX accounts_one_personal_per_user
    ON accounts(owner_user_id) WHERE kind = 'personal';

-- team membership + role (owner > admin > member). See L2D::Auth::Roles.
CREATE TABLE account_members (
    account_id BIGINT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    user_id    BIGINT NOT NULL REFERENCES users(user_id)       ON DELETE CASCADE,
    role       TEXT   NOT NULL DEFAULT 'member'
               CHECK (role IN ('owner', 'admin', 'member')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, user_id)
);
CREATE INDEX account_members_user_idx ON account_members(user_id);
